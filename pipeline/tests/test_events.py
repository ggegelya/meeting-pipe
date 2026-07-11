"""PERF7: size-based rename rotation for the pipeline logs, and the readers
that must keep working across a rotation boundary.

The write path (`events.emit`) had zero coverage before this; these pin the
rotation mechanics plus the two named readers (`mp logs`, `mp analyze-detection`)
reading the base log plus its generations.
"""
from __future__ import annotations

import json

from mp import events


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
