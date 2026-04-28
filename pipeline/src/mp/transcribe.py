"""WhisperX-based transcription with pyannote diarization.

Output: <stem>.json (structured) + <stem>.md (speaker-segmented Markdown).

Implementation notes
--------------------
- We import whisperx lazily so `mp --help` and unit tests don't pay the model-import cost.
- HF_TOKEN is required for pyannote model downloads on first run.
- compute_type="int8" runs on CPU. "float16" on Apple Silicon needs MPS support
  in faster-whisper which is still flaky — we don't expose it via the CLI.
"""
from __future__ import annotations

import json
import logging
import os
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

from .config import Config, load_secrets, require_env

log = logging.getLogger("mp.transcribe")


def _device_for(compute_type: str) -> str:
    # int8 → CPU. float16 → cuda (Linux) or mps (macOS). On macOS we leave it
    # to the user's torch install to honor MPS; whisperx accepts "cpu" or "cuda".
    return "cpu" if compute_type == "int8" else "cuda"


def transcribe(wav: Path, cfg: Config | None = None, out_dir: Path | None = None) -> dict[str, Path]:
    """Transcribe `wav` and write `<stem>.json` + `<stem>.md` next to it.

    Returns paths to both outputs.
    """
    cfg = cfg or Config.load()
    load_secrets()
    out_dir = out_dir or wav.parent
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = wav.stem
    json_path = out_dir / f"{stem}.json"
    md_path = out_dir / f"{stem}.md"

    # Lazy imports — heavy.
    import whisperx  # type: ignore

    tcfg = cfg.transcription
    device = _device_for(tcfg.compute_type)

    log.info("Loading model %s (compute_type=%s, device=%s)", tcfg.model, tcfg.compute_type, device)
    model = whisperx.load_model(tcfg.model, device, compute_type=tcfg.compute_type)

    log.info("Loading audio %s", wav)
    audio = whisperx.load_audio(str(wav))

    transcribe_kwargs: dict[str, Any] = {"batch_size": 16}
    if tcfg.language and tcfg.language.lower() != "auto":
        transcribe_kwargs["language"] = tcfg.language

    log.info("Transcribing")
    result = model.transcribe(audio, **transcribe_kwargs)
    detected_lang = result.get("language", tcfg.language if tcfg.language != "auto" else "en")

    # Word-level alignment with wav2vec2 — required for diarization to map
    # speaker turns onto word boundaries.
    log.info("Aligning (lang=%s)", detected_lang)
    try:
        align_model, metadata = whisperx.load_align_model(language_code=detected_lang, device=device)
        result = whisperx.align(
            result["segments"], align_model, metadata, audio, device, return_char_alignments=False
        )
    except Exception as e:  # noqa: BLE001
        # Some less-common languages have no alignment model. Skip alignment
        # and continue with sentence-level segments only.
        log.warning("Alignment skipped (%s): %s", detected_lang, e)

    if not tcfg.disable_diarization:
        hf_token = require_env("HF_TOKEN")
        log.info("Diarizing (min=%d, max=%d)", tcfg.min_speakers, tcfg.max_speakers)
        try:
            # whisperx 3.1+ moved the import path; try both.
            try:
                from whisperx.diarize import DiarizationPipeline  # type: ignore
            except ImportError:
                from whisperx import DiarizationPipeline  # type: ignore
            diarize_model = DiarizationPipeline(use_auth_token=hf_token, device=device)
            diarize_segments = diarize_model(
                audio, min_speakers=tcfg.min_speakers, max_speakers=tcfg.max_speakers
            )
            result = whisperx.assign_word_speakers(diarize_segments, result)
        except Exception as e:  # noqa: BLE001
            log.error(
                "Diarization failed (%s). Falling back to single-speaker labels. "
                "Common cause: HF model TOS not accepted at "
                "https://huggingface.co/pyannote/speaker-diarization-3.1",
                e,
            )

    structured = {
        "language": detected_lang,
        "segments": result.get("segments", []),
        "audio_path": str(wav),
        "model": tcfg.model,
        "diarization": not tcfg.disable_diarization,
    }
    json_path.write_text(json.dumps(structured, ensure_ascii=False, indent=2), encoding="utf-8")

    md = render_markdown(structured)
    md_path.write_text(md, encoding="utf-8")

    log.info("Wrote %s and %s", json_path, md_path)
    return {"json": json_path, "md": md_path}


def render_markdown(structured: dict[str, Any]) -> str:
    """Render the structured transcript into speaker-segmented Markdown.

    Consecutive segments from the same speaker are merged into a single block.
    """
    lines: list[str] = []
    title = Path(structured.get("audio_path", "transcript")).stem
    lines.append(f"# Transcript — {title}")
    lines.append("")
    lines.append(f"_Language detected: {structured.get('language', 'unknown')}_")
    lines.append("")

    current_speaker: str | None = object()  # type: ignore[assignment]
    buffer: list[str] = []

    def flush() -> None:
        if buffer and current_speaker is not None:
            label = current_speaker if isinstance(current_speaker, str) else "Speaker"
            lines.append(f"**{label}**: " + " ".join(buffer).strip())
            lines.append("")
            buffer.clear()

    for seg in structured.get("segments", []):
        speaker = seg.get("speaker") or "Speaker"
        text = (seg.get("text") or "").strip()
        if not text:
            continue
        if speaker != current_speaker:
            flush()
            current_speaker = speaker
        buffer.append(text)
    flush()

    # Speaker count footer for quick eyeballing.
    counts: dict[str, int] = defaultdict(int)
    for seg in structured.get("segments", []):
        counts[seg.get("speaker") or "Speaker"] += 1
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
