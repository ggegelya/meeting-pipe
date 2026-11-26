"""SEC22 item 5: every Python reader of `<stem>.embeddings.json` over the vectors-free
shape the daemon's audio retention leaves behind when it drops a meeting's audio.

The daemon (`AudioRetentionSweep`, Swift) is the writer; the shape is pinned by the
hand-maintained `embeddings-voiceprints-dropped-golden.json`, which the Swift suite
checks the writer against. Here each case's `after` is fed to the readers: label keys
present, every vector null. A reader must find nothing to compare and nothing to
enroll, without crashing and without matching on a missing voice.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from mp import diarize_cleanup
from mp import merge_meetings as mm
from mp.roster import EMBEDDING_DIM, RosterStore
from mp.roster_cmd import main as roster_main

_REPO = Path(__file__).resolve().parents[2]
_FIXTURE = _REPO / "daemon" / "Tests" / "MeetingPipeTests" / "Fixtures" / "embeddings-voiceprints-dropped-golden.json"
_CASES = json.loads(_FIXTURE.read_text(encoding="utf-8"))["cases"]


def _case_ids() -> list[str]:
    return [c["name"] for c in _CASES]


def _emb(seed: float = 1.0) -> list[float]:
    v = [0.0] * EMBEDDING_DIM
    v[0] = seed
    return v


def _meeting(tmp_path: Path, labels: list[str], stem: str = "20260601-0900") -> Path:
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    segments = [{"start": float(i), "end": float(i) + 1, "text": "t", "speaker": lbl} for i, lbl in enumerate(labels)]
    (tmp_path / f"{stem}.json").write_text(
        json.dumps({"language": "en", "segments": segments, "finalized": True}), encoding="utf-8"
    )
    (tmp_path / f"{stem}.md").write_text("# transcript\n", encoding="utf-8")
    return wav


def _write_embeddings(wav: Path, payload: dict) -> Path:
    path = wav.with_name(f"{wav.stem}.embeddings.json")
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def test_the_fixture_is_not_vacuous():
    assert len(_CASES) >= 3
    for case in _CASES:
        assert set(case["after"]["embeddings"]) == set(case["labels"])
        assert all(v is None for v in case["after"]["embeddings"].values())


@pytest.mark.parametrize("case", _CASES, ids=_case_ids())
def test_cleanup_voiceprint_check_finds_nothing_to_compare(tmp_path, case):
    wav = _meeting(tmp_path, case["labels"])
    _write_embeddings(wav, case["after"])
    assert diarize_cleanup._load_embeddings(wav.with_suffix(".json")) == {}


@pytest.mark.parametrize("case", _CASES, ids=_case_ids())
def test_enroll_refuses_every_label_and_leaves_the_roster_alone(tmp_path, monkeypatch, capsys, case):
    roster_path = tmp_path / "roster.json"
    monkeypatch.setattr("mp.roster.ROSTER_PATH", roster_path)
    wav = _meeting(tmp_path, case["labels"])
    _write_embeddings(wav, case["after"])
    for label in case["labels"]:
        assert roster_main(["enroll", "--name", "Alice", "--label", label, "--wav", str(wav), "--no-relabel"]) == 2
        out = capsys.readouterr().out
        assert "no voice vector" in out and "retention" in out, out
    assert not roster_path.exists(), "a refused enroll creates no roster"


def test_unenroll_still_takes_back_this_meetings_sample_by_provenance(tmp_path, monkeypatch):
    """Named before the drop, undone after it: the vector is gone, the provenance is not."""
    monkeypatch.setattr("mp.roster.ROSTER_PATH", tmp_path / "roster.json")
    wav = _meeting(tmp_path, ["THEM-A"])
    _write_embeddings(wav, {"schema_version": 2, "embeddings": {"THEM-A": _emb()}})
    assert roster_main(["enroll", "--name", "Alice", "--label", "THEM-A", "--wav", str(wav), "--no-relabel"]) == 0
    _write_embeddings(wav, {"schema_version": 2, "embeddings": {"THEM-A": None}})
    assert roster_main(["unenroll", "--name", "Alice", "--label", "THEM-A", "--wav", str(wav)]) == 0
    assert RosterStore(tmp_path / "roster.json").names() == []


def test_forget_purge_strips_a_dropped_label_too(tmp_path):
    case = next(c for c in _CASES if "Rana" in c["labels"])
    wav = _meeting(tmp_path, case["labels"])
    path = _write_embeddings(wav, case["after"])
    assert RosterStore.forget_embeddings("Rana", tmp_path) == 1
    data = json.loads(path.read_text(encoding="utf-8"))
    assert "Rana" not in data["embeddings"]
    assert "near_misses" not in data  # its only entry pointed at Rana


@pytest.mark.parametrize("case", _CASES, ids=_case_ids())
def test_merge_reserves_the_labels_and_carries_no_missing_vector(tmp_path, case):
    primary = _meeting(tmp_path, ["Me"], stem="20260101-0900")
    frag = _meeting(tmp_path, case["labels"], stem="20260101-0930")
    _write_embeddings(frag, case["after"])
    assert mm._primary_reserved_labels(frag) >= set(case["labels"])

    def structured(wav: Path) -> dict:
        return json.loads(wav.with_suffix(".json").read_text(encoding="utf-8"))

    mm._carry_sidecars(primary, [frag], [structured(primary), structured(frag)], [10.0, 20.0])
    assert not primary.with_suffix(".embeddings.json").exists(), "nothing to carry, nothing written"


def _valid1_check():
    import importlib.util

    spec = importlib.util.spec_from_file_location("valid1_check", _REPO / "scripts" / "valid1_check.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_the_owner_cluster_report_skips_a_dropped_meeting_without_crashing(tmp_path):
    """`scripts/valid1_check.py --owner-cluster` is the one reader that averages vectors: a
    null must be skipped, never averaged, and the meeting (no audio) is never re-selected."""
    vc = _valid1_check()
    case = next(c for c in _CASES if "1" in c["labels"])
    wav = _meeting(tmp_path, case["labels"])
    _write_embeddings(wav, case["after"])
    wav.unlink()  # the drop took the audio
    inputs = vc.load_owner_inputs(tmp_path)
    assert [i["stem"] for i in inputs] == [wav.stem]
    assert vc.owner_reference(inputs, "1", None) is None, "no vector to average"
    assert vc.reselect_placement(inputs[0], "1", None) is None
    report = vc.build_owner_cluster_report(inputs, [1.0, 0.0], lambda it: vc.current_placement(it, "1"))
    assert report["wrong_owner"]["count"] == 0 and report["them_matching"]["count"] == 0
