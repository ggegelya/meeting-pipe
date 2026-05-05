"""Whisper transcription on MLX (Apple Silicon native) + sherpa-onnx
diarization, with a faster-whisper-CPU fallback for non-Apple-Silicon
hosts.

Output:
  <stem>.json   structured transcript ({language, segments[], …})
  <stem>.md     speaker-segmented Markdown

The pre-MLX implementation used whisperx (faster-whisper + wav2vec2
alignment + pyannote diarization) on CPU and ran at ~2× realtime
end-to-end. mlx-whisper is ~5-10× faster than faster-whisper-CPU on
M-series hardware and emits word-level timestamps directly, so the
wav2vec2 alignment step (which downloaded a per-language ~360 MB model
on every new language) is no longer needed. Diarization moves to
sherpa-onnx (`mp.diarize`) which runs on CoreML / Apple Neural Engine
and is language-agnostic.

Multilang: mlx-whisper covers all 99 Whisper languages out of the box.
`config.transcription.language = "auto"` (default) lets the model pick;
forcing a language (e.g. `"uk"`, `"ru"`, `"en"`) skips the autodetect
step and is slightly faster.
"""
from __future__ import annotations

import json
import logging
import platform
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

from .config import Config, load_secrets
from .diarize import (
    DiarizationSegment,
    USER_SPEAKER,
    assign_speakers,
    assign_speakers_by_channel,
    diarize,
    is_stereo_recording,
)

log = logging.getLogger("mp.transcribe")

_UNSET: object = object()
_UNKNOWN_SPEAKER = "Speaker?"


def _is_apple_silicon() -> bool:
    return sys.platform == "darwin" and platform.machine() == "arm64"


def transcribe(
    wav: Path,
    cfg: Config | None = None,
    out_dir: Path | None = None,
) -> dict[str, Path]:
    """Transcribe `wav` and write `<stem>.json` + `<stem>.md` next to it.

    Returns paths to both outputs. The structured JSON shape is preserved
    from the previous whisperx-based implementation so downstream stages
    (orchestrate, summarize, publish) don't need to change.
    """
    cfg = cfg or Config.load()
    load_secrets()
    out_dir = out_dir or wav.parent
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = wav.stem
    json_path = out_dir / f"{stem}.json"
    md_path = out_dir / f"{stem}.md"

    tcfg = cfg.transcription

    # 1. ASR + word-level timestamps.
    backend, language, segments, audio_seconds = _run_asr(wav, tcfg)
    log.info("ASR done: backend=%s lang=%s segments=%d duration=%.1fs",
             backend, language, len(segments), audio_seconds)

    # 2. Diarization.
    diarization_failed = False
    diarization_failure_reason: str | None = None
    diarization_segments: list[DiarizationSegment] = []
    used_channel_aware = False

    audio_minutes = audio_seconds / 60.0
    skip_for_length = (
        tcfg.max_diarization_minutes
        and audio_minutes > tcfg.max_diarization_minutes
    )

    if not segments:
        log.info("Skipping diarization (no segments)")
    elif tcfg.disable_diarization:
        log.info("Diarization disabled by config")
    elif skip_for_length:
        log.warning(
            "Audio is %.1f min — exceeds max_diarization_minutes=%d. Skipping.",
            audio_minutes, tcfg.max_diarization_minutes,
        )
        diarization_failed = True
        diarization_failure_reason = (
            f"audio length {audio_minutes:.0f} min "
            f"> max_diarization_minutes={tcfg.max_diarization_minutes}"
        )
    elif is_stereo_recording(wav):
        # Daemon now writes stereo (mic-L, system-R) on a successful
        # mic+system recording. Channel-aware labelling is much more
        # accurate than embedding clustering for the 1:1 call case
        # (and ~free CPU-wise — just per-segment RMS comparisons).
        log.info("Stereo recording detected — using channel-aware speaker labelling")
        segments = assign_speakers_by_channel(segments, wav)
        used_channel_aware = True
    else:
        try:
            diarization_segments = diarize(
                wav,
                min_speakers=tcfg.min_speakers,
                max_speakers=tcfg.max_speakers,
                cluster_threshold=tcfg.diarize_cluster_threshold,
            )
        except Exception as e:  # noqa: BLE001
            diarization_failed = True
            diarization_failure_reason = f"{type(e).__name__}: {e}"
            log.error("Diarization failed: %s", e)

    # 3. Assign speakers to each transcript segment (skip when
    # channel-aware already labelled them above).
    if used_channel_aware:
        pass
    elif diarization_segments:
        segments = assign_speakers(segments, diarization_segments)
    elif diarization_failed:
        # Mark everything as unknown so the failure surfaces in the MD banner.
        segments = [{**s, "speaker": _UNKNOWN_SPEAKER} for s in segments]

    structured: dict[str, Any] = {
        "language": language,
        "segments": segments,
        "audio_path": str(wav),
        "audio_seconds": audio_seconds,
        "model": tcfg.model if backend == "mlx" else tcfg.fallback_model,
        "backend": backend,
        "diarization": not tcfg.disable_diarization and not skip_for_length,
        "diarization_failed": diarization_failed,
        "diarization_failure_reason": diarization_failure_reason,
        "diarization_method": "channel-aware" if used_channel_aware else "embedding",
    }
    json_path.write_text(json.dumps(structured, ensure_ascii=False, indent=2), encoding="utf-8")

    md = render_markdown(structured)
    md_path.write_text(md, encoding="utf-8")

    log.info("Wrote %s and %s", json_path, md_path)
    return {"json": json_path, "md": md_path}


# --- ASR backends -------------------------------------------------------------


def _run_asr(wav: Path, tcfg) -> tuple[str, str, list[dict], float]:
    """Run whichever Whisper backend is available. Returns
    `(backend, language, segments, audio_seconds)`.
    """
    if _is_apple_silicon():
        try:
            return _run_mlx(wav, tcfg)
        except Exception as e:  # noqa: BLE001
            log.warning("mlx-whisper failed (%s); falling back to faster-whisper", e)
    return _run_faster_whisper(wav, tcfg)


def _run_mlx(wav: Path, tcfg) -> tuple[str, str, list[dict], float]:
    """Native MLX/Metal Whisper. ~5-10× faster than faster-whisper on M-series."""
    import mlx_whisper  # type: ignore

    model_id = _resolve_mlx_model_id(tcfg.model)
    log.info("Loading MLX Whisper (%s)", model_id)
    kwargs: dict[str, Any] = {
        "path_or_hf_repo": model_id,
        "word_timestamps": True,
        # Disable mlx-whisper's tqdm bar (it spams pipeline.log otherwise).
        "verbose": None,
    }
    if tcfg.language and tcfg.language.lower() != "auto":
        kwargs["language"] = tcfg.language

    log.info("Transcribing %s", wav.name)
    result = mlx_whisper.transcribe(str(wav), **kwargs)

    raw_segments = result.get("segments", [])
    language = result.get("language", "en")

    audio_seconds = float(raw_segments[-1]["end"]) if raw_segments else 0.0
    segments = [_normalize_segment(s) for s in raw_segments]
    return "mlx", language, segments, audio_seconds


def _run_faster_whisper(wav: Path, tcfg) -> tuple[str, str, list[dict], float]:
    """Cross-platform fallback. Slower than MLX but works on Linux/Intel."""
    from faster_whisper import WhisperModel  # type: ignore

    log.info("Loading faster-whisper (%s, int8 CPU)", tcfg.fallback_model)
    model = WhisperModel(tcfg.fallback_model, device="cpu", compute_type="int8")
    language = None if (tcfg.language or "auto").lower() == "auto" else tcfg.language

    log.info("Transcribing %s", wav.name)
    seg_iter, info = model.transcribe(
        str(wav),
        language=language,
        word_timestamps=True,
        vad_filter=True,
    )
    segments = []
    last_end = 0.0
    for s in seg_iter:
        words = []
        if getattr(s, "words", None):
            for w in s.words:
                words.append({"word": w.word, "start": float(w.start or 0), "end": float(w.end or 0)})
        segments.append({
            "start": float(s.start),
            "end": float(s.end),
            "text": s.text,
            "words": words,
        })
        last_end = float(s.end)
    return "faster-whisper", info.language, segments, last_end


_DEFAULT_MLX_MODEL = "mlx-community/whisper-large-v3-turbo"

# Canonical MLX repo names for the faster-whisper bare names that
# pre-Tier-1 configs use. The mlx-community repo isn't 1:1 with the
# faster-whisper naming — `large-v3` only exists in MLX as the
# `-turbo` distillation (faster, near-equal WER), and the smaller
# variants get an explicit `-mlx` suffix. Without this table, naive
# prefixing produces 404s like `mlx-community/whisper-large-v3` and
# the pipeline silently degrades to faster-whisper-CPU.
_LEGACY_TO_MLX = {
    "large-v3":         "mlx-community/whisper-large-v3-turbo",
    "large-v3-turbo":   "mlx-community/whisper-large-v3-turbo",
    "large-v2":         "mlx-community/whisper-large-v2-mlx",
    "large":            "mlx-community/whisper-large-v3-turbo",
    "medium":           "mlx-community/whisper-medium-mlx",
    "medium.en":        "mlx-community/whisper-medium.en-mlx",
    "small":            "mlx-community/whisper-small-mlx",
    "small.en":         "mlx-community/whisper-small.en-mlx",
    "base":             "mlx-community/whisper-base-mlx",
    "base.en":          "mlx-community/whisper-base.en-mlx",
    "tiny":             "mlx-community/whisper-tiny-mlx",
    "tiny.en":          "mlx-community/whisper-tiny.en-mlx",
}


def _resolve_mlx_model_id(model: str) -> str:
    """Map a transcription.model string to an mlx-whisper-compatible
    HuggingFace repo or local path.

    Anything containing `/` (HF org/repo) or starting with `~`/`.`
    (local path) passes through untouched. Bare faster-whisper names
    are mapped via `_LEGACY_TO_MLX` to the actual published mlx-community
    repos. Unknown bare names fall back to a naive `mlx-community/
    whisper-X` prefix so a future Whisper variant we haven't enumerated
    can still be reached by setting `model = "<name>"`; mlx-whisper's
    own 404 path then surfaces the typo.
    """
    s = model.strip()
    if not s:
        return _DEFAULT_MLX_MODEL
    if "/" in s or s.startswith("~") or s.startswith("."):
        return s
    if s in _LEGACY_TO_MLX:
        return _LEGACY_TO_MLX[s]
    return f"mlx-community/whisper-{s}"


def _normalize_segment(seg: dict) -> dict:
    """Trim mlx-whisper's segment dict to the fields the downstream
    pipeline relies on. Keeps `words` when present so streaming
    consumers (Tier 2) can render partial transcripts."""
    out = {
        "start": float(seg.get("start", 0.0)),
        "end": float(seg.get("end", 0.0)),
        "text": (seg.get("text") or "").strip(),
    }
    if "words" in seg:
        out["words"] = [
            {
                "word": w.get("word", ""),
                "start": float(w.get("start", out["start"])),
                "end": float(w.get("end", out["end"])),
            }
            for w in seg["words"]
        ]
    return out


# --- Markdown rendering -------------------------------------------------------


def render_markdown(structured: dict[str, Any]) -> str:
    """Render the structured transcript into speaker-segmented Markdown.

    Consecutive segments from the same speaker are merged into a single
    block. When diarization failed (or returned no assignments), prepend
    a warning banner and use `Speaker?` for missing labels so the
    failure can never go unnoticed in downstream review.
    """
    lines: list[str] = []
    title = Path(structured.get("audio_path", "transcript")).stem
    lines.append(f"# Transcript — {title}")
    lines.append("")
    lines.append(f"_Language detected: {structured.get('language', 'unknown')}_")
    lines.append("")

    if structured.get("diarization_failed"):
        reason = structured.get("diarization_failure_reason") or "unknown"
        lines.append(
            f"> ⚠️ Diarization failed; all turns labeled `{_UNKNOWN_SPEAKER}`. "
            f"Reason: {reason}"
        )
        lines.append("")

    current_speaker: str | object = _UNSET
    buffer: list[str] = []

    def flush() -> None:
        if buffer and isinstance(current_speaker, str):
            lines.append(f"**{current_speaker}**: " + " ".join(buffer).strip())
            lines.append("")
            buffer.clear()

    for seg in structured.get("segments", []):
        speaker = seg.get("speaker") or _UNKNOWN_SPEAKER
        text = (seg.get("text") or "").strip()
        if not text:
            continue
        if speaker != current_speaker:
            flush()
            current_speaker = speaker
        buffer.append(text)
    flush()

    counts: dict[str, int] = defaultdict(int)
    for seg in structured.get("segments", []):
        counts[seg.get("speaker") or _UNKNOWN_SPEAKER] += 1
    if counts:
        lines.append("---")
        lines.append("")
        lines.append("Speakers (segment counts):")
        for spk, n in sorted(counts.items()):
            lines.append(f"- {spk}: {n}")
    return "\n".join(lines).rstrip() + "\n"


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: mp transcribe <wav>", file=sys.stderr)
        return 2
    wav = Path(argv[0]).expanduser().resolve()
    if not wav.exists():
        print(f"No such file: {wav}", file=sys.stderr)
        return 1
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    transcribe(wav)
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
