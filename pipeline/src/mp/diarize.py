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
