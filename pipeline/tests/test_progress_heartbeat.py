"""TECH-UX5: the run-all progress heartbeat emits periodic stage_progress
events plus a stdout sentinel, so the Swift daemon can tell a slow stage from
a wedged one and surface it on the row."""
from __future__ import annotations

import json
import time

from mp import orchestrate
from mp.orchestrate import PROGRESS_SENTINEL, _ProgressHeartbeat


def test_heartbeat_emits_stage_progress_events(monkeypatch, capsys):
    recorded: list[tuple[str, str, dict]] = []
    monkeypatch.setattr(
        orchestrate.events,
        "emit",
        lambda category, action, **attrs: recorded.append((category, action, attrs)),
    )

    hb = _ProgressHeartbeat(interval_s=0.02)
    hb.set_stage("summarize")
    hb.start()
    time.sleep(0.1)
    hb.stop()

    progress = [a for (c, act, a) in recorded if c == "pipeline" and act == "stage_progress"]
    assert progress, "expected at least one stage_progress event"
    assert all(p["stage"] == "summarize" for p in progress)
    assert progress[-1]["beat"] >= 1
    assert "elapsed_s" in progress[-1]

    out = capsys.readouterr().out
    sentinel_lines = [ln for ln in out.splitlines() if ln.startswith(PROGRESS_SENTINEL)]
    assert sentinel_lines, "expected a stdout progress sentinel"
    payload = json.loads(sentinel_lines[-1][len(PROGRESS_SENTINEL):].strip())
    assert payload["stage"] == "summarize"
    assert "elapsed_s" in payload


def test_heartbeat_set_stage_updates_emitted_stage(monkeypatch):
    recorded: list[tuple[str, dict]] = []
    monkeypatch.setattr(
        orchestrate.events,
        "emit",
        lambda category, action, **attrs: recorded.append((action, attrs)),
    )
    hb = _ProgressHeartbeat(interval_s=0.02)
    hb.start()
    hb.set_stage("publish")
    time.sleep(0.08)
    hb.stop()
    stages = [a["stage"] for (act, a) in recorded if act == "stage_progress"]
    assert "publish" in stages
