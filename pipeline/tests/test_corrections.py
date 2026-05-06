"""Tests for the correction loop helpers + ``mp corrections-stats``.

Coverage targets:

* ``write_run_sidecar`` round-trips through ``read_run_sidecar``.
* ``load_records`` tolerates missing optional fields, malformed files,
  and absent run sidecars.
* ``aggregate`` counts verdicts/backends/models correctly and applies
  the Phase 3 readiness gate (count >= 20 AND chars >= 200_000).
* The Markdown report and JSON output of the CLI shape.
* Per-field edit distance is 0 on identical fields, ~1 on full
  rewrites, and is only computed for ``edited`` verdicts.
"""
from __future__ import annotations

import io
import json
from contextlib import redirect_stdout
from pathlib import Path

import pytest

from mp import corrections


def _good_summary() -> dict:
    return {
        "title": "Original",
        "summary": ["one", "two"],
        "decisions": ["decided X"],
        "actions": [
            {"task": "send email", "owner": "alice", "due": None, "confidence": "high"}
        ],
        "questions": ["who owns Y?"],
        "attendees": ["alice", "bob"],
        "detected_language": "en",
    }


def _write_correction(
    dir_: Path,
    stem: str,
    *,
    verdict: str,
    backend: str = "local",
    model: str = "mlx-community/Qwen2.5-3B-Instruct-4bit",
    transcript_chars: int = 12_000,
    corrected: dict | None = None,
) -> Path:
    transcript_path = dir_ / "raw" / f"{stem}.md"
    transcript_path.parent.mkdir(parents=True, exist_ok=True)
    transcript_path.write_text("x" * transcript_chars, encoding="utf-8")

    # Drop a matching run sidecar so the stats path picks up the
    # transcript_chars without needing to stat the (potentially absent)
    # transcript file.
    corrections.write_run_sidecar(
        recordings_dir=transcript_path.parent,
        stem=stem,
        transcript_path=transcript_path,
        transcript_chars=transcript_chars,
        summary_json_path=transcript_path.with_suffix(".summary.json"),
        backend=backend,
        model=model,
    )

    out_dir = dir_ / "corrections"
    out_dir.mkdir(parents=True, exist_ok=True)
    payload: dict = {
        "transcript_path": str(transcript_path),
        "summary_json_path": str(transcript_path.with_suffix(".summary.json")),
        "model_id": model,
        "backend": backend,
        "ts": "2026-05-08T14:33:00Z",
        "verdict": verdict,
        "original_summary": _good_summary(),
    }
    if verdict == "edited":
        payload["corrected_summary"] = corrected or _good_summary()
    out = out_dir / f"{stem}.json"
    out.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return out


# -------- run sidecar -------------------------------------------------------


def test_write_run_sidecar_roundtrip(tmp_path: Path):
    transcript = tmp_path / "20260508.md"
    transcript.write_text("hello", encoding="utf-8")
    summary_json = tmp_path / "20260508.summary.json"

    out = corrections.write_run_sidecar(
        recordings_dir=tmp_path,
        stem="20260508",
        transcript_path=transcript,
        transcript_chars=42,
        summary_json_path=summary_json,
        backend="anthropic",
        model="claude-sonnet-4-6",
        ts="2026-05-08T14:33:00Z",
    )
    assert out == tmp_path / "20260508.run.json"
    data = corrections.read_run_sidecar(out)
    assert data == {
        "stem": "20260508",
        "transcript_path": str(transcript),
        "transcript_chars": 42,
        "summary_json_path": str(summary_json),
        "backend": "anthropic",
        "model": "claude-sonnet-4-6",
        "ts": "2026-05-08T14:33:00Z",
    }


def test_read_run_sidecar_returns_none_on_missing(tmp_path: Path):
    assert corrections.read_run_sidecar(tmp_path / "nope.run.json") is None


def test_read_run_sidecar_returns_none_on_garbage(tmp_path: Path):
    bad = tmp_path / "x.run.json"
    bad.write_text("not json", encoding="utf-8")
    assert corrections.read_run_sidecar(bad) is None


# -------- load_records ------------------------------------------------------


def test_load_records_missing_dir_is_empty(tmp_path: Path):
    assert corrections.load_records(tmp_path / "absent") == []


def test_load_records_skips_unparseable(tmp_path: Path, caplog):
    cdir = tmp_path / "corrections"
    cdir.mkdir()
    (cdir / "a.json").write_text("not json", encoding="utf-8")
    _write_correction(tmp_path, "ok", verdict="good")
    records = corrections.load_records(cdir)
    assert len(records) == 1
    assert records[0].verdict == "good"


def test_load_records_skips_unknown_verdict(tmp_path: Path):
    cdir = tmp_path / "corrections"
    cdir.mkdir()
    (cdir / "garbage.json").write_text(
        json.dumps({"verdict": "weird"}), encoding="utf-8"
    )
    assert corrections.load_records(cdir) == []


def test_load_records_resolves_chars_from_run_sidecar(tmp_path: Path):
    _write_correction(tmp_path, "abc", verdict="good", transcript_chars=8_000)
    records = corrections.load_records(tmp_path / "corrections")
    assert records[0].transcript_chars == 8_000


# -------- edit distance ----------------------------------------------------


def test_edit_distance_identical_summary_is_zero(tmp_path: Path):
    _write_correction(
        tmp_path, "no-edit", verdict="edited", corrected=_good_summary()
    )
    rec = corrections.load_records(tmp_path / "corrections")[0]
    assert rec.has_corrected
    for v in rec.edit_distances.values():
        assert v == 0.0


def test_edit_distance_full_rewrite_is_high(tmp_path: Path):
    rewritten = _good_summary()
    rewritten["title"] = "ZZZZZZZZZZZZZZ"  # nothing in common with "Original"
    _write_correction(
        tmp_path, "rewrite", verdict="edited", corrected=rewritten
    )
    rec = corrections.load_records(tmp_path / "corrections")[0]
    assert rec.edit_distances["title"] >= 0.7


def test_edit_distance_only_computed_for_edited(tmp_path: Path):
    _write_correction(tmp_path, "good", verdict="good")
    _write_correction(tmp_path, "bad", verdict="bad")
    records = {r.stem: r for r in corrections.load_records(tmp_path / "corrections")}
    assert not records["good"].has_corrected
    assert not records["bad"].has_corrected
    assert records["good"].edit_distances == {}


# -------- aggregate ---------------------------------------------------------


def test_aggregate_counts_by_verdict_backend_model(tmp_path: Path):
    _write_correction(tmp_path, "a", verdict="good", backend="anthropic",
                      model="claude-sonnet-4-6", transcript_chars=10_000)
    _write_correction(tmp_path, "b", verdict="edited", backend="local",
                      model="qwen-3b", transcript_chars=15_000,
                      corrected=_good_summary())
    _write_correction(tmp_path, "c", verdict="bad", backend="local",
                      model="qwen-3b", transcript_chars=5_000)

    stats = corrections.aggregate(corrections.load_records(tmp_path / "corrections"))
    assert stats["total"] == 3
    assert stats["by_verdict"] == {"good": 1, "edited": 1, "bad": 1}
    assert stats["by_backend"]["anthropic"]["total"] == 1
    assert stats["by_backend"]["local"]["total"] == 2
    assert stats["by_backend"]["local"]["edited"] == 1
    assert stats["by_model"]["qwen-3b"]["total"] == 2
    assert stats["transcript_chars"] == 30_000


def test_readiness_gate_requires_both_count_and_chars(tmp_path: Path):
    # Plenty of chars per record but not enough corrections.
    for i in range(5):
        _write_correction(tmp_path, f"big-{i}", verdict="good",
                          transcript_chars=200_000)
    stats = corrections.aggregate(corrections.load_records(tmp_path / "corrections"))
    assert stats["transcript_chars"] >= corrections.READINESS_MIN_TRANSCRIPT_CHARS
    assert stats["total"] < corrections.READINESS_MIN_COUNT
    assert stats["ready"] is False


def test_readiness_gate_passes_when_both_thresholds_met(tmp_path: Path):
    # 20 records * 12_000 chars = 240_000, both gates clear.
    for i in range(20):
        _write_correction(tmp_path, f"r-{i}", verdict="good",
                          transcript_chars=12_000)
    stats = corrections.aggregate(corrections.load_records(tmp_path / "corrections"))
    assert stats["total"] >= corrections.READINESS_MIN_COUNT
    assert stats["transcript_chars"] >= corrections.READINESS_MIN_TRANSCRIPT_CHARS
    assert stats["ready"] is True


def test_readiness_gate_fails_when_chars_short(tmp_path: Path):
    # 20 records but each has tiny transcript -> count gate passes, chars fails.
    for i in range(20):
        _write_correction(tmp_path, f"s-{i}", verdict="good",
                          transcript_chars=500)
    stats = corrections.aggregate(corrections.load_records(tmp_path / "corrections"))
    assert stats["total"] >= corrections.READINESS_MIN_COUNT
    assert stats["transcript_chars"] < corrections.READINESS_MIN_TRANSCRIPT_CHARS
    assert stats["ready"] is False


# -------- CLI ---------------------------------------------------------------


def test_cli_markdown_output(tmp_path: Path):
    _write_correction(tmp_path, "a", verdict="good")
    _write_correction(tmp_path, "b", verdict="edited", corrected=_good_summary())

    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = corrections.main(["--dir", str(tmp_path / "corrections")])
    assert rc == 0
    out = buf.getvalue()
    assert "# Correction corpus" in out
    assert "Phase 3 readiness" in out
    assert "Per backend" in out


def test_cli_json_output(tmp_path: Path):
    _write_correction(tmp_path, "a", verdict="good")

    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = corrections.main(["--dir", str(tmp_path / "corrections"), "--json"])
    assert rc == 0
    parsed = json.loads(buf.getvalue())
    assert parsed["total"] == 1
    assert parsed["by_verdict"]["good"] == 1
    assert parsed["ready"] is False


def test_cli_rejects_unknown_arg(tmp_path: Path):
    rc = corrections.main(["--bogus"])
    assert rc == 2


def test_cli_empty_dir_reports_zero(tmp_path: Path):
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = corrections.main(["--dir", str(tmp_path / "empty"), "--json"])
    assert rc == 0
    parsed = json.loads(buf.getvalue())
    assert parsed["total"] == 0
    assert parsed["ready"] is False


# -------- orchestrate integration ------------------------------------------


def test_orchestrate_writes_run_sidecar(tmp_path: Path, monkeypatch):
    """End-to-end: run_all writes <stem>.run.json with backend + model
    after the summarize stage. Mocks transcribe/summarize/publish so we
    only exercise the orchestrator's sidecar emission."""
    from mp.config import Config
    from mp.orchestrate import run_all

    monkeypatch.delenv("MP_FORCE_BYO", raising=False)

    stem = "20260508-1500"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    md_path = tmp_path / f"{stem}.md"
    md_path.write_text("hello", encoding="utf-8")
    json_path = tmp_path / f"{stem}.json"
    json_path.write_text(
        json.dumps({"segments": [{"text": "x"}], "language": "en"}),
        encoding="utf-8",
    )

    summary_json = tmp_path / f"{stem}.summary.json"
    summary_json.write_text("{}", encoding="utf-8")
    summary_md = tmp_path / f"{stem}.summary.md"
    summary_md.write_text("", encoding="utf-8")

    from unittest.mock import patch

    with patch("mp.orchestrate.transcribe", return_value={"json": json_path, "md": md_path}), \
         patch("mp.orchestrate.summarize", return_value={
             "json": summary_json,
             "md": summary_md,
             "backend": "local",
             "model": "mlx-community/Qwen2.5-3B-Instruct-4bit",
         }), \
         patch("mp.orchestrate.publish_fanout", return_value={
             "page_id": "p", "page_url": "u", "idempotent": False
         }):
        run_all(wav, cfg=Config())

    sidecar = tmp_path / f"{stem}.run.json"
    assert sidecar.exists()
    data = json.loads(sidecar.read_text(encoding="utf-8"))
    assert data["backend"] == "local"
    assert data["model"] == "mlx-community/Qwen2.5-3B-Instruct-4bit"
    assert data["transcript_chars"] == len("hello")
    assert data["stem"] == stem


def test_orchestrate_tolerates_summarize_without_meta(tmp_path: Path, monkeypatch):
    """Older test fixtures and the byo/long-meeting paths may return a
    summarize dict without backend/model fields. The sidecar writer must
    not raise; fields land empty."""
    from mp.config import Config
    from mp.orchestrate import run_all

    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260508-1600"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    md_path = tmp_path / f"{stem}.md"
    md_path.write_text("hello", encoding="utf-8")
    json_path = tmp_path / f"{stem}.json"
    json_path.write_text(
        json.dumps({"segments": [{"text": "x"}], "language": "en"}),
        encoding="utf-8",
    )
    summary_json = tmp_path / f"{stem}.summary.json"
    summary_json.write_text("{}", encoding="utf-8")
    summary_md = tmp_path / f"{stem}.summary.md"
    summary_md.write_text("", encoding="utf-8")

    from unittest.mock import patch

    with patch("mp.orchestrate.transcribe", return_value={"json": json_path, "md": md_path}), \
         patch("mp.orchestrate.summarize", return_value={"json": summary_json, "md": summary_md}), \
         patch("mp.orchestrate.publish_fanout", return_value={
             "page_id": "p", "page_url": "u", "idempotent": False
         }):
        run_all(wav, cfg=Config())

    data = json.loads((tmp_path / f"{stem}.run.json").read_text(encoding="utf-8"))
    assert data["backend"] == ""
    assert data["model"] == ""
