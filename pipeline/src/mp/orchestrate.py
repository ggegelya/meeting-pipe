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

import json
import logging
import os
import sys
from importlib import resources
from pathlib import Path

from .config import Config, load_secrets
from .diarize import assign_speakers, diarize as run_diarize
from .publish_notion import publish
from .summarize import summarize
from .transcribe import render_markdown, transcribe

log = logging.getLogger("mp.run_all")


def _configure_logging() -> None:
    """Mirror logs to stderr (captured by the Swift launcher) and ~/Library/Logs.

    The file handler is always opened so `pipeline.log` exists on disk after
    the first run, even if nothing is logged. Without this, a silent failure
    earlier in the pipeline left the user with no log to grep — which is how
    the diarization regression went undiagnosed for weeks.
    """
    logs_dir = Path(os.path.expanduser("~/Library/Logs/MeetingPipe"))
    logs_dir.mkdir(parents=True, exist_ok=True)
    log_file = logs_dir / "pipeline.log"
    log_file.touch(exist_ok=True)

    fmt = "%(asctime)s %(levelname)s %(name)s: %(message)s"

    root = logging.getLogger()
    if root.handlers:
        return  # already configured by caller (e.g. tests)
    root.setLevel(logging.INFO)

    stream = logging.StreamHandler(stream=sys.stderr)
    stream.setFormatter(logging.Formatter(fmt))
    root.addHandler(stream)

    file_handler = logging.FileHandler(log_file, encoding="utf-8")
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


def run_all(
    wav: Path,
    cfg: Config | None = None,
    *,
    force_byo: bool | None = None,
) -> dict:
    """Run transcribe → summarize → publish. Raises on first failure.

    `force_byo=True` short-circuits to the manual-paste bundle after
    transcription, even when the transcript is short enough to auto-
    summarize. Defaults to reading `MP_FORCE_BYO=1` from the environment
    so the Swift launcher can opt in per-meeting without flag plumbing.
    """
    cfg = cfg or Config.load()
    load_secrets()

    if force_byo is None:
        force_byo = os.environ.get("MP_FORCE_BYO") == "1"

    log.info("=" * 60)
    log.info("run-all: %s%s", wav, " (BYO summary)" if force_byo else "")
    log.info("=" * 60)

    # Streaming-transcribe path: when the daemon's StreamingTranscriber
    # ran during recording, the transcript JSON + Markdown are already on
    # disk. We pick up where the streamer left off — assign speakers via
    # diarization and proceed straight to summarize + publish. Falls back
    # to a fresh full transcribe if the streamed output is missing or
    # looks broken (zero segments, malformed JSON).
    streamed = _existing_streamed_transcript(wav)
    if streamed is not None:
        log.info("[1/3] transcribe (streamed during recording, finalizing)")
        t = _finalize_streamed_transcript(wav, streamed, cfg)
    else:
        log.info("[1/3] transcribe")
        t = transcribe(wav, cfg=cfg)

    # Short-circuit #1: empty transcript (silent audio, broken capture).
    # Don't burn Anthropic tokens summarizing nothing. Read the structured
    # JSON's segment count rather than scanning the markdown — the previous
    # `"**" not in md_text` heuristic broke the moment any header line
    # contained bold styling.
    structured = json.loads(t["json"].read_text(encoding="utf-8"))
    if not structured.get("segments"):
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

    md_text = t["md"].read_text(encoding="utf-8")

    # Short-circuit #2a: explicit BYO request from the user (per-meeting
    # toggle on the prompt panel). Same machinery as the long-meeting
    # guard — write the bundle and stop.
    if force_byo:
        bundle = _write_manual_bundle(t["md"], len(md_text), threshold=0)
        log.info("BYO summary requested — skipping Anthropic call.")
        log.info("Manual-processing bundle written: %s", bundle)
        log.info("Run `mp publish-from-paste %s` after saving your summary.", t["md"])
        return {
            "transcript_json": str(t["json"]),
            "transcript_md": str(t["md"]),
            "summary_json": None,
            "summary_md": None,
            "page_id": None,
            "page_url": None,
            "skipped": "byo",
            "manual_bundle": str(bundle),
        }

    # Short-circuit #2b: long-meeting guard. Avoid Anthropic costs on a
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


def _existing_streamed_transcript(wav: Path) -> dict | None:
    """Return the structured JSON the daemon's StreamingTranscriber wrote
    during recording, or None if it doesn't exist / is unusable.

    A "usable" streamed transcript is one with at least one segment AND
    the `streaming: true` marker (so we don't accidentally pick up a
    stale offline transcript from a previous run).
    """
    json_path = wav.parent / f"{wav.stem}.json"
    if not json_path.exists():
        return None
    try:
        data = json.loads(json_path.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return None
    if not isinstance(data, dict):
        return None
    if not data.get("streaming"):
        return None
    if not data.get("segments"):
        log.warning("Streamed transcript has zero segments — falling back to offline transcribe")
        return None
    return data


def _finalize_streamed_transcript(wav: Path, streamed: dict, cfg: Config) -> dict[str, Path]:
    """Run diarization on the canonical merged WAV and stamp speaker
    labels onto the streamed segments. Rewrites <stem>.json + <stem>.md
    in place so downstream stages see a single, consistent transcript.
    """
    json_path = wav.parent / f"{wav.stem}.json"
    md_path = wav.parent / f"{wav.stem}.md"
    tcfg = cfg.transcription

    diarization_failed = False
    diarization_failure_reason: str | None = None
    diar_segments: list = []

    audio_seconds = streamed.get("audio_seconds") or 0.0
    audio_minutes = audio_seconds / 60.0
    skip_for_length = (
        tcfg.max_diarization_minutes
        and audio_minutes > tcfg.max_diarization_minutes
    )

    if tcfg.disable_diarization:
        log.info("Diarization disabled by config")
    elif skip_for_length:
        log.warning(
            "Audio is %.1f min — exceeds max_diarization_minutes=%d. Skipping.",
            audio_minutes, tcfg.max_diarization_minutes,
        )
        diarization_failed = True
        diarization_failure_reason = (
            f"audio length {audio_minutes:.0f} min > max={tcfg.max_diarization_minutes}"
        )
    else:
        try:
            diar_segments = run_diarize(
                wav,
                min_speakers=tcfg.min_speakers,
                max_speakers=tcfg.max_speakers,
                cluster_threshold=tcfg.diarize_cluster_threshold,
            )
        except Exception as e:  # noqa: BLE001
            diarization_failed = True
            diarization_failure_reason = f"{type(e).__name__}: {e}"
            log.error("Diarization failed: %s", e)

    if diar_segments:
        labelled = assign_speakers(streamed["segments"], diar_segments)
    elif diarization_failed:
        labelled = [{**s, "speaker": "Speaker?"} for s in streamed["segments"]]
    else:
        labelled = list(streamed["segments"])

    structured = {
        **streamed,
        "segments": labelled,
        "diarization": not tcfg.disable_diarization and not skip_for_length,
        "diarization_failed": diarization_failed,
        "diarization_failure_reason": diarization_failure_reason,
        "streaming": True,
        "finalized": True,
    }
    json_path.write_text(json.dumps(structured, ensure_ascii=False, indent=2), encoding="utf-8")
    md_path.write_text(render_markdown(structured), encoding="utf-8")
    log.info("Finalized streamed transcript: %s", json_path)
    return {"json": json_path, "md": md_path}


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
