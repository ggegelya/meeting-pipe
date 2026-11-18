"""TECH-E4: dogfood_report aggregation over the event logs.

The script lives in scripts/ (stdlib-only, runs on a clean Mac without uv), so
it is loaded by path rather than imported as a package.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

_SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "dogfood_report.py"
_spec = importlib.util.spec_from_file_location("dogfood_report", _SCRIPT)
assert _spec and _spec.loader
dogfood_report = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dogfood_report)


def _ev(category: str, action: str, ts: str = "2026-06-01T10:00:00Z", **attrs):
    return {"category": category, "action": action, "ts": ts, **attrs}


def test_detection_and_micgate_counts():
    daemon = [
        _ev("lifecycle", "in_meeting"),
        _ev("lifecycle", "ended", leading_signal="ax_leave_button_invalid"),
        _ev("lifecycle", "ended", leading_signal="shareable_content_window_gone"),
        _ev("micgate", "verdict_changed", verdict="hot"),
        _ev("micgate", "verdict_changed", verdict="silent_by_rms"),
        _ev("micgate", "verdict_changed", verdict="hot"),
        _ev("coordinator", "pipeline_succeeded"),
    ]
    report = dogfood_report.build_report(daemon, [])
    assert report["detection"]["lifecycle"]["ended"] == 2
    assert report["detection"]["ended_by_leading_signal"]["ax_leave_button_invalid"] == 1
    assert report["micgate"]["verdict_changed"]["hot"] == 2
    assert report["detection"]["coordinator"]["pipeline_succeeded"] == 1


def test_pipeline_runs_skips_sinks_and_stage_timings():
    pipeline = [
        _ev("pipeline", "run_started"),
        _ev("pipeline", "stage_started", stage="summarize", ts="2026-06-01T10:00:00Z"),
        _ev("pipeline", "stage_completed", stage="summarize", ts="2026-06-01T10:00:04Z"),
        _ev("pipeline", "run_completed"),
        _ev("pipeline", "run_skipped", reason="byo"),
        _ev("pipeline", "run_skipped", reason="too_long"),
        _ev("pipeline", "run_failed"),
        _ev("publisher", "sink_completed", sink="notion"),
        _ev("publisher", "sink_failed", sink="notion"),
    ]
    report = dogfood_report.build_report([], pipeline)
    assert report["pipeline"]["runs"] == {"started": 1, "completed": 1, "skipped": 2, "failed": 1}
    assert report["pipeline"]["skipped_by_reason"]["byo"] == 1
    assert report["pipeline"]["sinks"]["notion"] == {"completed": 1, "failed": 1}
    assert report["pipeline"]["stage_seconds"]["summarize"]["n"] == 1
    assert report["pipeline"]["stage_seconds"]["summarize"]["mean"] == 4.0


def test_load_filters_by_since(tmp_path):
    log = tmp_path / "events.jsonl"
    log.write_text(
        '{"category":"lifecycle","action":"ended","ts":"2026-05-01T00:00:00Z"}\n'
        '{"category":"lifecycle","action":"ended","ts":"2026-06-10T00:00:00Z"}\n'
        "not json\n"
    )
    since = dogfood_report._parse_ts("2026-06-01T00:00:00Z")
    events = dogfood_report._load(log, since)
    assert len(events) == 1  # May filtered out, junk line skipped


def test_load_drops_test_residue(tmp_path):
    """The bug this filter exists for: both suites used to write into the user's real log,
    and the rows they left in the rotated generations are permanent. Unfiltered, the report
    counted 250 `pipeline_failed` on the dogfood Mac against 0 real ones.
    """
    log = tmp_path / "events.jsonl"
    log.write_text(
        '{"category":"coordinator","action":"pipeline_failed","file":"clip.wav",'
        '"ts":"2026-06-01T10:00:00Z"}\n'
        '{"category":"transcription","action":"engine_failed","engine":"fake",'
        '"file":"clip.wav","ts":"2026-06-01T10:00:00Z"}\n'
        '{"category":"coordinator","action":"pipeline_succeeded","file":"20260601-100000.wav",'
        '"ts":"2026-06-01T10:00:00Z"}\n'
    )
    report = dogfood_report.build_report(dogfood_report._load(log, None), [])
    assert report["detection"]["coordinator"] == {"pipeline_succeeded": 1}


def test_load_keeps_rows_that_name_no_meeting(tmp_path):
    """The filter keys on the meeting stem, so a row without one (state_change, and every
    lifecycle/micgate row) must survive it. Getting this wrong empties the report."""
    log = tmp_path / "events.jsonl"
    log.write_text(
        '{"category":"lifecycle","action":"ended","leading_signal":"ax","ts":"2026-06-01T10:00:00Z"}\n'
        '{"category":"coordinator","action":"state_change","ts":"2026-06-01T10:00:00Z"}\n'
    )
    events = dogfood_report._load(log, None)
    assert len(events) == 2


def test_render_empty_does_not_crash():
    out = dogfood_report.render_markdown(dogfood_report.build_report([], []))
    assert "MeetingPipe dogfood report" in out
    assert "(no events in range)" in out


def test_the_mirror_agrees_with_mp_events_on_the_merge_rows():
    # T9: the stdlib mirror keeps step with `mp.events.is_test_residue`.
    from mp import events

    rows = [
        {"action": "meetings_merged", "primary": "x", "fragments": ["y"]},
        {"action": "meetings_merged", "primary": "20260714-193655", "fragments": ["20260714-195012"]},
        {"action": "meetings_merge_resumed", "primary": "20260714-193655", "fragments": ["20260714-195012", "m"]},
    ]
    assert [dogfood_report._is_test_residue(r) for r in rows] == [events.is_test_residue(r) for r in rows]
    assert [events.is_test_residue(r) for r in rows] == [True, False, True]


def test_verdict_churn_is_summed():
    daemon = [
        _ev("micgate", "verdict_churn", reason_swaps=4, rms_opens=1, rms_closes=2, window_sec=60),
        _ev("micgate", "verdict_churn", reason_swaps=3, rms_opens=0, rms_closes=0, window_sec=12),
    ]
    report = dogfood_report.build_report(daemon, [])
    assert report["micgate"]["verdict_churn"] == {"reason_swaps": 7, "rms_opens": 1, "rms_closes": 2}
    assert "Unlogged churn" in dogfood_report.render_markdown(report)


def test_a_log_split_across_both_daemon_families_reports_as_the_single_file_did(tmp_path):
    """OBS9: `call_teardown_source_missing` and the HAL chatter now live in `diagnostics.jsonl`."""
    import json

    stem = "20260601-100000.wav"
    rows = [
        _ev("lifecycle", "in_meeting", ts="2026-06-01T10:00:00Z"),
        _ev("halbus", "subscribed", ts="2026-06-01T10:00:01Z"),
        _ev("coordinator", "call_teardown_source_missing", ts="2026-06-01T10:00:02Z", reason="x"),
        _ev("coordinator", "recording_started", ts="2026-06-01T10:00:03Z", file=stem),
        _ev("signal", "process_audio_object_resolved", ts="2026-06-01T10:00:04Z"),
    ]
    moved = {"subscribed", "call_teardown_source_missing", "process_audio_object_resolved"}

    def write(path, items):
        path.write_text("".join(json.dumps(r) + "\n" for r in items), encoding="utf-8")

    (tmp_path / "single").mkdir()
    (tmp_path / "split").mkdir()
    write(tmp_path / "single" / "events.jsonl", rows)
    write(tmp_path / "split" / "events.jsonl", [r for r in rows if r["action"] not in moved])
    write(tmp_path / "split" / "diagnostics.jsonl", [r for r in rows if r["action"] in moved])

    def report(base):
        events = base / "events.jsonl"
        daemon = dogfood_report._load(events, None, files=dogfood_report._daemon_files(events))
        daemon.sort(key=lambda e: str(e.get("ts", "")))
        return dogfood_report.build_report(daemon, [])

    assert report(tmp_path / "split") == report(tmp_path / "single")
    assert report(tmp_path / "split")["detection"]["coordinator"]["call_teardown_source_missing"] == 1
