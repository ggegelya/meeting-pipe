"""OBS3: every subcommand that fails leaves one event naming it and its typed cause, run-all's
missing secret exits 2, an event write never raises, and an unreadable transcript is not a
missing one."""
from __future__ import annotations

import json
import os
from pathlib import Path
from unittest.mock import patch

import pytest

from mp import (
    events,
    failure_details,
    finalize,
    merge_meetings,
    orchestrate,
    publish_from_paste,
    summarize,
)
from mp.config import Config, MissingSecretError


@pytest.fixture
def emitted(monkeypatch) -> list[tuple[str, str, dict]]:
    rows: list[tuple[str, str, dict]] = []
    monkeypatch.setattr(events, "emit", lambda cat, action, **attrs: rows.append((cat, action, attrs)))
    return rows


def _actions(rows, action):
    return [attrs for _, a, attrs in rows if a == action]


# --- one command_failed per failing command ---------------------------------------------------


def test_fail_command_emits_once_with_a_typed_cause_and_a_capped_message(emitted):
    payload = failure_details.fail_command("finalize", RuntimeError("x" * 500), operation="transcribe")
    rows = _actions(emitted, "command_failed")
    assert len(rows) == 1
    assert rows[0]["command"] == "finalize"
    assert rows[0]["error_type"] == "RuntimeError"
    assert rows[0]["cause"] == payload["cause"] == "unknown"
    assert len(rows[0]["message"]) == failure_details.COMMAND_MESSAGE_CAP


def test_a_failing_merge_emits_command_failed(tmp_path: Path, emitted):
    with patch.object(merge_meetings, "merge_meetings", side_effect=merge_meetings.MergeError("no primary")):
        assert merge_meetings.main([str(tmp_path / "a.wav"), str(tmp_path / "b.wav")]) == 1
    (row,) = _actions(emitted, "command_failed")
    assert row["command"] == "merge-meetings" and row["cause"] == "unknown"


def test_a_failing_paste_publish_emits_command_failed(tmp_path: Path, emitted):
    transcript = tmp_path / "20260101-1200.md"
    transcript.write_text("x", encoding="utf-8")
    with patch.object(publish_from_paste, "publish_from_paste", side_effect=RuntimeError("boom")):
        assert publish_from_paste.main([str(transcript)]) == 1
    (row,) = _actions(emitted, "command_failed")
    assert row["command"] == "publish-from-paste" and row["cause"] == "publish"


def test_a_failing_finalize_emits_command_failed(tmp_path: Path, emitted):
    wav = tmp_path / "20260101-1200.wav"
    wav.write_bytes(b"")
    with patch.object(finalize, "finalize", side_effect=RuntimeError("boom")):
        assert finalize.main([str(wav)]) == 1
    (row,) = _actions(emitted, "command_failed")
    assert row["command"] == "finalize" and "cause" in row


def test_a_failing_summarize_emits_command_failed(tmp_path: Path, emitted):
    md = tmp_path / "20260101-1200.md"
    md.write_text("x", encoding="utf-8")
    with patch.object(summarize, "summarize", side_effect=RuntimeError("boom")):
        assert summarize.main([str(md)]) == 1
    (row,) = _actions(emitted, "command_failed")
    assert row["command"] == "summarize" and row["cause"] == "unknown"


# --- run-all's missing secret is exit 2 ---------------------------------------------------------


def test_run_all_reraises_a_missing_secret_for_the_exit_2_boundary(tmp_path: Path, emitted):
    wav = tmp_path / "20260101-1200.wav"
    wav.write_bytes(b"")

    def missing(*_a, **_k):
        events.emit("pipeline", "run_failed", error="ANTHROPIC_API_KEY", error_type="MissingSecretError")
        raise MissingSecretError("ANTHROPIC_API_KEY")

    with patch.object(orchestrate, "run_all", side_effect=missing), pytest.raises(MissingSecretError):
        orchestrate.main([str(wav)])
    assert len(_actions(emitted, "run_failed")) == 1


def test_the_cli_boundary_maps_run_alls_missing_secret_to_exit_2(tmp_path: Path, monkeypatch):
    from mp import __main__

    wav = tmp_path / "20260101-1200.wav"
    wav.write_bytes(b"")
    monkeypatch.setattr(orchestrate, "run_all", lambda *a, **k: (_ for _ in ()).throw(MissingSecretError("ANTHROPIC_API_KEY")))
    monkeypatch.setattr("sys.argv", ["mp", "run-all", str(wav)])
    assert __main__.main() == 2


# --- emit never raises -------------------------------------------------------------------------


def test_emit_with_an_unwritable_logs_dir_returns(tmp_path: Path, monkeypatch):
    blocked = tmp_path / "blocked"
    blocked.write_text("a file where the logs dir should be", encoding="utf-8")
    monkeypatch.setenv("MEETINGPIPE_LOGS_DIR", str(blocked / "logs"))
    events.emit("pipeline", "run_failed", error="x")  # must not raise


# --- an unreadable transcript is not a missing one ---------------------------------------------


def test_a_corrupt_transcript_fails_typed_with_exactly_one_run_failed(tmp_path: Path, emitted, monkeypatch):
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260101-1200"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    (tmp_path / f"{stem}.json").write_text("{not json", encoding="utf-8")
    with pytest.raises(orchestrate.DaemonTranscriptUnreadable):
        orchestrate.run_all(wav, cfg=Config())
    rows = _actions(emitted, "run_failed")
    assert len(rows) == 1
    assert rows[0]["error_type"] == "DaemonTranscriptUnreadable"


def test_a_missing_and_a_foreign_transcript_have_their_own_types(tmp_path: Path):
    wav = tmp_path / "20260101-1200.wav"
    with pytest.raises(orchestrate.DaemonTranscriptMissing, match="No daemon transcript"):
        orchestrate.existing_daemon_transcript(wav)
    (tmp_path / "20260101-1200.json").write_text(json.dumps({"backend": "whisperx"}), encoding="utf-8")
    with pytest.raises(orchestrate.DaemonTranscriptForeign):
        orchestrate.existing_daemon_transcript(wav)


def test_an_unreadable_transcript_names_the_errno(tmp_path: Path):
    if os.geteuid() == 0:  # pragma: no cover - root reads anything
        pytest.skip("root ignores file modes")
    path = tmp_path / "20260101-1200.json"
    path.write_text("{}", encoding="utf-8")
    path.chmod(0)
    try:
        with pytest.raises(orchestrate.DaemonTranscriptUnreadable, match="EACCES"):
            orchestrate.existing_daemon_transcript(tmp_path / "20260101-1200.wav")
    finally:
        path.chmod(0o600)
