"""`mp run-all <wav>` — fail-fast pipeline orchestration.

Stages:
  1. transcribe   →  <stem>.json   + <stem>.md
  2. summarize    →  <stem>.summary.json + <stem>.summary.md
  3. publish      →  <stem>.notion.json (or skipped under regulated_mode)

Each stage logs to ~/Library/Logs/MeetingPipe/pipeline.log via the root logger
configured here. Daemon's PipelineLauncher tails this file too.
"""
from __future__ import annotations

import logging
import os
import sys
from pathlib import Path

from .config import Config, load_secrets
from .publish_notion import publish
from .summarize import summarize
from .transcribe import transcribe

log = logging.getLogger("mp.run_all")


def _configure_logging() -> None:
    """Mirror logs to stderr (captured by the Swift launcher) and ~/Library/Logs."""
    logs_dir = Path(os.path.expanduser("~/Library/Logs/MeetingPipe"))
    logs_dir.mkdir(parents=True, exist_ok=True)
    fmt = "%(asctime)s %(levelname)s %(name)s: %(message)s"

    root = logging.getLogger()
    if root.handlers:
        return  # already configured by caller (e.g. tests)
    root.setLevel(logging.INFO)

    stream = logging.StreamHandler(stream=sys.stderr)
    stream.setFormatter(logging.Formatter(fmt))
    root.addHandler(stream)

    file_handler = logging.FileHandler(logs_dir / "pipeline.log", encoding="utf-8")
    file_handler.setFormatter(logging.Formatter(fmt))
    root.addHandler(file_handler)


def run_all(wav: Path, cfg: Config | None = None) -> dict:
    """Run transcribe → summarize → publish. Raises on first failure."""
    cfg = cfg or Config.load()
    load_secrets()

    log.info("=" * 60)
    log.info("run-all: %s", wav)
    log.info("=" * 60)

    log.info("[1/3] transcribe")
    t = transcribe(wav, cfg=cfg)

    log.info("[2/3] summarize")
    s = summarize(t["md"], cfg=cfg)

    log.info("[3/3] publish")
    pub = publish(s["json"], cfg=cfg, transcript_md=t["md"])

    log.info("done: page_url=%s", pub.get("page_url"))
    return {
        "transcript_json": str(t["json"]),
        "transcript_md": str(t["md"]),
        "summary_json": str(s["json"]),
        "summary_md": str(s["md"]),
        **pub,
    }


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: mp run-all <wav>", file=sys.stderr)
        return 2
    wav = Path(argv[0]).expanduser().resolve()
    if not wav.exists():
        print(f"No such file: {wav}", file=sys.stderr)
        return 1
    _configure_logging()
    try:
        run_all(wav)
    except Exception as e:  # noqa: BLE001
        log.exception("run-all failed: %s", e)
        return 1
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
