"""`mp finalize <wav>` - re-run stage 1 of the pipeline on its own (ASR3).

`run-all` finalizes the daemon's raw FluidAudio sidecar (speaker labels,
voiceprint + roster matching, `<stem>.embeddings.json`, glossary normalization)
and then summarizes and publishes. The batch re-transcribe ratchet wants stage 1
alone: a meeting recorded months ago is re-transcribed by the daemon against the
current ASR + diarization stack, and this command re-derives everything the
finalize stage owns so the glossary entries and roster names learned since reach
that transcript too.

Deliberately stops there. It never summarizes and never publishes, so a batch
over an old library costs no engine call and touches no sink; the Library offers
"Re-summarize" as a separate, explicit follow-up. That also means the meeting
keeps its existing summary throughout, instead of losing it for the length of
the run.
"""
from __future__ import annotations

import json
import logging
import sys
from pathlib import Path

from . import entry, events
from .orchestrate import (
    apply_glossary,
    existing_daemon_transcript,
    finalize_streamed_transcript,
)
from .roster import RosterStore
from .voiceprint import VoiceprintStore

log = logging.getLogger("mp.finalize")


def finalize(
    wav: Path,
    cfg=None,
    *,
    voiceprint_store: VoiceprintStore | None = None,
    roster_store: RosterStore | None = None,
) -> dict[str, Path]:
    """Finalize `<stem>.json` in place and rewrite `<stem>.md`.

    Raises `RuntimeError` when the daemon sidecar is missing or unusable, which
    is the same contract `run_all` has: without a transcript there is nothing to
    finalize.
    """
    cfg = cfg or entry.prepare(anchor=wav, secrets=False)
    streamed = existing_daemon_transcript(wav)
    if streamed is None:
        events.emit("pipeline", "finalize_failed", wav=str(wav),
                    error="no daemon transcript", error_type="MissingSidecar")
        raise RuntimeError(
            f"No daemon transcript at {wav.with_suffix('.json')}. "
            "FluidAudio must produce the sidecar before finalize runs."
        )
    source = streamed.get("backend") or ("streamed" if streamed.get("streaming") else "daemon")
    events.emit("pipeline", "stage_started", stage="finalize", source=source, standalone=True)
    t = finalize_streamed_transcript(
        wav, streamed,
        user_label=cfg.summarization.user_label,
        voiceprint_store=voiceprint_store,
        roster_store=roster_store,
    )
    apply_glossary(wav, t)
    structured = json.loads(t["json"].read_text(encoding="utf-8"))
    segments = structured.get("segments") or []
    events.emit("pipeline", "stage_completed", stage="finalize", md=str(t["md"]),
                standalone=True, segments=len(segments))
    log.info("Finalized %s: %d segments", wav.stem, len(segments))
    return t


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: mp finalize <wav>", file=sys.stderr)
        return 2
    wav = Path(argv[0]).expanduser().resolve()
    if not wav.exists():
        print(f"No such file: {wav}", file=sys.stderr)
        return 1
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    try:
        t = finalize(wav)
    except Exception as e:  # noqa: BLE001 - surfaced as a non-zero exit for the daemon
        log.error("finalize failed: %s", e)
        print(f"finalize failed: {e}", file=sys.stderr)
        return 1
    print(f"finalized: {t['json']}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
