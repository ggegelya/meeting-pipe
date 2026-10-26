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
