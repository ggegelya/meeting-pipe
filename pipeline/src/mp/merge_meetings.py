"""`mp merge-meetings <primary.wav> <fragment.wav>...` (FEAT9).

A dropped-and-rejoined call leaves two (or more) stems: two recordings, two
transcripts, two published pages. This concatenates their audio, merges their
transcripts with an explicit gap marker, re-summarizes the whole, and
republishes under the primary stem (the upsert path). The daemon owns the
batch-selection UI, the same-workflow / NDA guardrails, and the post-success
soft-delete of the fragments; this command owns the transform.

Ordering is positional: the first argument is the primary (its stem, page, and
sidecars survive), the rest are the later fragments in chronological order.

Verified-outcome (REC1): the concatenated audio is written to a temp file and
its duration checked against the sum of the inputs before the primary's audio is
replaced, so a failed concat never destroys the primary recording. A
``merged_from`` provenance key on the transcript makes a retry after a
publish-stage failure re-summarize + republish rather than concatenate the
audio a second time.
"""
from __future__ import annotations

import json
import logging
import os
import sys
from pathlib import Path

from . import entry, events, storage
from .config import Config
from .markdown import render_markdown
from .publish_router import (
    EXIT_PUBLISH_FAILED,
    all_sinks_failed,
    fanout as publish_fanout,
)
from .services import SummaryClient
from .summarize import summarize

log = logging.getLogger("mp.merge_meetings")

# The synthetic segment the merge inserts between two fragments. `render_markdown`
# renders a `kind == "gap"` segment as a divider note (never a speaker turn) and
# excludes it from the speaker counts, so the summarizer sees an explicit break
# instead of mistaking the marker for an attendee.
GAP_TEXT = "Recording gap: the call dropped and was rejoined here."

# The concat verified-outcome tolerance: the merged duration must land within
# this many seconds (or 1%, whichever is larger) of the sum of the inputs.
_DURATION_TOLERANCE_S = 0.5


class MergeError(RuntimeError):
    """A merge could not complete without risking the source recordings."""


def merge_transcripts(fragments: list[dict], durations: list[float]) -> dict:
    """Concatenate the fragments' transcripts onto one continuous timeline.

    Pure: no IO. `fragments` are the structured `<stem>.json` dicts, primary
    first; `durations` are each fragment's audio duration in seconds (so a
    segment's timestamps stay aligned with the concatenated audio, not the
    transcript's last-segment end, which trails off into silence). A gap marker
    is inserted at every fragment boundary.
    """
    if not fragments:
        raise MergeError("no fragments to merge")
    if len(fragments) != len(durations):
        raise MergeError("fragment / duration count mismatch")

    merged_segments: list[dict] = []
    offset = 0.0
    for i, (frag, dur) in enumerate(zip(fragments, durations)):
        if i > 0:
            merged_segments.append(
                {"start": offset, "end": offset, "speaker": None,
                 "text": GAP_TEXT, "kind": "gap"}
            )
        for seg in frag.get("segments") or []:
            shifted = dict(seg)
            if isinstance(shifted.get("start"), (int, float)):
                shifted["start"] = float(shifted["start"]) + offset
            if isinstance(shifted.get("end"), (int, float)):
                shifted["end"] = float(shifted["end"]) + offset
            merged_segments.append(shifted)
        offset += dur

    primary = fragments[0]
    diarization_failed = all(bool(f.get("diarization_failed")) for f in fragments)
    merged = dict(primary)
    merged["segments"] = merged_segments
    # Stay a valid daemon transcript so a later `mp run-all` would still accept it.
    merged["backend"] = "fluidaudio"
    merged["streaming"] = False
    merged["finalized"] = True
    merged["diarization_failed"] = diarization_failed
    merged["diarization"] = (not diarization_failed) and any(
        bool(f.get("diarization")) for f in fragments
    )
    return merged


def concat_audio(inputs: list[Path], out_path: Path) -> list[float]:
    """Concatenate the input recordings into `out_path`, streaming block by block
    so a multi-gigabyte merge never loads whole files into memory. Returns each
    input's duration in seconds. Raises `MergeError` if the inputs disagree on
    sample rate or channel count (the daemon writes one format, so a mismatch is
    a corrupt or foreign file, not something to silently resample)."""
    import soundfile as sf  # heavy; deferred per the lazy-import contract

    infos = [sf.info(str(p)) for p in inputs]
    samplerate = infos[0].samplerate
    channels = infos[0].channels
    for p, info in zip(inputs, infos):
        if info.samplerate != samplerate or info.channels != channels:
            raise MergeError(
                f"cannot merge {p.name}: {info.samplerate}Hz/{info.channels}ch "
                f"differs from the primary's {samplerate}Hz/{channels}ch"
            )
    durations = [info.frames / float(info.samplerate) for info in infos]

    # Pass the format explicitly: the caller writes to a `.merging.tmp` temp whose
    # extension soundfile cannot map to an audio format on its own.
    with sf.SoundFile(str(out_path), "w", samplerate=samplerate,
                      channels=channels, subtype=infos[0].subtype,
                      format=infos[0].format) as out:
        for p in inputs:
            with sf.SoundFile(str(p), "r") as src:
                while True:
                    block = src.read(65536, dtype="float32", always_2d=True)
                    if len(block) == 0:
                        break
                    out.write(block)
    return durations


def _verify_concat(out_path: Path, durations: list[float]) -> None:
    """The REC1 guard: the merged file must exist and its duration must match the
    sum of the inputs before the caller replaces the primary recording."""
    import soundfile as sf

    if not out_path.exists():
        raise MergeError("merged audio was not written")
    expected = sum(durations)
    info = sf.info(str(out_path))
    actual = info.frames / float(info.samplerate)
    tolerance = max(_DURATION_TOLERANCE_S, expected * 0.01)
    if abs(actual - expected) > tolerance:
        raise MergeError(
            f"merged audio duration {actual:.1f}s differs from expected "
            f"{expected:.1f}s by more than {tolerance:.1f}s; refusing to replace"
        )


def _read_transcript(audio: Path) -> dict:
    json_path = audio.with_suffix(".json")
    if not json_path.exists():
        raise MergeError(f"missing transcript for {audio.name} ({json_path.name})")
    try:
        data = json.loads(json_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise MergeError(f"unreadable transcript for {audio.name}: {exc}") from exc
    if not isinstance(data, dict):
        raise MergeError(f"transcript for {audio.name} is not an object")
    return data


def merge_meetings(
    primary_audio: Path,
    fragment_audios: list[Path],
    *,
    cfg: Config | None = None,
    client: SummaryClient | None = None,
) -> dict:
    """Merge `fragment_audios` into `primary_audio`, re-summarize, and republish
    under the primary stem. Returns the publish result; sets ``publish_failed``
    when every configured sink failed (the caller maps that to exit 3)."""
    if not fragment_audios:
        raise MergeError("merge needs a primary and at least one fragment")

    inputs = [primary_audio, *fragment_audios]
    for a in inputs:
        if not a.exists():
            raise MergeError(f"missing recording: {a}")

    # Arm the egress guard on the primary's workflow. The daemon guardrail
    # guarantees every fragment shares the primary's workflow (and so its NDA /
    # regulated posture), so arming on the primary clamps the whole merge.
    cfg = entry.prepare(cfg, primary_audio)

    json_path = primary_audio.with_suffix(".json")
    md_path = primary_audio.with_suffix(".md")
    frag_stems = [a.stem for a in fragment_audios]

    existing = _read_transcript(primary_audio)
    already = set(existing.get("merged_from") or [])
    if already.issuperset(frag_stems):
        # A prior run already concatenated these fragments onto the primary and
        # then failed at summarize/publish. Re-running the concat would fold the
        # already-merged audio in again, so skip straight to re-summarize +
        # republish over the artifacts on disk.
        log.info("merge: primary already carries %s; re-publishing only", frag_stems)
        events.emit("pipeline", "meetings_merge_resumed",
                    primary=primary_audio.stem, fragments=frag_stems)
    else:
        structured = [existing, *(_read_transcript(a) for a in fragment_audios)]
        tmp = primary_audio.with_name(primary_audio.name + ".merging.tmp")
        try:
            durations = concat_audio(inputs, tmp)
            _verify_concat(tmp, durations)
        except Exception:
            tmp.unlink(missing_ok=True)
            raise

        merged = merge_transcripts(structured, durations)
        merged["audio_path"] = str(primary_audio)
        merged["merged_from"] = sorted(already | set(frag_stems))

        # PIPE8 (FEAT9 follow-up): commit the transcript that carries `merged_from`
        # BEFORE swapping in the merged audio. `merged_from` is the retry guard's
        # only key (the `already.issuperset` check above), so recording it first
        # means a crash between the two commits leaves a transcript that already
        # reflects the merge: a retry then takes the "re-publish only" branch
        # rather than re-concatenating the fragments onto already-merged audio
        # (the old ordering's corrupting double-concat). The reverse residual
        # (transcript merged, audio not yet swapped) is a retry that re-publishes
        # over the correct transcript, with the fragment audio recoverable from
        # the kept originals. Atomic writes so neither file is ever half-written.
        storage.atomic_write_text(json_path, json.dumps(merged, ensure_ascii=False, indent=2))
        storage.atomic_write_text(md_path, render_markdown(merged))
        os.replace(str(tmp), str(primary_audio))
        events.emit("pipeline", "meetings_merged", primary=primary_audio.stem,
                    fragments=frag_stems, segments=len(merged["segments"]))
        log.info("merged %d fragment(s) into %s (%d segments)",
                 len(fragment_audios), primary_audio.stem, len(merged["segments"]))

    s = summarize(md_path, cfg=cfg, client=client)
    pub = publish_fanout(summary_json=s["json"], cfg=cfg, transcript_md=md_path)
    result = {"primary": str(primary_audio), "summary_json": str(s["json"]), **pub}
    if all_sinks_failed(pub):
        result["publish_failed"] = True
    return result


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: mp merge-meetings <primary.wav> <fragment.wav> [<fragment.wav>...]",
              file=sys.stderr)
        return 2
    primary = Path(argv[0]).expanduser().resolve()
    fragments = [Path(a).expanduser().resolve() for a in argv[1:]]

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    try:
        result = merge_meetings(primary, fragments)
    except MergeError as e:
        print(f"merge failed: {e}", file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001
        log.exception("merge-meetings failed: %s", e)
        return 1
    if result.get("publish_failed"):
        return EXIT_PUBLISH_FAILED
    print(f"merged into {primary.stem}: {result.get('page_url') or 'local only'}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
