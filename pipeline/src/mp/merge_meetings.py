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

PIPE47: a fragment's labels, edits and sidecars are carried, not concatenated.
THEM-x and raw ``speaker_N`` ids are numbered per recording, so a fragment's are
renumbered to never collide with the primary's (`fragment_label_maps`); its
speaker names and text corrections are baked into the segments it contributes
(`transcript_corrections.overlaid_structured`), and its flagged moments and
voiceprints ride into the primary's ``.markers.json`` / ``.embeddings.json``.

PIPE48: ``merged_from`` is committed before the audio swap, so a retry that sees
it may be looking at a merge that never reached the swap. The resume branch
therefore decides from the audio's actual state (see `_resume_audio`), always
re-renders the markdown from the committed JSON, and refuses (`MergeError`, so
the daemon keeps the fragments) when the primary is still short.
"""
from __future__ import annotations

import json
import logging
import os
import re
import sys
from pathlib import Path

from . import entry, events, markers, speaker_overlay, storage, transcript_corrections
from .config import Config
from .markdown import render_markdown
from .publish_router import (
    EXIT_PUBLISH_FAILED,
    fanout as publish_fanout,
    publish_failed,
)
from .services import SummaryClient
from .summarize import refuse_unreadable_overlays, summarize

log = logging.getLogger("mp.merge_meetings")

# The synthetic segment the merge inserts between two fragments. `render_markdown`
# renders a `kind == "gap"` segment as a divider note (never a speaker turn) and
# excludes it from the speaker counts, so the summarizer sees an explicit break
# instead of mistaking the marker for an attendee.
GAP_TEXT = "Recording gap: the call dropped and was rejoined here."

# The concat verified-outcome tolerance: the merged duration must land within
# this many seconds (or 1%, whichever is larger) of the sum of the inputs.
_DURATION_TOLERANCE_S = 0.5

# PIPE48: free space required beyond the sum of the input sizes before the merge
# writes its temp (a copy of all inputs combined) next to the primary.
_FREE_SPACE_MARGIN_BYTES = 64 * 1024 * 1024


class MergeError(RuntimeError):
    """A merge could not complete without risking the source recordings."""


# PIPE47: the labels that are numbered per recording (the diarizer's raw `speaker_N`
# and the finalizer's `THEM-x` cluster), as opposed to the owner's label, roster and
# Library names, `speaker_user` / `speaker_other` and the `speaker_unknown` catch-all,
# which mean the same thing in every recording.
_THEM_RE = re.compile(r"^THEM-([A-Z]+)$")
_RAW_RE = re.compile(r"^speaker_\d+$")


def _them_index(label: str) -> int | None:
    """Inverse of `diarize.them_label`: THEM-A -> 0, THEM-AA -> 26; None otherwise."""
    m = _THEM_RE.match(label)
    if m is None:
        return None
    n = 0
    for ch in m.group(1):
        n = n * 26 + (ord(ch) - ord("A") + 1)
    return n - 1


def _speakers_in_order(segments: list[dict]) -> list[str]:
    seen: dict[str, None] = {}
    for seg in segments:
        spk = seg.get("speaker") if isinstance(seg, dict) else None
        if isinstance(spk, str) and spk:
            seen.setdefault(spk)
    return list(seen)


def fragment_label_maps(fragments: list[dict]) -> list[dict[str, str]]:
    """PIPE47: per fragment, the map from its own per-recording labels to labels
    that cannot collide with any earlier recording's. Pure. The primary (index 0)
    keeps every label. A later fragment's THEM-x labels continue after the highest
    THEM index used so far (`diarize.them_label`, in order of first speech), and a
    raw `speaker_N` gets a per-fragment suffix. Everything else maps to itself, so
    the owner and named people stay one label across recordings."""
    from .diarize import them_label

    next_them = 0
    maps: list[dict[str, str]] = []
    for i, frag in enumerate(fragments):
        mapping: dict[str, str] = {}
        speakers = _speakers_in_order(frag.get("segments") or [])
        if i == 0:
            for spk in speakers:
                idx = _them_index(spk)
                if idx is not None:
                    next_them = max(next_them, idx + 1)
        else:
            for spk in speakers:
                if _them_index(spk) is not None:
                    mapping[spk] = them_label(next_them)
                    next_them += 1
                elif _RAW_RE.match(spk):
                    mapping[spk] = f"{spk}-f{i}"
        maps.append(mapping)
    return maps


def merge_transcripts(fragments: list[dict], durations: list[float]) -> dict:
    """Concatenate the fragments' transcripts onto one continuous timeline.

    Pure: no IO. `fragments` are the structured `<stem>.json` dicts, primary
    first; `durations` are each fragment's audio duration in seconds (so a
    segment's timestamps stay aligned with the concatenated audio, not the
    transcript's last-segment end, which trails off into silence). A gap marker
    is inserted at every fragment boundary. Later fragments' per-recording speaker
    labels are renumbered so they never collide with the primary's (PIPE47).
    """
    if not fragments:
        raise MergeError("no fragments to merge")
    if len(fragments) != len(durations):
        raise MergeError("fragment / duration count mismatch")

    label_maps = fragment_label_maps(fragments)
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
            spk = shifted.get("speaker")
            if isinstance(spk, str) and spk in label_maps[i]:
                shifted["speaker"] = label_maps[i][spk]
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
    # ASR10: `dict(primary)` carried the first fragment's `audio_seconds`, while the segments run across
    # every fragment. The merged audio is the fragments laid end to end, and `last_speech_sec` (also the
    # mark the Library trusts `audio_seconds` by) is where the last merged word ends.
    merged["audio_seconds"] = float(sum(durations))
    ends: list[float] = [
        float(seg["end"]) for seg in merged_segments if isinstance(seg.get("end"), (int, float))
    ]
    merged["last_speech_sec"] = max(ends, default=0.0)
    # DIAR8: `dict(primary)` carried the first fragment's fallback. It describes the merged
    # transcript only when every fragment failed the same way.
    fallbacks = {f.get("speaker_fallback") for f in fragments}
    if not (diarization_failed and len(fallbacks) == 1):
        merged.pop("speaker_fallback", None)
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


def _check_free_space(inputs: list[Path], primary_audio: Path) -> None:
    """PIPE48: the concat writes a temp the size of all inputs combined, so refuse
    before writing anything when the primary's volume cannot hold it. An
    unreadable volume (`free_bytes` is None) is not a reason to refuse."""
    needed = sum(p.stat().st_size for p in inputs) + _FREE_SPACE_MARGIN_BYTES
    free = storage.free_bytes(primary_audio.parent)
    if free is not None and free < needed:
        raise MergeError(
            f"not enough free disk space to merge: need {needed / 1e6:.0f} MB "
            f"(the inputs plus a margin), {free / 1e6:.0f} MB free; nothing was written"
        )


def _audio_seconds(path: Path) -> float:
    import soundfile as sf

    info = sf.info(str(path))
    return info.frames / float(info.samplerate)


def _expected_total(merged: dict, last_fragment_seconds: float) -> float | None:
    """The merged audio's length as the committed transcript records it: the last
    gap marker sits at the end of everything before the last fragment, so that
    offset plus the last fragment's duration is the whole. None without a gap."""
    gaps = [
        float(s["start"]) for s in merged.get("segments") or []
        if isinstance(s, dict) and s.get("kind") == "gap"
        and isinstance(s.get("start"), (int, float))
    ]
    return max(gaps) + last_fragment_seconds if gaps else None


def _resume_audio(primary_audio: Path, fragment_audios: list[Path], merged: dict) -> bool:
    """PIPE48: finish or vouch for the audio swap of a merge whose transcript is
    already committed. Returns True when this call performed the swap.

    - temp present: verify it and swap it in;
    - temp absent, primary already full length: nothing to do;
    - temp absent, primary short: raise, so the fragments are kept.
    The primary is never replaced by anything unverified."""
    tmp = primary_audio.with_name(primary_audio.name + ".merging.tmp")
    last_dur = _audio_seconds(fragment_audios[-1])
    expected = _expected_total(merged, last_dur)

    if tmp.exists():
        if expected is None:
            raise MergeError(
                f"{tmp.name} is left over but the transcript records no recording "
                "gap to verify it against; refusing to swap it in"
            )
        try:
            _verify_concat(tmp, [expected])
        except Exception:
            tmp.unlink(missing_ok=True)
            raise
        os.replace(str(tmp), str(primary_audio))
        return True

    actual = _audio_seconds(primary_audio)
    fragments_total = sum(_audio_seconds(a) for a in fragment_audios)
    floor = max(expected or 0.0, fragments_total)
    # The slack must stay under what a part-one primary is missing (the fragments),
    # or a short fragment on a long call reads as "full length".
    slack = min(max(_DURATION_TOLERANCE_S, floor * 0.01), fragments_total / 2)
    if actual + slack < floor:
        raise MergeError(
            f"{primary_audio.name} is {actual:.1f}s but the merged transcript covers at "
            f"least {floor:.1f}s and no merged audio is left to swap in: the earlier "
            "merge failed before its audio swap. The fragment recordings were not touched."
        )
    return False


def _read_transcript(audio: Path) -> dict:
    json_path = audio.with_suffix(".json")
    read = storage.load_json_object(json_path)
    if read.state == "missing":
        raise MergeError(f"missing transcript for {audio.name} ({json_path.name})")
    if read.not_object:
        raise MergeError(f"transcript for {audio.name} is not an object")
    if read.data is None:
        raise MergeError(f"unreadable transcript for {audio.name}: {read.reason}")
    return read.data


def _read_fragment(audio: Path) -> dict:
    """A later fragment's transcript as the Library shows it (PIPE47): its speaker
    names and text corrections baked into the segments, because the fragment's
    sidecars go to the Trash with it on success. An unreadable overlay refuses,
    as `summarize` does (STOR9), rather than quietly dropping the owner's edits."""
    _read_transcript(audio)  # the missing / unreadable errors, named for this recording
    md = audio.with_suffix(".md")
    refuse_unreadable_overlays(md)
    composed = transcript_corrections.overlaid_structured(md)
    if composed is None:
        raise MergeError(f"unreadable transcript for {audio.name}")
    return composed[0]


def _read_sidecar(path: Path) -> dict | None:
    """A sidecar to carry: None when missing, the object when readable, and a
    MergeError when present but unreadable (the writer refuses rather than read
    unreadable as empty and overwrite it, STOR9)."""
    read = storage.load_json_object(path)
    if read.state == "missing":
        return None
    if read.data is None:
        raise MergeError(f"{path.name} is present but cannot be read ({read.reason}); "
                         "nothing was merged")
    return read.data


def _marker_entries(obj: dict | None) -> list[dict]:
    raw = obj.get("markers") if obj else None
    return [m for m in raw if isinstance(m, dict)] if isinstance(raw, list) else []


def _carry_sidecars(
    primary_audio: Path,
    fragment_audios: list[Path],
    fragments: list[dict],
    durations: list[float],
) -> None:
    """PIPE47: fold each later fragment's flagged moments and voiceprints into the
    primary's `.markers.json` / `.embeddings.json`. `fragments` is primary-first,
    like `durations`. Every read happens before any write (an unreadable sidecar
    refuses with nothing touched), and both writes are idempotent (a marker already
    present at the same offset, an embedding label already present, is not added
    again), because a crash before the transcript commit re-runs the whole merge.
    The primary's own entries are never moved: its segment indices do not change,
    so its overlays stay valid."""
    primary_md = primary_audio.with_suffix(".md")
    label_maps = fragment_label_maps(fragments)
    marker_file = _read_sidecar(markers.markers_path(primary_md))
    emb_file = _read_sidecar(primary_audio.with_suffix(".embeddings.json"))

    marker_entries = _marker_entries(marker_file)
    seen_offsets = {m.get("t_seconds") for m in marker_entries}
    embeddings = dict(emb_file.get("embeddings") or {}) if emb_file else {}
    if not isinstance(embeddings, dict):
        embeddings = {}
    added_markers = added_embeddings = False

    offset = durations[0]
    for i, audio in enumerate(fragment_audios, start=1):
        frag_md = audio.with_suffix(".md")
        frag_markers = _read_sidecar(markers.markers_path(frag_md))
        frag_emb = _read_sidecar(audio.with_suffix(".embeddings.json"))
        for m in _marker_entries(frag_markers):
            t = m.get("t_seconds")
            if isinstance(t, bool) or not isinstance(t, (int, float)):
                continue
            shifted = {**m, "t_seconds": float(t) + offset}
            if shifted["t_seconds"] not in seen_offsets:
                seen_offsets.add(shifted["t_seconds"])
                marker_entries.append(shifted)
                added_markers = True
        # A voiceprint is keyed by the label the recording showed at finalize; the
        # Library's rename of that label (the overlay) and then the renumbering
        # decide what the merged transcript calls the voice.
        names = speaker_overlay.read_overlay(frag_md).get("labels") or {}
        present = {label_maps[i].get(s, s) for s in _speakers_in_order(fragments[i].get("segments") or [])}
        frag_vectors = frag_emb.get("embeddings") if frag_emb else None
        for key, vec in (frag_vectors.items() if isinstance(frag_vectors, dict) else ()):
            if not isinstance(key, str) or not isinstance(vec, list) or not vec:
                continue
            label = names.get(key, key)
            label = label_maps[i].get(label, label)
            if label in present and label not in embeddings:
                embeddings[label] = vec
                added_embeddings = True
        offset += durations[i]

    if added_markers:
        storage.atomic_write_text(
            markers.markers_path(primary_md),
            json.dumps({"schema_version": 1, "markers": marker_entries}),
        )
    if added_embeddings:
        payload: dict = dict(emb_file) if emb_file else {"schema_version": 2}
        payload["embeddings"] = embeddings
        # Biometric: `atomic_write_text` creates it 0600, as the finalizer's write does.
        storage.atomic_write_text(primary_audio.with_suffix(".embeddings.json"),
                                  json.dumps(payload))


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
        # A prior run committed the merged transcript (`merged_from`) and then
        # failed, possibly before the audio swap. Re-running the concat would
        # fold already-merged audio in again, so decide from the audio's state
        # (PIPE48), re-render the markdown from the committed JSON, and publish.
        log.info("merge: primary already carries %s; resuming", frag_stems)
        swapped = _resume_audio(primary_audio, fragment_audios, existing)
        storage.atomic_write_text(md_path, render_markdown(existing))
        events.emit("pipeline", "meetings_merge_resumed",
                    primary=primary_audio.stem, fragments=frag_stems, swapped=swapped)
        if swapped:
            events.emit("pipeline", "meetings_merged", primary=primary_audio.stem,
                        fragments=frag_stems, segments=len(existing.get("segments") or []),
                        resumed=True)
    else:
        structured = [existing, *(_read_fragment(a) for a in fragment_audios)]
        _check_free_space(inputs, primary_audio)
        tmp = primary_audio.with_name(primary_audio.name + ".merging.tmp")
        try:
            durations = concat_audio(inputs, tmp)
            _verify_concat(tmp, durations)
            merged = merge_transcripts(structured, durations)
            merged["audio_path"] = str(primary_audio)
            merged["merged_from"] = sorted(already | set(frag_stems))
            # PIPE47: the carried sidecars land BEFORE the transcript commit, so a
            # resume (PIPE48) never meets a merge with its markers half carried.
            _carry_sidecars(primary_audio, fragment_audios, structured, durations)

            # PIPE8 (FEAT9 follow-up): commit the transcript that carries
            # `merged_from` BEFORE swapping in the merged audio, so a crash between
            # the two leaves a transcript a retry recognises instead of
            # re-concatenating onto already-merged audio. PIPE48: that retry now
            # finishes the swap from the verified temp (`_resume_audio`) rather
            # than trusting `merged_from` alone. Atomic writes, so neither file is
            # ever half-written.
            storage.atomic_write_text(json_path, json.dumps(merged, ensure_ascii=False, indent=2))
        except Exception:
            # Nothing is committed yet: the temp is pure litter.
            tmp.unlink(missing_ok=True)
            raise
        # From here `merged_from` is recorded, and a failure KEEPS the verified temp:
        # the resume branch swaps it in, and it is the only copy of the merged audio.
        storage.atomic_write_text(md_path, render_markdown(merged))
        os.replace(str(tmp), str(primary_audio))
        events.emit("pipeline", "meetings_merged", primary=primary_audio.stem,
                    fragments=frag_stems, segments=len(merged["segments"]))
        log.info("merged %d fragment(s) into %s (%d segments)",
                 len(fragment_audios), primary_audio.stem, len(merged["segments"]))

    s = summarize(md_path, cfg=cfg, client=client)
    pub = publish_fanout(summary_json=s["json"], cfg=cfg, transcript_md=md_path)
    result = {"primary": str(primary_audio), "summary_json": str(s["json"]), **pub}
    if publish_failed(pub):
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
        from .failure_details import fail_command
        fail_command("merge-meetings", e, operation="processing")
        print(f"merge failed: {e}", file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001
        from .failure_details import fail_command
        fail_command("merge-meetings", e, operation="processing")
        return 1
    if result.get("publish_failed"):
        return EXIT_PUBLISH_FAILED
    print(f"merged into {primary.stem}: {result.get('page_url') or 'local only'}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
