"""Tests for the LLM diarization cleanup pass (TECH-DIAR1).

The real Anthropic / local clients are exercised only by their parsing
helpers here; the end-to-end apply path injects a fake CleanupClient so
no live model is needed. Backend selection (regulated -> local, the
Apple Intelligence -> local mapping) is asserted directly.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from mp.config import Config
from mp.diarize_cleanup import (
    MERGE_MIN_SIMILARITY,
    AnthropicCleanupClient,
    EditRecord,
    LocalCleanupClient,
    SpeakerEdit,
    _apply_edits,
    _distinct_speakers,
    _effective_edits,
    _parse_edits,
    _parse_edits_from_text,
    _refuse_unsupported_merges,
    _select_cleanup_backend,
    cleanup_transcript,
)


def _write_transcript(
    tmp_path: Path,
    *,
    stem: str = "20260516-0900",
    segments: list[dict[str, Any]] | None = None,
) -> Path:
    segs = segments if segments is not None else [
        {"start": 0.0, "end": 1.0, "text": "Hi all.", "speaker": "speaker_0"},
        {"start": 1.0, "end": 2.0, "text": "Hey.", "speaker": "speaker_1"},
        {"start": 2.0, "end": 3.0, "text": "Thanks Tom.", "speaker": "speaker_0"},
        {"start": 3.0, "end": 4.0, "text": "No problem.", "speaker": "speaker_2"},
    ]
    p = tmp_path / f"{stem}.json"
    p.write_text(
        json.dumps({
            "language": "en",
            "segments": segs,
            "audio_path": str(tmp_path / f"{stem}.wav"),
            "backend": "fluidaudio",
            "finalized": True,
        }),
        encoding="utf-8",
    )
    return p


class _FakeClient:
    def __init__(self, edits: list[SpeakerEdit]) -> None:
        self._edits = edits
        self.calls = 0
        self.speakers_seen: list[list[str]] = []

    def propose_edits(self, *, window_prompt: str, speakers: list[str]) -> list[SpeakerEdit]:
        self.calls += 1
        self.speakers_seen.append(list(speakers))
        return list(self._edits)


def _backend_cfg(backend: str = "local", regulated: bool = False) -> Config:
    return Config.model_validate({
        "summarization": {
            "backend": backend,
            "local_endpoint": "http://127.0.0.1:9999",
            "local_model": "fake-model",
        },
        "modes": {"regulated_mode": regulated},
    })


# ----- End-to-end apply path (fake client) -----


def test_applies_merge_and_reattribution(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    p = _write_transcript(tmp_path)
    emitted: list[tuple[tuple, dict]] = []
    monkeypatch.setattr("mp.diarize_cleanup.events.emit",
                        lambda *a, **k: emitted.append((a, k)))

    fake = _FakeClient([
        SpeakerEdit(segment_index=3, speaker="speaker_1", kind="reattribute"),
        SpeakerEdit(segment_index=2, speaker="speaker_1", kind="merge"),
    ])
    result = cleanup_transcript(p, cfg=Config(), client=fake)

    assert fake.calls == 1
    assert fake.speakers_seen[0] == ["speaker_0", "speaker_1", "speaker_2"]
    assert result["merges_count"] == 1
    assert result["reattributions_count"] == 1

    data = json.loads(p.read_text(encoding="utf-8"))
    assert data["segments"][3]["speaker"] == "speaker_1"
    assert data["segments"][2]["speaker"] == "speaker_1"
    assert data["diarize_cleaned"] is True

    md = (tmp_path / "20260516-0900.md").read_text(encoding="utf-8")
    assert "speaker_1" in md

    ev = [k for (a, k) in emitted if a[:2] == ("pipeline", "diarize_cleanup")]
    assert ev, "expected a diarize_cleanup event"
    assert ev[0]["merges_count"] == 1
    assert ev[0]["reattributions_count"] == 1
    assert "latency_ms" in ev[0]


def test_invented_speaker_is_dropped(tmp_path: Path) -> None:
    p = _write_transcript(tmp_path)
    fake = _FakeClient([SpeakerEdit(segment_index=2, speaker="ghost", kind="reattribute")])
    result = cleanup_transcript(p, cfg=Config(), client=fake)

    assert result["merges_count"] == 0
    assert result["reattributions_count"] == 0
    data = json.loads(p.read_text(encoding="utf-8"))
    assert data["segments"][2]["speaker"] == "speaker_0"  # unchanged


def test_single_speaker_is_noop_with_no_client_call(tmp_path: Path) -> None:
    segs = [
        {"start": 0.0, "end": 1.0, "text": "Hi.", "speaker": "speaker_0"},
        {"start": 1.0, "end": 2.0, "text": "Still me.", "speaker": "speaker_0"},
    ]
    p = _write_transcript(tmp_path, segments=segs)
    fake = _FakeClient([SpeakerEdit(segment_index=0, speaker="speaker_0", kind="merge")])
    result = cleanup_transcript(p, cfg=Config(), client=fake)

    assert fake.calls == 0
    assert result["merges_count"] == 0
    assert result["reattributions_count"] == 0


# ----- Audit record (DIAR5 scope item 1) -----


def _write_embeddings(
    tmp_path: Path, mapping: dict[str, list[float]], *, stem: str = "20260516-0900"
) -> Path:
    p = tmp_path / f"{stem}.embeddings.json"
    p.write_text(
        json.dumps({"schema_version": 1, "embeddings": mapping}), encoding="utf-8"
    )
    return p


def _audit(tmp_path: Path, *, stem: str = "20260516-0900") -> dict[str, Any]:
    return json.loads(
        (tmp_path / f"{stem}.diarize_cleanup.json").read_text(encoding="utf-8")
    )


def test_audit_records_every_edit_per_segment(tmp_path: Path) -> None:
    p = _write_transcript(tmp_path)
    fake = _FakeClient([
        SpeakerEdit(segment_index=3, speaker="speaker_1", kind="reattribute"),
        SpeakerEdit(segment_index=2, speaker="speaker_1", kind="merge"),
    ])
    cleanup_transcript(p, cfg=Config(), client=fake)

    audit = _audit(tmp_path)
    assert audit["schema_version"] == 1
    assert audit["segments"] == 4
    assert audit["labels_before"] == ["speaker_0", "speaker_1", "speaker_2"]
    # speaker_2's only segment moved away, so the label is gone entirely.
    assert audit["labels_eliminated"] == ["speaker_2"]
    assert audit["labels_after"] == ["speaker_0", "speaker_1"]
    assert audit["edits"] == [
        {"segment_index": 2, "from": "speaker_0", "to": "speaker_1", "kind": "merge"},
        {"segment_index": 3, "from": "speaker_2", "to": "speaker_1",
         "kind": "reattribute"},
    ]
    assert audit["refused"] == []


def test_audit_is_written_even_when_the_pass_changes_nothing(tmp_path: Path) -> None:
    """Presence means the pass ran; only absence means it never did."""
    segs = [
        {"start": 0.0, "end": 1.0, "text": "Hi.", "speaker": "speaker_0"},
        {"start": 1.0, "end": 2.0, "text": "Still me.", "speaker": "speaker_0"},
    ]
    p = _write_transcript(tmp_path, segments=segs)
    fake = _FakeClient([SpeakerEdit(segment_index=0, speaker="speaker_0", kind="merge")])
    cleanup_transcript(p, cfg=Config(), client=fake)

    audit = _audit(tmp_path)
    assert fake.calls == 0
    assert audit["edits"] == []
    assert audit["refused"] == []
    assert audit["labels_eliminated"] == []


# ----- Voiceprint guard (DIAR5 scope item 3) -----


def test_merge_between_far_apart_voiceprints_is_refused(tmp_path: Path) -> None:
    p = _write_transcript(tmp_path)
    _write_embeddings(tmp_path, {
        "speaker_0": [1.0, 0.0, 0.0],
        "speaker_1": [1.0, 0.0, 0.0],
        "speaker_2": [0.0, 1.0, 0.0],  # orthogonal to speaker_1: a different voice
    })
    # Segment 3 is speaker_2's only segment, so this empties the label.
    fake = _FakeClient([SpeakerEdit(segment_index=3, speaker="speaker_1", kind="merge")])
    result = cleanup_transcript(p, cfg=Config(), client=fake)

    assert result["merges_count"] == 0
    assert result["refusals_count"] == 1
    data = json.loads(p.read_text(encoding="utf-8"))
    assert data["segments"][3]["speaker"] == "speaker_2", "the label must survive"

    audit = _audit(tmp_path)
    assert audit["edits"] == []
    assert audit["refused"] == [{
        "segment_index": 3, "from": "speaker_2", "to": "speaker_1",
        "kind": "merge", "similarity": 0.0, "reason": "voiceprint_distance",
    }]
    assert audit["labels_eliminated"] == []


def test_merge_between_close_voiceprints_is_allowed(tmp_path: Path) -> None:
    p = _write_transcript(tmp_path)
    _write_embeddings(tmp_path, {
        "speaker_0": [1.0, 0.0, 0.0],
        "speaker_1": [1.0, 0.0, 0.0],
        "speaker_2": [1.0, 0.0, 0.0],  # identical: one voice the diarizer split
    })
    fake = _FakeClient([SpeakerEdit(segment_index=3, speaker="speaker_1", kind="merge")])
    result = cleanup_transcript(p, cfg=Config(), client=fake)

    assert result["merges_count"] == 1
    assert result["refusals_count"] == 0
    audit = _audit(tmp_path)
    assert audit["edits"][0]["similarity"] == 1.0
    assert audit["labels_eliminated"] == ["speaker_2"]


def test_reattribution_that_leaves_its_label_alive_is_not_guarded(tmp_path: Path) -> None:
    """Two different people is what a real reattribution looks like, so their
    distance carries no signal and must not veto the edit."""
    p = _write_transcript(tmp_path)
    _write_embeddings(tmp_path, {
        "speaker_0": [1.0, 0.0, 0.0],
        "speaker_1": [0.0, 1.0, 0.0],
        "speaker_2": [0.0, 0.0, 1.0],
    })
    # speaker_0 holds segments 0 and 2, so moving one leaves the label alive.
    fake = _FakeClient([
        SpeakerEdit(segment_index=0, speaker="speaker_1", kind="reattribute")
    ])
    result = cleanup_transcript(p, cfg=Config(), client=fake)

    assert result["reattributions_count"] == 1
    assert result["refusals_count"] == 0
    data = json.loads(p.read_text(encoding="utf-8"))
    assert data["segments"][0]["speaker"] == "speaker_1"


def test_guard_is_fail_open_when_a_label_has_no_voiceprint(tmp_path: Path) -> None:
    p = _write_transcript(tmp_path)  # no embeddings sidecar at all
    fake = _FakeClient([SpeakerEdit(segment_index=3, speaker="speaker_1", kind="merge")])
    result = cleanup_transcript(p, cfg=Config(), client=fake)

    assert result["merges_count"] == 1
    assert result["refusals_count"] == 0
    # No similarity key at all, so "allowed because close" cannot be confused
    # with "allowed because unmeasurable".
    assert "similarity" not in _audit(tmp_path)["edits"][0]


def test_guard_ignores_the_models_self_reported_kind(tmp_path: Path) -> None:
    """`kind` is the model's own word and nothing validates it, so the guard
    reads what the edit does to the labels instead."""
    segs = [{"speaker": "A"}, {"speaker": "B"}]
    embeddings = {"A": [1.0, 0.0], "B": [0.0, 1.0]}
    proposed = _effective_edits(segs, {1: SpeakerEdit(1, "A", "reattribute")}, ["A", "B"])
    allowed, refused = _refuse_unsupported_merges(segs, proposed, embeddings)

    assert allowed == []
    assert [(e.kind, e.reason) for e in refused] == [
        ("reattribute", "voiceprint_distance")
    ]


def test_guard_evaluates_each_destination_separately(tmp_path: Path) -> None:
    """A label emptied into two destinations is refused only where the
    voiceprints disagree; the other half still lands."""
    segs = [{"speaker": "A"}, {"speaker": "A"}, {"speaker": "B"}, {"speaker": "C"}]
    embeddings = {"A": [1.0, 0.0], "B": [1.0, 0.0], "C": [0.0, 1.0]}
    proposed = _effective_edits(
        segs,
        {0: SpeakerEdit(0, "B", "merge"), 1: SpeakerEdit(1, "C", "merge")},
        ["A", "B", "C"],
    )
    allowed, refused = _refuse_unsupported_merges(segs, proposed, embeddings)

    assert [(e.segment_index, e.to_speaker) for e in allowed] == [(0, "B")]
    assert [(e.segment_index, e.to_speaker) for e in refused] == [(1, "C")]


def test_merge_threshold_is_the_roster_same_person_bar() -> None:
    from mp.roster import MATCH_MIN

    assert MERGE_MIN_SIMILARITY == MATCH_MIN


def test_edit_record_omits_absent_similarity_and_reason() -> None:
    assert EditRecord(3, "A", "B", "merge").as_json() == {
        "segment_index": 3, "from": "A", "to": "B", "kind": "merge",
    }


# ----- Unit helpers -----


def test_distinct_speakers_excludes_unknown_and_empty() -> None:
    segs = [
        {"speaker": "speaker_0"},
        {"speaker": "Speaker?"},
        {"speaker": None},
        {"speaker": "speaker_1"},
        {"speaker": "speaker_0"},
    ]
    assert _distinct_speakers(segs) == ["speaker_0", "speaker_1"]


def test_effective_edits_skips_out_of_range_invented_and_noop() -> None:
    segs = [{"speaker": "speaker_0"}, {"speaker": "speaker_1"}]
    edits = {
        0: SpeakerEdit(0, "speaker_0", "merge"),        # no-op (same label)
        1: SpeakerEdit(1, "speaker_0", "reattribute"),  # kept
        9: SpeakerEdit(9, "speaker_0", "merge"),        # out of range
    }
    kept = _effective_edits(segs, edits, ["speaker_0", "speaker_1"])
    assert [(e.segment_index, e.from_speaker, e.to_speaker) for e in kept] == [
        (1, "speaker_1", "speaker_0")
    ]
    assert segs[1]["speaker"] == "speaker_1", "_effective_edits must not mutate"

    _apply_edits(segs, kept)
    assert segs[1]["speaker"] == "speaker_0"


def test_parse_edits_coerces_bad_kind_and_drops_malformed() -> None:
    obj = {
        "edits": [
            {"segment_index": 1, "speaker": "speaker_0", "kind": "merge"},
            {"segment_index": 2, "speaker": "speaker_1", "kind": "bogus"},
            {"speaker": "speaker_0"},          # missing index
            {"segment_index": 3, "speaker": ""},  # empty speaker
        ]
    }
    edits = _parse_edits(obj)
    assert len(edits) == 2
    assert edits[0] == SpeakerEdit(1, "speaker_0", "merge")
    assert edits[1].kind == "reattribute"  # coerced from "bogus"


def test_parse_edits_from_text_recovers_embedded_json() -> None:
    text = 'sure! {"edits":[{"segment_index":0,"speaker":"speaker_0","kind":"merge"}]} done'
    assert _parse_edits_from_text(text) == [SpeakerEdit(0, "speaker_0", "merge")]
    assert _parse_edits_from_text("no json at all") == []


# ----- Backend selection -----


def test_select_local_backend_returns_local_client() -> None:
    assert isinstance(_select_cleanup_backend(_backend_cfg("local")), LocalCleanupClient)


def test_regulated_mode_forces_local(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    client = _select_cleanup_backend(_backend_cfg("anthropic", regulated=True))
    assert isinstance(client, LocalCleanupClient)


def test_apple_intelligence_backend_maps_to_local() -> None:
    cfg = _backend_cfg("local")
    # Set post-construction so this test does not depend on the backend
    # Literal having grown the apple_intelligence value yet (TECH-SUM1-APPLE).
    cfg.summarization.backend = "apple_intelligence"  # type: ignore[assignment]
    assert isinstance(_select_cleanup_backend(cfg), LocalCleanupClient)


def test_auto_uses_anthropic_when_key_present(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    assert isinstance(_select_cleanup_backend(_backend_cfg("auto")), AnthropicCleanupClient)


def test_auto_falls_back_to_local_without_key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    assert isinstance(_select_cleanup_backend(_backend_cfg("auto")), LocalCleanupClient)


def test_unknown_backend_raises() -> None:
    cfg = _backend_cfg("local")
    cfg.summarization.backend = "made-up"  # type: ignore[assignment]
    with pytest.raises(ValueError):
        _select_cleanup_backend(cfg)
