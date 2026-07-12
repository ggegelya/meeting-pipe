#!/usr/bin/env python3
"""LOCAL12 spike harness: latency + peak-memory (+ quality via the written
summary) for the on-device summary path, against a configurable local endpoint.

The same tool measures the current ``mlx_lm`` baseline today and an MLX-Swift
candidate server the day one exists, because it keys off a host:port, not a
spawner. It drives the REAL production path (``mp.summarize_local`` with the
pipeline's own system prompt and the LOCAL3 map-reduce), so the numbers are the
workload, not a synthetic proxy. Throwaway: not part of the ``mp`` package, not
in CI. Backs the verdict in ``local12-mlx-swift-trigger-evaluation.md``.

Run from the pipeline venv so ``mp`` is importable:

    # baseline: this tool spawns mlx_lm.server on the configured port (:8765)
    cd pipeline && uv run python ../docs/spikes/local12_bench.py \
        --transcript ~/Documents/Meetings/raw/<stem>.transcript.md --runs 3

    # candidate: point at an already-running MLX-Swift server (e.g. :8770)
    cd pipeline && uv run python ../docs/spikes/local12_bench.py \
        --transcript <same-stem>.transcript.md --no-manage --port 8770 --runs 3

Then grade the written ``local12-<label>.summary.json`` for quality against the
dogfood SHIP_GATE bars (actions >= 0.80, decisions >= 0.80, hallucination <= 0.05).
Compare the two labels' latency / peak-RSS / quality to answer the I7 trigger.
"""
from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path


class RSSSampler:
    """Best-effort peak-RSS sampler for whatever process is LISTENING on ``port``.

    Keys off the port, not the spawner, so it measures the ``mlx_lm.server`` this
    tool spawns and an external MLX-Swift server identically. macOS ``lsof`` +
    ``ps``; degrades to ``None`` if either is unavailable.
    """

    def __init__(self, port: int, interval: float = 0.5) -> None:
        self._port = port
        self._interval = interval
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self.peak_kb: int | None = None

    def _listening_pid(self) -> int | None:
        try:
            out = subprocess.run(
                ["lsof", "-nP", f"-iTCP:{self._port}", "-sTCP:LISTEN", "-t"],
                capture_output=True, text=True, timeout=2.0,
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return None
        first = out.splitlines()[0] if out else ""
        return int(first) if first.isdigit() else None

    def _rss_kb(self, pid: int) -> int | None:
        try:
            out = subprocess.run(
                ["ps", "-o", "rss=", "-p", str(pid)],
                capture_output=True, text=True, timeout=2.0,
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return None
        return int(out) if out.isdigit() else None

    def _run(self) -> None:
        while not self._stop.wait(self._interval):
            pid = self._listening_pid()
            if pid is None:
                continue
            rss = self._rss_kb(pid)
            if rss is not None and (self.peak_kb is None or rss > self.peak_kb):
                self.peak_kb = rss

    def __enter__(self) -> "RSSSampler":
        self._thread.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self._stop.set()
        self._thread.join(timeout=2.0)

    @property
    def peak_mb(self) -> float | None:
        return None if self.peak_kb is None else round(self.peak_kb / 1024, 1)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="local12_bench",
        description="LOCAL12: latency / memory / quality bench for the local summary path.",
    )
    p.add_argument("--transcript", type=Path, required=True,
                   help="A real transcript .md to summarize (representative workload).")
    p.add_argument("--runs", type=int, default=1, help="Timed runs (default 1).")
    p.add_argument("--model", default=None,
                   help="MLX repo id (default: summarization.local_model, else the 7B).")
    p.add_argument("--host", default=None, help="Server host (default: config, else 127.0.0.1).")
    p.add_argument("--port", type=int, default=None, help="Server port (default: config, else 8765).")
    p.add_argument("--no-manage", dest="manage", action="store_false",
                   help="Do not spawn mlx_lm.server; connect to an already-running server "
                        "(point at an external MLX-Swift server).")
    p.add_argument("--label", default=None,
                   help="Label for the written summary (default: baseline / candidate).")
    p.add_argument("--runs-dir", type=Path, default=Path("runs"),
                   help="Where to write the produced summary for quality grading.")
    args = p.parse_args(argv)

    # Lazy: keep mp (and its transitive httpx / pydantic) out of --help.
    from mp.summarize import _load_system_prompt
    from mp.summarize_local import DEFAULT_HOST, DEFAULT_MODEL, DEFAULT_PORT, LocalSummaryClient

    team_context, language, max_tokens = "", "auto", 4000
    cfg_model: str | None = None
    cfg_host, cfg_port = DEFAULT_HOST, DEFAULT_PORT
    try:
        from mp.config import Config, parse_local_endpoint
        cfg = Config.load()
        team_context = cfg.summarization.team_context
        language = cfg.summarization.summary_language
        max_tokens = cfg.summarization.max_tokens
        cfg_model = cfg.summarization.local_model
        cfg_host, cfg_port = parse_local_endpoint(cfg.summarization.local_endpoint)
    except Exception as exc:  # noqa: BLE001 - a throwaway bench falls back to defaults
        print(f"(config unavailable: {exc}; using defaults)", file=sys.stderr)

    model = args.model or cfg_model or DEFAULT_MODEL
    host = args.host or cfg_host
    port = args.port or cfg_port

    transcript = args.transcript.read_text(encoding="utf-8")
    if not transcript.strip():
        print(f"empty transcript: {args.transcript}", file=sys.stderr)
        return 2
    sys_prompt = _load_system_prompt(team_context, language)
    label = args.label or ("baseline" if args.manage else "candidate")

    print(f"model={model} endpoint={host}:{port} manage={args.manage} "
          f"transcript={args.transcript.name} ({len(transcript)} chars) runs={args.runs}")

    latencies: list[float] = []
    summary_obj = None
    with RSSSampler(port) as sampler, LocalSummaryClient(
        model=model, host=host, port=port,
        manage_subprocess=args.manage, summary_language=language,
    ) as client:
        for i in range(args.runs):
            t0 = time.perf_counter()
            summary_obj = client.summarize(
                system_prompt=sys_prompt, transcript=transcript,
                model=model, max_tokens=max_tokens,
            )
            dt = time.perf_counter() - t0
            latencies.append(dt)
            print(f"  run {i + 1}/{args.runs}: {dt:.1f}s")

    out_chars = len(json.dumps(summary_obj.model_dump(), ensure_ascii=False)) if summary_obj else 0
    approx_tokens = out_chars / 4  # rough char->token
    p50 = statistics.median(latencies)
    print("\n== LOCAL12 bench ==")
    print(f"latency  p50={p50:.1f}s  min={min(latencies):.1f}s  max={max(latencies):.1f}s  "
          f"(n={len(latencies)})")
    print(f"peak RSS {sampler.peak_mb} MB" if sampler.peak_mb is not None
          else "peak RSS n/a (lsof/ps unavailable or server not on this port)")
    print(f"output   ~{int(approx_tokens)} tokens ({out_chars} chars); "
          f"~{approx_tokens / p50:.0f} tok/s" if p50 else "output   n/a")

    if summary_obj is not None:
        args.runs_dir.mkdir(parents=True, exist_ok=True)
        out = args.runs_dir / f"local12-{label}.summary.json"
        out.write_text(json.dumps(summary_obj.model_dump(), ensure_ascii=False, indent=2),
                       encoding="utf-8")
        print(f"wrote {out} (grade vs SHIP_GATE: actions>=0.80, decisions>=0.80, halluc<=0.05)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
