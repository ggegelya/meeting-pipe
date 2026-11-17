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


# ----- PIPE53: the beat says how long the stage has gone without progress -----


class _Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def test_stage_elapsed_resets_on_a_stage_change_and_on_progress_and_otherwise_grows():
    clock = _Clock()
    hb = _ProgressHeartbeat(clock=clock)
    hb.set_stage("summarize")
    clock.now += 40
    assert hb._snapshot() == ("summarize", 40, 40)
    clock.now += 50  # a request in flight the whole time: only the stage clock grows
    assert hb._snapshot() == ("summarize", 90, 90)
    hb.mark_progress()  # one model call returned
    clock.now += 7
    assert hb._snapshot() == ("summarize", 97, 7)
    hb.set_stage("publish")
    assert hb._snapshot() == ("publish", 97, 0)


def test_the_beat_carries_stage_elapsed_on_both_the_event_and_the_stdout_line(monkeypatch, capsys):
    recorded: list[dict] = []
    monkeypatch.setattr(
        orchestrate.events, "emit",
        lambda category, action, **attrs: recorded.append(attrs) if action == "stage_progress" else None,
    )
    hb = _ProgressHeartbeat(interval_s=0.02)
    hb.start()
    time.sleep(0.1)
    hb.stop()
    assert recorded and all("stage_elapsed_s" in r for r in recorded)
    line = next(ln for ln in capsys.readouterr().out.splitlines() if ln.startswith(PROGRESS_SENTINEL))
    assert "stage_elapsed_s" in json.loads(line[len(PROGRESS_SENTINEL):].strip())


def test_note_progress_reaches_the_running_heartbeat_and_stops_with_it():
    clock = _Clock()
    hb = _ProgressHeartbeat(interval_s=3600, clock=clock).start()
    try:
        clock.now += 30
        orchestrate.events.note_progress()
        assert hb._snapshot()[2] == 0
    finally:
        hb.stop()
    clock.now += 5
    orchestrate.events.note_progress()  # no heartbeat registered any more: a no-op, not an error
    assert hb._snapshot()[2] == 5


def test_a_blocked_summarize_shows_stage_elapsed_growing_across_beats(tmp_path, monkeypatch):
    from .test_orchestrate import _write_fluidaudio_sidecar
    from mp.config import Config

    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    wav = tmp_path / "20260516-0900.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path)
    summary_json = tmp_path / "20260516-0900.summary.json"
    summary_json.write_text("{}", encoding="utf-8")
    beats: list[dict] = []
    monkeypatch.setattr(
        orchestrate.events, "emit",
        lambda category, action, **attrs: beats.append(attrs) if action == "stage_progress" else None,
    )
    real = orchestrate._ProgressHeartbeat
    # 100x faster beats and a 100x clock, so 0.3 real seconds of a hung call read as ~30 s.
    monkeypatch.setattr(
        orchestrate, "_ProgressHeartbeat",
        lambda: real(interval_s=0.03, clock=lambda: time.monotonic() * 100),
    )

    def hung_summarize(*_a, **_k):
        time.sleep(0.35)  # a request that never returns a unit of progress
        return {"json": summary_json, "md": tmp_path / "x.md"}

    from unittest.mock import patch
    with patch("mp.orchestrate.summarize", hung_summarize), \
         patch("mp.orchestrate.publish_fanout", return_value={"page_id": "p", "page_url": "u", "idempotent": False}):
        orchestrate.run_all(wav, cfg=Config())

    summarize_beats = [b["stage_elapsed_s"] for b in beats if b["stage"] == "summarize"]
    assert len(summarize_beats) >= 3
    assert summarize_beats == sorted(summarize_beats) and summarize_beats[-1] > summarize_beats[0] + 5


def test_a_finished_model_call_and_a_finished_cleanup_window_each_note_progress(monkeypatch, tmp_path):
    from mp import summarize
    from mp.config import Config
    from mp.diarize_cleanup import SpeakerEdit, cleanup_transcript

    noted: list[int] = []
    monkeypatch.setattr(orchestrate.events, "note_progress", lambda: noted.append(1))

    class _Fake:
        messages = None

        def __init__(self) -> None:
            self.messages = self

        def create(self, **_):
            return "answer"

    assert summarize._create_message(_Fake(), model="m") == "answer"
    assert noted == [1]

    noted.clear()
    segs = [{"start": float(i), "end": i + 1.0, "text": "w " * 30, "speaker": f"S{i % 2}"} for i in range(30)]
    p = tmp_path / "x.json"
    p.write_text(json.dumps({"segments": segs}), encoding="utf-8")

    class _Cleanup:
        def propose_edits(self, **_) -> list[SpeakerEdit]:
            return []

    cleanup_transcript(p, cfg=Config(), client=_Cleanup(), window_chars=300, overlap_chars=0)
    assert len(noted) >= 3  # one per window
