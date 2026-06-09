"""Tests for `mp analyze-detection` — TECH-C1 audit tool.

The classification logic (detector-triggered vs manual stop) is what
the report hinges on, so we exercise pairing, classification, and
report rendering against synthetic event sequences. End-to-end via
`main()` is covered too, to lock in the CLI surface.
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from mp.analyze_detection import (
    Session,
    aggregate,
    classify_session,
    iter_events,
    main,
    pair_sessions,
    render_report,
)


def _event(ts: str, category: str, action: str, **attrs) -> dict:
    return {"ts": ts, "category": category, "action": action, **attrs}


def _write_events(path: Path, events: list[dict]) -> Path:
    path.write_text("\n".join(json.dumps(e) for e in events) + "\n", encoding="utf-8")
    return path


def test_iter_events_skips_blank_and_malformed_lines(tmp_path: Path) -> None:
    p = tmp_path / "events.jsonl"
    p.write_text(
        '{"ts": "2026-05-01T10:00:00Z", "category": "coordinator", "action": "x"}\n'
        '\n'
        '{not json\n'
        '{"ts": "2026-05-01T10:00:01Z", "category": "detector", "action": "y"}\n',
        encoding="utf-8",
    )
    out = list(iter_events(p))
    assert [e["action"] for e in out] == ["x", "y"]


def test_iter_events_missing_file_returns_empty(tmp_path: Path) -> None:
    assert list(iter_events(tmp_path / "absent.jsonl")) == []


def test_pair_sessions_classifies_detector_triggered_stop() -> None:
    events = [
        _event("2026-05-01T10:00:00Z", "coordinator", "recording_started",
               file="meet.wav", bundle_id="us.zoom.xos"),
        _event("2026-05-01T10:30:00Z", "lifecycle", "ended", bundle_id="us.zoom.xos"),
        _event("2026-05-01T10:30:02Z", "coordinator", "recording_stopped",
               file="meet.wav", bundle_id="us.zoom.xos"),
    ]
    sessions = [classify_session(s) for s in pair_sessions(events)]
    assert len(sessions) == 1
    assert sessions[0].stop_kind == "detector"
    assert sessions[0].delta_sec == 2.0
    assert sessions[0].bundle_id == "us.zoom.xos"


def test_pair_sessions_classifies_manual_stop() -> None:
    """No `lifecycle.ended` between start and stop → manual stop."""
    events = [
        _event("2026-05-01T11:00:00Z", "coordinator", "recording_started",
               file="hotkey.wav", bundle_id="manual"),
        _event("2026-05-01T11:25:00Z", "coordinator", "recording_stopped",
               file="hotkey.wav", bundle_id="manual"),
    ]
    sessions = [classify_session(s) for s in pair_sessions(events)]
    assert len(sessions) == 1
    assert sessions[0].stop_kind == "manual"
    assert sessions[0].delta_sec is None


def test_classify_silence_backstop_is_not_a_manual_miss() -> None:
    """A `coordinator.auto_stop_silence` in-window is the backstop, not a
    user miss (the dishonesty TECH-END4 fixes: these used to count manual)."""
    events = [
        _event("2026-05-01T11:00:00Z", "coordinator", "recording_started",
               file="forgot.wav", bundle_id="com.microsoft.teams2"),
        _event("2026-05-01T11:20:00Z", "coordinator", "auto_stop_silence",
               reason="idle_15m"),
        _event("2026-05-01T11:20:01Z", "coordinator", "recording_stopped",
               file="forgot.wav", bundle_id="com.microsoft.teams2"),
    ]
    sessions = [classify_session(s) for s in pair_sessions(events)]
    assert sessions[0].stop_kind == "silence_backstop"
    assert sessions[0].delta_sec is None


def test_classify_force_stop_hotkey() -> None:
    events = [
        _event("2026-05-01T11:00:00Z", "coordinator", "recording_started",
               file="hk.wav", bundle_id="us.zoom.xos"),
        _event("2026-05-01T11:05:00Z", "coordinator", "force_stop", reason="hotkey"),
        _event("2026-05-01T11:05:01Z", "coordinator", "recording_stopped",
               file="hk.wav", bundle_id="us.zoom.xos"),
    ]
    sessions = [classify_session(s) for s in pair_sessions(events)]
    assert sessions[0].stop_kind == "force_stop"


def test_classify_force_stop_with_silence_reason_is_backstop() -> None:
    """The legacy mic-only backstop force-stops with reason `mic_only_silence`;
    a reason naming silence classifies as the backstop, not a user force-stop."""
    events = [
        _event("2026-05-01T11:00:00Z", "coordinator", "recording_started",
               file="leg.wav", bundle_id="us.zoom.xos"),
        _event("2026-05-01T11:08:00Z", "coordinator", "force_stop",
               reason="mic_only_silence"),
        _event("2026-05-01T11:08:01Z", "coordinator", "recording_stopped",
               file="leg.wav", bundle_id="us.zoom.xos"),
    ]
    sessions = [classify_session(s) for s in pair_sessions(events)]
    assert sessions[0].stop_kind == "silence_backstop"


def test_detector_end_wins_over_backstop_marker() -> None:
    """If both a lifecycle.ended and an auto_stop_silence land in-window, the
    detector end is the real cause and takes priority."""
    events = [
        _event("2026-05-01T11:00:00Z", "coordinator", "recording_started",
               file="both.wav", bundle_id="us.zoom.xos"),
        _event("2026-05-01T11:19:59Z", "coordinator", "auto_stop_silence"),
        _event("2026-05-01T11:20:00Z", "lifecycle", "ended"),
        _event("2026-05-01T11:20:01Z", "coordinator", "recording_stopped",
               file="both.wav", bundle_id="us.zoom.xos"),
    ]
    sessions = [classify_session(s) for s in pair_sessions(events)]
    assert sessions[0].stop_kind == "detector"


def test_silence_backstop_excluded_from_misses_section() -> None:
    events = [
        _event("2026-05-01T11:00:00Z", "coordinator", "recording_started",
               file="forgot.wav", bundle_id="com.microsoft.teams2"),
        _event("2026-05-01T11:20:00Z", "coordinator", "auto_stop_silence"),
        _event("2026-05-01T11:20:01Z", "coordinator", "recording_stopped",
               file="forgot.wav", bundle_id="com.microsoft.teams2"),
    ]
    sessions = [classify_session(s) for s in pair_sessions(events)]
    out = render_report(sessions, aggregate(sessions))
    misses_section = out.split("## Detector misses")[1]
    assert "forgot.wav" not in misses_section
    assert "silence backstop" in out  # surfaced in the summary instead


def test_pair_sessions_picks_latest_detector_ended_when_debounce_flutters() -> None:
    """Multiple `lifecycle.ended` inside one session (debounce flutter):
    use the latest, which is the one that actually drove the stop."""
    events = [
        _event("2026-05-01T12:00:00Z", "coordinator", "recording_started",
               file="m.wav", bundle_id="com.google.Chrome"),
        _event("2026-05-01T12:10:00Z", "lifecycle", "ended"),
        _event("2026-05-01T12:20:00Z", "lifecycle", "ended"),
        _event("2026-05-01T12:20:03Z", "coordinator", "recording_stopped",
               file="m.wav", bundle_id="com.google.Chrome"),
    ]
    sessions = [classify_session(s) for s in pair_sessions(events)]
    assert sessions[0].stop_kind == "detector"
    assert sessions[0].delta_sec == 3.0


def test_pair_sessions_ignores_detector_ended_outside_session() -> None:
    """`lifecycle.ended` before any started, or after stopped, must not
    flip the classification."""
    events = [
        _event("2026-05-01T09:00:00Z", "lifecycle", "ended"),  # before any session
        _event("2026-05-01T10:00:00Z", "coordinator", "recording_started",
               file="a.wav", bundle_id="manual"),
        _event("2026-05-01T10:05:00Z", "coordinator", "recording_stopped",
               file="a.wav", bundle_id="manual"),
        _event("2026-05-01T10:10:00Z", "lifecycle", "ended"),  # after stop
    ]
    sessions = [classify_session(s) for s in pair_sessions(events)]
    assert len(sessions) == 1
    assert sessions[0].stop_kind == "manual"


def test_pair_sessions_filters_by_since() -> None:
    events = [
        _event("2026-05-01T08:00:00Z", "coordinator", "recording_started",
               file="old.wav", bundle_id="us.zoom.xos"),
        _event("2026-05-01T08:30:00Z", "coordinator", "recording_stopped",
               file="old.wav", bundle_id="us.zoom.xos"),
        _event("2026-05-02T08:00:00Z", "coordinator", "recording_started",
               file="new.wav", bundle_id="us.zoom.xos"),
        _event("2026-05-02T08:30:00Z", "coordinator", "recording_stopped",
               file="new.wav", bundle_id="us.zoom.xos"),
    ]
    since = datetime(2026, 5, 2, tzinfo=timezone.utc)
    sessions = pair_sessions(events, since=since)
    assert [s.file for s in sessions] == ["new.wav"]


def test_pair_sessions_unterminated_session_is_skipped() -> None:
    """A `recording_started` with no matching `recording_stopped` (daemon
    crash, log rotation) should not produce a half-paired session."""
    events = [
        _event("2026-05-01T10:00:00Z", "coordinator", "recording_started",
               file="dangling.wav", bundle_id="manual"),
    ]
    assert pair_sessions(events) == []


def test_aggregate_buckets_by_bundle_id() -> None:
    sessions = [
        Session(
            started_ts=datetime(2026, 5, 1, 10, tzinfo=timezone.utc),
            stopped_ts=datetime(2026, 5, 1, 10, 30, tzinfo=timezone.utc),
            bundle_id="us.zoom.xos",
            file="z1.wav",
            detector_ended_ts=datetime(2026, 5, 1, 10, 29, 58, tzinfo=timezone.utc),
        ),
        Session(
            started_ts=datetime(2026, 5, 1, 11, tzinfo=timezone.utc),
            stopped_ts=datetime(2026, 5, 1, 11, 30, tzinfo=timezone.utc),
            bundle_id="us.zoom.xos",
            file="z2.wav",
        ),
        Session(
            started_ts=datetime(2026, 5, 1, 12, tzinfo=timezone.utc),
            stopped_ts=datetime(2026, 5, 1, 12, 30, tzinfo=timezone.utc),
            bundle_id="com.google.Chrome",
            file="c1.wav",
        ),
    ]
    for s in sessions:
        classify_session(s)
    stats = aggregate(sessions)
    assert stats["us.zoom.xos"].total == 2
    assert stats["us.zoom.xos"].detector_triggered == 1
    assert stats["us.zoom.xos"].manual == 1
    assert stats["com.google.Chrome"].total == 1
    assert stats["com.google.Chrome"].manual == 1


def test_render_report_empty_input_returns_skeleton() -> None:
    out = render_report([], {})
    assert "# Detection Audit" in out
    assert "No recording sessions" in out


def test_render_report_includes_per_app_table_and_misses(tmp_path: Path) -> None:
    events = [
        _event("2026-05-01T10:00:00Z", "coordinator", "recording_started",
               file="zoom.wav", bundle_id="us.zoom.xos"),
        _event("2026-05-01T10:30:00Z", "lifecycle", "ended"),
        _event("2026-05-01T10:30:01Z", "coordinator", "recording_stopped",
               file="zoom.wav", bundle_id="us.zoom.xos"),
        _event("2026-05-01T11:00:00Z", "coordinator", "recording_started",
               file="meet.wav", bundle_id="com.google.Chrome"),
        _event("2026-05-01T11:45:00Z", "coordinator", "recording_stopped",
               file="meet.wav", bundle_id="com.google.Chrome"),
    ]
    sessions = [classify_session(s) for s in pair_sessions(events)]
    stats = aggregate(sessions)
    out = render_report(sessions, stats)

    assert "us.zoom.xos" in out
    assert "com.google.Chrome" in out
    # The Chrome session is the miss — must appear in the misses section.
    misses_section = out.split("## Detector misses")[1]
    assert "meet.wav" in misses_section
    assert "zoom.wav" not in misses_section


def test_main_writes_markdown_to_output(tmp_path: Path) -> None:
    events = [
        _event("2026-05-01T10:00:00Z", "coordinator", "recording_started",
               file="x.wav", bundle_id="us.zoom.xos"),
        _event("2026-05-01T10:10:00Z", "lifecycle", "ended"),
        _event("2026-05-01T10:10:01Z", "coordinator", "recording_stopped",
               file="x.wav", bundle_id="us.zoom.xos"),
    ]
    source = _write_events(tmp_path / "events.jsonl", events)
    out = tmp_path / "report.md"

    rc = main(["--source", str(source), "--output", str(out)])
    assert rc == 0
    body = out.read_text(encoding="utf-8")
    assert "# Detection Audit" in body
    assert "us.zoom.xos" in body


def test_main_json_mode_emits_aggregate(tmp_path: Path, capsys) -> None:
    events = [
        _event("2026-05-01T10:00:00Z", "coordinator", "recording_started",
               file="x.wav", bundle_id="manual"),
        _event("2026-05-01T10:10:00Z", "coordinator", "recording_stopped",
               file="x.wav", bundle_id="manual"),
    ]
    source = _write_events(tmp_path / "events.jsonl", events)

    rc = main(["--source", str(source), "--json"])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["total_sessions"] == 1
    assert payload["per_app"]["manual"]["manual"] == 1
    assert payload["misses"][0]["file"] == "x.wav"


def test_main_missing_source_is_not_an_error(tmp_path: Path, capsys) -> None:
    """`mp analyze-detection` on a fresh install (no events yet) should
    print the empty skeleton, not crash."""
    rc = main(["--source", str(tmp_path / "nope.jsonl")])
    assert rc == 0
    out = capsys.readouterr().out
    assert "No recording sessions" in out
