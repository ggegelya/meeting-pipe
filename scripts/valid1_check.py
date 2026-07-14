#!/usr/bin/env python3
"""TECH-VALID1 helper: read the MeetingPipe event logs and surface the numbers
the on-device acceptance bars (A15 / A16 / DIAR1 / SUM1-APPLE / UX4) are graded
against.

Some bars are machine-checkable and some are not, and the split is the whole
point of this script. `--ux4`, `--diar`, `--attribution` and `--coldstart` are
hard measurements. Summary *quality* (A16, SUM1-APPLE) and a true diarization
error rate stay human reads; see the runbook for why.

Reads, by default:
  ~/Library/Logs/MeetingPipe/events.jsonl           (daemon: recording.degraded/recovered,
                                                     transcription.engine_* with audio_seconds)
  ~/Library/Logs/MeetingPipe/pipeline_events.jsonl  (pipeline: run_*/stage_* with a `stage` attr)
  ~/Documents/Meetings/raw/<stem>.json              (transcripts, for --attribution)

Usage:
  scripts/valid1_check.py                 # UX4 + DIAR1 latency + attribution + stage timings
  scripts/valid1_check.py --ux4           # only the UX4 degraded/recovered assertion (exit 1 on fail)
  scripts/valid1_check.py --diar          # only DIAR1: ASR+diarization latency (exit 1 on fail)
  scripts/valid1_check.py --attribution   # only the speaker-attribution coverage read
  scripts/valid1_check.py --coldstart     # A15: measure a cold vs warm local summarize (runs the model)
  scripts/valid1_check.py --timings       # only the run/stage timing table
  scripts/valid1_check.py --since 2026-06-03T00:00:00Z
  scripts/valid1_check.py --events <path> --pipeline-events <path>

Stdlib only, so it runs on a clean Mac without `uv`.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

DEFAULT_DIR = Path("~/Library/Logs/MeetingPipe").expanduser()
DEFAULT_MEETINGS_DIR = Path("~/Documents/Meetings/raw").expanduser()
DEFAULT_ENDPOINT = "http://127.0.0.1:8765"

# A15 guard rails. The 14B at long context has OOM-hung this Mac before, so a
# measurement run is wrapped in `caffeinate` and aborted if the machine gets
# close to swapping rather than being allowed to wedge it.
MIN_FREE_MEMORY_PCT = 10.0
COLDSTART_TIMEOUT_SEC = 900.0


def _parse_ts(raw: object) -> datetime | None:
    if not isinstance(raw, str) or not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def _log_files(path: Path) -> list[Path]:
    """PERF7: the base log plus its rotated generations (`events.1.jsonl`, ...),
    oldest first, so the report still sees the recent window after rotation.
    Stdlib-only mirror of mp.events.log_generations (this script imports no mp)."""
    numbered: list[tuple[int, Path]] = []
    for g in path.parent.glob(f"{path.stem}.*{path.suffix}"):
        mid = g.name[len(path.stem) + 1 : len(g.name) - len(path.suffix)]
        if mid.isdigit():
            numbered.append((int(mid), g))
    files = [g for _, g in sorted(numbered, reverse=True)]
    if path.exists():
        files.append(path)
    return files


def _load(path: Path, since: datetime | None) -> list[dict]:
    events: list[dict] = []
    for source in _log_files(path):
        for line in source.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(event, dict):
                continue
            if since is not None:
                ts = _parse_ts(event.get("ts"))
                if ts is not None and ts < since:
                    continue
            events.append(event)
    return events


def _key(event: dict) -> str:
    return f"{event.get('category', '?')}.{event.get('action', '?')}"


def check_ux4(daemon_events: list[dict]) -> bool:
    """UX4: a real failed SCStream must surface `recording.degraded` (and ideally
    a later `recording.recovered`). Pass when at least one degraded event exists.
    """
    degraded = [e for e in daemon_events if _key(e) == "recording.degraded"]
    recovered = [e for e in daemon_events if _key(e) == "recording.recovered"]
    print("== UX4: live degraded banner + recording.degraded event ==")
    if not degraded:
        print("  FAIL  no recording.degraded event found.")
        print("        Force a real SCStream failure (revoke Screen Recording mid-call,")
        print("        or stop the capture target) and confirm the HUD banner appears.")
        return False
    for e in degraded:
        print(f"  degraded  {e.get('ts', '?')}  reason={e.get('reason', '?')}")
    for e in recovered:
        print(f"  recovered {e.get('ts', '?')}")
    print(f"  PASS  {len(degraded)} degraded, {len(recovered)} recovered.")
    return True


def report_timings(pipeline_events: list[dict]) -> None:
    """Pair run_started/run_completed and stage_started/stage_completed (by
    `stage`) and print elapsed seconds. Feeds the A15 cold-start, A16 latency,
    and DIAR1 under-10s reads; thresholds live in the runbook, not here.
    """
    print("== Run + stage timings (A15 cold-start / A16 latency / DIAR1) ==")
    open_runs: list[datetime] = []
    open_stages: dict[str, datetime] = {}
    any_row = False
    for e in pipeline_events:
        key = _key(e)
        ts = _parse_ts(e.get("ts"))
        if ts is None:
            continue
        if key == "pipeline.run_started":
            open_runs.append(ts)
        elif key == "pipeline.run_completed" and open_runs:
            start = open_runs.pop(0)
            print(f"  run        {start.isoformat()}  ->  {(ts - start).total_seconds():7.2f} s total")
            any_row = True
        elif key == "pipeline.stage_started":
            open_stages[str(e.get("stage", "?"))] = ts
        elif key == "pipeline.stage_completed":
            stage = str(e.get("stage", "?"))
            start = open_stages.pop(stage, None)
            if start is not None:
                print(f"    stage {stage:<16} {(ts - start).total_seconds():7.2f} s")
                any_row = True
    if not any_row:
        print("  (no completed runs in range; run a meeting through the pipeline first.)")


def _spread(values: list[float]) -> dict:
    """min / median / max of a non-empty list, rounded for reading."""
    ordered = sorted(values)
    return {
        "min": round(ordered[0], 2),
        "median": round(ordered[len(ordered) // 2], 2),
        "max": round(ordered[-1], 2),
    }


# ---------------------------------------------------------------- DIAR1 latency

REAL_ENGINE = "fluidaudio"


def build_diar_report(daemon_events: list[dict], engine: str = REAL_ENGINE) -> dict:
    """DIAR1's latency leg, from the daemon's own transcription events.

    ASR and diarization run in Swift (FluidAudio), not in the pipeline, so their
    timing lands in `events.jsonl` under `transcription.*` and NOT in the
    `pipeline.stage_*` table `report_timings` pairs. The Q4 scaffolding predated
    that move and only ever read the pipeline stages, which is why this bar read
    as unmeasurable while the data was sitting in the log the whole time.

    `engine_started` / `engine_succeeded` pair on `file`; `engine_succeeded`
    carries `audio_seconds` and `segments`, so the real-time factor (audio
    processed per wall-clock second) falls straight out.

    Filtered to `engine` on purpose, and the filter stays even though both test
    harnesses are now isolated (Swift at TECH-END4, Python at the `mp.events.logs_dir`
    guard). The rows they already wrote are permanent: they sit in rotated generations
    that nothing rewrites, and `_log_files` reads every generation. An unfiltered read
    still reports hundreds of "failures" that are `FakeRunner.Boom` from
    SinkDispatcherTests. This is the transparent form of `mp.events.is_test_residue`:
    skipped engines are counted and surfaced as `other_engines`, never silently dropped.
    """
    started: dict[str, datetime] = {}
    runs: list[dict] = []
    failed = 0
    other_engines: dict[str, int] = {}
    for e in daemon_events:
        if e.get("category") != "transcription":
            continue
        action = e.get("action")
        name = e.get("file")
        ts = _parse_ts(e.get("ts"))
        if not isinstance(name, str) or ts is None:
            continue
        seen = e.get("engine")
        if seen != engine:
            if action in ("engine_succeeded", "engine_failed"):
                key = str(seen)
                other_engines[key] = other_engines.get(key, 0) + 1
            continue
        if action == "engine_started":
            started[name] = ts
        elif action == "engine_failed":
            started.pop(name, None)
            failed += 1
        elif action == "engine_succeeded":
            start = started.pop(name, None)
            audio = e.get("audio_seconds")
            if start is None or not isinstance(audio, (int, float)) or audio <= 0:
                # An empty recording (no speech) succeeds with 0 s of audio and 0
                # segments. Nothing was diarized, so it carries no latency signal.
                continue
            elapsed = (ts - start).total_seconds()
            if elapsed < 0:
                continue
            runs.append({
                "file": name,
                "elapsed_sec": elapsed,
                "audio_sec": float(audio),
                "segments": e.get("segments", 0),
                # Guard the degenerate sub-second run: the event timestamps are
                # whole milliseconds, so a very short recording can pair at 0.0 s
                # elapsed and blow up the ratio. Floor it at one millisecond.
                "rtf": float(audio) / max(elapsed, 0.001),
            })

    report: dict = {"engine": engine, "runs": len(runs), "failed": failed,
                    "other_engines": other_engines}
    if not runs:
        return report
    slow = [r for r in runs if r["rtf"] < 1.0]
    worst = min(runs, key=lambda r: r["rtf"])
    longest = max(runs, key=lambda r: r["elapsed_sec"])
    report.update({
        "audio_hours": round(sum(r["audio_sec"] for r in runs) / 3600.0, 1),
        "elapsed_sec": _spread([r["elapsed_sec"] for r in runs]),
        "rtf": _spread([r["rtf"] for r in runs]),
        "slower_than_realtime": len(slow),
        "worst_rtf": {"file": worst["file"], "rtf": round(worst["rtf"], 1),
                      "elapsed_sec": round(worst["elapsed_sec"], 1)},
        "longest": {"file": longest["file"], "elapsed_sec": round(longest["elapsed_sec"], 1),
                    "audio_sec": round(longest["audio_sec"], 1)},
    })
    return report


def report_diar(daemon_events: list[dict], engine: str = REAL_ENGINE) -> bool:
    """Pass when every transcription run kept up with real time."""
    r = build_diar_report(daemon_events, engine)
    print(f"== DIAR1: ASR + diarization latency (engine={engine}) ==")
    if r["other_engines"]:
        skipped = ", ".join(f"{k}={v}" for k, v in sorted(r["other_engines"].items()))
        print(f"  note: skipped {skipped} (the Swift test suite writes its fake engines")
        print("        into this same log; they are not real transcription runs)")
    if not r["runs"]:
        print("  SKIP  no paired transcription.engine_started/succeeded events in range.")
        return True
    print(f"  {r['runs']} runs over {r['audio_hours']} h of audio ({r['failed']} failed)")
    e, f = r["elapsed_sec"], r["rtf"]
    print(f"  elapsed  min {e['min']:.1f}s  median {e['median']:.1f}s  max {e['max']:.1f}s")
    print(f"  realtime factor  min {f['min']:.0f}x  median {f['median']:.0f}x  max {f['max']:.0f}x")
    print(f"  longest run  {r['longest']['file']}  {r['longest']['elapsed_sec']}s "
          f"for {r['longest']['audio_sec']}s of audio")
    if r["slower_than_realtime"]:
        w = r["worst_rtf"]
        print(f"  FAIL  {r['slower_than_realtime']} run(s) slower than real time; "
              f"worst {w['file']} at {w['rtf']}x")
        return False
    print(f"  PASS  every run faster than real time (worst {r['worst_rtf']['rtf']}x).")
    return True


# ------------------------------------------------- speaker-attribution coverage

_RAW_SPEAKER = re.compile(r"^speaker_\d+$")


def classify_speaker(label: object) -> str:
    """Bucket a transcript segment's speaker label.

    - `named`             a roster name or the user's own label: fully resolved.
    - `them_cluster`      THEM-A/B/...: an unnamed but distinct remote voice.
    - `channel_fallback`  speaker_user / speaker_other: the stereo RMS fallback
                          ran because embedding diarization did not.
    - `unattributed`      speaker_unknown, or a raw `speaker_N` that never
                          resolved to a cluster. Speech nobody is credited with.
    """
    if not isinstance(label, str) or not label:
        return "unattributed"
    if label == "speaker_unknown" or _RAW_SPEAKER.match(label):
        return "unattributed"
    if label in ("speaker_user", "speaker_other"):
        return "channel_fallback"
    if label.startswith("THEM-"):
        return "them_cluster"
    return "named"


def build_attribution_report(transcripts: list[tuple[str, dict]]) -> dict:
    """Time-weighted speaker-attribution coverage over the meeting corpus.

    This is NOT a diarization error rate, and it deliberately does not pretend to
    be one. A real DER needs ground truth for who spoke when, and the tempting
    shortcut (grade the me-vs-them label against the stereo mic/system channel)
    is circular: `diarize.label_me_speaker` already picks the "me" speaker FROM
    the channel, so the channel cannot also be the judge of it. The channel is
    blind to the split that actually matters anyway, since every remote speaker
    shares the system channel. See the runbook.

    What IS measurable without ground truth is coverage: how much speech the
    diarizer left credited to nobody. That number needs no labels to be true.
    """
    by_class: dict[str, float] = {}
    total = 0.0
    per_meeting: list[dict] = []
    clusters: list[int] = []
    for stem, doc in transcripts:
        segments = doc.get("segments")
        if not isinstance(segments, list) or not segments:
            continue
        seen: set[str] = set()
        m_total = 0.0
        m_unattributed = 0.0
        for seg in segments:
            if not isinstance(seg, dict):
                continue
            try:
                dur = float(seg.get("end", 0)) - float(seg.get("start", 0))
            except (TypeError, ValueError):
                continue
            if dur <= 0:
                continue
            label = seg.get("speaker")
            klass = classify_speaker(label)
            by_class[klass] = by_class.get(klass, 0.0) + dur
            total += dur
            m_total += dur
            if klass == "unattributed":
                m_unattributed += dur
            elif isinstance(label, str):
                seen.add(label)
        if m_total <= 0:
            continue
        clusters.append(len(seen))
        per_meeting.append({
            "stem": stem,
            "unattributed_share": m_unattributed / m_total,
            "speech_sec": m_total,
        })

    report: dict = {"meetings": len(per_meeting)}
    if not per_meeting or total <= 0:
        return report
    worst = sorted(per_meeting, key=lambda m: -m["unattributed_share"])[:5]
    report.update({
        "speech_hours": round(total / 3600.0, 1),
        "by_class_share": {k: round(v / total, 4) for k, v in sorted(by_class.items())},
        "unattributed_share": round(by_class.get("unattributed", 0.0) / total, 4),
        "speakers_per_meeting": _spread([float(c) for c in clusters]),
        "worst_meetings": [
            {"stem": m["stem"], "unattributed_share": round(m["unattributed_share"], 3)}
            for m in worst
        ],
    })
    return report


def load_transcripts(meetings_dir: Path, since: datetime | None = None) -> list[tuple[str, dict]]:
    """Read every `<stem>.json` transcript in the meetings dir. Sidecars
    (`.meta.json`, `.summary.json`, ...) carry a second dot in the stem, so a
    single-suffix check keeps this to real transcripts.

    `since` filters on the stem's own `YYYYMMDD-HHMMSS` date. This matters more
    than it looks: attribution quality is not stationary. The pre-roster era
    drags the corpus-wide number up by a lot, so a lifetime read understates how
    well the CURRENT diarizer does. Always report the window you measured.
    """
    out: list[tuple[str, dict]] = []
    if not meetings_dir.is_dir():
        return out
    cutoff = since.strftime("%Y%m%d") if since else None
    for path in sorted(meetings_dir.glob("*.json")):
        if path.name.count(".") != 1:
            continue
        if cutoff and path.stem[:8] < cutoff:
            continue
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(doc, dict):
            out.append((path.stem, doc))
    return out


def report_attribution(meetings_dir: Path, since: datetime | None = None) -> None:
    r = build_attribution_report(load_transcripts(meetings_dir, since))
    print("== Speaker-attribution coverage (the measurable half of DIAR1 quality) ==")
    if since:
        print(f"  window: meetings on/after {since.date()}")
    if not r["meetings"]:
        print(f"  (no transcripts under {meetings_dir})")
        return
    print(f"  {r['meetings']} meetings, {r['speech_hours']} h of speech")
    for klass, share in r["by_class_share"].items():
        print(f"    {klass:<18} {share * 100:5.1f}%")
    s = r["speakers_per_meeting"]
    print(f"  distinct speakers/meeting  min {s['min']:.0f}  median {s['median']:.0f}  max {s['max']:.0f}")
    print(f"  UNATTRIBUTED SPEECH: {r['unattributed_share'] * 100:.1f}% "
          "(no threshold; this is a baseline, not a gate)")
    print("  worst: " + ", ".join(
        f"{m['stem']} ({m['unattributed_share'] * 100:.0f}%)" for m in r["worst_meetings"]))


# ------------------------------------------------------------ A15 cold-start

def free_memory_pct() -> float | None:
    """System-wide free memory, per `memory_pressure`. None when unavailable."""
    try:
        out = subprocess.run(["memory_pressure"], capture_output=True, text=True,
                             timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"free percentage:\s*(\d+)%", out)
    return float(m.group(1)) if m else None


def endpoint_is_warm(endpoint: str, timeout: float = 2.0) -> bool:
    """True when an mlx_lm.server is already serving on `endpoint`."""
    try:
        with urllib.request.urlopen(f"{endpoint}/v1/models", timeout=timeout) as r:
            return 200 <= r.status < 300
    except (urllib.error.URLError, OSError, ValueError):
        return False


def _run_timed(argv: list[str], label: str) -> tuple[float, int]:
    """Run `argv` under caffeinate, wall-clocked, with a low-memory abort.

    The watchdog exists because the 14B has OOM-hung this Mac. It samples free
    memory and kills the whole process group rather than letting the machine
    swap itself to death.
    """
    print(f"  [{label}] $ {' '.join(argv)}")
    started = time.monotonic()
    proc = subprocess.Popen(
        ["caffeinate", "-i", *argv],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
    )
    aborted = threading.Event()

    def watchdog() -> None:
        while proc.poll() is None:
            free = free_memory_pct()
            if free is not None and free < MIN_FREE_MEMORY_PCT:
                aborted.set()
                print(f"  [{label}] ABORT: free memory {free}% below "
                      f"{MIN_FREE_MEMORY_PCT}%, killing the run.")
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except (OSError, ProcessLookupError):
                    pass
                return
            time.sleep(2.0)

    monitor = threading.Thread(target=watchdog, daemon=True)
    monitor.start()
    try:
        rc = proc.wait(timeout=COLDSTART_TIMEOUT_SEC)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (OSError, ProcessLookupError):
            pass
        rc = -1
    elapsed = time.monotonic() - started
    if aborted.is_set():
        rc = -2
    return elapsed, rc


def pick_transcript(meetings_dir: Path) -> Path | None:
    """A median-length transcript, so the timing is representative rather than a
    best or worst case. Summary sidecars carry a second dot; skip them."""
    candidates = [p for p in sorted(meetings_dir.glob("*.md")) if p.name.count(".") == 1]
    sized = sorted((p.stat().st_size, p) for p in candidates if p.stat().st_size > 0)
    return sized[len(sized) // 2][1] if sized else None


def run_coldstart(mp_cmd: list[str], transcript: Path, endpoint: str,
                  out: Path | None) -> bool:
    """A15: time a cold local summarize (pays the model load) against a warm one.

    Cold is the honest number only when nothing is already serving: a one-shot
    `mp summarize` spawns its own mlx_lm.server and tears it down on exit, so it
    reloads the model every time. Warm therefore needs a separate `mp serve-local`
    held up alongside it.

    Caveat worth stating rather than hiding: the OS page cache means the second
    cold start of a model reads its safetensors from cache, so this measures a
    warm-disk cold start, not a first-ever-load cold start.
    """
    print("== A15: local summarize cold-start vs warm ==")
    if endpoint_is_warm(endpoint):
        print(f"  ERROR  something is already serving on {endpoint}; a cold measurement")
        print("         against a warm server is a lie. Stop it first (`mp doctor` prints")
        print("         the pid of an orphan server), then re-run.")
        return False
    free = free_memory_pct()
    if free is not None and free < MIN_FREE_MEMORY_PCT:
        print(f"  ERROR  only {free}% memory free; refusing to start a model run.")
        return False
    print(f"  transcript: {transcript.name}  (free memory {free}%)")

    result: dict = {"transcript": transcript.name, "endpoint": endpoint}
    summarize = [*mp_cmd, "summarize", str(transcript), "--backend", "local", "--candidate"]

    cold_sec, rc = _run_timed(summarize, "cold")
    result["cold_sec"] = round(cold_sec, 1)
    result["cold_rc"] = rc
    _write_json(out, result)
    if rc != 0:
        print(f"  FAIL  cold run exited {rc} after {cold_sec:.1f}s.")
        return False
    print(f"  cold: {cold_sec:.1f}s (model load + generate)")

    server = subprocess.Popen(
        ["caffeinate", "-i", *mp_cmd, "serve-local"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 180.0
        while time.monotonic() < deadline and not endpoint_is_warm(endpoint):
            if server.poll() is not None:
                print("  FAIL  `mp serve-local` exited before serving.")
                return False
            time.sleep(1.0)
        if not endpoint_is_warm(endpoint):
            print("  FAIL  `mp serve-local` never became healthy.")
            return False
        warm_sec, rc = _run_timed(summarize, "warm")
        result["warm_sec"] = round(warm_sec, 1)
        result["warm_rc"] = rc
    finally:
        # Only ever tear down the server this function started.
        try:
            os.killpg(server.pid, signal.SIGTERM)
        except (OSError, ProcessLookupError):
            pass

    _write_json(out, result)
    if rc != 0:
        print(f"  FAIL  warm run exited {rc} after {result['warm_sec']}s.")
        return False
    load_sec = round(cold_sec - result["warm_sec"], 1)
    result["model_load_sec"] = load_sec
    _write_json(out, result)
    print(f"  warm: {result['warm_sec']:.1f}s (generate only)")
    print(f"  PASS  model load costs {load_sec}s. Record cold={result['cold_sec']}s as the")
    print("        A15 baseline; the bar is a regression check against it, and no prior")
    print("        cold-start number was ever recorded to regress against.")
    return True


def _write_json(out: Path | None, payload: dict) -> None:
    """Write results as they land, so an aborted model run still leaves the
    numbers it already produced."""
    if out is None:
        return
    out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def resolve_mp() -> list[str]:
    """`mp` if installed, else run it out of the repo checkout next to this script."""
    found = shutil.which("mp")
    if found:
        return [found]
    pipeline = Path(__file__).resolve().parents[1] / "pipeline"
    if pipeline.is_dir() and shutil.which("uv"):
        return ["uv", "run", "--directory", str(pipeline), "mp"]
    return ["mp"]


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="MeetingPipe VALID1 acceptance helper.")
    ap.add_argument("--events", type=Path, default=DEFAULT_DIR / "events.jsonl",
                    help="daemon events.jsonl path")
    ap.add_argument("--pipeline-events", type=Path, default=DEFAULT_DIR / "pipeline_events.jsonl",
                    help="pipeline_events.jsonl path")
    ap.add_argument("--meetings-dir", type=Path, default=DEFAULT_MEETINGS_DIR,
                    help="transcript directory, for --attribution")
    ap.add_argument("--engine", type=str, default=REAL_ENGINE,
                    help="transcription engine to grade, for --diar (test fakes are excluded)")
    ap.add_argument("--since", type=str, default=None,
                    help="ISO8601 lower bound, e.g. 2026-06-03T00:00:00Z")
    ap.add_argument("--ux4", action="store_true", help="only the UX4 assertion")
    ap.add_argument("--diar", action="store_true", help="only the DIAR1 latency assertion")
    ap.add_argument("--attribution", action="store_true",
                    help="only the speaker-attribution coverage read")
    ap.add_argument("--timings", action="store_true", help="only the pipeline timing table")
    ap.add_argument("--coldstart", action="store_true",
                    help="A15: measure a cold vs warm local summarize (runs the model)")
    ap.add_argument("--transcript", type=Path, default=None,
                    help="transcript for --coldstart (default: a median-length one)")
    ap.add_argument("--endpoint", type=str, default=DEFAULT_ENDPOINT,
                    help="local model endpoint, for --coldstart")
    ap.add_argument("--out", type=Path, default=None,
                    help="write --coldstart results to this JSON file as they land")
    args = ap.parse_args(argv)

    since = _parse_ts(args.since) if args.since else None
    if args.since and since is None:
        print(f"error: could not parse --since {args.since!r}", file=sys.stderr)
        return 2

    # --coldstart is the one mode that runs a model, so it never rides along with
    # the read-only reports; ask for it explicitly.
    if args.coldstart:
        transcript = args.transcript or pick_transcript(args.meetings_dir)
        if transcript is None or not transcript.is_file():
            print(f"error: no transcript to summarize under {args.meetings_dir}", file=sys.stderr)
            return 2
        return 0 if run_coldstart(resolve_mp(), transcript, args.endpoint, args.out) else 1

    selected = args.ux4 or args.diar or args.attribution or args.timings
    run_ux4 = args.ux4 or not selected
    run_diar = args.diar or not selected
    run_attribution = args.attribution or not selected
    run_timings = args.timings or not selected

    daemon_events = _load(args.events, since) if (run_ux4 or run_diar) else []
    pipeline_events = _load(args.pipeline_events, since) if run_timings else []

    ok = True
    sections = []
    if run_ux4:
        sections.append(lambda: check_ux4(daemon_events))
    if run_diar:
        sections.append(lambda: report_diar(daemon_events, args.engine))
    if run_attribution:
        sections.append(lambda: (report_attribution(args.meetings_dir, since), True)[1])
    if run_timings:
        sections.append(lambda: (report_timings(pipeline_events), True)[1])

    for i, section in enumerate(sections):
        if i:
            print()
        ok = section() and ok

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
