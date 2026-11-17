#!/usr/bin/env python3
"""MIC17 probe: the quiet-mic tier's inputs, per recording, read-only and aggregate-only.

For each `<stem>.wav` in the recordings folder (or the stems named), prints the mic device the
meta sidecar names and the numbers `MicCoverageWarning` judges, computed the way the recorder
computes them: per-buffer RMS in dBFS over the mic channel, a buffer the length of the recorder's
tap (4096 frames at the device rate; `--buffer-ms`, default 85.3 ms, the 48 kHz case), exact-zero
buffers dropped as muted or redacted (the recorder counts un-muted from the gate's verdict, which
the file does not carry, so a zeroed span is the closest offline stand-in).

The recorder measures the live device-rate float buffer before the gate; this reads the final
16 kHz 16-bit file, so the two agree only to within resampling and quantization. The -74.9 dB MIC15
quoted for its dead-mic recording was that file's whole-file RMS, not a buffer peak (its loudest 85
ms buffer is -51.3 dB), so the `file_rms_db` column is printed beside `peak_db` to keep the two apart.

Reads WAV headers and samples and, with `--events`, `recording_started` / `ending_provisional`
rows from events.jsonl to window the in-call span. Writes nothing, plays nothing, prints no
transcript text, no title and no path beyond the stem. Standard library only, so it runs with the
system python3 on a machine with no pipeline venv.

Usage:
  python3 scripts/mic_level_probe.py [--dir DIR] [--events PATH] [--buffer-ms MS] [--channel left|right|both] [STEM ...]
"""

from __future__ import annotations

import argparse
import array
import json
import math
import os
import sys
import wave
from datetime import datetime, timezone
from pathlib import Path

# The tier's provisional constants, mirrored from MicCoverageWarning.swift. The probe prints its
# own verdict with them so a run on a library says directly where the bar would fall.
DEAD_FLOOR_DB = -65.0
MIN_RECORDING_S = 60.0
QUIET_MIN_UNMUTED_S = 300.0
QUIET_LOUD_DB = -40.0
QUIET_MAX_LOUD_S = 5.0
GATE_OPEN_DB = -45.0
LIVE_TICK_S = 30.0  # the HUD notice's check cadence (MeetingSessionController.checkMicQuiet)


def _rms_db(samples: array.array, start: int, end: int, step: int, offset: int, scale: float) -> float | None:
    """RMS in dBFS of one channel's samples in [start, end); None for an exact-zero buffer."""
    total = 0.0
    n = 0
    for i in range(start * step + offset, end * step + offset, step):
        v = samples[i] / scale
        total += v * v
        n += 1
    if n == 0 or total == 0.0:
        return None
    return 10.0 * math.log10(total / n)


def _read(path: Path) -> tuple[array.array, int, int, int, float]:
    with wave.open(str(path), "rb") as w:
        channels = w.getnchannels()
        width = w.getsampwidth()
        rate = w.getframerate()
        frames = w.getnframes()
        raw = w.readframes(frames)
    if width != 2:
        raise ValueError(f"{path.name}: {width * 8}-bit samples; the recorder writes 16-bit")
    samples = array.array("h")
    samples.frombytes(raw)
    if sys.byteorder == "big":
        samples.byteswap()
    return samples, channels, rate, frames, 32768.0


def _parse_ts(value: str) -> float | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def _in_call_seconds(events: Path | None, stem: str) -> float | None:
    """Seconds from `recording_started` to the first `ending_provisional` after it, or None."""
    if events is None or not events.exists():
        return None
    started = None
    with events.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if stem not in line and started is None:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            ts = _parse_ts(row.get("ts", ""))
            if ts is None:
                continue
            if started is None:
                if row.get("action") == "recording_started" and stem in json.dumps(row):
                    started = ts
            elif row.get("action") == "ending_provisional" and ts >= started:
                return ts - started
    return None


def probe(path: Path, buffer_ms: float, channel_index: int, in_call_s: float | None) -> dict:
    samples, channels, rate, frames, scale = _read(path)
    if channel_index >= channels:
        raise ValueError(f"{path.name}: channel {channel_index} of {channels}")
    buf = max(1, int(round(rate * buffer_ms / 1000.0)))
    buf_s = buf / rate
    total_s = frames / rate
    unmuted = loud = gate = gate_in_call = 0.0
    peak = -120.0
    energy = 0.0
    counted = 0
    live_at = None
    next_tick = LIVE_TICK_S
    for start in range(0, frames, buf):
        end = min(frames, start + buf)
        # The live HUD check, replayed: every 30 s of recording, the running tally against the
        # same bar. It fires earlier and more often than the stop tier, since an owner who
        # listens for the first five minutes trips it; the work-library run should count both.
        if live_at is None and start / rate >= next_tick:
            if unmuted >= QUIET_MIN_UNMUTED_S and loud < QUIET_MAX_LOUD_S:
                live_at = next_tick
            next_tick += LIVE_TICK_S
        db = _rms_db(samples, start, end, channels, channel_index, scale)
        if db is None:
            continue
        seconds = (end - start) / rate
        energy += (10 ** (db / 10.0)) * (end - start)
        counted += end - start
        unmuted += seconds
        peak = max(peak, db)
        if db >= QUIET_LOUD_DB:
            loud += seconds
        if db >= GATE_OPEN_DB:
            gate += seconds
            if in_call_s is not None and start / rate < in_call_s:
                gate_in_call += seconds
    dead = total_s >= MIN_RECORDING_S and unmuted >= 30.0 and peak < DEAD_FLOOR_DB
    quiet = (
        not dead
        and total_s >= MIN_RECORDING_S
        and unmuted >= QUIET_MIN_UNMUTED_S
        and loud < QUIET_MAX_LOUD_S
    )
    return {
        "seconds": round(total_s, 1),
        "rate": rate,
        "buffer_s": round(buf_s, 4),
        "unmuted_s": round(unmuted, 1),
        "peak_db": round(peak, 1),
        # Whole-file RMS over the un-muted buffers: NOT the recorder's measure. Printed because
        # MIC15's "-74.9 dB" for its dead-mic recording was this number (its loudest buffer is -51.3).
        "file_rms_db": round(10 * math.log10(energy / counted), 1) if counted and energy > 0 else -120.0,
        "loud_s": round(loud, 1),
        "ge_minus45_s": round(gate, 1),
        "ge_minus45_in_call_s": None if in_call_s is None else round(gate_in_call, 1),
        "in_call_s": None if in_call_s is None else round(in_call_s, 1),
        "tier": "dead" if dead else ("quiet" if quiet else "-"),
        # When the live notice would have shown (seconds into the recording), assuming the far
        # side was live; "-" when it never would.
        "live_notice_s": live_at,
    }


def _device(stem_wav: Path) -> str:
    meta = stem_wav.with_suffix(".meta.json")
    try:
        return json.loads(meta.read_text(encoding="utf-8")).get("mic_device_name") or "(not recorded)"
    except (OSError, ValueError):
        return "(no sidecar)"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dir", type=Path, default=Path(os.path.expanduser("~/Documents/Meetings/raw")))
    ap.add_argument("--events", type=Path, default=Path(os.path.expanduser("~/Library/Logs/MeetingPipe/events.jsonl")))
    ap.add_argument("--buffer-ms", type=float, default=4096 / 48.0)
    ap.add_argument("--channel", choices=("left", "right", "both"), default="left")
    ap.add_argument("stems", nargs="*")
    args = ap.parse_args(argv)

    if args.stems:
        wavs = [args.dir / f"{s}.wav" for s in args.stems]
    else:
        wavs = sorted(p for p in args.dir.glob("*.wav") if p.name.count(".") == 1)
    channels = {"left": [0], "right": [1], "both": [0, 1]}[args.channel]

    cols = ["stem", "ch", "device", "seconds", "unmuted_s", "peak_db", "file_rms_db", "loud_s", "ge_minus45_s",
            "ge_minus45_in_call_s", "tier", "live_notice_s"]
    print("\t".join(cols))
    fired = considered = live_fired = 0
    for wav in wavs:
        if not wav.exists():
            print(f"{wav.stem}\t-\tmissing", file=sys.stderr)
            continue
        stem = wav.stem
        in_call = _in_call_seconds(args.events, stem)
        for ch in channels:
            try:
                row = probe(wav, args.buffer_ms, ch, in_call)
            except (ValueError, wave.Error, EOFError) as exc:
                print(f"{stem}\t{ch}\tunreadable: {exc}", file=sys.stderr)
                continue
            if ch == 0:
                considered += 1
                fired += row["tier"] == "quiet"
                live_fired += row["live_notice_s"] is not None
            print("\t".join(str(x) for x in [
                stem, "L" if ch == 0 else "R", _device(wav), row["seconds"], row["unmuted_s"],
                row["peak_db"], row["file_rms_db"], row["loud_s"], row["ge_minus45_s"],
                "-" if row["ge_minus45_in_call_s"] is None else row["ge_minus45_in_call_s"], row["tier"],
                "-" if row["live_notice_s"] is None else int(row["live_notice_s"]),
            ]))
    print(f"\nquiet tier fired on {fired} of {considered} recordings at stop, the live notice on "
          f"{live_fired} "
          f"(thresholds: unmuted >= {QUIET_MIN_UNMUTED_S:.0f} s, under {QUIET_MAX_LOUD_S:.0f} s at or above "
          f"{QUIET_LOUD_DB:.0f} dBFS; buffer {args.buffer_ms:.1f} ms)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
