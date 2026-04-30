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
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

from .config import Config, load_secrets, require_env
from .endpoints import PYANNOTE_DIARIZATION_REPO, hf_model_page_url

log = logging.getLogger("mp.transcribe")

_UNSET: object = object()


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
    try:
        result = model.transcribe(audio, **transcribe_kwargs)
    except IndexError:
        # WhisperX's VAD can return zero speech segments on a near-silent
        # input, then transformers crashes accessing inputs[0]. Treat as
        # "no speech" rather than an orchestrator-level failure — the wav
        # is still on disk for inspection, and run-all can continue past
        # this step (downstream summarize will see an empty transcript and
        # produce a "(no content)" stub instead of a billable LLM call).
        log.warning("No speech detected in audio (VAD returned zero segments). Writing empty transcript.")
        result = {"language": "en", "segments": []}
    detected_lang = result.get("language", tcfg.language if tcfg.language != "auto" else "en")

    # Word-level alignment with wav2vec2 — required for diarization to map
    # speaker turns onto word boundaries. Skip when there's no speech: the
    # align-model load triggers a 360 MB wav2vec2 download on first run, and
    # there's nothing to align anyway.
    if not result.get("segments"):
        log.info("Skipping alignment + diarization (no segments)")
    else:
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

    diarization_failed = False
    diarization_failure_reason: str | None = None
    if not tcfg.disable_diarization and result.get("segments"):
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
            diarization_failed = True
            diarization_failure_reason = f"{type(e).__name__}: {e}"
            log.error(
                "Diarization failed (%s). Falling back to single-speaker labels. "
                "Common cause: HF model TOS not accepted at %s",
                e,
                hf_model_page_url(PYANNOTE_DIARIZATION_REPO),
            )

        # Even when no exception was raised, the run may have produced zero
        # speaker assignments — a known whisperx symptom that previously went
        # undetected. Flag that case explicitly so the markdown banner fires
        # and the user knows the labels are unreliable.
        if not diarization_failed and result.get("segments"):
            any_assigned = any(
                seg.get("speaker") is not None for seg in result["segments"]
            )
            if not any_assigned:
                diarization_failed = True
                diarization_failure_reason = (
                    "diarization returned no speaker assignments "
                    "(whisperx assign_word_speakers produced empty result)"
                )
                log.error("Diarization returned no speaker assignments — see commit 3 fix path")

    structured = {
        "language": detected_lang,
        "segments": result.get("segments", []),
        "audio_path": str(wav),
        "model": tcfg.model,
        "diarization": not tcfg.disable_diarization,
        "diarization_failed": diarization_failed,
        "diarization_failure_reason": diarization_failure_reason,
    }
    json_path.write_text(json.dumps(structured, ensure_ascii=False, indent=2), encoding="utf-8")

    md = render_markdown(structured)
    md_path.write_text(md, encoding="utf-8")

    log.info("Wrote %s and %s", json_path, md_path)
    return {"json": json_path, "md": md_path}


_UNKNOWN_SPEAKER = "Speaker?"


def render_markdown(structured: dict[str, Any]) -> str:
    """Render the structured transcript into speaker-segmented Markdown.

    Consecutive segments from the same speaker are merged into a single block.
    When diarization failed (or returned no assignments), prepend a warning
    banner and use `Speaker?` for missing labels so the failure can never go
    unnoticed in downstream review.
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

    # Speaker count footer for quick eyeballing.
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
