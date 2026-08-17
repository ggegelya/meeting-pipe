"""AUTO3 leg 0: the visibility gate, and the two shipped commands it fixes.

The gate is the security-carrying half of AUTO3, so these run with no `mcp`
package, no index, and no engine: everything here is files on disk and a pure
function over them.
"""
from __future__ import annotations

import json
from datetime import date
from pathlib import Path

from mp import actions as actions_mod
from mp import digest, embed_index, visibility
from mp.config import Config


def _meeting(root: Path, stem: str, *, text: str = "hello", meta: dict | None = None,
             decisions: list[str] | None = None, actions: list[dict] | None = None) -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / f"{stem}.md").write_text(f"# {stem}\n\n{text}\n", encoding="utf-8")
    (root / f"{stem}.summary.json").write_text(json.dumps({
        "title": f"Meeting {stem}",
        "summary": [text],
        "decisions": decisions or [],
        "actions": actions or [],
        "questions": [],
        "attendees": [],
        "detected_language": "en",
    }), encoding="utf-8")
    (root / f"{stem}.summary.md").write_text(f"# {stem}\n\n{text}\n", encoding="utf-8")
    if meta is not None:
        (root / f"{stem}.meta.json").write_text(json.dumps(meta), encoding="utf-8")


def _fixture_library(root: Path) -> None:
    """The four-meeting library AUTO3's acceptance names: one NDA, one with no
    sidecar, two normal."""
    _meeting(root, "20260101-100000", text="alpha budget decision",
             meta={"schema_version": 1, "workflow_name": "Standup"})
    _meeting(root, "20260102-100000", text="beta hiring decision",
             meta={"schema_version": 1, "workflow_name": "Standup"})
    _meeting(root, "20260103-100000", text="secret acquisition terms",
             meta={"schema_version": 1, "workflow_name": "Client work",
                   "workflow_nda_mode": True})
    _meeting(root, "20260104-100000", text="unknown provenance notes")  # no sidecar


# ----- the gate itself -----


def test_nda_stem_is_withheld(tmp_path: Path) -> None:
    _fixture_library(tmp_path)
    assert visibility.withheld_reason(tmp_path, "20260103-100000") == visibility.WITHHELD_NDA
    assert not visibility.is_visible(tmp_path, "20260103-100000")


def test_stem_with_no_sidecar_is_withheld(tmp_path: Path) -> None:
    _fixture_library(tmp_path)
    assert visibility.withheld_reason(tmp_path, "20260104-100000") == visibility.WITHHELD_NO_SIDECAR
    assert not visibility.is_visible(tmp_path, "20260104-100000")


def test_normal_stem_is_visible(tmp_path: Path) -> None:
    _fixture_library(tmp_path)
    assert visibility.withheld_reason(tmp_path, "20260101-100000") is None
    assert visibility.is_visible(tmp_path, "20260101-100000")


def test_regulated_sidecar_is_withheld(tmp_path: Path) -> None:
    """TECH-DSN6 persists `regulated_mode` into the sidecar at record time and
    `workflow.apply_overrides` folds it in fail-closed; the gate reads the same
    evidence the same way."""
    _meeting(tmp_path, "20260105-100000", meta={"schema_version": 1, "regulated_mode": True})
    assert visibility.withheld_reason(tmp_path, "20260105-100000") == visibility.WITHHELD_REGULATED


def test_malformed_sidecar_reads_as_no_sidecar(tmp_path: Path) -> None:
    """A policy gate must not be openable by corrupting a file."""
    _meeting(tmp_path, "20260106-100000", meta={"schema_version": 1, "workflow_name": "Standup"})
    (tmp_path / "20260106-100000.meta.json").write_text("{not json", encoding="utf-8")
    assert visibility.withheld_reason(tmp_path, "20260106-100000") == visibility.WITHHELD_NO_SIDECAR


def test_library_visibility_counts_and_reasons(tmp_path: Path) -> None:
    _fixture_library(tmp_path)
    snapshot = visibility.library_visibility(tmp_path)
    assert snapshot.visible_count == 2
    assert snapshot.withheld_count == 2
    assert snapshot.reason_counts() == {"nda": 1, "no_sidecar": 1}
    assert snapshot.visible_set == {"20260101-100000", "20260102-100000"}
    assert snapshot.to_json() == {
        "visible": 2, "withheld": 2,
        "withheld_by_reason": {"nda": 1, "no_sidecar": 1},
    }


def test_unknown_stem_is_withheld_like_an_nda_one(tmp_path: Path) -> None:
    """Leg 2 needs "withheld" and "never existed" to be one answer, and this is
    where that starts: neither has a sidecar, so neither is visible."""
    _fixture_library(tmp_path)
    assert not visibility.is_visible(tmp_path, "20991231-235959")


# ----- the index -----


def test_chunk_library_produces_no_chunk_from_a_withheld_stem(tmp_path: Path) -> None:
    _fixture_library(tmp_path)
    allow = visibility.visible_stems(tmp_path)
    chunks = embed_index.chunk_library(tmp_path, allow_stems=allow)
    assert {c.stem for c in chunks} == allow
    joined = "\n".join(c.text for c in chunks)
    assert "secret acquisition terms" not in joined
    assert "unknown provenance notes" not in joined


def test_chunk_library_without_a_gate_keeps_everything(tmp_path: Path) -> None:
    """The gate is opt-in per caller, so a surface with no egress (a from-scratch
    build in a test, a future local-only consumer) is unchanged."""
    _fixture_library(tmp_path)
    assert len({c.stem for c in embed_index.chunk_library(tmp_path)}) == 4


def test_a_gated_refresh_drops_a_previously_indexed_withheld_stem(tmp_path: Path) -> None:
    """An index built before the gate existed un-indexes withheld meetings on the
    first gated run, rather than needing a migration."""
    lib, idx = tmp_path / "lib", tmp_path / "idx"
    _fixture_library(lib)
    ungated = embed_index.load_or_build(lib, idx, embed_index.HashingEmbedder(dim=64))
    assert len({c.stem for c in ungated.chunks}) == 4

    allow = visibility.visible_stems(lib)
    gated = embed_index.load_or_build(
        lib, idx, embed_index.HashingEmbedder(dim=64), allow_stems=allow
    )
    assert {c.stem for c in gated.chunks} == allow
    assert gated.vectors.shape[0] == len(gated.chunks)
    reloaded = embed_index.EmbeddingIndex.load(idx, embed_index.HashingEmbedder(dim=64))
    assert {c.stem for c in reloaded.chunks} == allow


def test_gated_search_never_ranks_a_withheld_stem(tmp_path: Path) -> None:
    lib, idx = tmp_path / "lib", tmp_path / "idx"
    _fixture_library(lib)
    index = embed_index.load_or_build(
        lib, idx, embed_index.HashingEmbedder(dim=256),
        allow_stems=visibility.visible_stems(lib),
    )
    hits = index.search("secret acquisition terms", k=10)
    assert hits, "the gated index should still answer, just not with withheld text"
    assert all(h.chunk.stem != "20260103-100000" for h in hits)


# ----- `mp ask`'s retrieval set -----


def test_ask_builds_its_index_under_the_gate(tmp_path: Path, monkeypatch) -> None:
    """`mp ask` is library-wide, so it anchors on no meeting and per-meeting NDA
    can never clamp it. Pinned with `regulated_mode = false`, which is the
    configuration the hole was found under."""
    from mp import ask

    lib = tmp_path / "lib"
    _fixture_library(lib)
    cfg = Config()
    assert cfg.modes.regulated_mode is False
    monkeypatch.setattr(ask.entry, "prepare", lambda *a, **k: cfg)
    monkeypatch.setattr(ask.embed_index, "default_embedder",
                        lambda *a, **k: embed_index.HashingEmbedder(dim=128))

    seen: dict = {}
    real = embed_index.load_or_build

    def _spy(root, index_dir, embedder=None, **kwargs):
        seen["allow"] = kwargs.get("allow_stems")
        return real(root, index_dir, embedder, **kwargs)

    monkeypatch.setattr(ask.embed_index, "load_or_build", _spy)
    monkeypatch.setattr(ask, "answer_question",
                        lambda *a, **k: ask.Answer(question="q", answer="a"))

    rc = ask.main(["--dir", str(lib), "--index-dir", str(tmp_path / "idx"), "--json", "what"])
    assert rc == 0
    assert seen["allow"] == {"20260101-100000", "20260102-100000"}


# ----- `mp digest`'s facts -----


def test_digest_facts_exclude_withheld_meetings(tmp_path: Path, monkeypatch) -> None:
    lib = tmp_path / "lib"
    today = date(2026, 1, 5)
    _meeting(lib, "20260101-100000", decisions=["ship the visible thing"],
             actions=[{"task": "visible task", "owner": "A", "due": "2026-01-02",
                       "confidence": "high", "resolved": False}],
             meta={"schema_version": 1, "workflow_name": "Standup"})
    _meeting(lib, "20260103-100000", decisions=["sign the secret contract"],
             actions=[{"task": "secret task", "owner": "B", "due": "2026-01-02",
                       "confidence": "high", "resolved": False}],
             meta={"schema_version": 1, "workflow_name": "Client work",
                   "workflow_nda_mode": True})
    _meeting(lib, "20260104-100000", decisions=["decide the unknown thing"],
             actions=[{"task": "unknown task", "owner": "C", "due": "2026-01-02",
                       "confidence": "high", "resolved": False}])

    cfg = Config()
    assert cfg.modes.regulated_mode is False
    narrated: dict = {}

    def _narrate(_cfg, scope, decisions, _today, _since):
        narrated["scope"] = scope
        narrated["decisions"] = decisions
        return (["bullet"], "fake")

    monkeypatch.setattr(digest, "narrate", _narrate)
    result = digest.generate(cfg, lib, since_days=7, today=today)

    tasks = {a.task for a in result.summary.actions}
    assert tasks == {"visible task"}
    assert result.summary.decisions == ["ship the visible thing (Meeting 20260101-100000)"]
    # The narration prompt is built from these, so the gate has to hold before
    # they are assembled, not after.
    assert all("secret" not in d.text for d in narrated["decisions"])
    assert narrated["scope"].library_total == 1


def test_actions_discover_is_ungated_by_default(tmp_path: Path) -> None:
    """`mp actions` prints to the owner's own terminal and reaches no engine, so
    it is deliberately not gated; the gate is a parameter its egressing callers
    pass."""
    _fixture_library(tmp_path)
    _meeting(tmp_path, "20260107-100000",
             actions=[{"task": "t", "owner": "A", "confidence": "high", "resolved": False}],
             meta={"schema_version": 1, "workflow_name": "Standup"})
    assert actions_mod.discover(tmp_path)
    gated = actions_mod.discover(tmp_path, allow_stems={"20260101-100000"})
    assert all(a.stem == "20260101-100000" for a in gated)
