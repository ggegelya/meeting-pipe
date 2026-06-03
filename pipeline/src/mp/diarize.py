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

from pathlib import Path

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
