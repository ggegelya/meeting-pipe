"""Offline speaker diarization on sherpa-onnx (CoreML on Apple Silicon).

Replaces the previous pyannote.audio-on-CPU pipeline that ran at ~1.5×
realtime and hung on multi-hour recordings. sherpa-onnx is ONNX
Runtime + a small C++ core; the segmentation + embedding models are
ONNX-converted pyannote-segmentation-3.0 and 3D-Speaker, both
language-agnostic (speaker identity doesn't depend on what's being said).

Returns a list of `(start, end, speaker_id)` tuples, equivalent to the
`Annotation.itertracks(yield_label=True)` shape the rest of the
pipeline used to consume from pyannote.

Models are downloaded once on first run into
`~/.cache/meeting-pipe/sherpa-models/` (~40 MB total). The downloads
are HTTP-only — no Hugging Face TOS, no auth.
"""
from __future__ import annotations

import logging
import os
import shutil
import tarfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import numpy as np

log = logging.getLogger("mp.diarize")


# --- Models -------------------------------------------------------------------
#
# sherpa-onnx ships pre-converted ONNX builds of pyannote-segmentation-3.0
# (segmentation) and 3D-Speaker (embedding) on the k2-fsa GitHub releases.
# Both are small enough to ship lazily on first use rather than baking
# into install.sh.

SEGMENTATION_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/"
    "sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
)
SEGMENTATION_MODEL_REL = (
    "sherpa-onnx-pyannote-segmentation-3-0/model.onnx"
)

# NeMo TitaNet-small: 25 MB, English-trained but speaker ID transfers well
# across languages (phoneme-invariant features). The 3D-Speaker zh-cn model
# we tried first over-segmented for English meetings (22 spurious clusters
# on a 17-min two-person call). TitaNet at threshold 0.7 reliably resolves
# 2-4 speakers on the same audio.
EMBEDDING_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/"
    "nemo_en_titanet_small.onnx"
)
EMBEDDING_FILENAME = "nemo_en_titanet_small.onnx"

# silero-vad for streaming speech-activity detection. Tiny (~2 MB),
# real-time on a single CPU thread, and language-agnostic.
SILERO_VAD_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
)
SILERO_VAD_FILENAME = "silero_vad.onnx"


def models_dir() -> Path:
    """Where downloaded sherpa-onnx models live."""
    return Path(os.path.expanduser("~/.cache/meeting-pipe/sherpa-models"))


@dataclass(frozen=True)
class DiarizationSegment:
    """One contiguous speaker turn."""
    start: float
    end: float
    speaker: str


# --- Public API ---------------------------------------------------------------


def diarize(
    wav: Path,
    *,
    min_speakers: int = 1,
    max_speakers: int = 8,
    num_threads: int = 2,
    provider: str = "coreml",
    cluster_threshold: float = 0.7,
) -> list[DiarizationSegment]:
    """Run offline speaker diarization on `wav`.

    Returns a list of `DiarizationSegment`s, sorted by start time.
    Speaker labels are stable strings like `"speaker_0"`, `"speaker_1"`.

    `provider="coreml"` enables Apple's CoreML execution provider on
    Apple Silicon — falls back automatically to "cpu" if the underlying
    sherpa-onnx build wasn't compiled with CoreML support.

    `cluster_threshold` is the cosine-distance bound below which two
    embedding clusters get merged. Higher values merge more aggressively
    (fewer speakers); lower values keep more clusters separate. 0.7 is
    a good default for English/Russian meeting audio with the TitaNet
    embedding model — 0.5 over-segmented (one speaker became 10+ clusters).
    """
    import sherpa_onnx  # type: ignore
    import soundfile as sf  # type: ignore

    seg_path = _ensure_segmentation_model()
    emb_path = _ensure_embedding_model()

    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                model=str(seg_path)
            ),
        ),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=str(emb_path),
            num_threads=num_threads,
            provider=provider,
        ),
        clustering=sherpa_onnx.FastClusteringConfig(
            num_clusters=min_speakers if min_speakers == max_speakers else -1,
            threshold=cluster_threshold,
        ),
    )
    if not config.validate():
        raise RuntimeError("sherpa-onnx diarization config rejected by validate()")

    pipeline = sherpa_onnx.OfflineSpeakerDiarization(config)

    audio, sr = sf.read(str(wav), dtype="float32", always_2d=False)
    if audio.ndim > 1:
        # Mix down to mono.
        audio = audio.mean(axis=1)
    target_sr = pipeline.sample_rate
    if sr != target_sr:
        audio = _resample(audio, sr, target_sr)

    log.info("Diarizing %s (%.1fs at %d Hz)", wav.name, len(audio) / target_sr, target_sr)
    result = pipeline.process(audio).sort_by_start_time()

    segments: list[DiarizationSegment] = []
    for s in result:
        segments.append(
            DiarizationSegment(
                start=float(s.start),
                end=float(s.end),
                speaker=f"speaker_{s.speaker}",
            )
        )
    return _renumber_speakers(segments)


def _renumber_speakers(segments: list[DiarizationSegment]) -> list[DiarizationSegment]:
    """sherpa-onnx assigns speaker IDs from internal cluster numbers, which
    can be non-contiguous (e.g. `speaker_0, speaker_4, speaker_22`) when
    the clusterer merges some clusters and leaves others. Renumber in
    order of first appearance so downstream surfaces (Markdown, Notion)
    see consecutive labels: `speaker_0, speaker_1, speaker_2, ...`."""
    mapping: dict[str, str] = {}
    out: list[DiarizationSegment] = []
    for s in segments:
        if s.speaker not in mapping:
            mapping[s.speaker] = f"speaker_{len(mapping)}"
        out.append(DiarizationSegment(start=s.start, end=s.end, speaker=mapping[s.speaker]))
    return out


# --- Streaming (online) diarization ------------------------------------------
#
# Pairs with `mp.transcribe_stream`. Each 30 s chunk goes through:
#   1. silero-vad → speech intervals
#   2. SpeakerEmbeddingExtractor on each interval → 192/256-dim embedding
#   3. Online clustering: nearest-centroid match within `threshold`
#      (cosine distance). New cluster created when no match.
#
# Cross-chunk continuity is preserved by keeping the centroid table
# across calls — the same speaker keeps the same ID throughout the
# meeting. Quality is competitive with offline diarization for typical
# meeting audio; it can drift on long calls where one speaker's voice
# changes pitch significantly. Offline finalization at stop is still an
# option (orchestrator falls back if the streamed output is unusable).


class StreamDiarizer:
    """Online diarizer fed one audio chunk at a time. Maintains a small
    table of speaker centroids and assigns each new speech segment to
    the nearest centroid (or starts a new one)."""

    SAMPLE_RATE = 16_000
    DEFAULT_MIN_SEGMENT_SEC = 0.6
    DEFAULT_MAX_SPEAKERS = 12

    def __init__(
        self,
        *,
        cluster_threshold: float = 0.5,
        max_speakers: int = DEFAULT_MAX_SPEAKERS,
        min_segment_sec: float = DEFAULT_MIN_SEGMENT_SEC,
    ) -> None:
        self._cluster_threshold = cluster_threshold
        self._max_speakers = max_speakers
        self._min_segment_sec = min_segment_sec
        self._vad = None  # type: ignore[assignment]
        self._extractor = None  # type: ignore[assignment]
        # Each centroid is a unit-norm np.ndarray (float32). Index = speaker id.
        self._centroids: list[np.ndarray] = []

    def _ensure_models(self) -> None:
        if self._vad is not None and self._extractor is not None:
            return
        import sherpa_onnx  # type: ignore

        vad_path = _ensure_silero_vad()
        emb_path = _ensure_embedding_model()

        vad_config = sherpa_onnx.VadModelConfig(
            silero_vad=sherpa_onnx.SileroVadModelConfig(
                model=str(vad_path),
                threshold=0.5,
                min_silence_duration=0.5,
                min_speech_duration=self._min_segment_sec,
                window_size=512,
            ),
            sample_rate=self.SAMPLE_RATE,
            num_threads=1,
        )
        # buffer_size_in_seconds defaults to 60 s — enough headroom for
        # our 30 s chunks plus the 5 s overlap.
        self._vad = sherpa_onnx.VoiceActivityDetector(vad_config, buffer_size_in_seconds=60)

        ext_config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=str(emb_path),
            num_threads=2,
            provider="coreml",
        )
        self._extractor = sherpa_onnx.SpeakerEmbeddingExtractor(ext_config)

    def process_chunk(
        self, audio: np.ndarray, time_offset: float
    ) -> list[DiarizationSegment]:
        """Diarize one chunk of 16 kHz mono float32 audio. `time_offset`
        is added to all returned segment timestamps so they line up with
        the global recording timeline."""
        if audio.size == 0:
            return []
        self._ensure_models()
        assert self._vad is not None and self._extractor is not None

        # Feed the VAD; collect speech intervals as raw samples.
        self._vad.reset()
        self._vad.accept_waveform(audio)
        self._vad.flush()

        speech_segments: list[tuple[int, int]] = []  # (start_sample, end_sample)
        while not self._vad.empty():
            seg = self._vad.front
            speech_segments.append((seg.start, seg.start + len(seg.samples)))
            self._vad.pop()

        out: list[DiarizationSegment] = []
        for start_sample, end_sample in speech_segments:
            length = end_sample - start_sample
            if length < int(self._min_segment_sec * self.SAMPLE_RATE):
                continue
            window = audio[start_sample:end_sample]
            embedding = self._embed(window)
            if embedding is None:
                continue
            speaker_id = self._assign_or_create(embedding)
            out.append(
                DiarizationSegment(
                    start=start_sample / self.SAMPLE_RATE + time_offset,
                    end=end_sample / self.SAMPLE_RATE + time_offset,
                    speaker=f"speaker_{speaker_id}",
                )
            )
        return out

    def _embed(self, window: np.ndarray) -> np.ndarray | None:
        assert self._extractor is not None
        stream = self._extractor.create_stream()
        stream.accept_waveform(self.SAMPLE_RATE, window)
        stream.input_finished()
        if not self._extractor.is_ready(stream):
            return None
        emb = np.asarray(self._extractor.compute(stream), dtype=np.float32)
        norm = float(np.linalg.norm(emb))
        if norm == 0:
            return None
        return emb / norm

    def _assign_or_create(self, embedding: np.ndarray) -> int:
        if not self._centroids:
            self._centroids.append(embedding)
            return 0
        # Cosine distance against unit-norm centroids = 1 - dot product.
        sims = np.array([float(np.dot(c, embedding)) for c in self._centroids])
        nearest = int(np.argmax(sims))
        if 1.0 - sims[nearest] <= self._cluster_threshold:
            # Update centroid via running average; renormalize.
            updated = self._centroids[nearest] + embedding
            updated /= max(np.linalg.norm(updated), 1e-9)
            self._centroids[nearest] = updated
            return nearest
        if len(self._centroids) >= self._max_speakers:
            # Cap reached — assign to the nearest cluster anyway. Better
            # to slightly mis-attribute than to keep growing forever.
            return nearest
        self._centroids.append(embedding)
        return len(self._centroids) - 1


# --- Channel-aware speaker labelling -----------------------------------------
#
# When the daemon writes a stereo WAV with mic on L and system audio on R,
# speaker labelling becomes a per-segment RMS comparison: whichever channel
# was loudest during a transcript segment's time window owns the segment.
# Much simpler and more accurate than embedding clustering for the typical
# 1:1 call shape, and degrades gracefully into "speaker_0 always" when
# system audio capture failed (R channel is silent the whole recording).


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

    audio, sr = sf.read(str(wav), dtype="int16", always_2d=True)
    if audio.shape[1] != 2:
        # Caller should have checked is_stereo_recording first; defend
        # against future config drift by collapsing to a single label.
        return [{**s, "speaker": USER_SPEAKER} for s in transcript_segments]

    L = audio[:, 0].astype(np.float32)
    R = audio[:, 1].astype(np.float32)

    # Decide once whether the right channel ever had real audio. If
    # not, all segments go to USER_SPEAKER — much more useful than
    # spurious OTHER attributions on silence/noise.
    overall_r_rms = float(np.sqrt(np.mean(R * R))) if R.size > 0 else 0.0
    other_channel_present = overall_r_rms >= min_other_rms

    out: list[dict] = []
    for seg in transcript_segments:
        seg = dict(seg)
        if not other_channel_present:
            seg["speaker"] = USER_SPEAKER
            out.append(seg)
            continue
        start_i = max(0, int(float(seg.get("start", 0)) * sr))
        end_i = min(audio.shape[0], int(float(seg.get("end", 0)) * sr))
        if end_i <= start_i:
            seg["speaker"] = USER_SPEAKER
            out.append(seg)
            continue
        l_chunk = L[start_i:end_i]
        r_chunk = R[start_i:end_i]
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


# --- Speaker assignment -------------------------------------------------------


def assign_speakers(
    transcript_segments: Iterable[dict],
    diarization: list[DiarizationSegment],
    *,
    unknown: str = "Speaker?",
) -> list[dict]:
    """Annotate each transcript segment with `speaker = "speaker_N"` from
    the diarization timeline.

    Strategy: take the midpoint of each transcript segment, find the
    diarization segment that contains it. Falls back to the closest
    diarization segment if no exact overlap (rare; usually means the
    transcript drifted by < 1s from the diarizer's boundaries). When
    there are no diarization segments at all, every transcript segment
    gets `unknown` — render_markdown surfaces this with a banner.
    """
    out: list[dict] = []
    if not diarization:
        for seg in transcript_segments:
            seg = dict(seg)
            seg["speaker"] = unknown
            out.append(seg)
        return out

    # Sorted by start; binary search would be faster but linear is fine
    # for typical meeting lengths (a few hundred segments at most).
    for seg in transcript_segments:
        seg = dict(seg)
        start = float(seg.get("start", 0.0))
        end = float(seg.get("end", start))
        mid = (start + end) / 2.0

        match: DiarizationSegment | None = None
        for d in diarization:
            if d.start <= mid <= d.end:
                match = d
                break
        if match is None:
            # Fall back to closest by midpoint distance.
            match = min(
                diarization,
                key=lambda d: min(abs(d.start - mid), abs(d.end - mid)),
            )
        seg["speaker"] = match.speaker
        out.append(seg)
    return out


# --- Model fetching -----------------------------------------------------------


def _ensure_segmentation_model() -> Path:
    target = models_dir() / SEGMENTATION_MODEL_REL
    if target.exists():
        return target
    archive = models_dir() / "sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
    _download(SEGMENTATION_URL, archive)
    log.info("Extracting %s", archive.name)
    with tarfile.open(archive, "r:bz2") as tf:
        tf.extractall(models_dir())
    archive.unlink(missing_ok=True)
    if not target.exists():
        raise RuntimeError(f"Segmentation model missing after extract: {target}")
    return target


def _ensure_embedding_model() -> Path:
    target = models_dir() / EMBEDDING_FILENAME
    if target.exists():
        return target
    _download(EMBEDDING_URL, target)
    return target


def _ensure_silero_vad() -> Path:
    target = models_dir() / SILERO_VAD_FILENAME
    if target.exists():
        return target
    _download(SILERO_VAD_URL, target)
    return target


def _download(url: str, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_suffix(dst.suffix + ".part")
    log.info("Downloading %s → %s", url, dst.name)
    with urllib.request.urlopen(url) as resp, tmp.open("wb") as out:
        shutil.copyfileobj(resp, out)
    tmp.replace(dst)


# --- Helpers ------------------------------------------------------------------


def _resample(audio: np.ndarray, src_sr: int, dst_sr: int) -> np.ndarray:
    """Linear-interp resample. Speaker embeddings are robust to a cheap
    resample — perceptual quality doesn't matter, only that 1 second of
    audio at the input rate maps to 1 second at the target rate."""
    if src_sr == dst_sr:
        return audio
    ratio = dst_sr / src_sr
    new_len = int(round(len(audio) * ratio))
    if new_len == 0:
        return np.zeros(0, dtype=np.float32)
    src_idx = np.linspace(0, len(audio) - 1, new_len, dtype=np.float64)
    return np.interp(src_idx, np.arange(len(audio)), audio).astype(np.float32)
