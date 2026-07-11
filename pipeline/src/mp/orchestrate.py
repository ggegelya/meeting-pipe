"""`mp run-all <wav>` — fail-fast pipeline orchestration.

Stages:
  1. finalize     →  <stem>.json   + <stem>.md   (finalizes the daemon's FluidAudio transcript)
  2. summarize    →  <stem>.summary.json + <stem>.summary.md
  3. publish      →  per-sink sidecars (e.g. <stem>.notion.json)

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
import threading
import time
from importlib import resources
from pathlib import Path

from . import entry
from .config import Config, effective_backend, extract_backend_flag, with_backend_override
from .corrections import set_publish_state, write_empty_marker, write_run_sidecar
from .transcript_quality import transcript_issues
from .diarize import (
    apply_speaker_labels,
    assign_speakers_by_channel,
    identify_user_speaker,
    is_stereo_recording,
    label_me_speaker,
    match_voiceprint,
    resolve_speaker_labels,
)
from .roster import RosterStore
from .voiceprint import VoiceprintStore
from . import events
from .glossary import load_glossary
from .markdown import render_markdown
from .markers import flagged_moments_block
from .publish_router import (
    EXIT_PUBLISH_FAILED,
    all_sinks_failed,
    fanout as publish_fanout,
    publish_state,
)
from .summarize import summarize

log = logging.getLogger("mp.run_all")

# Sentinel prefix for the live progress channel the Swift daemon parses off our
# stdout (TECH-UX5). The durable record is the `pipeline.stage_progress` event;
# this line is ephemeral and stripped from the daemon's pipeline.log.
PROGRESS_SENTINEL = "__MP_PROGRESS__"


class _ProgressHeartbeat:
    """Background heartbeat for `run_all` (TECH-UX5). Every `interval_s` it
    emits a `pipeline.stage_progress` event and prints a stdout sentinel with
    the current stage + elapsed, so the daemon can distinguish a slow stage
    from a wedged one. The stage is updated by the run as it advances."""

    def __init__(self, interval_s: float = 5.0) -> None:
        self._interval = interval_s
        self._stage = "starting"
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._started_at = time.monotonic()
        self._thread = threading.Thread(target=self._run, name="mp-progress", daemon=True)

    def set_stage(self, stage: str) -> None:
        with self._lock:
            self._stage = stage

    def start(self) -> "_ProgressHeartbeat":
        self._thread.start()
        return self

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=1.0)

    def _run(self) -> None:
        beat = 0
        while not self._stop.wait(self._interval):
            beat += 1
            with self._lock:
                stage = self._stage
            elapsed = int(time.monotonic() - self._started_at)
            events.emit("pipeline", "stage_progress", stage=stage, elapsed_s=elapsed, beat=beat)
            try:
                payload = json.dumps({"stage": stage, "elapsed_s": elapsed, "beat": beat})
                print(f"{PROGRESS_SENTINEL} {payload}", flush=True)
            except Exception:  # noqa: BLE001 - progress is best-effort
                pass


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
    # FEAT8: carry the flagged moments into the paste bundle so a BYO / long
    # meeting summarized by hand still sees what the user marked as important.
    flagged = flagged_moments_block(transcript_md)
    if flagged:
        body += f"\n\n---\n\n{flagged}\n"
    bundle.write_text(body, encoding="utf-8")
    return bundle


def _apply_glossary(wav: Path, t: dict[str, Path]) -> None:
    """ASR1: normalize custom vocabulary in the finalized transcript.

    A pure local transform (no engine call, no egress) applied before
    summarize / embed ever see the text, so a recurring proper noun mangled by
    ASR is spelled consistently across the transcript, summary, and embedding
    index. Runs only on this fresh finalize (transcripts stay write-once); a
    no-op when no glossary is configured or nothing matches, in which case the
    finalized files are left byte-identical.
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
    t["json"].write_text(json.dumps(structured, ensure_ascii=False, indent=2), encoding="utf-8")
    t["md"].write_text(render_markdown(structured), encoding="utf-8")
    # SEC14: transcripts carry meeting content, so keep them user-private (0600), like the logs.
    os.chmod(t["json"], 0o600)
    os.chmod(t["md"], 0o600)
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
    if backend is not None:
        cfg = with_backend_override(cfg, backend)
        log.info("run-all: one-shot backend override -> %s", backend)

    if force_byo is None:
        force_byo = os.environ.get("MP_FORCE_BYO") == "1"

    log.info("=" * 60)
    log.info("run-all: %s%s", wav, " (BYO summary)" if force_byo else "")
    log.info("=" * 60)
    events.emit("pipeline", "run_started", wav=str(wav), force_byo=force_byo)

    heartbeat = _ProgressHeartbeat().start()
    try:
        return _run_all_inner(
            wav, cfg, force_byo=force_byo, heartbeat=heartbeat, backend=backend
        )
    except Exception as e:
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


def _check_byo(wav: Path, t: dict[str, Path], md_text: str, force_byo: bool) -> dict | None:
    """Explicit BYO request from the user (per-meeting toggle on the prompt
    panel). Same machinery as the long-meeting guard: write the bundle and stop."""
    if not force_byo:
        return None
    bundle = _write_manual_bundle(t["md"], len(md_text), threshold=0)
    log.info("BYO summary requested — skipping Anthropic call.")
    log.info("Manual-processing bundle written: %s", bundle)
    log.info("Run `mp publish-from-paste %s` after saving your summary.", t["md"])
    events.emit("pipeline", "run_skipped", wav=str(wav), reason="byo",
                transcript_chars=len(md_text), bundle=str(bundle))
    return _skip_result(t, "byo", manual_bundle=str(bundle))


def _will_summarize_locally(cfg: Config) -> bool:
    """Whether this run summarizes on-device, so the long-meeting guard should route
    rather than bundle (PIPE4). True for ``local`` and ``apple_intelligence``, and for
    ``auto`` only when no Anthropic key is available (mirroring
    ``backend_fallback.run_with_local_fallback``'s resolution). ``entry.prepare`` ran
    before this and loaded secrets, so the env is authoritative. Regulated / NDA already
    fold to ``local`` in ``effective_backend``."""
    backend = effective_backend(cfg)
    if backend in ("local", "apple_intelligence"):
        return True
    if backend == "auto":
        return not os.environ.get("ANTHROPIC_API_KEY")
    return False


def _check_too_long(wav: Path, t: dict[str, Path], md_text: str, cfg: Config) -> dict | None:
    """Long-meeting guard, cloud-only (PIPE4). It exists to avoid Anthropic costs on a
    1+ hour transcript by handing it to the user for manual processing. An on-device run
    is free and does not overflow the bill, so it is exempt: Apple Intelligence chunks
    long transcripts in the daemon, and the local MLX backend map-reduces them in
    ``summarize_local`` (both above the same ``skip_above_chars`` threshold). The
    paste-bundle escape hatch stays the cloud-over-threshold behaviour and the fallback."""
    threshold = cfg.summarization.skip_above_chars
    if not threshold or len(md_text) <= threshold:
        return None
    if _will_summarize_locally(cfg):
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
    sentinel.write_text(
        json.dumps({
            "schema_version": 1,
            "transcript_md": str(t["md"]),
            "transcript_json": str(t["json"]),
        }),
        encoding="utf-8",
    )
    log.info("Apple Intelligence backend: handing summary off to the daemon.")
    log.info("Apple-pending sentinel written: %s", sentinel)
    events.emit("pipeline", "run_skipped", wav=str(wav), reason="apple_pending",
                transcript_chars=len(md_text), sentinel=str(sentinel))
    return _skip_result(t, "apple_pending", apple_pending=str(sentinel))


def _run_all_inner(
    wav: Path, cfg: Config, *, force_byo: bool,
    heartbeat: "_ProgressHeartbeat | None" = None, backend: str | None = None,
) -> dict:
    def _stage(name: str) -> None:
        if heartbeat is not None:
            heartbeat.set_stage(name)

    # The Swift daemon writes `<stem>.json` with FluidAudio's transcript
    # before invoking us. We finalize it (channel-aware speaker labels
    # fallback if FluidAudio diarization failed) and continue with
    # summarize + publish. No Python-side ASR exists anymore.
    streamed = _existing_daemon_transcript(wav)
    if streamed is None:
        events.emit("pipeline", "run_failed", wav=str(wav),
                    error="no daemon transcript", error_type="MissingSidecar")
        raise RuntimeError(
            f"No daemon transcript at {wav.with_suffix('.json')}. "
            "FluidAudio must produce the sidecar before the Python "
            "pipeline runs."
        )
    source = streamed.get("backend") or ("streamed" if streamed.get("streaming") else "daemon")
    log.info("[1/3] finalize (produced by daemon: %s)", source)
    _stage("finalize")
    events.emit("pipeline", "stage_started", stage="finalize", source=source)
    t = _finalize_streamed_transcript(wav, streamed, user_label=cfg.summarization.user_label)
    # ASR1: custom-vocabulary normalization before any downstream stage (BYO /
    # long-meeting bundle, Apple hand-off, summarize, publish) reads the text.
    _apply_glossary(wav, t)
    events.emit("pipeline", "stage_completed", stage="finalize", md=str(t["md"]))

    structured = json.loads(t["json"].read_text(encoding="utf-8"))
    skip = _check_no_speech(wav, t, structured) or _check_suspect_transcript(wav, t, structured)
    if skip is not None:
        return skip

    md_text = t["md"].read_text(encoding="utf-8")
    skip = _check_byo(wav, t, md_text, force_byo) or _check_too_long(wav, t, md_text, cfg)
    if skip is not None:
        return skip

    # Diarization cleanup (TECH-DIAR1): opt-in LLM pass that tidies the
    # speaker labels before summarizing. Placed after every cost-guard skip
    # short-circuit so it runs only when we are actually going to
    # summarize, and so it inherits the same cost guards. Failure is
    # non-fatal: a summary on the un-cleaned transcript beats no run.
    if cfg.summarization.diarize_cleanup:
        _stage("diarize_cleanup")
        events.emit("pipeline", "stage_started", stage="diarize_cleanup")
        try:
            from .diarize_cleanup import cleanup_transcript
            cr = cleanup_transcript(t["json"], cfg=cfg)
            events.emit("pipeline", "stage_completed", stage="diarize_cleanup",
                        merges=cr["merges_count"],
                        reattributions=cr["reattributions_count"])
            md_text = t["md"].read_text(encoding="utf-8")
        except Exception as e:  # noqa: BLE001
            log.warning("diarize cleanup failed (non-fatal): %s", e)

    skip = _check_apple_handoff(wav, t, md_text, cfg)
    if skip is not None:
        return skip

    log.info("[2/3] summarize")
    _stage("summarize")
    events.emit("pipeline", "stage_started", stage="summarize")
    s = summarize(t["md"], cfg=cfg, backend=backend)
    events.emit("pipeline", "stage_completed", stage="summarize", md=str(s["md"]))

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
    events.emit("pipeline", "stage_completed", stage="publish",
                page_url=pub.get("page_url"),
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
    if all_sinks_failed(pub):
        reason = "; ".join(f"{name}: {err}" for name, err in pub.get("failures", []))
        log.error("publish failed on every sink: %s", reason)
        events.emit("pipeline", "run_failed", wav=str(wav), stage="publish",
                    error=reason, error_type="PublishFailed")
        return {**result, "publish_failed": True}

    log.info("done: page_url=%s", pub.get("page_url"))
    events.emit("pipeline", "run_completed", wav=str(wav),
                page_url=pub.get("page_url"))
    return result


_DAEMON_BACKENDS = frozenset({"fluidaudio"})


def _existing_daemon_transcript(wav: Path) -> dict | None:
    """Return the structured JSON the daemon wrote, or None if it doesn't
    exist / is unusable. The daemon's FluidAudio runner writes `<stem>.json`
    with `backend: "fluidaudio"`, `streaming: false`, `finalized: true`.
    Empty-segments sidecars are accepted; the no-speech short-circuit in
    `_run_all_inner` handles them.
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
    if str(data.get("backend") or "") not in _DAEMON_BACKENDS:
        return None
    return data


def _streamed_segments_have_speakers(streamed: dict) -> bool:
    """FluidAudio writes speaker labels inline. When at least half the
    segments carry a real label (not None / not `Speaker?`), trust them
    and skip the channel-aware finalize step entirely."""
    segs = streamed.get("segments") or []
    if not segs:
        return False
    labelled = sum(1 for s in segs if s.get("speaker") and s.get("speaker") != "Speaker?")
    return labelled >= max(1, len(segs) // 2)


# Stop auto-enrolling once the running-average voiceprint is stable, so the
# once-per-meeting channel RMS pass that enrollment needs is not paid forever.
_VOICEPRINT_ENROLL_CAP = 12


def _apply_voiceprint(
    segments: list[dict],
    speaker_embeddings: dict | None,
    wav: Path,
    store: VoiceprintStore,
) -> str | None:
    """Match the meeting's speakers to the persisted self-voiceprint (returning
    the "me" speaker id, or None) and, on a stereo recording, fold the
    mic-channel user's embedding back into the voiceprint (auto-enrollment).

    No-ops when the daemon wrote no per-speaker embeddings (diarization failed).
    Matches before enrolling, so a meeting never just matches its own freshly
    added sample.
    """
    if not isinstance(speaker_embeddings, dict) or not speaker_embeddings:
        return None
    matched = match_voiceprint(speaker_embeddings, store.embedding())
    if store.meetings() < _VOICEPRINT_ENROLL_CAP:
        me = identify_user_speaker(segments, wav)
        if me is not None and me in speaker_embeddings:
            store.update(speaker_embeddings[me])
    return matched


def _write_embeddings_sidecar(
    wav: Path, speaker_embeddings: dict | None, mapping: dict[str, str]
) -> None:
    """Persist per-speaker embeddings keyed by FINAL label to
    `<stem>.embeddings.json`, so the Library naming UI can enroll a renamed
    speaker into the roster later. Keyed by the label the transcript shows
    (e.g. "THEM-A") so the daemon can look up the embedding for a label it
    renames. No-op when the daemon wrote no embeddings."""
    if not isinstance(speaker_embeddings, dict) or not speaker_embeddings:
        return
    by_label: dict[str, list[float]] = {}
    for raw_id, emb in speaker_embeddings.items():
        label = mapping.get(str(raw_id), str(raw_id))
        by_label.setdefault(label, emb)  # first wins on collision
    path = wav.parent / f"{wav.stem}.embeddings.json"
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(
        json.dumps({"schema_version": 1, "embeddings": by_label}), encoding="utf-8"
    )
    tmp.replace(path)


def _finalize_streamed_transcript(
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
        voiceprint_me = _apply_voiceprint(segs, speaker_embeddings, wav, store)
        mapping = resolve_speaker_labels(
            segs, speaker_embeddings, roster,
            user_label=user_label, voiceprint_me=voiceprint_me,
        )
        segments = apply_speaker_labels(segs, mapping)
        _write_embeddings_sidecar(wav, speaker_embeddings, mapping)
        structured = {**streamed, "segments": segments, "finalized": True}
        json_path.write_text(json.dumps(structured, ensure_ascii=False, indent=2), encoding="utf-8")
        md_path.write_text(render_markdown(structured), encoding="utf-8")
        # SEC14: transcripts carry meeting content, so keep them user-private (0600), like the logs.
        os.chmod(json_path, 0o600)
        os.chmod(md_path, 0o600)
        return {"json": json_path, "md": md_path}

    diarization_failed = False
    diarization_failure_reason: str | None = None
    used_channel_aware = False

    if is_stereo_recording(wav):
        log.info("Stereo recording; channel-aware speaker labelling at finalization")
        used_channel_aware = True
    else:
        diarization_failed = True
        diarization_failure_reason = (
            "FluidAudio diarization missing and mono input; cannot label speakers"
        )

    if used_channel_aware:
        labelled = assign_speakers_by_channel(streamed["segments"], wav)
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
        "finalized": True,
    }
    json_path.write_text(json.dumps(structured, ensure_ascii=False, indent=2), encoding="utf-8")
    md_path.write_text(render_markdown(structured), encoding="utf-8")
    # SEC14: transcripts carry meeting content, so keep them user-private (0600), like the logs.
    os.chmod(json_path, 0o600)
    os.chmod(md_path, 0o600)
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
