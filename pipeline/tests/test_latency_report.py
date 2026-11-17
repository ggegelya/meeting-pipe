"""OBS7: scripts/latency_report.py over a canned two-build event log (a rotated generation plus the base)."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

_SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "latency_report.py"
_spec = importlib.util.spec_from_file_location("latency_report", _SCRIPT)
assert _spec and _spec.loader
latency_report = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(latency_report)


def _row(category: str, action: str, ts: str, **attrs) -> dict:
    return {"category": category, "action": action, "ts": ts, **attrs}


def _click(seq: int, name: str, ts: str, surface: str = "hud") -> dict:
    return _row("ui", "ui_action", ts, seq=seq, name=name, surface=surface)


def _fb(seq: int, ms: int, ts: str) -> dict:
    return _row("ui", "ui_feedback", ts, seq=seq, ms=ms)


def _write(path: Path, rows: list[dict]) -> None:
    path.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")


def _canned(tmp_path: Path) -> Path:
    base = tmp_path / "events.jsonl"
    # Build A, in the rotated generation (oldest).
    _write(tmp_path / "events.1.jsonl", [
        _row("main", "app_rebuild", "2026-11-17T08:00:00Z", prev_cdhash="0", new_cdhash="aaaaaaaa11"),
        _click(1, "hud_stop", "2026-11-17T08:01:00Z"), _fb(1, 10, "2026-11-17T08:01:00Z"),
        _click(2, "hud_stop", "2026-11-17T08:02:00Z"), _fb(2, 20, "2026-11-17T08:02:00Z"),
        _click(3, "hud_stop", "2026-11-17T08:03:00Z"), _fb(3, 300, "2026-11-17T08:03:00Z"),
        _click(4, "hotkey_toggle", "2026-11-17T08:04:00.000Z", surface="hotkey"),
        _fb(4, 100, "2026-11-17T08:04:00.100Z"),
        _row("ui", "first_paint", "2026-11-17T08:04:00.150Z", seq=4, surface="hud", phase="present", ms=150),
        _row("coordinator", "recording_started", "2026-11-17T08:04:00.600Z"),
        _row("ui", "window_opened", "2026-11-17T08:05:00Z", window="guide", cold=True, seq=5, ms_to_key=200),
    ])
    # Build B, in the base log. The daemon restarted, so the sequence starts over at 1.
    _write(base, [
        _row("main", "app_rebuild", "2026-11-17T09:00:00Z", prev_cdhash="aaaaaaaa11", new_cdhash="bbbbbbbb22"),
        _click(1, "hud_stop", "2026-11-17T09:01:00Z"), _fb(1, 40, "2026-11-17T09:01:00Z"),
        _row("ui", "window_opened", "2026-11-17T09:02:00Z", window="guide", cold=False, seq=2, ms_to_key=None),
        _row("ui", "window_opened", "2026-11-17T09:03:00Z", window="guide", cold=False, seq=3, ms_to_key=0),
    ])
    return base


def test_n_median_p90_max_per_action_and_per_build(tmp_path):
    report = latency_report.build_report(latency_report.dogfood._load(_canned(tmp_path), None))
    assert list(report) == ["aaaaaaaa", "bbbbbbbb"]
    a = report["aaaaaaaa"]
    assert a["feedback_ms"]["hud_stop"] == {"n": 3, "median": 20.0, "p90": 300.0, "max": 300.0}
    assert a["feedback_ms"]["hotkey_toggle"]["n"] == 1
    assert a["first_paint_ms"]["hotkey_toggle"]["median"] == 150.0
    assert a["completion_ms"]["hotkey_toggle"]["median"] == 600.0
    assert a["window_ms_to_key"]["guide"]["median"] == 200.0
    b = report["bbbbbbbb"]
    # The same seq in the next process answers the click that preceded it, not build A's.
    assert b["feedback_ms"]["hud_stop"] == {"n": 1, "median": 40.0, "p90": 40.0, "max": 40.0}
    # A null ms_to_key (the window never became key) is not a sample.
    assert b["window_ms_to_key"]["guide"]["n"] == 1


def test_it_reads_only(tmp_path, capsys):
    base = _canned(tmp_path)
    before = {p.name: p.read_bytes() for p in tmp_path.iterdir()}
    assert latency_report.main(["--events", str(base)]) == 0
    assert latency_report.main(["--events", str(base), "--json"]) == 0
    assert {p.name: p.read_bytes() for p in tmp_path.iterdir()} == before
    out = capsys.readouterr().out
    assert "build aaaaaaaa" in out and "hud_stop" in out


def test_an_empty_log_says_so(tmp_path, capsys):
    assert latency_report.main(["--events", str(tmp_path / "events.jsonl")]) == 0
    assert "No `ui` rows" in capsys.readouterr().out


def test_a_completion_row_long_after_the_click_answers_nothing(tmp_path):
    base = tmp_path / "events.jsonl"
    _write(base, [
        _click(1, "menu_start", "2026-11-17T08:00:00Z", surface="menu"),
        _row("coordinator", "recording_started", "2026-11-17T08:10:00Z"),
    ])
    report = latency_report.build_report(latency_report.dogfood._load(base, None))
    assert "completion_ms" not in report.get(latency_report.UNKNOWN_BUILD, {})


def test_a_completion_only_answers_the_clicks_that_can_cause_it(tmp_path):
    base = tmp_path / "events.jsonl"
    _write(base, [
        _click(1, "open_window", "2026-11-17T08:00:00.000Z", surface="guide"),
        _click(2, "prompt_skip", "2026-11-17T08:00:01.000Z", surface="prompt"),
        _click(3, "menu_start", "2026-11-17T08:00:02.000Z", surface="menu"),
        _row("coordinator", "recording_stopped", "2026-11-17T08:00:03.000Z"),
        _row("coordinator", "recording_started", "2026-11-17T08:00:04.000Z"),
    ])
    completion = latency_report.build_report(latency_report.dogfood._load(base, None))[
        latency_report.UNKNOWN_BUILD]["completion_ms"]
    # The stop row cannot answer a Start press, and a window open or a Skip has no completion row.
    assert list(completion) == ["menu_start"]
    assert completion["menu_start"]["median"] == 2000.0
