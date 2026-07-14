"""PERF7: size-based rename rotation for the pipeline logs, and the readers
that must keep working across a rotation boundary.

The write path (`events.emit`) had zero coverage before this; these pin the
rotation mechanics plus the two named readers (`mp logs`, `mp analyze-detection`)
reading the base log plus its generations.
"""
from __future__ import annotations

import json
from pathlib import Path

from mp import events

PRODUCTION_LOGS = Path("~/Library/Logs/MeetingPipe").expanduser()


def test_generation_path_inserts_index_before_extension(tmp_path):
    p = tmp_path / "events.jsonl"
    assert events._generation_path(p, 1).name == "events.1.jsonl"
    assert events._generation_path(tmp_path / "pipeline.log", 2).name == "pipeline.2.log"


def test_rotate_if_needed_below_cap_is_noop(tmp_path, monkeypatch):
    monkeypatch.setenv("MEETINGPIPE_LOG_MAX_BYTES", "1000")
    p = tmp_path / "events.jsonl"
    p.write_text("x" * 10)
    events.rotate_if_needed(p)
    assert p.exists()
    assert not events._generation_path(p, 1).exists()


def test_rotate_if_needed_shifts_and_bounds(tmp_path, monkeypatch):
    monkeypatch.setenv("MEETINGPIPE_LOG_MAX_BYTES", "100")
    p = tmp_path / "events.jsonl"

    p.write_text("x" * 200)
    events.rotate_if_needed(p)
    assert not p.exists()
    assert events._generation_path(p, 1).exists()

    p.write_text("x" * 200)
    events.rotate_if_needed(p)
    assert events._generation_path(p, 2).exists()

    for _ in range(5):
        p.write_text("x" * 200)
        events.rotate_if_needed(p)

    # Self-bounds: never keeps more than _LOG_GENERATIONS backups.
    assert events._generation_path(p, events._LOG_GENERATIONS).exists()
    assert not events._generation_path(p, events._LOG_GENERATIONS + 1).exists()


def test_log_generations_oldest_first_base_last(tmp_path):
    p = tmp_path / "events.jsonl"
    p.write_text("base")
    events._generation_path(p, 1).write_text("g1")
    events._generation_path(p, 2).write_text("g2")
    assert events.log_generations(p) == [
        events._generation_path(p, 2),
        events._generation_path(p, 1),
        p,
    ]


def test_emit_rotates_at_cap(tmp_path, monkeypatch):
    target = tmp_path / "pipeline_events.jsonl"
    monkeypatch.setattr(events, "_events_path", lambda: target)
    monkeypatch.setenv("MEETINGPIPE_LOG_MAX_BYTES", "500")
    for i in range(200):
        events.emit("test", "tick", i=i, pad="x" * 40)
    assert target.exists()
    assert events._generation_path(target, 1).exists()
    assert not events._generation_path(target, events._LOG_GENERATIONS + 1).exists()


def test_logs_cmd_reads_across_generations(tmp_path, monkeypatch):
    from mp import logs_cmd

    monkeypatch.setattr(logs_cmd, "LOGS_DIR", tmp_path)
    base = tmp_path / "events.jsonl"
    base.write_text(
        json.dumps({"ts": "2026-07-11T10:00:00Z", "category": "c", "action": "new"}) + "\n"
    )
    events._generation_path(base, 1).write_text(
        json.dumps({"ts": "2026-07-11T09:00:00Z", "category": "c", "action": "old"}) + "\n"
    )
    actions = [e["action"] for e in logs_cmd._iter_events()]
    assert "new" in actions
    assert "old" in actions


# ------------------------------------------------- test isolation (the writer guard)


def test_logs_dir_honors_explicit_env_override(tmp_path, monkeypatch):
    monkeypatch.setenv("MEETINGPIPE_LOGS_DIR", str(tmp_path))
    assert events.logs_dir() == tmp_path


def test_logs_dir_under_pytest_never_touches_production(monkeypatch):
    """`pytest` must not append fixture rows to the user's real pipeline_events.jsonl.

    Before this guard the suite owned 21% of that file (1491 of 7020 rows), and every
    consumer read them back as meetings that never happened. Twin of Swift's
    LoggerTests.test_logsDir_under_test_never_touches_production.
    """
    monkeypatch.delenv("MEETINGPIPE_LOGS_DIR", raising=False)
    assert events.logs_dir() != PRODUCTION_LOGS


def test_emit_under_pytest_writes_outside_production(monkeypatch):
    monkeypatch.delenv("MEETINGPIPE_LOGS_DIR", raising=False)
    events.emit("test", "tick", stem="x")
    assert events._events_path().parent != PRODUCTION_LOGS


# ------------------------------------------------- test residue (the reader guard)


def test_is_test_residue_flags_fake_engines_and_fixture_stems():
    assert events.is_test_residue({"category": "transcription", "engine": "fake"})
    assert events.is_test_residue({"category": "transcription", "engine": "pass"})
    assert events.is_test_residue(
        {"category": "coordinator", "action": "pipeline_failed", "file": "clip.wav"}
    )
    assert events.is_test_residue({"category": "pipeline", "stem": "x"})
    # A real recording stamps seconds; the 4-digit-time stems are fixtures.
    assert events.is_test_residue({"category": "pipeline", "wav": "/raw/20260506-1500.wav"})


def test_is_test_residue_keeps_real_rows():
    assert not events.is_test_residue(
        {"category": "transcription", "engine": "fluidaudio", "file": "20260714-193655.wav"}
    )
    # The .mic/.system intermediates keep the real stem.
    assert not events.is_test_residue({"category": "recorder", "file": "20260605-163026.mic.wav"})
    # `path` on a prefetch row is a model cache dir, not a meeting: keying on it would
    # drop a real event.
    assert not events.is_test_residue(
        {"category": "prefetch", "action": "complete", "path": "/hub/models--x/snapshots/abc"}
    )
    # Rows that name no meeting are byte-identical to real ones. They must survive.
    assert not events.is_test_residue({"category": "coordinator", "action": "state_change"})


def test_drop_test_residue_removes_only_residue():
    kept = events.drop_test_residue(
        [
            {"action": "pipeline_failed", "file": "clip.wav"},
            {"action": "pipeline_succeeded", "file": "20260714-193655.wav"},
        ]
    )
    assert [r["action"] for r in kept] == ["pipeline_succeeded"]


def test_analyze_detection_pairs_session_across_rotation(tmp_path):
    from mp import analyze_detection as ad

    base = tmp_path / "events.jsonl"
    # A session whose start rotated into events.1.jsonl while its stop is still
    # in the live base file must still pair.
    events._generation_path(base, 1).write_text(
        json.dumps(
            {
                "ts": "2026-07-11T09:00:00.000Z",
                "category": "coordinator",
                "action": "recording_started",
                "bundle_id": "us.zoom.xos",
                "file": "a.wav",
            }
        )
        + "\n"
    )
    base.write_text(
        json.dumps(
            {
                "ts": "2026-07-11T09:05:00.000Z",
                "category": "coordinator",
                "action": "recording_stopped",
                "file": "a.wav",
            }
        )
        + "\n"
    )
    raw = [ev for p in events.log_generations(base) for ev in ad.iter_events(p)]
    sessions = ad.pair_sessions(raw)
    assert len(sessions) == 1
