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
    MIC_INPUT_DEVICE_UNAVAILABLE,
    MIC_INPUT_NO_SPANS,
    MIC_INPUT_OBSERVED,
    Session,
    aggregate,
    classify_mic_spans,
    classify_session,
    collect_correlation_markers,
    collect_mic_input_faults,
    iter_events,
    main,
    mic_input_status,
    pair_mic_spans,
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


# --- DET3: mic-busy miss correlation -------------------------------------------------


def _mic(bundle: str, start: str, end: str, name: str = "App") -> list[dict]:
    return [
        _event(start, "detector", "mic_busy_started", bundle_id=bundle, display_name=name),
        _event(end, "detector", "mic_busy_ended", bundle_id=bundle, display_name=name),
    ]


def _classify_spans(events: list[dict]) -> list:
    sessions = [classify_session(s) for s in pair_sessions(events)]
    prompts, dropped, picks, unreadable = collect_correlation_markers(events)
    return classify_mic_spans(
        pair_mic_spans(events), sessions,
        prompts=prompts, dropped=dropped, picks=picks, unreadable=unreadable,
    )


def test_pair_mic_spans_pairs_and_drops_unclosed_tail() -> None:
    events = [
        *_mic("com.hnc.Discord", "2026-05-01T10:00:00Z", "2026-05-01T10:45:00Z", "Discord"),
        # A still-open span (analysis ran mid-call): no `mic_busy_ended`, so it is dropped.
        _event("2026-05-01T11:00:00Z", "detector", "mic_busy_started", bundle_id="b"),
    ]
    spans = pair_mic_spans(events)
    assert len(spans) == 1
    assert spans[0].bundle_id == "com.hnc.Discord"
    assert spans[0].duration_sec == 2700.0


def test_mic_span_overlapping_a_recording_is_handled() -> None:
    events = [
        *_mic("us.zoom.xos", "2026-05-01T11:00:00Z", "2026-05-01T11:30:05Z", "Zoom"),
        _event("2026-05-01T11:00:05Z", "coordinator", "recording_started",
               file="m.wav", bundle_id="us.zoom.xos"),
        _event("2026-05-01T11:30:00Z", "coordinator", "recording_stopped",
               file="m.wav", bundle_id="us.zoom.xos"),
    ]
    assert _classify_spans(events)[0].handled is True


def test_mic_span_with_a_prompt_is_handled() -> None:
    events = [
        *_mic("us.zoom.xos", "2026-05-01T11:00:00Z", "2026-05-01T11:05:00Z", "Zoom"),
        _event("2026-05-01T11:00:10Z", "coordinator", "prompt_shown", bundle_id="us.zoom.xos"),
    ]
    assert _classify_spans(events)[0].handled is True


def test_unlisted_call_is_a_miss_with_no_candidate_reason() -> None:
    # Acceptance: a deliberately missed call on an app absent from meeting_apps.toml appears with
    # attribution and a reason.
    events = _mic("chat.unknown.app", "2026-05-01T10:00:00Z", "2026-05-01T10:45:00Z", "Unknown Chat")
    span = _classify_spans(events)[0]
    assert span.handled is False
    assert span.display_name == "Unknown Chat"
    assert "no candidate" in span.miss_reason


def test_candidate_dropped_in_window_reads_as_recognizer_rot() -> None:
    events = [
        *_mic("com.microsoft.teams2", "2026-05-01T12:00:00Z", "2026-05-01T12:40:00Z", "Teams"),
        _event("2026-05-01T12:00:10Z", "detector", "candidate_dropped",
               bundle_id="com.microsoft.teams2", reason="no_confident_winner", score=2),
    ]
    span = _classify_spans(events)[0]
    assert span.handled is False
    assert span.miss_reason == "candidate dropped (no_confident_winner)"


def test_candidate_unreadable_in_window_names_the_denied_permission() -> None:
    # DET11: the miss a denied Accessibility grant causes used to fall through to the generic
    # "no candidate (unlisted app, or Accessibility / Screen Recording denied)" guess, because the
    # daemon emitted nothing at all for it. With the marker the report states the cause and names
    # the app that was running, which is the difference between a guess and a fix.
    events = [
        *_mic("com.microsoft.teams2", "2026-05-01T14:00:00Z", "2026-05-01T14:40:00Z", "Teams"),
        _event("2026-05-01T14:00:10Z", "detector", "candidate_unreadable",
               bundle_id="com.microsoft.teams2", kind="native", reason="accessibility_untrusted"),
    ]
    span = _classify_spans(events)[0]
    assert span.handled is False
    assert span.miss_reason == "unreadable (com.microsoft.teams2 was running, Accessibility denied)"


def test_unreadable_outranks_a_drop_in_the_same_window() -> None:
    # Precedence: a permission that stops every read is more actionable than a scoring gap, and it
    # also explains the drop rather than competing with it.
    events = [
        *_mic("com.microsoft.teams2", "2026-05-01T15:00:00Z", "2026-05-01T15:40:00Z", "Teams"),
        _event("2026-05-01T15:00:05Z", "detector", "candidate_dropped",
               bundle_id="com.brave.Browser", reason="no_confident_winner", score=2),
        _event("2026-05-01T15:00:10Z", "detector", "candidate_unreadable",
               bundle_id="com.microsoft.teams2", kind="native", reason="accessibility_untrusted"),
    ]
    assert "Accessibility denied" in _classify_spans(events)[0].miss_reason


def test_shadow_pick_without_prompt_reads_as_suppressed() -> None:
    events = [
        *_mic("us.zoom.xos", "2026-05-01T13:00:00Z", "2026-05-01T13:40:00Z", "Zoom"),
        _event("2026-05-01T13:00:05Z", "detector", "discovery_shadow_pick",
               winner_bundle_id="us.zoom.xos"),
    ]
    span = _classify_spans(events)[0]
    assert span.handled is False
    assert "discovered but not prompted" in span.miss_reason


def test_clean_week_reports_zero_mic_misses() -> None:
    # A recorded meeting plus a short dictation blip: the meeting is handled and the blip is below
    # --min-miss-sec, so the report shows zero mic-busy misses.
    events = [
        *_mic("us.zoom.xos", "2026-05-01T11:00:00Z", "2026-05-01T11:30:05Z", "Zoom"),
        _event("2026-05-01T11:00:05Z", "coordinator", "recording_started",
               file="m.wav", bundle_id="us.zoom.xos"),
        _event("2026-05-01T11:30:00Z", "coordinator", "recording_stopped",
               file="m.wav", bundle_id="us.zoom.xos"),
        *_mic("com.apple.Dictation", "2026-05-01T14:00:00Z", "2026-05-01T14:00:08Z", "Dictation"),
    ]
    sessions = [classify_session(s) for s in pair_sessions(events)]
    report = render_report(sessions, aggregate(sessions), mic_spans=_classify_spans(events))
    assert "## Mic-busy misses (0)" in report


def test_main_reports_mic_miss_in_markdown_and_json(tmp_path: Path, capsys) -> None:
    events = _mic("chat.unknown.app", "2026-05-01T10:00:00Z", "2026-05-01T10:45:00Z", "Unknown Chat")
    source = _write_events(tmp_path / "events.jsonl", events)

    rc = main(["--source", str(source)])
    assert rc == 0
    out = capsys.readouterr().out
    assert "## Mic-busy misses (1)" in out
    assert "Unknown Chat" in out
    assert "no candidate" in out

    rc = main(["--source", str(source), "--json"])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["mic_busy"]["spans_observed"] == 1
    assert payload["mic_busy"]["misses"][0]["bundle_id"] == "chat.unknown.app"
    assert "no candidate" in payload["mic_busy"]["misses"][0]["reason"]


def test_min_miss_sec_excludes_short_spans(tmp_path: Path, capsys) -> None:
    events = _mic("com.apple.Dictation", "2026-05-01T14:00:00Z", "2026-05-01T14:00:15Z", "Dictation")
    source = _write_events(tmp_path / "events.jsonl", events)
    # 15 s span, default threshold 30 s -> not a miss.
    rc = main(["--source", str(source), "--json"])
    assert rc == 0
    assert json.loads(capsys.readouterr().out)["mic_busy"]["misses"] == []
    # Lower the threshold and it surfaces.
    rc = main(["--source", str(source), "--json", "--min-miss-sec", "5"])
    assert rc == 0
    assert len(json.loads(capsys.readouterr().out)["mic_busy"]["misses"]) == 1


# --- DET10: zero misses is not zero spans -------------------------------------------------


def _unavailable(ts: str) -> dict:
    return _event(ts, "detector", "mic_device_unavailable", authorization="authorized")


def test_collect_mic_input_faults_reads_only_its_own_action() -> None:
    events = [
        _unavailable("2026-05-01T09:00:00Z"),
        _event("2026-05-01T09:01:00Z", "detector", "candidate_dropped", bundle_id="x"),
        _event("2026-05-01T09:02:00Z", "coordinator", "mic_device_unavailable"),  # wrong category
        _unavailable("2026-05-01T09:03:00Z"),
    ]
    assert len(collect_mic_input_faults(events)) == 2


def test_collect_mic_input_faults_filters_by_since() -> None:
    events = [_unavailable("2026-05-01T09:00:00Z"), _unavailable("2026-05-08T09:00:00Z")]
    since = datetime(2026, 5, 5, tzinfo=timezone.utc)
    assert len(collect_mic_input_faults(events, since=since)) == 1


def test_mic_input_status_reports_what_was_measured() -> None:
    spans = pair_mic_spans(_mic("us.zoom.xos", "2026-05-01T11:00:00Z", "2026-05-01T11:30:00Z"))
    fault = [datetime(2026, 5, 1, 9, tzinfo=timezone.utc)]
    # Spans exist: a zero-miss count is a real measurement, whatever else is in the log.
    assert mic_input_status(spans, []) == MIC_INPUT_OBSERVED
    assert mic_input_status(spans, fault) == MIC_INPUT_OBSERVED
    # No spans: the dimension audited nothing, and the fault event says why.
    assert mic_input_status([], fault) == MIC_INPUT_DEVICE_UNAVAILABLE
    assert mic_input_status([], []) == MIC_INPUT_NO_SPANS


def test_a_week_with_no_mic_spans_does_not_render_as_zero_misses() -> None:
    """The filing's whole point: recordings all ended cleanly, and the mic-busy dimension measured
    nothing at all. The section must exist and must not claim a count."""
    events = [
        _event("2026-05-01T10:00:00Z", "coordinator", "recording_started",
               file="m.wav", bundle_id="us.zoom.xos"),
        _event("2026-05-01T10:30:00Z", "lifecycle", "ended", bundle_id="us.zoom.xos"),
        _event("2026-05-01T10:30:02Z", "coordinator", "recording_stopped",
               file="m.wav", bundle_id="us.zoom.xos"),
    ]
    sessions = [classify_session(s) for s in pair_sessions(events)]
    report = render_report(sessions, aggregate(sessions), mic_spans=[])
    assert "## Mic-busy misses (not audited)" in report
    assert "## Mic-busy misses (0)" not in report
    assert "det10-mic-busy-probe.swift" in report


def test_dead_input_names_the_daemon_event_as_the_cause() -> None:
    fault = datetime(2026, 5, 1, 9, 0, tzinfo=timezone.utc)
    report = render_report([], {}, mic_spans=[], mic_input_faults=[fault])
    assert "## Mic-busy misses (not audited)" in report
    assert "mic_device_unavailable" in report
    assert "2026-05-01T09:00:00" in report
    # It is not the fresh-install skeleton: there IS something to report.
    assert "No recording sessions" not in report


def test_empty_log_still_returns_the_skeleton() -> None:
    # Guard against the DET10 section swallowing the fresh-install case: no events at all is not a
    # false-clean, there is simply no window to be clean about.
    assert "No recording sessions" in render_report([], {}, mic_spans=[], mic_input_faults=[])


def test_json_mode_distinguishes_zero_misses_from_zero_spans(tmp_path: Path, capsys) -> None:
    # A machine reader saw `spans_observed: 0, misses: []` for both, which is the same false-clean
    # one level down.
    quiet = _write_events(tmp_path / "quiet.jsonl", [
        _event("2026-05-01T10:00:00Z", "coordinator", "recording_started", file="m.wav"),
        _event("2026-05-01T10:30:00Z", "coordinator", "recording_stopped", file="m.wav"),
    ])
    assert main(["--source", str(quiet), "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)["mic_busy"]
    assert payload["input_status"] == MIC_INPUT_NO_SPANS
    assert payload["spans_observed"] == 0
    assert payload["device_unavailable_events"] == 0

    dead = _write_events(tmp_path / "dead.jsonl", [_unavailable("2026-05-01T09:00:00Z")])
    assert main(["--source", str(dead), "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)["mic_busy"]
    assert payload["input_status"] == MIC_INPUT_DEVICE_UNAVAILABLE
    assert payload["device_unavailable_events"] == 1

    live = _write_events(tmp_path / "live.jsonl", _mic(
        "chat.unknown.app", "2026-05-01T10:00:00Z", "2026-05-01T10:45:00Z", "Unknown Chat"))
    assert main(["--source", str(live), "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["mic_busy"]["input_status"] == MIC_INPUT_OBSERVED
