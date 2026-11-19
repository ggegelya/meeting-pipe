"""PIPE29: every reader that `.get`s a per-meeting or config JSON file treats a
file holding valid JSON that is not an object as absent, instead of crashing.

One case per reader that crashed on `main` (the "unguarded" readers of the
spec), plus pins for the meta-sidecar consumers SEC25 already made safe.
"""
from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path

import pytest

from mp import corrections, doctor, storage, visibility
from mp.actions import discover
from mp.config import Config, Recording
from mp.schemas import MeetingSummary

STEM = "20260428-120000"


def _summary_json(root: Path, stem: str = STEM, **meta: object) -> Path:
    path = root / f"{stem}.summary.json"
    path.write_text(MeetingSummary(
        title="Sync", summary=["s"], decisions=["Ship it."], detected_language="en",
    ).model_dump_json())
    if meta:
        (root / f"{stem}.meta.json").write_text(json.dumps(meta))
    return path


def test_the_run_sidecar_reader_treats_a_list_as_absent(tmp_path: Path) -> None:
    path = tmp_path / f"{STEM}.run.json"
    path.write_text("[1]")
    assert corrections.read_run_sidecar(path) is None


def test_doctor_reads_a_list_shaped_backup_marker_as_no_backup(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """`data["at"]` on a list raised TypeError, outside doctor's catch."""
    marker = storage.backup_marker(tmp_path)
    marker.parent.mkdir(parents=True)
    marker.write_text("[1]")
    doctor.check_last_backup(home=tmp_path, now=datetime(2026, 11, 18, tzinfo=UTC))
    assert "no `mp backup` has run" in capsys.readouterr().out


def test_the_training_corrections_loop_skips_a_list(tmp_path: Path) -> None:
    from mp import train_adapter

    (tmp_path / "bad.json").write_text("[1]")
    assert train_adapter.build_pairs(tmp_path, read_transcript=lambda _p: "t") == []


def test_diarize_cleanup_reads_a_list_shaped_embeddings_sidecar_as_no_evidence(
    tmp_path: Path,
) -> None:
    from mp import diarize_cleanup

    transcript = tmp_path / f"{STEM}.json"
    (tmp_path / f"{STEM}.embeddings.json").write_text('"x"')
    assert diarize_cleanup._load_embeddings(transcript) == {}


def test_roster_enroll_reports_a_list_shaped_embeddings_sidecar_instead_of_crashing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    from mp import roster_cmd

    monkeypatch.setenv("HOME", str(tmp_path))
    wav = tmp_path / f"{STEM}.wav"
    wav.write_bytes(b"RIFF")
    (tmp_path / f"{STEM}.embeddings.json").write_text("[1]")
    monkeypatch.setattr("mp.entry.prepare", lambda *a, **k: Config())
    assert roster_cmd.main(["enroll", "--name", "Ann", "--label", "S1", "--wav", str(wav)]) == 2
    assert "no embeddings sidecar" in capsys.readouterr().out


def test_a_list_shaped_meta_sidecar_is_withheld_and_the_rest_stay_visible(tmp_path: Path) -> None:
    """Pinned rather than red: SEC25's `load_meta` already reads it as unreadable."""
    _summary_json(tmp_path, "20260428-120000", workflow_name="Weekly")
    _summary_json(tmp_path, "20260429-120000")
    (tmp_path / "20260429-120000.meta.json").write_text("[1]")

    assert visibility.visible_stems(tmp_path) == {"20260428-120000"}
    assert visibility.withheld_reason(tmp_path, "20260429-120000") == visibility.WITHHELD_NO_SIDECAR


def test_actions_discover_skips_nothing_over_a_list_shaped_meta_sidecar(tmp_path: Path) -> None:
    _summary_json(tmp_path, STEM)
    (tmp_path / f"{STEM}.meta.json").write_text("[1]")
    discover(tmp_path)  # pinned: raised AttributeError before SEC25


@pytest.mark.parametrize("bad", ["[1]", "null"])
def test_prior_meeting_context_skips_a_bad_prior_sidecar(tmp_path: Path, bad: str) -> None:
    from mp.summarize import _prior_meeting_context

    _summary_json(tmp_path, "20260401-100000")
    (tmp_path / "20260401-100000.meta.json").write_text(bad)
    md = tmp_path / "20260408-100000.md"
    md.write_text("# Transcript\n")
    (tmp_path / "20260408-100000.meta.json").write_text(json.dumps({"workflow_id": "wf"}))
    assert _prior_meeting_context(md, Config(recording=Recording(output_dir=tmp_path))) is None


def test_the_corrections_corpus_skips_a_list_shaped_record(tmp_path: Path) -> None:
    (tmp_path / "bad.json").write_text("[1]")
    (tmp_path / "good.json").write_text(json.dumps({"verdict": "good", "stem": STEM}))
    records = corrections.load_records(tmp_path)
    assert [r.verdict for r in records] == ["good"]
