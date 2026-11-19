"""`mp run-all <wav>` — fail-fast pipeline orchestration.

Stages:
  1. finalize     →  <stem>.json   + <stem>.md   (finalizes the daemon's FluidAudio transcript)
  2. summarize    →  <stem>.summary.json + <stem>.summary.md
  3. publish      →  per-sink sidecars (e.g. <stem>.notion.json)

Each stage logs to ~/Library/Logs/MeetingPipe/pipeline.log: through the root
logger configured here on a hand run, and through the daemon's copy of our
stderr when the daemon spawned us (PERF13, one writer per run).

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
import threading
import time
from collections.abc import Callable
from importlib import resources
from pathlib import Path
from typing import Any, NamedTuple

from . import entry, events, providers, storage, usage
from .config import (
    Config,
    effective_backend,
    extract_backend_flag,
    with_backend_override,
    zero_egress,
)
from .corrections import cleanup_counts as corrections_cleanup_counts
from .corrections import set_publish_state, write_empty_marker, write_run_sidecar
from .diarize import (
    MicTier,
    analyze_mic_tier,
    apply_speaker_labels,
    assign_speakers_by_channel,
    is_stereo_recording,
    label_me_speaker,
    match_voiceprint,
    resolve_speaker_labels,
)
from .glossary import load_glossary
from .markdown import render_markdown
from .markers import flagged_moments_block
from .publish_router import (
    EXIT_PUBLISH_FAILED,
    publish_failed,
    publish_failure_reason,
    publish_state,
    published_sinks,
)
from .publish_router import (
    fanout as publish_fanout,
)
from .roster import RosterStore
from .summarize import summarize
from .transcript_quality import below_content_floor, speech_span_sec, transcript_issues, word_count
from .voiceprint import VoiceprintStore

log = logging.getLogger("mp.run_all")

# Sentinel prefix for the live progress channel the Swift daemon parses off our
# stdout (TECH-UX5). The durable record is the `pipeline.stage_progress` event;
# the daemon copies this line into pipeline.log with the rest of stdout. AI11 moved
# the constant and the emit to `events` once `mp ask` needed the same channel;
# this alias keeps the name run-all's readers already know.
PROGRESS_SENTINEL = events.PROGRESS_SENTINEL


class _ProgressHeartbeat:
    """Background heartbeat for `run_all` (TECH-UX5). Every `interval_s` it
    emits a `pipeline.stage_progress` event and prints a stdout sentinel with
    the current stage + elapsed, so the daemon can distinguish a slow stage
    from a wedged one. The stage is updated by the run as it advances.

    PIPE53: the beat also carries `stage_elapsed_s`, the seconds since the stage
    began or since the last unit of real work finished (`mark_progress`, reached
    through `events.note_progress` from each model call and cleanup window). The
    timer thread beats whether or not the run is doing anything, so on its own a
    request hung for 124 s looked exactly like a healthy one; this number is the
    part of the beat that only moves when the run does."""

    def __init__(self, interval_s: float = 5.0, clock: Callable[[], float] = time.monotonic) -> None:
        self._interval = interval_s
        self._clock = clock
        self._stage = "starting"
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._started_at = clock()
        self._progress_at = self._started_at
        self._thread = threading.Thread(target=self._run, name="mp-progress", daemon=True)

    def set_stage(self, stage: str) -> None:
        with self._lock:
            self._stage = stage
            self._progress_at = self._clock()

    def mark_progress(self) -> None:
        with self._lock:
            self._progress_at = self._clock()

    def start(self) -> _ProgressHeartbeat:
        events.set_progress_hook(self.mark_progress)
        self._thread.start()
        return self

    def stop(self) -> None:
        events.set_progress_hook(None)
        self._stop.set()
        self._thread.join(timeout=1.0)

    def _snapshot(self) -> tuple[str, int, int]:
        """(stage, whole-run elapsed, stage elapsed) as of now."""
        with self._lock:
            stage = self._stage
            now = self._clock()
            return stage, int(now - self._started_at), int(now - self._progress_at)

    def _run(self) -> None:
        beat = 0
        while not self._stop.wait(self._interval):
            beat += 1
            stage, elapsed, stage_elapsed = self._snapshot()
            events.emit_progress(stage, elapsed_s=elapsed, beat=beat, stage_elapsed_s=stage_elapsed)


#: Set by the daemon's `PipelineLauncher.runMP` on every spawn (PERF13); mirrored
#: by `PipelineLauncher.pipelineLogOwnerKey`. "daemon" means the daemon owns
#: `pipeline.log` and this process must not open it.
PIPELINE_LOG_OWNER_ENV = "MP_PIPELINE_LOG_OWNER"


def _configure_logging() -> None:
    """Mirror logs to stderr (captured by the Swift launcher) and ~/Library/Logs.

    The file handler is always opened so `pipeline.log` exists on disk after
    the first run, even if nothing is logged. Without this, a silent failure
    earlier in the pipeline left the user with no log to grep — which is how
    the diarization regression went undiagnosed for weeks.

    Everything touching that path sits **below** the already-configured guard
    (CI6). Above it, a caller that owns the root logger already, which in
    practice means the test suite, created `~/Library/Logs/MeetingPipe/` and an
    empty `pipeline.log` under the process umask rather than the 0600 SEC14
    ships for that file, and bumped the real one's mtime on a developer's Mac.
    A run that reaches the handler below still gets the file, which is the only
    caller the promise above was ever about.

    PERF13: `pipeline.log` has one writer per run. When the daemon spawned us
    (`MP_PIPELINE_LOG_OWNER=daemon`) it copies our stderr into the file through
    its own `O_APPEND` writes, so this returns after the stream handler and
    touches the file not at all: no FileHandler, no rotation under the daemon's
    feet. Both used to write, which put every record in twice and, through the
    daemon's stale write offset, tore the tail of 5 of 8 real runs. A hand-run
    `mp run-all` has no flag and keeps the FileHandler, its only file sink.
    """
    fmt = "%(asctime)s %(levelname)s %(name)s: %(message)s"

    root = logging.getLogger()
    if root.handlers:
        return  # already configured by caller (e.g. tests)
    root.setLevel(logging.INFO)

    stream = logging.StreamHandler(stream=sys.stderr)
    stream.setFormatter(logging.Formatter(fmt))
    root.addHandler(stream)

    if os.environ.get(PIPELINE_LOG_OWNER_ENV) == "daemon":
        return

    # T9: through `events.logs_dir`, so `MEETINGPIPE_LOGS_DIR` and the pytest
    # redirect hold for the text log exactly as for the event log.
    logs_dir = events.logs_dir()
    logs_dir.mkdir(parents=True, exist_ok=True)
    log_file = logs_dir / "pipeline.log"
    log_file.touch(exist_ok=True)

    events.rotate_if_needed(log_file)  # PERF7: rotate before opening the run's handle
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
The pipeline did NOT call the configured engine to summarize it, since that
engine is billed per token and a meeting this size costs noticeable money.

## How to process it

1. Open Claude Code (or claude.ai, or any LLM that takes large contexts).
2. Paste the prompt below as the system message / first instruction.
3. Attach or paste the transcript markdown:

   `{transcript_md}`

4. Ask for the summary. Save the result wherever you want — the pipeline
   won't touch it.

If you decide later that you DO want this meeting auto-summarized, run:

    mp run-all "{transcript_md.with_suffix('.wav')}"

after raising **Pay-per-token limit** in Preferences > Pipeline > Long meetings
(`summarization.skip_above_chars` in `~/.config/meeting-pipe/config.toml`), or
set it to 0 to turn the guard off. Local chunking has its own knob since PIPE27,
so turning this off no longer changes how the local model splits a meeting.

---

## System prompt the pipeline would have used

```markdown
{prompt}
```
"""
    # FEAT8: carry the flagged moments into the paste bundle so a BYO / long
    # meeting summarized by hand still sees what the user marked as important.
    flagged = flagged_moments_block(transcript_md)
    if flagged:
        body += f"\n\n---\n\n{flagged}\n"
    storage.atomic_write_text(bundle, body)  # the whole transcript: 0600 (PIPE30)
    return bundle


def apply_glossary(wav: Path, t: dict[str, Path]) -> None:
    """ASR1: normalize custom vocabulary in the finalized transcript.

    A pure local transform (no engine call, no egress) applied before
    summarize / embed ever see the text, so a recurring proper noun mangled by
    ASR is spelled consistently across the transcript, summary, and embedding
    index. Runs only on a fresh finalize (transcripts stay write-once); a
    no-op when no glossary is configured or nothing matches, in which case the
    finalized files are left byte-identical.

    Public, not module-private, because `mp finalize` is the second caller
    (ASR3): a re-transcribed old meeting has to pick up glossary entries added
    since it was recorded, and that is the same transform, not a copy of it.
    """
    glossary = load_glossary(wav)
    if not glossary:
        return
    structured = json.loads(t["json"].read_text(encoding="utf-8"))
    segments = structured.get("segments") or []
    exact = fuzzy = 0
    changed = False
    for seg in segments:
        text = seg.get("text")
        if not text:
            continue
        new, e, f = glossary.apply(text)
        exact += e
        fuzzy += f
        if new != text:
            seg["text"] = new
            changed = True
    if not changed:
        return
    # Atomic (PIPE8) + 0600 (SEC14): a crash mid-rewrite leaves the prior
    # transcript intact rather than a truncated one; transcripts carry meeting content.
    storage.atomic_write_text(t["json"], json.dumps(structured, ensure_ascii=False, indent=2))
    storage.atomic_write_text(t["md"], render_markdown(structured))
    events.emit("pipeline", "glossary_applied", exact=exact, fuzzy=fuzzy, segments=len(segments))
    log.info("glossary: %d exact + %d fuzzy substitutions across %d segments",
             exact, fuzzy, len(segments))


def run_all(
    wav: Path,
    cfg: Config | None = None,
    *,
    force_byo: bool | None = None,
    backend: str | None = None,
) -> dict:
    """Run finalize -> summarize -> publish. Raises on first failure.
    ASR + diarization happen in Swift (FluidAudio) before this is
    invoked; the daemon writes `<stem>.json` and we read it.

    `force_byo=True` short-circuits to the manual-paste bundle after
    finalize, even when the transcript is short enough to auto-summarize.
    Defaults to reading `MP_FORCE_BYO=1` from the environment so the
    Swift launcher can opt in per-meeting without flag plumbing.

    `backend` is a one-shot summarization backend override for a re-run over an
    existing recording (PIPE6). Applied here so the pre-summarize apple-handoff
    decision reflects it, and threaded into `summarize` (which re-applies it after
    its own overlay). It never rewrites the workflow's persisted backend.
    """
    # The entry contract (SEC13): per-meeting workflow overrides from the
    # daemon-written meta sidecar (TECH-B4), then the structural egress backstop
    # on the resolved config (TECH-SEC3), then secrets. No-op overlay for
    # shell-invoked `mp run-all` against wavs that have no sidecar.
    cfg = entry.prepare(cfg, wav)
    storage.sweep_stale_temps(wav.parent, wav.stem)  # PIPE30: a killed writer's leftovers
    _clear_stale_apple_sentinel(wav)
    if backend is not None:
        cfg = with_backend_override(cfg, backend)
        log.info("run-all: one-shot backend override -> %s", backend)

    if force_byo is None:
        force_byo = os.environ.get("MP_FORCE_BYO") == "1"

    log.info("=" * 60)
    log.info("run-all: %s%s", wav, " (BYO summary)" if force_byo else "")
    log.info("=" * 60)
    usage.reset()  # PIPE27: this run's tokens, not an earlier in-process run's
    events.emit("pipeline", "run_started", wav=str(wav), force_byo=force_byo)

    heartbeat = _ProgressHeartbeat().start()
    try:
        return _run_all_inner(
            wav, cfg, force_byo=force_byo, heartbeat=heartbeat, backend=backend
        )
    except Exception as e:
        from .failure_details import emit_failure
        operation = {"summarize": "summary", "publish": "publish", "finalize": "transcribe"}.get(heartbeat._stage, "processing")
        emit_failure(e, operation=operation)
        events.emit("pipeline", "run_failed", wav=str(wav),
                    error=str(e), error_type=type(e).__name__)
        raise
    finally:
        heartbeat.stop()


def _skip_result(t: dict[str, Path], reason: str, **extra: str) -> dict:
    """The shape every short-circuit returns: the transcript we did produce, no
    summary, no page, and the reason we stopped. `extra` carries the one
    skip-specific key (`manual_bundle`, `apple_pending`) where there is one."""
    return {
        "transcript_json": str(t["json"]),
        "transcript_md": str(t["md"]),
        "summary_json": None,
        "summary_md": None,
        "page_id": None,
        "page_url": None,
        "skipped": reason,
        **extra,
    }


def _mark_empty(wav: Path, reason: str) -> None:
    """Terminal marker so the Library shows a real state instead of spinning in
    "Processing" forever. Best-effort: a marker write failure must not turn a
    clean skip into a crash."""
    try:
        write_empty_marker(recordings_dir=wav.parent, stem=wav.stem, reason=reason)
    except OSError as exc:
        log.warning("empty marker write failed: %s", exc)


def _check_no_speech(wav: Path, t: dict[str, Path], structured: dict) -> dict | None:
    """Empty transcript (silent audio, broken capture). Don't burn Anthropic
    tokens summarizing nothing. Reads the structured JSON's segment count rather
    than scanning the markdown: the previous `"**" not in md_text` heuristic
    broke the moment any header line contained bold styling."""
    if structured.get("segments"):
        return None
    log.warning("Transcript has no speaker turns — skipping summarize + publish.")
    log.warning("  WAV: %s", wav)
    log.warning("  MD : %s", t["md"])
    events.emit("pipeline", "run_skipped", wav=str(wav), reason="no_speech")
    _mark_empty(wav, "no_speech")
    return _skip_result(t, "no_speech")


def _check_suspect_transcript(wav: Path, t: dict[str, Path], structured: dict) -> dict | None:
    """Degenerate transcript (LOCAL2/AUD-21). FluidAudio can emit garbage on real
    audio without erroring (a decoder stuck on one phrase, or near-empty output
    over a long recording). Summarizing it burns a model call and publishes
    nonsense, so mark it suspect and stop, the way no-speech stops on genuine
    silence. The checks (transcript_quality) are conservative so a real meeting is
    never withheld; the marker's reason records the true cause for the Library to
    surface (distinct UI: PIPE3)."""
    suspect = transcript_issues(structured.get("segments", []))
    if not suspect:
        return None
    log.warning("Transcript looks degenerate - skipping summarize + publish:")
    for reason in suspect:
        log.warning("  - %s", reason)
    events.emit("pipeline", "run_skipped", wav=str(wav),
                reason="suspect_transcript", issues="; ".join(suspect))
    _mark_empty(wav, "suspect_transcript")
    return _skip_result(t, "suspect_transcript")


def _check_content_floor(wav: Path, t: dict[str, Path], structured: dict) -> dict | None:
    """PIPE43: a transcript too thin to summarize (a 20 s, 32-word fragment got an 88-word
    summary with action items in the field). Kept with its transcript and an empty marker the
    Library shows as its own state; not summarized, not published. Re-summarize still runs
    `mp summarize`, which does not pass through these gates, so the owner can override."""
    segments = structured.get("segments") or []
    reason = below_content_floor(segments)
    if reason is None:
        return None
    log.info("Transcript is below the content floor (%s) - skipping summarize + publish.", reason)
    events.emit("pipeline", "run_skipped", wav=str(wav), reason="below_content_floor",
                words=word_count(segments), span_s=round(speech_span_sec(segments), 1))
    _mark_empty(wav, "below_content_floor")
    return _skip_result(t, "below_content_floor")


def _check_byo(
    wav: Path, t: dict[str, Path], md_text: str, force_byo: bool, cfg: Config
) -> dict | None:
    """Explicit BYO request from the user (per-meeting toggle on the prompt
    panel). Same machinery as the long-meeting guard: write the bundle and stop.

    Declined under zero egress (SEC18): the bundle's only purpose is to be pasted
    into a cloud chat, which a regulated or NDA meeting promised never happens. The
    run falls through to the on-device summary instead of stopping, so the owner who
    ticked BYO still gets a summary and nothing is written for pasting."""
    if not force_byo:
        return None
    if zero_egress(cfg):
        log.warning("BYO summary requested but this run is zero-egress; summarizing on-device instead.")
        events.emit("pipeline", "byo_refused", wav=str(wav), reason="byo_refused_zero_egress",
                    transcript_chars=len(md_text))
        return None
    bundle = _write_manual_bundle(t["md"], len(md_text), threshold=0)
    log.info("BYO summary requested — skipping Anthropic call.")
    log.info("Manual-processing bundle written: %s", bundle)
    log.info("Run `mp publish-from-paste %s` after saving your summary.", t["md"])
    events.emit("pipeline", "run_skipped", wav=str(wav), reason="byo",
                transcript_chars=len(md_text), bundle=str(bundle))
    return _skip_result(t, "byo", manual_bundle=str(bundle))


def _bills_per_token(cfg: Config) -> bool:
    """Whether this run's engine is billed per token, so the long-meeting gate applies
    (PIPE27). Read off the backend's `providers` row (PIPE19): `bills_per_token`, and
    for `auto` (``cloud_then_local``) only while an Anthropic key is available
    (mirroring ``backend_fallback.run_with_local_fallback``'s resolution); keyless
    `auto` summarizes locally. On-device engines and `claude_cli`, which runs on the
    user's subscription, are never gated. ``entry.prepare`` loaded secrets before
    this, so the env is authoritative; regulated / NDA already fold to ``local`` in
    ``effective_backend``."""
    row = providers.lookup(effective_backend(cfg))
    if not row.bills_per_token:
        return False
    if row.locality == "cloud_then_local":
        return bool(os.environ.get("ANTHROPIC_API_KEY"))
    return True


def _check_too_long(wav: Path, t: dict[str, Path], md_text: str, cfg: Config) -> dict | None:
    """Long-meeting guard for per-token engines (PIPE4, narrowed by PIPE27). It exists
    to avoid a large API bill on a long transcript by handing it to the user for manual
    processing. An engine with no per-token bill is exempt: on-device runs (Apple
    Intelligence chunks in the daemon, local MLX map-reduces above
    ``local_chunk_above_chars``) and ``claude_cli`` (the user's subscription). The
    paste-bundle escape hatch stays the per-token-over-threshold behaviour."""
    threshold = cfg.summarization.skip_above_chars
    if not threshold or len(md_text) <= threshold:
        return None
    if not _bills_per_token(cfg):
        return None
    bundle = _write_manual_bundle(t["md"], len(md_text), threshold)
    log.warning(
        "Transcript is %d chars (threshold %d) — skipping summarize + publish.",
        len(md_text), threshold,
    )
    log.warning("Manual-processing bundle written: %s", bundle)
    events.emit("pipeline", "run_skipped", wav=str(wav), reason="too_long",
                transcript_chars=len(md_text), threshold=threshold,
                bundle=str(bundle))
    return _skip_result(t, "too_long", manual_bundle=str(bundle))


def _clear_stale_apple_sentinel(wav: Path) -> None:
    """PIPE34 (F054): remove a `<stem>.apple_pending.json` an earlier run left.

    Only the daemon consumes the sentinel, so a hand-run `mp run-all` on the Apple backend,
    or a run killed after writing it, leaves one behind; a later run-all that succeeds on
    another backend then exits 0 and the daemon diverts it into an on-device re-summarize.
    Cleared at start, the only sentinel left after this run is one this run wrote.
    """
    sentinel = wav.parent / f"{wav.stem}.apple_pending.json"
    try:
        sentinel.unlink(missing_ok=True)
    except OSError as e:
        log.warning("stale apple_pending sentinel could not be removed: %s", e)


def _check_apple_handoff(wav: Path, t: dict[str, Path], md_text: str, cfg: Config) -> dict | None:
    """Apple Intelligence hand-off. The macOS 26 Foundation Model is Swift-only,
    so we finalize (and optionally clean) the transcript here, then stop and let
    the daemon produce the summary on-device and run `mp publish`. The sentinel is
    the signal the daemon watches for.

    Runs after diarize_cleanup, not with the other short-circuits: the daemon
    summarizes the transcript this function points it at, so the cleanup pass has
    to have already rewritten it."""
    if effective_backend(cfg) != "apple_intelligence":
        return None
    sentinel = wav.parent / f"{wav.stem}.apple_pending.json"
    storage.atomic_write_text(sentinel, json.dumps({
        "schema_version": 1,
        "transcript_md": str(t["md"]),
        "transcript_json": str(t["json"]),
    }))
    log.info("Apple Intelligence backend: handing summary off to the daemon.")
    log.info("Apple-pending sentinel written: %s", sentinel)
    events.emit("pipeline", "run_skipped", wav=str(wav), reason="apple_pending",
                transcript_chars=len(md_text), sentinel=str(sentinel))
    return _skip_result(t, "apple_pending", apple_pending=str(sentinel))


def _shared_local_client(cfg: Config) -> Any:
    """The one client speaker cleanup and summarize share in a run, or None (PERF25).

    Only when cleanup is on and the effective backend is `local`. Built through
    the providers row, so it carries every configured local setting and is not a
    direct construction (`test_local_client_contract.py`). Every other backend
    builds its clients as before: `auto`'s local rung lives inside its fallback
    ladder, Apple Intelligence summarizes in the daemon, and a cloud client owns
    no process to reload."""
    if not cfg.summarization.diarize_cleanup or effective_backend(cfg) != "local":
        return None
    build = providers.lookup("local").build_summary
    return build(cfg) if build is not None else None


def _close_shared(shared: Any) -> None:
    close = getattr(shared, "close", None)
    if callable(close):
        close()


def _run_all_inner(
    wav: Path, cfg: Config, *, force_byo: bool,
    heartbeat: _ProgressHeartbeat | None = None, backend: str | None = None,
) -> dict:
    def _stage(name: str) -> None:
        if heartbeat is not None:
            heartbeat.set_stage(name)

    # The Swift daemon writes `<stem>.json` with FluidAudio's transcript
    # before invoking us. We finalize it (channel-aware speaker labels
    # fallback if FluidAudio diarization failed) and continue with
    # summarize + publish. No Python-side ASR exists anymore.
    # OBS3: raises the typed reason and emits nothing; `run_all`'s wrapper writes the one
    # `run_failed`, with that type as `error_type`.
    streamed = existing_daemon_transcript(wav)
    source = streamed.get("backend") or ("streamed" if streamed.get("streaming") else "daemon")
    log.info("[1/3] finalize (produced by daemon: %s)", source)
    _stage("finalize")
    events.emit("pipeline", "stage_started", stage="finalize", source=source)
    t = finalize_streamed_transcript(wav, streamed, user_label=cfg.summarization.user_label)
    # ASR1: custom-vocabulary normalization before any downstream stage (BYO /
    # long-meeting bundle, Apple hand-off, summarize, publish) reads the text.
    apply_glossary(wav, t)
    events.emit("pipeline", "stage_completed", stage="finalize", md=str(t["md"]))

    structured = json.loads(t["json"].read_text(encoding="utf-8"))
    log.debug("guards: segments=%d", len(structured.get("segments") or []))
    skip = (_check_no_speech(wav, t, structured)
            or _check_suspect_transcript(wav, t, structured)
            or _check_content_floor(wav, t, structured))
    if skip is not None:
        log.debug("guards: skipped (%s)", skip.get("skipped"))
        return skip

    md_text = t["md"].read_text(encoding="utf-8")
    skip = _check_byo(wav, t, md_text, force_byo, cfg) or _check_too_long(wav, t, md_text, cfg)
    if skip is not None:
        log.debug("summarize path: none (%s)", skip.get("skipped"))
        return skip
    log.debug("summarize path: backend=%s effective=%s per_token=%s chars=%d",
              cfg.summarization.backend, effective_backend(cfg), _bills_per_token(cfg),
              len(md_text))

    # PERF25: on the local backend, speaker cleanup and summarize share one
    # client, so one mlx_lm.server load serves both. Each used to build its own
    # and close it, which killed the server cleanup had spawned seconds before
    # summarize spawned it again and reloaded the weights. Closed once, right
    # after summarize, so the model's memory is back before publish exactly as
    # when summarize closed its own; a cleanup failure, an Apple hand-off, or a
    # summarize that raises all still close it.
    shared = _shared_local_client(cfg)
    # OBS8: (segments changed, segments) when this run's cleanup pass ran, for run.json.
    cleanup_counts: tuple[int, int] | None = None
    try:
        # Diarization cleanup (TECH-DIAR1): opt-in LLM pass that tidies the
        # speaker labels before summarizing. Placed after every cost-guard skip
        # short-circuit so it runs only when we are actually going to
        # summarize, and so it inherits the same cost guards. Failure is
        # non-fatal: a summary on the un-cleaned transcript beats no run.
        if cfg.summarization.diarize_cleanup:
            _stage("diarize_cleanup")
            events.emit("pipeline", "stage_started", stage="diarize_cleanup")
            try:
                from .diarize_cleanup import LocalCleanupClient, cleanup_transcript
                if shared is None:
                    cr = cleanup_transcript(t["json"], cfg=cfg)
                else:
                    cr = cleanup_transcript(
                        t["json"], cfg=cfg,
                        client=LocalCleanupClient(shared, max_tokens=cfg.summarization.max_tokens),
                    )
                events.emit("pipeline", "stage_completed", stage="diarize_cleanup",
                            merges=cr["merges_count"],
                            reattributions=cr["reattributions_count"])
                if "segments" in cr:
                    # Each applied edit is one segment, so the two counts are its changes.
                    cleanup_counts = (cr["merges_count"] + cr["reattributions_count"], cr["segments"])
                elif cr.get("skipped"):
                    # Already cleaned by an earlier run: that run's counts still describe it.
                    prior = storage.read_json_object(t["md"].with_name(f"{t['md'].stem}.run.json"))
                    cleanup_counts = corrections_cleanup_counts(prior) if prior else None
                md_text = t["md"].read_text(encoding="utf-8")
            except Exception as e:  # noqa: BLE001
                # PIPE19: non-fatal, but never silent. This used to be the log line
                # alone, so a cleanup that raised on every meeting left a
                # `stage_started` with nothing after it and nothing on screen.
                log.warning("diarize cleanup failed (non-fatal): %s", e)
                events.emit("pipeline", "stage_failed", stage="diarize_cleanup",
                            error=type(e).__name__, message=str(e)[:300])
                # PERF25: a failed pass may leave the shared server spawned but
                # unhealthy (a startup timeout, a request it was too busy to
                # finish), and `_ensure_running` would then spawn a second one on
                # the same port over the handle to the first. Close it, as the
                # pass's own client used to be closed, and summarize starts clean.
                if shared is not None:
                    _close_shared(shared)
                    shared = _shared_local_client(cfg)

        skip = _check_apple_handoff(wav, t, md_text, cfg)
        if skip is not None:
            return skip

        log.info("[2/3] summarize")
        _stage("summarize")
        events.emit("pipeline", "stage_started", stage="summarize")
        if shared is None:
            s = summarize(t["md"], cfg=cfg, backend=backend)
        else:
            s = summarize(t["md"], cfg=cfg, backend=backend, client=shared)
        events.emit("pipeline", "stage_completed", stage="summarize", md=str(s["md"]))
    finally:
        _close_shared(shared)

    # Run sidecar: snapshot of which backend + model produced this
    # summary, plus enough metadata for the Phase 2 correction loop to
    # round-trip the original summary without guessing. Best-effort; a
    # write failure is logged but does not block publish.
    sidecar: Path | None = None
    try:
        sidecar = write_run_sidecar(
            recordings_dir=t["md"].parent,
            stem=t["md"].stem,
            transcript_path=t["md"],
            transcript_chars=len(md_text),
            summary_json_path=s["json"],
            # `SummaryOutput` promises these statically, but a TypedDict is not
            # enforced at runtime and this write is best-effort: read them
            # tolerantly rather than turn a missing key into a lost sidecar.
            backend=s.get("backend", ""),
            model=s.get("model", ""),
            adapter_path=s.get("adapter_path", ""),
            fallback_from=s.get("fallback_from"),
            fallback_cause=s.get("fallback_cause"),
            usage=s.get("usage"),
            evidence_kept=s.get("evidence_kept"),
            evidence_dropped=s.get("evidence_dropped"),
            cleanup=cleanup_counts,
        )
        log.info("Wrote run sidecar: %s", sidecar)
    except Exception as e:  # noqa: BLE001
        log.warning("run sidecar write failed: %s", e)

    log.info("[3/3] publish (sinks=%s)", ",".join(cfg.output.sinks) or "none")
    _stage("publish")
    events.emit("pipeline", "stage_started", stage="publish",
                sinks=list(cfg.output.sinks))
    pub = publish_fanout(
        summary_json=s["json"],
        cfg=cfg,
        transcript_md=t["md"],
    )
    # SEC38: sink names, never the page address (it embeds the meeting title's slug).
    events.emit("pipeline", "stage_completed", stage="publish",
                sinks=published_sinks(pub),
                failures=[name for name, _ in pub.get("failures", [])])

    # Record the publish outcome onto the run sidecar so the Library can badge a
    # partial / failed publish (TECH-I6). Best-effort, like the run-sidecar write.
    if sidecar is not None:
        try:
            set_publish_state(sidecar, publish_state(pub))
        except Exception as e:  # noqa: BLE001
            log.warning("publish_state update failed: %s", e)

    result = {
        "transcript_json": str(t["json"]),
        "transcript_md": str(t["md"]),
        "summary_json": str(s["json"]),
        "summary_md": str(s["md"]),
        **pub,
    }

    # Every configured sink failed (PIPE1/AUD-14). The transcript and summary are
    # on disk and worth keeping, so this is not an exception, but it is not a
    # completed run either: say so in the event log and let `main` exit non-zero.
    # Reporting `run_completed` here is what let the daemon clear the failure
    # sidecar and announce a meeting that never landed anywhere.
    if publish_failed(pub):
        reason = publish_failure_reason(pub)
        log.error("publish failed: %s", reason)
        events.emit("pipeline", "run_failed", wav=str(wav), stage="publish",
                    error=reason, error_type="PublishFailed")
        return {**result, "publish_failed": True}

    landed = published_sinks(pub)
    log.info("done: sinks=%s", ",".join(landed) or "local-only")
    events.emit("pipeline", "run_completed", wav=str(wav),
                published=bool(landed), sinks=landed, **(usage.snapshot() or {}))
    return result


_DAEMON_BACKENDS = frozenset({"fluidaudio"})


class DaemonTranscriptError(RuntimeError):
    """OBS3: the daemon's `<stem>.json` cannot be used. Three cases, three types, because they have
    three different causes: the recorder never wrote it, the disk will not give it back (an
    iCloud-evicted file reads EDEADLK), or something else wrote it. All three used to read as
    `MissingSidecar`, so an evicted transcript was filed as a recorder fault."""


class DaemonTranscriptMissing(DaemonTranscriptError):
    pass


class DaemonTranscriptUnreadable(DaemonTranscriptError):
    pass


class DaemonTranscriptForeign(DaemonTranscriptError):
    pass


def existing_daemon_transcript(wav: Path) -> dict:
    """Return the structured JSON the daemon wrote, or raise the typed reason it cannot be used.
    The daemon's FluidAudio runner writes `<stem>.json` with `backend: "fluidaudio"`,
    `streaming: false`, `finalized: true`. Empty-segments sidecars are accepted; the no-speech
    short-circuit in `_run_all_inner` handles them.

    Shared with `mp finalize` (ASR3), which reads the same sidecar.
    """
    path = wav.parent / f"{wav.stem}.json"
    read = storage.load_json_object(path)
    if read.state == "missing":
        raise DaemonTranscriptMissing(
            f"No daemon transcript at {path}. FluidAudio must produce the sidecar before the "
            "Python pipeline runs."
        )
    if read.state == "unreadable" or read.data is None:
        detail = read.errno or ("not a JSON object" if read.kind == "parse" else "unreadable")
        raise DaemonTranscriptUnreadable(f"The daemon transcript at {path} cannot be read ({detail}).")
    if str(read.data.get("backend") or "") not in _DAEMON_BACKENDS:
        raise DaemonTranscriptForeign(f"{path} was not written by the daemon's transcriber.")
    return read.data


def _streamed_segments_have_speakers(streamed: dict) -> bool:
    """FluidAudio writes speaker labels inline. When at least half the
    segments carry a real label (not None / not `Speaker?`), trust them
    and skip the channel-aware finalize step entirely.

    DIAR8: the sidecar's own `diarization_failed` flag decides before any label is
    counted. Swift labels every segment `speaker_unknown` when its diarizer throws, and
    that string is not `Speaker?`, so counting labels called a failed run labelled. The
    flag, not the string, is the signal: `speaker_unknown` is also the healthy run's
    junk drawer. A transcript that already carries `speaker_fallback` was handled by an
    earlier finalize, so it is not routed back here: that pass needs the WAV, and a
    second `mp finalize` over a compressed or removed recording would otherwise wipe the
    channel labels it wrote."""
    if streamed.get("diarization_failed") and not streamed.get("speaker_fallback"):
        return False
    segs = streamed.get("segments") or []
    if not segs:
        return False
    labelled = sum(1 for s in segs if s.get("speaker") and s.get("speaker") != "Speaker?")
    return labelled >= max(1, len(segs) // 2)


# Stop folding new samples in once the running-average voiceprint is stable.
# The channel RMS pass itself is no longer capped: `_me_signals` needs it on
# every meeting, since the mic channel is what identifies the user.
_VOICEPRINT_ENROLL_CAP = 12


class MeSignals(NamedTuple):
    """The evidence `_me_signals` gathered for the owner cluster (DIAR11)."""

    mic_me: str | None
    voiceprint_me: str | None
    mic_tier: MicTier | None
    voiceprint: list[float] | None  # the self-voiceprint as it stood BEFORE this meeting enrolled


def _me_signals(
    segments: list[dict],
    speaker_embeddings: dict | None,
    wav: Path,
    store: VoiceprintStore,
) -> MeSignals:
    """Identify which diarized speaker is the user, and auto-enroll them.

    Returns the mic pick (`mic_me`), the voiceprint match (`voiceprint_me`), the
    mic tier's per-cluster numbers and the voiceprint, any of them None when that
    signal cannot decide:
      - `mic_me`: the speaker whose speech is predominantly on the mic channel
        of the stereo recording, chosen by mic speech time with a floor and a
        runner-up check (`diarize.pick_mic_speaker`); None on mono, and None when
        no cluster is clearly the one mic-side voice.
      - `voiceprint_me`: the speaker matching the persisted self-voiceprint,
        which still resolves those cases. When it disagrees with `mic_me`, the
        resolution prefers it (`diarize._resolve_me`).

    Both None means no evidence the user spoke at all, and the caller names
    nobody. No-ops when the daemon wrote no per-speaker embeddings (diarization
    failed). Matches before enrolling, so a meeting never just matches its own
    freshly added sample.

    With no voiceprint and a mic tier that declined only because a second mic-side
    cluster reached the runner-up share, the leader is taken as the owner (an
    over-split owner); see the block below and `diarize.resolve_speaker_labels`.

    Enrolment folds the mic pick's sample in only when it is corroborated
    (DIAR11): the voiceprint picked the same cluster, or no voiceprint exists yet
    and the mic pick cleared its checks. A pick the voiceprint disagrees with, or
    cannot place, is not evidence of the owner's voice, and a poisoned print weakens
    the very fallback the next meeting relies on.
    """
    if not isinstance(speaker_embeddings, dict) or not speaker_embeddings:
        return MeSignals(None, None, None, None)
    # STOR9: an unusable self-voiceprint is skipped, never read as "not enrolled",
    # which made the enrol below write a one-sample print over it.
    try:
        voiceprint, enrolled = store.load_checked()
        usable = True
    except storage.StoreUnreadable as e:
        storage.report_unreadable("voiceprint", e, "skipped")
        voiceprint, enrolled, usable = None, 0, False
    voiceprint_me = match_voiceprint(speaker_embeddings, voiceprint)
    tier = analyze_mic_tier(segments, wav)
    # No print yet and two mic-side clusters of comparable size: `owner_pick` takes the leader as
    # the owner (an over-split owner far more often than a second person, owner decision
    # 2026-11-17, accepting audit F096's cost), and it enrols, which bootstraps the print.
    # `resolve_speaker_labels` folds the rest of `tier.split` into the same name.
    mic_me = tier.owner_pick(voiceprint) if tier else None
    if (
        usable
        and enrolled < _VOICEPRINT_ENROLL_CAP
        and mic_me is not None
        and mic_me in speaker_embeddings
        and (voiceprint is None or voiceprint_me == mic_me)
    ):
        try:
            store.update(speaker_embeddings[mic_me])
        except storage.StoreUnreadable as e:  # went bad between the read and the lock
            storage.report_unreadable("voiceprint", e, "skipped")
    return MeSignals(mic_me, voiceprint_me, tier, voiceprint)


def _write_embeddings_sidecar(
    wav: Path,
    speaker_embeddings: dict | None,
    mapping: dict[str, str],
    near_misses: dict[str, str] | None = None,
    first: str | None = None,
) -> None:
    """Persist per-speaker embeddings keyed by FINAL label to
    `<stem>.embeddings.json`, so the Library naming UI can enroll a renamed
    speaker into the roster later. Keyed by the label the transcript shows
    (e.g. "THEM-A") so the daemon can look up the embedding for a label it
    renames. No-op when the daemon wrote no embeddings.

    `near_misses` (FEAT14) rides along under the same keys: for a `THEM-x` the
    roster declined but came close on, the person it came closest to. It is the
    same shape of record as the keys themselves, what the pipeline decided at
    finalize, so the app reads a suggestion off disk rather than re-running the
    matcher in a second language. Written only when there is one, and with no
    similarity beside it (`roster.MatchResult` says why)."""
    if not isinstance(speaker_embeddings, dict) or not speaker_embeddings:
        return
    by_label: dict[str, list[float]] = {}
    # `first` is the raw id the owner was resolved to: when a fold gives one label to several raw
    # ids, the stored vector must be the chosen cluster's, not whichever fragment the daemon listed
    # first (DIAR11).
    items = sorted(speaker_embeddings.items(), key=lambda kv: str(kv[0]) != first)
    for raw_id, emb in items:
        label = mapping.get(str(raw_id), str(raw_id))
        by_label.setdefault(label, emb)  # first wins on collision
    payload: dict = {"schema_version": 2, "embeddings": by_label}
    if near_misses:
        payload["near_misses"] = dict(near_misses)
    path = wav.parent / f"{wav.stem}.embeddings.json"
    # SEC22: biometric, so 0600 at creation, not at the next daemon launch's sweep.
    storage.atomic_write_text(path, json.dumps(payload))


def finalize_streamed_transcript(
    wav: Path,
    streamed: dict,
    *,
    user_label: str = "",
    voiceprint_store: VoiceprintStore | None = None,
    roster_store: RosterStore | None = None,
) -> dict[str, Path]:
    """Finalize the daemon transcript so downstream stages see clean
    `<stem>.json` + `<stem>.md`. FluidAudio normally provides speaker
    labels; when it didn't (diarization failed), fall back to a channel-
    aware pass over the stereo WAV.

    Public, not module-private, because `mp finalize` runs this stage on its
    own for the ASR3 re-transcribe ratchet: roster names learned after a
    meeting was recorded only reach it by re-running the match here.
    """
    json_path = wav.parent / f"{wav.stem}.json"
    md_path = wav.parent / f"{wav.stem}.md"

    store = voiceprint_store or VoiceprintStore()
    roster = roster_store or RosterStore()
    # The daemon writes per-speaker embeddings into the draft sidecar; consume
    # them here (voiceprint enroll/match + roster match) and strip them from the
    # transcript. They are re-persisted keyed by final label to
    # `<stem>.embeddings.json` for the Library naming UI.
    speaker_embeddings = streamed.pop("speaker_embeddings", None)

    if _streamed_segments_have_speakers(streamed):
        log.info("FluidAudio sidecar already labelled segments; finalizing as-is")
        segs = streamed.get("segments") or []
        sig = _me_signals(segs, speaker_embeddings, wav, store)
        resolved = resolve_speaker_labels(
            segs, speaker_embeddings, roster,
            user_label=user_label, mic_me=sig.mic_me, voiceprint_me=sig.voiceprint_me,
            mic_tier=sig.mic_tier, voiceprint=sig.voiceprint,
        )
        if resolved.owner is not None:
            # DIAR11: once per finalize. No label, name or text: the evidence only.
            events.emit("pipeline", "owner_cluster_chosen", stem=wav.stem, **resolved.owner._asdict())
        segments = apply_speaker_labels(segs, resolved.mapping)
        _write_embeddings_sidecar(
            wav, speaker_embeddings, resolved.mapping, resolved.near_misses,
            first=resolved.owner_id,
        )
        structured = {**streamed, "segments": segments, "finalized": True}
        # Atomic (PIPE8) + 0600 (SEC14): a crash mid-finalize leaves the prior
        # transcript intact, not a truncated one; transcripts carry meeting content.
        storage.atomic_write_text(json_path, json.dumps(structured, ensure_ascii=False, indent=2))
        storage.atomic_write_text(md_path, render_markdown(structured))
        return {"json": json_path, "md": md_path}

    # DIAR8: what the daemon recorded about its own diarizer, kept on the record through this pass.
    swift_failed = bool(streamed.get("diarization_failed"))
    swift_reason = streamed.get("diarization_failure_reason")
    diarization_failed = False
    diarization_failure_reason: str | None = None
    used_channel_aware = False
    speaker_fallback: str

    if is_stereo_recording(wav):
        log.info("Stereo recording; channel-aware speaker labelling at finalization")
        used_channel_aware = True
        diarization_failed = swift_failed
        diarization_failure_reason = swift_reason if swift_failed else None
        speaker_fallback = "channel"
    else:
        diarization_failed = True
        diarization_failure_reason = (
            swift_reason
            if swift_failed and swift_reason
            else "FluidAudio diarization missing and mono input; cannot label speakers"
        )
        speaker_fallback = "none"

    if used_channel_aware:
        labelled = assign_speakers_by_channel(streamed["segments"], wav)
    elif swift_failed:
        # The daemon's own sentinel stays: Swift's readers (the cast, the stats, the transcript
        # rows) know `speaker_unknown` and would show a literal `Speaker?` as a person.
        labelled = list(streamed["segments"])
    elif diarization_failed:
        labelled = [{**s, "speaker": "Speaker?"} for s in streamed["segments"]]
    else:
        labelled = list(streamed["segments"])

    labelled = label_me_speaker(labelled, user_label)  # TECH-FEAT3 speaker enrollment

    structured = {
        **streamed,
        "segments": labelled,
        "diarization": not diarization_failed,
        "diarization_failed": diarization_failed,
        "diarization_failure_reason": diarization_failure_reason,
        "speaker_fallback": speaker_fallback,
        "finalized": True,
    }
    # Atomic (PIPE8) + 0600 (SEC14), exactly as the labelled branch above: this
    # branch hand-rolled `write_text` + `chmod` until PIPE17, so a kill mid-write
    # left a truncated transcript that a retry then summarized as a whole meeting.
    storage.atomic_write_text(json_path, json.dumps(structured, ensure_ascii=False, indent=2))
    storage.atomic_write_text(md_path, render_markdown(structured))
    log.info("Finalized transcript: %s", json_path)
    return {"json": json_path, "md": md_path}


def main(argv: list[str]) -> int:
    try:
        argv, backend_override = extract_backend_flag(argv)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    if not argv:
        print(
            "usage: mp run-all <wav> [--backend anthropic|local|auto|apple_intelligence]",
            file=sys.stderr,
        )
        return 2
    wav = Path(argv[0]).expanduser().resolve()
    if not wav.exists():
        print(f"No such file: {wav}", file=sys.stderr)
        return 1
    _configure_logging()
    try:
        result = run_all(wav, backend=backend_override)
    except Exception as e:  # noqa: BLE001
        from .config import MissingSecretError
        from .failure_details import emit_failure
        emit_failure(e, operation="summary")
        if isinstance(e, MissingSecretError):
            # OBS3: the CLI boundary's exit 2 (PIPE16), as `summarize.main` already does; this
            # handler used to swallow it into exit 1 for the command that runs every meeting.
            raise
        log.exception("run-all failed: %s", e)
        return 1
    # PIPE1: an all-sinks-failed publish is a failed run. The daemon reads this
    # exit code to stamp `<stem>.error.json` with stage=publish, which in turn
    # makes the Library offer a publish-only retry over the summary we just wrote
    # rather than paying for a second summarize.
    if result.get("publish_failed"):
        return EXIT_PUBLISH_FAILED
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
