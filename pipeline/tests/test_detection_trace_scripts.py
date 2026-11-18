"""T8: the detection-corpus helpers' raw lifecycle path.

`extract_detection_trace.py --raw` turns a window of a real `events.jsonl` into an
`engine: "lifecycle"` trace, and `redact_detection_trace.py --check` is the gate every
committed trace passes. Both live in scripts/ (stdlib-only, run on a clean Mac without
uv), so they are loaded by path, as test_valid1_check.py does. This file is also their
only CI coverage: ruff and pyright are scoped to pipeline/, and CI runs this on Linux,
so a non-stdlib import in either script fails here at once.
"""
from __future__ import annotations

import importlib.util
import json
from datetime import datetime
from pathlib import Path

_SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
_CORPUS = (Path(__file__).resolve().parents[2]
           / "daemon" / "Tests" / "MeetingPipeCoreTests" / "Fixtures" / "detection-corpus")


def _load(name: str):
    spec = importlib.util.spec_from_file_location(name, _SCRIPTS / f"{name}.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


extract = _load("extract_detection_trace")
redact = _load("redact_detection_trace")

TEAMS = "com.microsoft.teams2"


def _row(ts: str, category: str, action: str, **attrs) -> dict:
    return {"ts": ts, "category": category, "action": action, **attrs}


def _ts(raw: str) -> datetime:
    parsed = extract._parse_ts(raw)
    assert parsed is not None
    return parsed


def _end15_log() -> list[dict]:
    """END15's 2026-10-22 rows as its spec quotes them, plus the call's start and noise a
    real log carries: a title-bearing row, another app's signal, a real pid."""
    return [
        _row("2026-10-22T12:00:20.000Z", "signal", "process_audio_is_running_input",
             bundle_id=TEAMS, pid=635, value=True, reason="initial", previous=None),
        _row("2026-10-22T12:00:20.002Z", "lifecycle", "starting", bundle_id=TEAMS, kind="native", pid=635),
        _row("2026-10-22T12:00:20.010Z", "signal", "ax_leave_button_state",
             bundle_id=TEAMS, pid=635, state="healthy", reason="initial", previous=None),
        _row("2026-10-22T12:00:20.020Z", "signal", "shareable_content_window_present",
             bundle_id=TEAMS, value=True, reason="initial", previous=None),
        _row("2026-10-22T12:00:25.000Z", "coordinator", "recording_started",
             bundle_id=TEAMS, file="20261022-150025.wav", workflow_name="Client work"),
        _row("2026-10-22T12:00:25.010Z", "lifecycle", "in_meeting", bundle_id=TEAMS, kind="native", pid=635),
        _row("2026-10-22T12:10:00.000Z", "signal", "shareable_content_no_match",
             bundle_id=TEAMS, candidate_titles=["Quarterly sync with Acme | Microsoft Teams"], reason="poll"),
        _row("2026-10-22T12:14:51.000Z", "signal", "process_audio_is_running_input",
             bundle_id="us.zoom.xos", pid=99, value=False, reason="poll", previous=True),
        _row("2026-10-22T12:14:53.286Z", "signal", "ax_leave_button_state",
             bundle_id=TEAMS, pid=635, state="invalid", reason="health_poll", previous="healthy"),
        _row("2026-10-22T12:14:53.287Z", "lifecycle", "ending_provisional",
             bundle_id=TEAMS, kind="native", pid=635, leading_signal="ax_leave_button_invalid"),
        _row("2026-10-22T12:14:53.443Z", "coordinator", "lifecycle_end_held",
             bundle_id=TEAMS, hold_cap_sec=150, live_signal="call_is_up"),
        _row("2026-10-22T12:14:59.002Z", "signal", "process_audio_is_running_input",
             bundle_id=TEAMS, pid=635, value=False, reason="poll", previous=True),
        _row("2026-10-22T12:14:59.006Z", "lifecycle", "ended", bundle_id=TEAMS, kind="native", pid=635,
             leading_signal="ax_leave_button_invalid", confirmed_by=["process_audio_is_running_input_false"]),
        _row("2026-10-22T12:14:59.012Z", "coordinator", "state_change", **{"from": "recording", "to": "stopping"}),
        _row("2026-10-22T12:15:21.948Z", "coordinator", "record_attached", bundle_id=TEAMS, trigger="manual"),
        _row("2026-10-22T12:15:22.542Z", "signal", "process_audio_is_running_input",
             bundle_id=TEAMS, pid=635, value=True, reason="initial", previous=None),
        _row("2026-10-22T12:15:22.569Z", "signal", "ax_leave_button_state",
             bundle_id=TEAMS, pid=635, state="healthy", reason="initial", previous=None),
    ]


def _extract(rows: list[dict], start: str, end: str, **kwargs) -> tuple[dict, list[str]]:
    return extract.extract_raw(rows, _ts(start), _ts(end), **kwargs)


def _clean(trace: dict) -> bool:
    return not redact.validate(trace) and not redact.scan_pii(trace) and not redact.needs_redaction(trace)


# ------------------------------------------------------------------ extractor --raw

def test_raw_window_maps_signal_rows_and_carries_the_state_before_it():
    trace, _ = _extract(_end15_log(), "2026-10-22T12:14:50Z", "2026-10-22T12:15:25Z")

    assert trace["engine"] == "lifecycle"
    assert trace["origin"] == "raw"
    assert trace["context"] == {"bundle_id": TEAMS, "kind": "native", "pid": 1234}
    assert trace["until"] == 35.0
    events = trace["events"]
    carried = [e for e in events if e.get("carried")]
    # The last reading of each signal, and the recording's start, from before the window,
    # at their real (negative) offsets so the oracle's recording-start floor is right.
    assert {(e["kind"], e.get("state")) for e in carried} == {
        ("process_audio_is_running_input_false", "live"),
        ("ax_leave_button", "live"),
        ("shareable_content_window", "live"),
        ("recording_started", None),
    }
    assert next(e for e in carried if e["kind"] == "recording_started")["t"] == -865.0
    in_window = [(e["t"], e["kind"], e.get("state")) for e in events if not e.get("carried")]
    assert (3.286, "ax_leave_button", "ended") in in_window
    assert (9.002, "process_audio_is_running_input_false", "ended") in in_window
    assert (32.542, "process_audio_is_running_input_false", "live") in in_window
    assert (3.443, "live_signal", None) in in_window


def test_raw_window_is_redaction_clean_by_construction():
    trace, _ = _extract(_end15_log(), "2026-10-22T12:00:00Z", "2026-10-22T12:15:25Z")
    text = json.dumps(trace)

    assert "Acme" not in text and "Quarterly" not in text, "a title must never reach a trace"
    assert "Client work" not in text and "150025" not in text
    assert "635" not in text and "us.zoom.xos" not in text, "real pids and other apps are dropped"
    assert _clean(trace)


def test_the_logged_verdicts_are_kept_as_record_not_as_expectation():
    trace, _ = _extract(_end15_log(), "2026-10-22T12:14:50Z", "2026-10-22T12:15:25Z")

    assert trace["expected_outcome"] == "no_end", "an incident trace expects the correct outcome"
    assert {"t": 9.006, "verdict": "ended", "leading": "ax_leave_button_invalid",
            "confirmed_by": ["process_audio_is_running_input_false"]} in trace["logged_verdicts"]


def test_only_an_observed_teardown_becomes_teardown_evidence():
    rows = _end15_log()[:6] + [
        _row("2026-10-22T12:14:53.286Z", "signal", "ax_leave_button_state",
             bundle_id=TEAMS, pid=635, state="invalid", reason="health_poll", previous="healthy"),
        _row("2026-10-22T12:14:53.443Z", "coordinator", "lifecycle_end_held", bundle_id=TEAMS,
             oracle_available=True, log_written_sec_ago=30.5, live_signal="call_is_up"),
        _row("2026-10-22T12:16:23.443Z", "coordinator", "lifecycle_provisional_end_confirmed",
             bundle_id=TEAMS, oracle="hold_cap_reached", held_sec=150.0),
        _row("2026-10-22T12:16:24.000Z", "coordinator", "lifecycle_provisional_end_confirmed",
             bundle_id=TEAMS, oracle="teardown_observed", held_sec=150.6),
    ]
    trace, report = _extract(rows, "2026-10-22T12:14:50Z", "2026-10-22T12:16:30Z")

    snapshots = [e for e in trace["events"] if e["kind"] == "teardown_snapshot"]
    assert snapshots == [
        {"t": 3.443, "kind": "teardown_snapshot", "available": True, "teardown_at": None, "log_written_at": -27.057},
        {"t": 94.0, "kind": "teardown_snapshot", "available": True, "teardown_at": 94.0, "log_written_at": None},
    ]
    assert any("hold_cap_reached" in line for line in report), "a retired confirm is reported, not replayed"


def test_a_found_rewalk_and_an_unreadable_log_are_carried_as_host_inputs():
    rows = _end15_log()[:6] + [
        _row("2026-10-22T12:14:52.000Z", "coordinator", "call_teardown_source_missing", cause="permission"),
        _row("2026-10-22T12:14:53.410Z", "coordinator", "lifecycle_provisional_end_rescued",
             bundle_id=TEAMS, leave_buttons_found=1),
    ]
    trace, _ = _extract(rows, "2026-10-22T12:14:50Z", "2026-10-22T12:15:00Z")

    kinds = [(e["kind"], e.get("found"), e.get("available")) for e in trace["events"] if not e.get("carried")]
    assert ("teardown_snapshot", None, False) in kinds
    assert ("rewalk", True, None) in kinds


def test_a_title_keyed_signal_is_dropped_and_reported():
    rows = _end15_log()[:6] + [
        _row("2026-10-22T12:14:55.000Z", "signal", "window_title_changed",
             bundle_id=TEAMS, title="Acme roadmap", previous="Acme", reason="title_changed_notification"),
    ]
    trace, report = _extract(rows, "2026-10-22T12:14:50Z", "2026-10-22T12:15:00Z")

    assert "Acme" not in json.dumps(trace)
    assert any("window_title_changed" in line for line in report)


def test_a_browser_window_signal_maps_to_the_tab_title_kind():
    rows = [
        _row("2026-10-16T09:27:35.477Z", "signal", "shareable_content_window_present",
             bundle_id="com.apple.Safari", value=True, reason="initial", previous=None),
        _row("2026-10-16T09:27:35.477Z", "lifecycle", "starting", bundle_id="com.apple.Safari", kind="browser", pid=7),
        _row("2026-10-16T09:46:08.611Z", "signal", "shareable_content_window_present",
             bundle_id="com.apple.Safari", value=False, reason="poll", previous=True),
    ]
    trace, _ = _extract(rows, "2026-10-16T09:46:00Z", "2026-10-16T09:46:20Z")

    assert trace["context"]["kind"] == "browser"
    assert {"t": 8.611, "kind": "browser_tab_title", "state": "ended"} in trace["events"]


def test_an_ended_engagement_carries_nothing_into_the_window():
    rows = _end15_log()[:6] + [_row("2026-10-22T12:10:00.000Z", "lifecycle", "idle")] + [
        _row("2026-10-22T12:14:53.286Z", "signal", "ax_leave_button_state",
             bundle_id=TEAMS, pid=635, state="invalid", reason="health_poll", previous="healthy"),
    ]
    trace, _ = _extract(rows, "2026-10-22T12:14:50Z", "2026-10-22T12:15:00Z", bundle=TEAMS)

    assert trace["context"]["kind"] == "native", "the kind comes from the newest lifecycle row before"
    assert not [e for e in trace["events"] if e.get("carried")]


def test_reproduction_compares_the_replayed_content_and_ignores_prose():
    trace, _ = _extract(_end15_log(), "2026-10-22T12:14:50Z", "2026-10-22T12:15:25Z")
    committed = json.loads(json.dumps(trace))
    committed["description"] = "edited by the session"
    committed["scenario"] = "teams_native_end15_mic_switch_raw"

    assert extract.reproduction_drift(trace, committed) == []

    committed["events"][-1]["t"] += 1
    assert extract.reproduction_drift(trace, committed) == ["events"]


def test_raw_cli_writes_a_trace_that_passes_the_check(tmp_path: Path, capsys):
    log = tmp_path / "events.jsonl"
    log.write_text("\n".join(json.dumps(r) for r in _end15_log()) + "\n\n", encoding="utf-8")
    out = tmp_path / "trace.json"

    code = extract.main(["--events", str(log), "--raw", "--from", "2026-10-22T12:14:50Z",
                         "--to", "2026-10-22T12:15:25Z", "--scenario", "teams_native_end15_raw",
                         "--out", str(out)])

    assert code == 0
    assert redact.main([str(out), "--check"]) == 0
    assert extract.main(["--events", str(log), "--raw", "--from", "2026-10-22T12:14:50Z",
                         "--to", "2026-10-22T12:15:25Z", "--check-against", str(out)]) == 0
    capsys.readouterr()


# ------------------------------------------------------------------ redactor --check

def test_check_fails_a_trace_that_still_needs_redacting(tmp_path: Path):
    draft = {"scenario": "x", "description": "y", "engine": "promotion",
             "context": {"bundle_id": TEAMS, "kind": "native", "pid": 635},
             "events": [], "expected_verdicts": []}
    path = tmp_path / "draft.json"
    path.write_text(json.dumps(draft), encoding="utf-8")

    assert redact.main([str(path), "--check"]) == 1, "a real pid in the file is not redacted"


def test_lifecycle_schema_rejects_unknown_host_inputs_and_free_text():
    base = {"scenario": "x", "description": "y", "engine": "lifecycle", "origin": "raw",
            "expected_outcome": "no_end", "until": 10.0,
            "context": {"bundle_id": TEAMS, "kind": "native", "pid": 1234}}

    assert redact.validate({**base, "events": [{"t": 0.0, "kind": "teams_chat", "text": "hi"}]})
    assert redact.validate({**base, "events": [{"t": 0.0, "kind": "live_signal", "value": "probably"}]})
    assert redact.validate({**base, "events": [{"t": 0.0, "kind": "ax_leave_button", "state": "gone"}]})
    assert redact.validate({**base, "events": [], "logged_verdicts": [
        {"t": 0.0, "verdict": "ended", "leading": "Acme roadmap call"}]})
    assert redact.validate({**base, "origin": "guess", "events": []})
    assert redact.validate({**base, "expected_outcome": "ended", "events": []}), "an end needs ended_at"
    assert not redact.validate({**base, "events": [
        {"t": 0.0, "kind": "recording_started", "carried": True},
        {"t": 1.0, "kind": "teardown_snapshot", "available": True, "teardown_at": None, "log_written_at": 0.5},
        {"t": 2.0, "kind": "rewalk", "found": False},
        {"t": 3.0, "kind": "live_signal", "value": "call_is_up"},
    ]})


def test_every_committed_corpus_trace_passes_the_strict_check():
    traces = sorted(_CORPUS.glob("*.json"))
    assert len(traces) > 30
    for path in traces:
        if path.name == "INDEX.json":
            continue
        trace = json.loads(path.read_text(encoding="utf-8"))
        assert _clean(trace), f"{path.name} fails redact_detection_trace.py --check"


def test_a_teardown_line_row_puts_its_own_time_in_the_snapshot():
    # END16: the confirm-time fallback could only replay the logged decision. With the line's own
    # row, the snapshot carries when Teams wrote it, so a replay can ask whether a different rule
    # would have confirmed sooner. A registration line is never teardown evidence.
    rows = _end15_log()[:6] + [
        _row("2026-10-22T12:14:53.443Z", "coordinator", "lifecycle_end_held", bundle_id=TEAMS,
             oracle_available=True, log_written_sec_ago=30.5, live_signal="call_is_down"),
        _row("2026-10-22T12:14:54.000Z", "coordinator", "call_teardown_line", kind="register",
             line_at="2026-10-22T12:00:00.000Z", call_id_hash="ab12cd34", read_lag_sec=894.0),
        _row("2026-10-22T12:15:40.000Z", "coordinator", "call_teardown_line", kind="unregister",
             line_at="2026-10-22T12:15:38.500Z", call_id_hash="ab12cd34", read_lag_sec=1.5),
        _row("2026-10-22T12:15:40.200Z", "coordinator", "lifecycle_provisional_end_confirmed",
             bundle_id=TEAMS, oracle="teardown_observed", held_sec=46.8),
    ]
    trace, report = _extract(rows, "2026-10-22T12:14:50Z", "2026-10-22T12:16:30Z")

    snapshots = [e for e in trace["events"] if e["kind"] == "teardown_snapshot"]
    assert snapshots[1:] == [
        {"t": 50.0, "kind": "teardown_snapshot", "available": True, "teardown_at": 48.5, "log_written_at": None},
    ], "one snapshot at the line's read, carrying the line's own time; none from the register line or the confirm"
    assert any("covered by a call_teardown_line" in line for line in report)


def test_a_confirm_without_a_line_row_falls_back_and_says_so():
    rows = _end15_log()[:6] + [
        _row("2026-10-22T12:16:24.000Z", "coordinator", "lifecycle_provisional_end_confirmed",
             bundle_id=TEAMS, oracle="teardown_observed", held_sec=150.6),
    ]
    trace, report = _extract(rows, "2026-10-22T12:14:50Z", "2026-10-22T12:16:30Z")
    snapshots = [e for e in trace["events"] if e["kind"] == "teardown_snapshot"]
    assert snapshots == [{"t": 94.0, "kind": "teardown_snapshot", "available": True, "teardown_at": 94.0, "log_written_at": None}]
    assert any("teardown_at is the confirm time" in line for line in report)


def test_a_recovered_row_makes_the_log_readable_again():
    rows = _end15_log()[:6] + [
        _row("2026-10-22T12:14:52.000Z", "coordinator", "call_teardown_source_missing", reason="x", failures=1),
        _row("2026-10-22T12:14:55.000Z", "coordinator", "call_teardown_source_recovered", outage_sec=3.0, failures=3),
    ]
    trace, _ = _extract(rows, "2026-10-22T12:14:50Z", "2026-10-22T12:15:00Z")
    availability = [e["available"] for e in trace["events"] if e["kind"] == "teardown_snapshot"]
    assert availability == [False, True]


# ------------------------------------------------------------------ T17

def _session(confirmed_by: list[str], leading: str = "ax_leave_button_invalid"):
    s = extract.Session({"ts": "2026-10-22T12:00:00.000Z", "bundle_id": TEAMS, "kind": "native"})
    s.in_meeting = True
    s.steps = [("provisional", leading, _ts("2026-10-22T12:10:00.000Z"))]
    s.leading = leading
    s.confirmed_by = confirmed_by
    s.end = _ts("2026-10-22T12:10:01.000Z")
    return s


def test_a_distilled_trace_says_it_is_a_constructed_template():
    # T17 (G023): the extractor rebuilds the timeline from logged verdicts, fabricating the opening
    # live event and the lone-dwell tick, so its description may not claim a real session.
    for confirmed, leading in ((["ax_leave_rewalk"], "ax_leave_button_invalid"),
                               ([], "shareable_content_window_gone")):
        trace, _ = extract.synthesize(_session(confirmed, leading), "s")
        assert trace is not None
        assert "Real dogfood session" not in trace["description"]
        assert "constructed, not logged" in trace["description"]
        assert "Evidence for no end rule" in trace["description"]


def test_the_committed_legacy_traces_carry_the_template_words():
    index = json.loads((_CORPUS / "INDEX.json").read_text(encoding="utf-8"))
    legacy = index["legacy_characterization"]
    assert len(legacy) == 22
    assert not set(legacy) & set(index["scenarios"])
    distilled = [n for n in legacy if "_end_" in n]
    assert len(distilled) == 20
    for name in distilled:
        description = json.loads((_CORPUS / name).read_text(encoding="utf-8"))["description"]
        assert description.startswith(extract.TEMPLATE_PREFIX), name
        assert description.endswith(extract.TEMPLATE_SUFFIX), name


def _recording_log() -> list[dict]:
    """Three recordings: a lifecycle end, a hand stop, the idle backstop, and one never stopped."""
    return [
        _row("2026-10-22T09:00:00.000Z", "coordinator", "recording_started", bundle_id=TEAMS),
        _row("2026-10-22T09:30:00.000Z", "lifecycle", "ended", bundle_id=TEAMS,
             leading_signal="ax_leave_button_invalid", confirmed_by=["process_audio_is_running_input_false"]),
        _row("2026-10-22T09:30:01.000Z", "coordinator", "recording_stopped", bundle_id=TEAMS),
        _row("2026-10-22T10:00:00.000Z", "coordinator", "recording_started", bundle_id=TEAMS),
        # Another app's end inside the recording is not this recording's end.
        _row("2026-10-22T10:05:00.000Z", "lifecycle", "ended", bundle_id="us.zoom.xos",
             leading_signal="workspace_app_terminated", confirmed_by=[]),
        _row("2026-10-22T10:20:00.000Z", "coordinator", "recording_stopped", bundle_id=TEAMS),
        _row("2026-10-22T11:00:00.000Z", "coordinator", "recording_started", bundle_id="manual"),
        _row("2026-10-22T11:40:00.000Z", "coordinator", "auto_stop_silence", bundle_id="manual"),
        _row("2026-10-22T11:40:02.000Z", "coordinator", "recording_stopped", bundle_id="manual"),
        _row("2026-10-22T12:00:00.000Z", "coordinator", "recording_started", bundle_id=TEAMS),
    ]


def test_a_sourceless_recording_stopped_by_another_apps_end_is_a_lifecycle_end():
    rows = [
        _row("2026-11-11T13:59:52.000Z", "coordinator", "recording_started", bundle_id="manual"),
        _row("2026-11-11T14:14:28.000Z", "lifecycle", "ended", bundle_id="com.google.Chrome",
             leading_signal="browser_tab_title_left_meet_pattern", confirmed_by=[]),
        _row("2026-11-11T14:14:35.000Z", "coordinator", "recording_stopped", bundle_id="manual"),
    ]
    assert [r["cause"] for r in extract.recordings(rows)] == ["lifecycle_end"]


def test_the_inventory_reports_each_recordings_stop_cause():
    # T17 (D085): sessionize sees only ends the detector made, so a hand or backstop stop was never
    # inventoried. Segmenting by recording shows them as candidate windows.
    recs = extract.recordings(_recording_log())
    assert [r["cause"] for r in recs] == ["lifecycle_end", "hand_stop", "idle_backstop", "unclosed"]
    assert [r["lifecycle_ended"] for r in recs] == [True, False, False, False]
    assert recs[0]["cause_to_stop_s"] == 1.0
    assert recs[1]["duration_s"] == 1200.0


def test_the_inventory_prints_the_recordings(tmp_path, capsys):
    log = tmp_path / "events.jsonl"
    log.write_text("".join(json.dumps(r) + "\n" for r in _recording_log()), encoding="utf-8")
    assert extract.main(["--events", str(log), "--inventory"]) == 0
    out = capsys.readouterr().out
    assert "hand_stop" in out and "idle_backstop" in out
    assert "<- candidate" in out


def test_a_reengage_row_with_handles_becomes_an_engage_event_and_one_without_does_not():
    rows = _end15_log()[:6] + [
        _row("2026-10-22T12:14:55.000Z", "coordinator", "lifecycle_reengaged", bundle_id=TEAMS,
             reason="terminal_at_start", has_handles=True),
        # Without handles the host engaged nothing (`no_pid`): the terminal engine stays.
        _row("2026-10-22T12:14:57.000Z", "coordinator", "lifecycle_reengaged", bundle_id=TEAMS,
             reason="terminal_at_start", has_handles=False),
    ]
    trace, _ = _extract(rows, "2026-10-22T12:14:50Z", "2026-10-22T12:15:00Z")
    assert [e for e in trace["events"] if e["kind"] == "engage"] == [{"t": 5.0, "kind": "engage"}]
    assert _clean(trace)


def test_an_idle_row_in_the_window_becomes_an_engage_event():
    # The host's disengage after an acted end publishes idle; the replay re-engages there only if
    # its own engine has ended, which the Swift side pins.
    rows = _end15_log()[:6] + [_row("2026-10-22T12:14:56.000Z", "lifecycle", "idle")]
    trace, _ = _extract(rows, "2026-10-22T12:14:50Z", "2026-10-22T12:15:00Z")
    assert {"t": 6.0, "kind": "engage"} in trace["events"]


def test_stop_causes_name_ignored_ends_owner_force_stops_and_call_splits():
    rows = [
        # An end the host ignored, then the owner's own hotkey Stop.
        _row("2026-11-11T10:00:00.000Z", "coordinator", "recording_started", bundle_id="manual"),
        _row("2026-11-11T10:05:00.000Z", "lifecycle", "ended", bundle_id="com.google.Chrome",
             leading_signal="browser_tab_title_left_meet_pattern", confirmed_by=[]),
        _row("2026-11-11T10:05:00.010Z", "coordinator", "meeting_end_ignored_sourceless", bundle_id="com.google.Chrome"),
        _row("2026-11-11T10:20:00.000Z", "coordinator", "force_stop", reason="hotkey", state="recording"),
        _row("2026-11-11T10:20:01.000Z", "coordinator", "recording_stopped", bundle_id="manual"),
        # An app-side force stop.
        _row("2026-11-11T11:00:00.000Z", "coordinator", "recording_started", bundle_id=TEAMS),
        _row("2026-11-11T11:10:00.000Z", "coordinator", "force_stop", reason="low_space", state="recording"),
        _row("2026-11-11T11:10:01.000Z", "coordinator", "recording_stopped", bundle_id=TEAMS),
        # END28's split on a call change.
        _row("2026-11-11T12:00:00.000Z", "coordinator", "recording_started", bundle_id=TEAMS),
        _row("2026-11-11T12:10:00.000Z", "coordinator", "recording_split_on_call_change", bundle_id=TEAMS),
        _row("2026-11-11T12:10:01.000Z", "coordinator", "recording_stopped", bundle_id=TEAMS),
    ]
    recs = extract.recordings(rows)
    assert [r["cause"] for r in recs] == ["hand_stop", "other:force_stop", "other:call_changed"]
    assert recs[0]["lifecycle_ended"] is True, "the ignored end is still reported as logged"


def test_the_check_accepts_a_truth_label_and_rejects_an_unknown_key_beside_it():
    trace, _ = _extract(_end15_log(), "2026-10-22T12:14:50Z", "2026-10-22T12:15:25Z")
    trace["truth"] = {"call_ended_at": None, "truth_source": "redetect", "max_overrun_sec": None}
    assert _clean(trace)
    trace["truth"] = {"call_ended_at": 9.0, "truth_source": "mic_release", "max_overrun_sec": 20.0}
    assert _clean(trace)

    for bad in (
        {"call_ended_at": None, "truth_source": "redetect", "max_overrun_sec": None, "note": "Acme call"},
        {"call_ended_at": None, "truth_source": "a hunch", "max_overrun_sec": None},
        {"call_ended_at": 9.0, "truth_source": "mic_release", "max_overrun_sec": None},
        {"call_ended_at": "late", "truth_source": "owner_stop", "max_overrun_sec": 5.0},
        {"call_ended_at": 30.0, "truth_source": "owner_stop", "max_overrun_sec": 10.0},  # 30 + 10 >= until 35
        {"call_ended_at": -1.0, "truth_source": "owner_stop", "max_overrun_sec": 5.0},
    ):
        trace["truth"] = bad
        assert redact.validate(trace), bad


def test_a_stop_no_logged_end_caused_ends_the_trace():
    # T17: a hand stop disengages at HEAD too, so the replay may not run past it into an end the
    # host could never make for a recording that no longer exists.
    rows = _end15_log()[:6] + [
        _row("2026-10-22T12:14:53.000Z", "signal", "ax_leave_button_state",
             bundle_id=TEAMS, pid=635, state="invalid", reason="health_poll", previous="healthy"),
        _row("2026-10-22T12:14:58.000Z", "coordinator", "recording_stopped", bundle_id=TEAMS),
        _row("2026-10-22T12:14:58.100Z", "lifecycle", "idle"),
        _row("2026-10-22T12:15:10.000Z", "signal", "process_audio_is_running_input",
             bundle_id=TEAMS, pid=635, value=False, reason="poll", previous=True),
    ]
    trace, report = _extract(rows, "2026-10-22T12:14:50Z", "2026-10-22T12:15:30Z")
    assert trace["until"] == 8.0
    assert all(e["t"] <= 8.0 for e in trace["events"])
    assert any("no logged end before it" in line for line in report)

    # A stop a logged end caused is today's engine's to re-decide, so the window runs on.
    rows.insert(-3, _row("2026-10-22T12:14:57.000Z", "lifecycle", "ended", bundle_id=TEAMS,
                         leading_signal="ax_leave_button_invalid", confirmed_by=["lone_dwell"]))
    trace, _ = _extract(rows, "2026-10-22T12:14:50Z", "2026-10-22T12:15:30Z")
    assert trace["until"] == 40.0


# ------------------------------------------------------------------ OBS9

def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")


def test_a_log_split_across_both_families_extracts_as_the_single_file_did(tmp_path: Path):
    """OBS9 moved `call_teardown_source_missing` into `diagnostics.jsonl`; `_load` reads both."""
    rows = _end15_log()[:6] + [
        _row("2026-10-22T12:14:52.000Z", "coordinator", "call_teardown_source_missing", reason="x", failures=1),
        _row("2026-10-22T12:14:55.000Z", "coordinator", "call_teardown_source_recovered", outage_sec=3.0, failures=3),
    ]
    single = tmp_path / "single"
    split = tmp_path / "split"
    single.mkdir()
    split.mkdir()
    _write_jsonl(single / "events.jsonl", rows)
    diagnostic = [r for r in rows if r["action"] == "call_teardown_source_missing"]
    _write_jsonl(split / "events.jsonl", [r for r in rows if r not in diagnostic])
    _write_jsonl(split / "diagnostics.jsonl", diagnostic)

    loaded_single = extract._load(single / "events.jsonl")
    loaded_split = extract._load(split / "events.jsonl")
    assert loaded_split == loaded_single
    window = ("2026-10-22T12:14:50Z", "2026-10-22T12:15:00Z")
    assert _extract(loaded_split, *window) == _extract(loaded_single, *window)
