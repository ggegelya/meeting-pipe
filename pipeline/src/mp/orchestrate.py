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
from .corrections import write_run_sidecar
from .diarize import (
    assign_speakers,
    assign_speakers_by_channel,
    diarize as run_diarize,
    is_stereo_recording,
)
from . import events
from .publish_router import fanout as publish_fanout
from .summarize import summarize
from .transcribe import render_markdown, transcribe
from .workflow import apply_overrides as apply_workflow_overrides

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
    # Apply per-meeting workflow overrides from the daemon-written meta
    # sidecar (TECH-B4). No-op for shell-invoked `mp run-all` against
    # wavs that have no sidecar; otherwise replaces team_context /
    # backend / sinks / notion DB for this single run.
    cfg = apply_workflow_overrides(cfg, wav)
    load_secrets()

    if force_byo is None:
        force_byo = os.environ.get("MP_FORCE_BYO") == "1"

    log.info("=" * 60)
    log.info("run-all: %s%s", wav, " (BYO summary)" if force_byo else "")
    log.info("=" * 60)
    events.emit("pipeline", "run_started", wav=str(wav), force_byo=force_byo)

    try:
        return _run_all_inner(wav, cfg, force_byo=force_byo)
    except Exception as e:
        events.emit("pipeline", "run_failed", wav=str(wav),
                    error=str(e), error_type=type(e).__name__)
        raise


def _run_all_inner(wav: Path, cfg: Config, *, force_byo: bool) -> dict:
    # Daemon-produced transcript path: when the Swift daemon produced
    # `<stem>.json` before invoking us (streaming subprocess during
    # recording, or the FluidAudio in-process runner after stop), we pick
    # up where the daemon left off. Speaker labels may already be attached
    # (FluidAudio runs pyannote inline; the streaming diarizer can also
    # populate them) — `_finalize_streamed_transcript` checks and skips
    # the offline diarize step accordingly. Falls back to a fresh full
    # transcribe if the daemon output is missing or looks broken.
    streamed = _existing_daemon_transcript(wav)
    if streamed is not None:
        source = streamed.get("backend") or ("streamed" if streamed.get("streaming") else "daemon")
        log.info("[1/3] transcribe (produced by daemon: %s)", source)
        events.emit("pipeline", "stage_started", stage="transcribe", source=source)
        t = _finalize_streamed_transcript(wav, streamed, cfg)
    else:
        log.info("[1/3] transcribe")
        events.emit("pipeline", "stage_started", stage="transcribe", source="offline")
        t = transcribe(wav, cfg=cfg)
    events.emit("pipeline", "stage_completed", stage="transcribe", md=str(t["md"]))

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
        events.emit("pipeline", "run_skipped", wav=str(wav), reason="no_speech")
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
        events.emit("pipeline", "run_skipped", wav=str(wav), reason="byo",
                    transcript_chars=len(md_text), bundle=str(bundle))
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
        events.emit("pipeline", "run_skipped", wav=str(wav), reason="too_long",
                    transcript_chars=len(md_text), threshold=threshold,
                    bundle=str(bundle))
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
    events.emit("pipeline", "stage_started", stage="summarize")
    s = summarize(t["md"], cfg=cfg)
    events.emit("pipeline", "stage_completed", stage="summarize", md=str(s["md"]))

    # Run sidecar: snapshot of which backend + model produced this
    # summary, plus enough metadata for the Phase 2 correction loop to
    # round-trip the original summary without guessing. Best-effort; a
    # write failure is logged but does not block publish.
    try:
        sidecar = write_run_sidecar(
            recordings_dir=Path(t["md"]).parent,
            stem=Path(t["md"]).stem,
            transcript_path=Path(t["md"]),
            transcript_chars=len(md_text),
            summary_json_path=Path(s["json"]),
            backend=str(s.get("backend") or ""),
            model=str(s.get("model") or ""),
        )
        log.info("Wrote run sidecar: %s", sidecar)
    except Exception as e:  # noqa: BLE001
        log.warning("run sidecar write failed: %s", e)

    log.info("[3/3] publish (sinks=%s)", ",".join(cfg.output.sinks) or "none")
    events.emit("pipeline", "stage_started", stage="publish",
                sinks=list(cfg.output.sinks))
    pub = publish_fanout(
        summary_json=s["json"],
        cfg=cfg,
        transcript_md=t["md"],
    )
    events.emit("pipeline", "stage_completed", stage="publish",
                page_url=pub.get("page_url"),
                failures=[name for name, _ in pub.get("failures", [])])

    log.info("done: page_url=%s", pub.get("page_url"))
    events.emit("pipeline", "run_completed", wav=str(wav),
                page_url=pub.get("page_url"))
    return {
        "transcript_json": str(t["json"]),
        "transcript_md": str(t["md"]),
        "summary_json": str(s["json"]),
        "summary_md": str(s["md"]),
        **pub,
    }


_DAEMON_BACKENDS = frozenset({"fluidaudio"})


def _existing_daemon_transcript(wav: Path) -> dict | None:
    """Return the structured JSON the daemon wrote, or None if it doesn't
    exist / is unusable.

    Two daemon-side producers count as "the daemon wrote it":
    - the streaming subprocess (legacy path; `streaming: true`)
    - the in-process FluidAudio runner (Group P; `backend: "fluidaudio"`,
      `streaming: false`, `finalized: true`)

    Both write the same schema (`segments`, `language`, `audio_seconds`,
    etc.). We accept either provenance and reject a stale Python-side
    offline transcript from a previous run (no daemon marker present).
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
    is_streamed = bool(data.get("streaming"))
    is_daemon_backend = str(data.get("backend") or "") in _DAEMON_BACKENDS
    if not (is_streamed or is_daemon_backend):
        return None
    if not data.get("segments"):
        log.warning("Daemon transcript has zero segments — falling back to offline transcribe")
        return None
    return data


def _streamed_segments_have_speakers(streamed: dict) -> bool:
    """The streaming sidecar may have already attached speaker labels via
    the online diarizer (Tier 2.5). When at least half the segments have
    a real speaker label (not None / not the `Speaker?` fallback), trust
    the streamed diarization and skip the offline at-stop step entirely."""
    segs = streamed.get("segments") or []
    if not segs:
        return False
    labelled = sum(1 for s in segs if s.get("speaker") and s.get("speaker") != "Speaker?")
    return labelled >= max(1, len(segs) // 2)


def _finalize_streamed_transcript(wav: Path, streamed: dict, cfg: Config) -> dict[str, Path]:
    """Finish the streamed transcript so downstream stages see a clean
    `<stem>.json` + `<stem>.md`.

    Two paths:
      - Streaming diarizer already labelled most segments → trust it,
        rewrite only the `finalized: true` marker. No offline diarize run.
      - Speaker labels are missing or sparse → run offline diarize on
        the canonical merged WAV (slower, but produces a correct
        labelling that the streaming pass missed).
    """
    json_path = wav.parent / f"{wav.stem}.json"
    md_path = wav.parent / f"{wav.stem}.md"
    tcfg = cfg.transcription

    if _streamed_segments_have_speakers(streamed):
        log.info("Streaming diarizer already labelled segments — skipping offline diarize")
        structured = {**streamed, "streaming": True, "finalized": True}
        json_path.write_text(json.dumps(structured, ensure_ascii=False, indent=2), encoding="utf-8")
        md_path.write_text(render_markdown(structured), encoding="utf-8")
        return {"json": json_path, "md": md_path}

    diarization_failed = False
    diarization_failure_reason: str | None = None
    diar_segments: list = []

    audio_seconds = streamed.get("audio_seconds") or 0.0
    audio_minutes = audio_seconds / 60.0
    skip_for_length = (
        tcfg.max_diarization_minutes
        and audio_minutes > tcfg.max_diarization_minutes
    )

    used_channel_aware = False
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
    elif is_stereo_recording(wav):
        log.info("Stereo recording — channel-aware speaker labelling at finalization")
        used_channel_aware = True
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

    if used_channel_aware:
        labelled = assign_speakers_by_channel(streamed["segments"], wav)
    elif diar_segments:
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
