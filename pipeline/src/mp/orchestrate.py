"""`mp run-all <wav>` — fail-fast pipeline orchestration.

Stages:
  1. transcribe   →  <stem>.json   + <stem>.md
  2. summarize    →  <stem>.summary.json + <stem>.summary.md
  3. publish      →  <stem>.notion.json (or skipped under regulated_mode)

Each stage logs to ~/Library/Logs/MeetingPipe/pipeline.log via the root logger
configured here. Daemon's PipelineLauncher tails this file too.

Long-meeting guard: if the transcript markdown is longer than
`summarization.skip_above_chars`, stages 2 and 3 are skipped — instead we
write a paste-into-Claude-Code bundle (`<stem>.READY_FOR_MANUAL.md`) so the
user can process the meeting themselves without paying Anthropic API costs
on a 1+ hour transcript.
"""
from __future__ import annotations

import logging
import os
import sys
from importlib import resources
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


def _read_meeting_summary_prompt() -> str:
    """Read the system prompt the pipeline would have sent to Anthropic.
    Used to compose the manual-processing bundle so the user has the same
    context Claude Code would need to produce equivalent output."""
    try:
        return resources.files("mp.prompts").joinpath("meeting_summary.md").read_text(encoding="utf-8")
    except Exception:  # pragma: no cover
        return "(prompt file not found in package — see pipeline/src/mp/prompts/meeting_summary.md)"


def _write_manual_bundle(transcript_md: Path, char_count: int, threshold: int) -> Path:
    """Produce a sidecar `<stem>.READY_FOR_MANUAL.md` containing the system
    prompt + a pointer to the transcript. The user pastes both into Claude
    Code (or any LLM frontend) to get the same shape of output without
    burning API tokens on a 1+ hour transcript.
    """
    bundle = transcript_md.with_suffix(".READY_FOR_MANUAL.md")
    prompt = _read_meeting_summary_prompt()
    body = f"""# Manual processing required

This meeting's transcript is **{char_count:,} characters** (threshold: {threshold:,}).
The pipeline did NOT call the Anthropic API to summarize it — that would
cost noticeable money on a meeting this size.

## How to process it

1. Open Claude Code (or claude.ai, or any LLM that takes large contexts).
2. Paste the prompt below as the system message / first instruction.
3. Attach or paste the transcript markdown:

   `{transcript_md}`

4. Ask for the summary. Save the result wherever you want — the pipeline
   won't touch it.

If you decide later that you DO want this meeting auto-summarized, run:

    mp run-all "{transcript_md.with_suffix('.wav')}"

after raising `summarization.skip_above_chars` in
`~/.config/meeting-pipe/config.toml` (or set it to 0 to disable the guard).

---

## System prompt the pipeline would have used

```markdown
{prompt}
```
"""
    bundle.write_text(body, encoding="utf-8")
    return bundle


def run_all(wav: Path, cfg: Config | None = None) -> dict:
    """Run transcribe → summarize → publish. Raises on first failure."""
    cfg = cfg or Config.load()
    load_secrets()

    log.info("=" * 60)
    log.info("run-all: %s", wav)
    log.info("=" * 60)

    log.info("[1/3] transcribe")
    t = transcribe(wav, cfg=cfg)

    md_text = t["md"].read_text(encoding="utf-8")

    # Short-circuit #1: empty transcript (silent audio, broken capture).
    # Don't burn Anthropic tokens summarizing nothing.
    if "**" not in md_text:
        log.warning("Transcript has no speaker turns — skipping summarize + publish.")
        log.warning("  WAV: %s", wav)
        log.warning("  MD : %s", t["md"])
        return {
            "transcript_json": str(t["json"]),
            "transcript_md": str(t["md"]),
            "summary_json": None,
            "summary_md": None,
            "page_id": None,
            "page_url": None,
            "skipped": "no_speech",
        }

    # Short-circuit #2: long-meeting guard. Avoid Anthropic costs on a
    # 1+ hour transcript by handing it to the user for manual processing.
    threshold = cfg.summarization.skip_above_chars
    if threshold and len(md_text) > threshold:
        bundle = _write_manual_bundle(t["md"], len(md_text), threshold)
        log.warning(
            "Transcript is %d chars (threshold %d) — skipping summarize + publish.",
            len(md_text), threshold,
        )
        log.warning("Manual-processing bundle written: %s", bundle)
        return {
            "transcript_json": str(t["json"]),
            "transcript_md": str(t["md"]),
            "summary_json": None,
            "summary_md": None,
            "page_id": None,
            "page_url": None,
            "skipped": "too_long",
            "manual_bundle": str(bundle),
        }

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
