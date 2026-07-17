"""Channel-aware speaker labelling for stereo recordings.

The daemon writes stereo WAVs (mic-L, system-R), so the entire Python
fallback path needs is a per-segment RMS comparison: whichever channel
was loudest during a transcript segment's window owns the segment.
Diarization on mono recordings is no longer attempted from Python;
FluidAudio (Swift-native) is the source of truth for embedding-based
diarization. The fallback gracefully degrades to USER_SPEAKER for the
mono case rather than re-introducing a per-recording embedding cluster.
"""
from __future__ import annotations

import math
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    # `roster` imports `cosine_similarity` from this module, so importing it at
    # runtime would close the cycle. The annotation only needs the name.
    from .roster import RosterStore

# Speaker labels for the stereo channel-aware path. Stable strings so
# downstream Markdown renders consistently across recordings.
USER_SPEAKER = "speaker_user"
OTHER_SPEAKER = "speaker_other"


def is_stereo_recording(wav: Path) -> bool:
    """Cheap channel-count probe (reads only the WAV header)."""
    import soundfile as sf  # type: ignore
    try:
        return sf.info(str(wav)).channels == 2
    except Exception:  # noqa: BLE001
        return False


def assign_speakers_by_channel(
    transcript_segments: list[dict],
    wav: Path,
    *,
    dominance_ratio: float = 1.5,
    min_other_rms: float = 50.0,
) -> list[dict]:
    """Stamp speaker labels onto each transcript segment by comparing
    per-channel RMS over the segment's time window.

    Heuristic per segment:
      - L_rms > dominance_ratio * R_rms  → USER_SPEAKER
      - R_rms > dominance_ratio * L_rms  → OTHER_SPEAKER
      - both close                        → whichever is louder (overlap)

    `min_other_rms` guards the degenerate "system audio is silent the
    whole recording" case: when the right channel is below this floor,
    we collapse all segments to USER_SPEAKER rather than producing a
    silly "OTHER said one quiet word" attribution from background noise.
    PCM s16 RMS of pure silence is ~0; threshold 50 is well above noise
    floor and well below normal speech.

    The WAV passed here is the redacted artifact: under capture-first the
    daemon zero-fills the muted mic spans before the pipeline runs (ADR
    0016 / TECH-MIC5), and the kept full recording lives outside the
    pipeline's reach. So these int16 thresholds keep their gated-audio
    meaning and a muted speaker is never relabeled USER_SPEAKER from
    full-amplitude audio.
    """
    import numpy as np
    import soundfile as sf  # type: ignore

    # Stream the WAV instead of reading the whole clip plus two float32 copies
    # (~2 GB peak on a 3-hour stereo file, in the exact degraded fallback we
    # least want to also OOM). Reads stay int16 with a local float32 cast on
    # bounded slices, so every RMS value, and therefore `min_other_rms` and
    # `dominance_ratio`, keeps its int16-magnitude meaning. (TECH-PERF1)
    with sf.SoundFile(str(wav)) as f:
        if f.channels != 2:
            # Caller should have checked is_stereo_recording first; defend
            # against future config drift by collapsing to a single label.
            return [{**s, "speaker": USER_SPEAKER} for s in transcript_segments]
        sr = f.samplerate
        total_frames = f.frames

        # Decide once whether the right channel ever had real audio, scanning
        # it block-wise so we never hold more than one block in RAM. If not,
        # all segments go to USER_SPEAKER, much more useful than spurious OTHER
        # attributions on silence/noise. (float64 accumulation is a touch more
        # accurate than the old whole-channel float32 mean; the silence floor
        # has orders-of-magnitude margin, so it cannot flip the threshold.)
        sumsq_r = 0.0
        count_r = 0
        for block in f.blocks(blocksize=1 << 20, dtype="int16", always_2d=True):
            r = block[:, 1].astype(np.float64)
            sumsq_r += float(r @ r)
            count_r += r.shape[0]
        overall_r_rms = (sumsq_r / count_r) ** 0.5 if count_r else 0.0
        other_channel_present = overall_r_rms >= min_other_rms

        out: list[dict] = []
        for seg in transcript_segments:
            seg = dict(seg)
            if not other_channel_present:
                seg["speaker"] = USER_SPEAKER
                out.append(seg)
                continue
            start_i = max(0, int(float(seg.get("start", 0)) * sr))
            end_i = min(total_frames, int(float(seg.get("end", 0)) * sr))
            if end_i <= start_i:
                seg["speaker"] = USER_SPEAKER
                out.append(seg)
                continue
            # Read only this segment's window. int16 + a local float32 cast
            # leaves the per-segment RMS identical to the old whole-file slice.
            f.seek(start_i)
            chunk = f.read(frames=end_i - start_i, dtype="int16", always_2d=True)
            l_chunk = chunk[:, 0].astype(np.float32)
            r_chunk = chunk[:, 1].astype(np.float32)
            l_rms = float(np.sqrt(np.mean(l_chunk * l_chunk)))
            r_rms = float(np.sqrt(np.mean(r_chunk * r_chunk)))
            if l_rms > dominance_ratio * r_rms:
                seg["speaker"] = USER_SPEAKER
            elif r_rms > dominance_ratio * l_rms:
                seg["speaker"] = OTHER_SPEAKER
            else:
                seg["speaker"] = USER_SPEAKER if l_rms >= r_rms else OTHER_SPEAKER
            out.append(seg)
    return out


def _resolve_me_id(
    segments: list[dict],
    *,
    channel_me: str = USER_SPEAKER,
    mic_me: str | None = None,
    voiceprint_me: str | None = None,
) -> str | None:
    """Pick which diarization speaker id is the user, by precedence: the
    channel-assigned mic speaker, else the mic-channel identification, else the
    voiceprint match.

    None when no signal places the user among these speakers, which is the
    correct answer when the user sat silent. Naming "me" requires positive
    evidence: every tier here is a measurement of the user's own voice, so a
    meeting the user only listened to leaves the speakers unnamed rather than
    lending the owner's name to whoever talked most.
    """
    present = {s.get("speaker") for s in segments if s.get("speaker")}
    if channel_me in present:
        return channel_me
    if mic_me and mic_me in present:
        return mic_me
    if voiceprint_me and voiceprint_me in present:
        return voiceprint_me
    return None


def label_me_speaker(
    segments: list[dict],
    user_label: str,
    *,
    channel_me: str = USER_SPEAKER,
    mic_me: str | None = None,
    voiceprint_me: str | None = None,
) -> list[dict]:
    """Stamp the user's enrolled display name on their own speaker, so
    "me vs them" reads as a real name.

    Picks the "me" speaker by precedence:
      - the channel-assigned mic speaker (`speaker_user`) when present, the
        reliable stereo path since the mic channel is always the user; else
      - `mic_me`, the diarized speaker whose speech is predominantly on the mic
        channel (`identify_user_speaker`), physical evidence that the voice is
        the user's; else
      - `voiceprint_me`, the speaker matched to the persisted self-voiceprint
        (FEAT3-VOICEPRINT), which still resolves on mono and when a merged
        cluster leaves no clean mic winner.

    Returns a new segment list with the chosen speaker relabeled to
    `user_label`. No-op (segments copied unchanged) when `user_label` is empty
    or no signal identifies the user, the latter being what a meeting the user
    stayed silent through looks like. The name is enrolled once in config
    (`summarization.user_label`) and reused on every meeting.
    """
    label = user_label.strip()
    if not label or not segments:
        return [dict(s) for s in segments]

    me = _resolve_me_id(
        segments, channel_me=channel_me, mic_me=mic_me, voiceprint_me=voiceprint_me
    )
    if me is None or me == label:
        return [dict(s) for s in segments]
    return [
        {**s, "speaker": label} if s.get("speaker") == me else dict(s)
        for s in segments
    ]


def cosine_similarity(a: list[float], b: list[float]) -> float:
    """Cosine similarity of two equal-length vectors; 0.0 on length mismatch,
    empty input, or a zero vector."""
    if not a or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na < 1e-9 or nb < 1e-9:
        return 0.0
    return dot / (na * nb)


# Two-gate accept rule for the self-voiceprint, mirroring `roster.match`: the
# top similarity must clear MATCH_MIN and the runner-up must trail it by
# MATCH_MARGIN. Conservative on both counts, since an unresolved "me" costs one
# in-app naming while a wrong one puts the owner's name on a stranger. The
# margin is what stops two near-identical scores (0.506 vs 0.495 was seen in the
# real library) from deciding the owner's identity on a coin flip.
VOICEPRINT_MATCH_MIN = 0.5
VOICEPRINT_MATCH_MARGIN = 0.07


def match_voiceprint(
    speaker_embeddings: dict[str, list[float]],
    voiceprint: list[float] | None,
    *,
    min_similarity: float = VOICEPRINT_MATCH_MIN,
    margin: float = VOICEPRINT_MATCH_MARGIN,
) -> str | None:
    """Return the diarized speaker id whose embedding matches the persisted
    `voiceprint` under the two-gate rule, else None. The top similarity must
    clear `min_similarity`, and the gap to the runner-up speaker must clear
    `margin`; a lone candidate only faces the first gate. Ties break to the
    lowest speaker id for determinism."""
    if not voiceprint or not speaker_embeddings:
        return None
    scored = sorted(
        (
            (cosine_similarity(emb, voiceprint), spk)
            for spk, emb in speaker_embeddings.items()
        ),
        key=lambda t: (-t[0], t[1]),
    )
    top_sim, top_id = scored[0]
    if top_sim < min_similarity:
        return None
    runner_up = scored[1][0] if len(scored) > 1 else -1.0
    if top_sim - runner_up < margin:
        return None
    return top_id


def identify_user_speaker(
    segments: list[dict],
    wav: Path,
    *,
    min_fraction: float = 0.6,
) -> str | None:
    """On a stereo recording, return which diarized speaker is the mic-channel
    user (the voiceprint-enrollment target), or None when mono / ambiguous.

    Runs the channel-aware assignment on a copy and cross-tabulates each
    original diarized speaker against the mic/other verdict: the speaker whose
    speech time is at least `min_fraction` on the mic channel is the user.
    Deliberately conservative, since a wrong enrollment poisons the voiceprint.
    """
    if not segments or not is_stereo_recording(wav):
        return None
    channel = assign_speakers_by_channel([dict(s) for s in segments], wav)
    if len(channel) != len(segments):
        return None
    mic_time: dict[str, float] = {}
    total_time: dict[str, float] = {}
    saw_other = False
    for orig, chan in zip(segments, channel):
        spk = orig.get("speaker")
        if not spk:
            continue
        dur = max(0.0, float(orig.get("end", 0)) - float(orig.get("start", 0)))
        total_time[spk] = total_time.get(spk, 0.0) + dur
        if chan.get("speaker") == USER_SPEAKER:
            mic_time[spk] = mic_time.get(spk, 0.0) + dur
        else:
            saw_other = True
    # assign_speakers_by_channel collapses every segment to USER_SPEAKER when the
    # system channel is silent (effectively mono-from-mic); we can't tell the
    # user's voice apart there, so decline to enroll.
    if not total_time or not saw_other:
        return None

    def mic_fraction(spk: str) -> float:
        return mic_time.get(spk, 0.0) / total_time[spk] if total_time[spk] > 0 else 0.0

    best = max(total_time, key=mic_fraction)
    return best if mic_fraction(best) >= min_fraction else None


def them_label(idx: int) -> str:
    """Stable unknown-voice cluster label: 0 -> THEM-A, 25 -> THEM-Z, 26 -> THEM-AA."""
    letters = ""
    n = idx
    while True:
        letters = chr(ord("A") + n % 26) + letters
        n = n // 26 - 1
        if n < 0:
            break
    return f"THEM-{letters}"


def resolve_speaker_labels(
    segments: list[dict],
    speaker_embeddings: dict[str, list[float]] | None,
    roster: RosterStore,
    *,
    user_label: str = "",
    channel_me: str = USER_SPEAKER,
    mic_me: str | None = None,
    voiceprint_me: str | None = None,
) -> dict[str, str]:
    """Map each diarization speaker id present in `segments` to its final label:
    the user's name ("me"), a matched roster name (`roster.match`), or a stable
    THEM-A/B cluster for an unknown voice. A speaker with no embedding keeps its
    raw id (it cannot be roster-matched, e.g. channel-fallback labels). The "me"
    speaker is never roster-matched. `roster` may be None (no roster).

    When no signal identifies the user (`_resolve_me_id` returns None, the
    silent-owner case), no speaker is given `user_label`; every voice falls
    through to a roster match or a THEM-x cluster, which the user can name in
    the app."""
    mapping: dict[str, str] = {}
    me = _resolve_me_id(
        segments, channel_me=channel_me, mic_me=mic_me, voiceprint_me=voiceprint_me
    )
    label = user_label.strip()
    if me is not None and label:
        mapping[me] = label
    order: list[str] = []
    seen: set[str] = set()
    for s in segments:
        spk = s.get("speaker")
        if spk and spk != me and spk not in seen:
            seen.add(spk)
            order.append(spk)
    unknown_idx = 0
    for spk in order:
        emb = speaker_embeddings.get(spk) if speaker_embeddings else None
        name = roster.match(emb) if (roster is not None and emb) else None
        if name and name != label:
            mapping[spk] = name
        elif emb is not None:
            mapping[spk] = them_label(unknown_idx)
            unknown_idx += 1
    return mapping


def apply_speaker_labels(segments: list[dict], mapping: dict[str, str]) -> list[dict]:
    """Return a new segment list with each speaker id replaced per `mapping`;
    ids absent from the mapping (and a segment with no speaker at all) are left
    unchanged."""
    out: list[dict] = []
    for s in segments:
        speaker = s.get("speaker")
        resolved = mapping.get(speaker, speaker) if isinstance(speaker, str) else speaker
        out.append({**s, "speaker": resolved})
    return out
