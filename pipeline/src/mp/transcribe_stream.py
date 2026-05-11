"""Streaming transcription — runs in parallel with the daemon's recording.

The daemon spawns this process at recording-start time and tails the
mic.wav / system.wav files as they grow. Each chunk worth of new audio
is decoded, mixed mono, and fed to mlx-whisper. Transcripts accumulate
in `<stem>.json` so the orchestrator can skip the transcribe stage at
finalization (it sees the file already exists and moves straight to
diarize + summarize + publish).

Termination: the daemon sends SIGTERM when recording stops. We flush
the remaining buffer, finalize the JSON / Markdown, and exit cleanly.

This module is intentionally narrow — the heavy ASR path lives in
`mp.transcribe._run_mlx`, which we import here. Diarization is NOT done
here; speaker labels are filled in by the at-stop diarize step.
"""
from __future__ import annotations

import argparse
import json
import logging
import signal
import struct
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

from .config import Config, load_secrets
from .diarize import StreamDiarizer, assign_speakers
from .transcribe import _is_apple_silicon, render_markdown

log = logging.getLogger("mp.transcribe_stream")


# Whisper's natural context window is 30s. We chunk on that boundary so
# the model sees one full window per inference. 5s of overlap with the
# previous chunk preserves continuity at boundaries (otherwise mid-word
# splits show up in the joined transcript).
CHUNK_SECONDS = 30.0
OVERLAP_SECONDS = 5.0
TARGET_SR = 16_000
POLL_INTERVAL = 1.0


@dataclass
class StreamState:
    stem: str
    out_dir: Path
    language: str | None
    model: str
    fallback_model: str
    diarize: bool = True
    diarize_threshold: float = 0.5
    # PCM samples accumulated and not yet transcribed (16 kHz mono float32).
    buffer: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=np.float32))
    # Time at the START of the buffer, in seconds since recording-start.
    # Used to offset segment timestamps so they align with the canonical
    # at-stop diarization timeline.
    buffer_start: float = 0.0
    segments: list[dict] = field(default_factory=list)
    diarization_segments: list = field(default_factory=list)  # list[DiarizationSegment]
    diarizer: StreamDiarizer | None = None
    detected_language: str | None = None
    # Set when SIGTERM arrives — the main loop notices and flushes.
    stopping: bool = False


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="mp transcribe-stream")
    parser.add_argument("--mic-wav", required=True, help="Path to growing mic WAV (input)")
    parser.add_argument("--system-wav", required=False, default=None,
                        help="Path to growing system-audio WAV (input, may not exist)")
    parser.add_argument("--out-dir", required=True, help="Where to write <stem>.json/.md")
    parser.add_argument("--stem", required=True, help="Output stem (e.g. 20260506-1430)")
    parser.add_argument("--language", default=None, help="ISO 639-1 code or omit for auto")
    parser.add_argument("--model", default=None, help="Override transcription.model")
    parser.add_argument("--no-finalize-on-exit", action="store_true",
                        help="Don't write final outputs on shutdown (for tests)")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    cfg = Config.load()
    load_secrets()

    state = StreamState(
        stem=args.stem,
        out_dir=Path(args.out_dir),
        language=args.language if args.language and args.language.lower() != "auto" else None,
        model=args.model or cfg.transcription.model,
        fallback_model=cfg.transcription.fallback_model,
        diarize=not cfg.transcription.disable_diarization,
        diarize_threshold=cfg.transcription.stream_diarize_threshold,
    )
    state.out_dir.mkdir(parents=True, exist_ok=True)
    if state.diarize:
        # Lazy: the actual model load happens on first chunk.
        state.diarizer = StreamDiarizer(cluster_threshold=state.diarize_threshold)

    # SIGTERM (graceful) and SIGINT (Ctrl-C while debugging) both ask the
    # main loop to flush + exit. We don't trap SIGKILL — that's terminal
    # and the file the daemon already has on disk will be re-transcribed
    # offline by the at-stop orchestrator path.
    def _handle_term(signum, frame):  # noqa: ARG001
        log.info("Got signal %d — finishing up", signum)
        state.stopping = True

    signal.signal(signal.SIGTERM, _handle_term)
    signal.signal(signal.SIGINT, _handle_term)

    log.info("Streaming transcribe started: stem=%s mic=%s system=%s",
             args.stem, args.mic_wav, args.system_wav or "(none)")

    mic_reader = _GrowingWavReader(Path(args.mic_wav))
    system_reader = _GrowingWavReader(Path(args.system_wav)) if args.system_wav else None

    # Loop until SIGTERM AND both inputs are drained.
    while True:
        new_samples = _pull_mixed_block(mic_reader, system_reader, target_sr=TARGET_SR)
        if new_samples.size > 0:
            state.buffer = np.concatenate((state.buffer, new_samples))
            _maybe_flush_chunks(state, force=False)

        if state.stopping:
            # Drain any remaining inputs (the daemon's recorder.stop has
            # written the last samples by the time we get here).
            tail = _pull_mixed_block(mic_reader, system_reader, target_sr=TARGET_SR)
            if tail.size > 0:
                state.buffer = np.concatenate((state.buffer, tail))
            _maybe_flush_chunks(state, force=True)
            break

        time.sleep(POLL_INTERVAL)

    if not args.no_finalize_on_exit:
        _write_outputs(state)
    log.info("Streaming transcribe done: stem=%s segments=%d", args.stem, len(state.segments))
    return 0


# --- Chunked transcription ---------------------------------------------------


def _maybe_flush_chunks(state: StreamState, *, force: bool) -> None:
    """Run mlx-whisper on any 30 s chunks that have accumulated. When
    `force=True`, also flush any remaining tail (used at shutdown so we
    don't drop the last few seconds of audio)."""
    chunk_samples = int(CHUNK_SECONDS * TARGET_SR)
    overlap_samples = int(OVERLAP_SECONDS * TARGET_SR)

    while state.buffer.size >= chunk_samples or (force and state.buffer.size > 0):
        if state.buffer.size <= overlap_samples and not force:
            # Just overlap left, no new content yet.
            break
        chunk = state.buffer[:chunk_samples] if state.buffer.size >= chunk_samples else state.buffer
        chunk_start = state.buffer_start
        _transcribe_chunk(state, chunk, chunk_start)
        if chunk.size == chunk_samples and not force:
            # Full chunk during steady-state streaming: keep overlap for
            # context continuity on the next pass.
            keep = chunk_samples - overlap_samples
            state.buffer = state.buffer[keep:]
            state.buffer_start += keep / TARGET_SR
        else:
            # Final-tail flush (force=True) or short trailing chunk —
            # drain entirely; nothing more is coming.
            state.buffer = np.zeros(0, dtype=np.float32)
            state.buffer_start += chunk.size / TARGET_SR
            break


def _transcribe_chunk(state: StreamState, chunk: np.ndarray, offset: float) -> None:
    """Run a single chunk through mlx-whisper (or faster-whisper fallback)
    AND through the streaming diarizer (if enabled). Speaker labels get
    stamped onto the ASR segments inside _absorb_segments — see how
    `state.diarization_segments` accumulates and is consulted there."""
    if chunk.size == 0:
        return
    if _is_apple_silicon():
        try:
            _transcribe_chunk_mlx(state, chunk, offset)
        except Exception as e:  # noqa: BLE001
            log.warning("mlx chunk failed (%s) — falling back to faster-whisper", e)
            _transcribe_chunk_faster_whisper(state, chunk, offset)
    else:
        _transcribe_chunk_faster_whisper(state, chunk, offset)
    _diarize_chunk(state, chunk, offset)


def _diarize_chunk(state: StreamState, chunk: np.ndarray, offset: float) -> None:
    """Run the streaming diarizer on the same chunk and append its
    DiarizationSegments to `state.diarization_segments`. Best-effort:
    a failure here doesn't crash transcription — the orchestrator's
    offline diarize is the safety net at finalization."""
    if state.diarizer is None:
        return
    try:
        new = state.diarizer.process_chunk(chunk, time_offset=offset)
        state.diarization_segments.extend(new)
    except Exception as e:  # noqa: BLE001
        log.warning("Streaming diarize chunk failed (%s) — at-stop offline diarize will catch up", e)
        # Don't try again on subsequent chunks — most likely a model load
        # issue that won't resolve. Drop the diarizer; orchestrator will
        # see segments without speaker labels and re-run offline.
        state.diarizer = None


def _transcribe_chunk_mlx(state: StreamState, chunk: np.ndarray, offset: float) -> None:
    import mlx_whisper  # type: ignore
    from .transcribe import _MLX_ANTI_LOOP_KWARGS, _resolve_mlx_model_id
    kwargs: dict[str, Any] = {
        "path_or_hf_repo": _resolve_mlx_model_id(state.model),
        "word_timestamps": True,
        "verbose": None,
        **_MLX_ANTI_LOOP_KWARGS,
    }
    if state.language:
        kwargs["language"] = state.language
    result = mlx_whisper.transcribe(chunk.astype(np.float32), **kwargs)
    state.detected_language = state.detected_language or result.get("language")
    _absorb_segments(state, result.get("segments", []), offset)


def _transcribe_chunk_faster_whisper(state: StreamState, chunk: np.ndarray, offset: float) -> None:
    from faster_whisper import WhisperModel  # type: ignore
    # Re-using the model across chunks would be ideal but would require
    # carrying the WhisperModel handle across the StreamState. Fallback
    # path is rare on Apple Silicon, so the per-chunk reload is acceptable.
    model = WhisperModel(state.fallback_model, device="cpu", compute_type="int8")
    seg_iter, info = model.transcribe(
        chunk,
        language=state.language,
        word_timestamps=True,
        vad_filter=True,
    )
    state.detected_language = state.detected_language or info.language
    raw = []
    for s in seg_iter:
        words = []
        if getattr(s, "words", None):
            for w in s.words:
                words.append({"word": w.word, "start": float(w.start or 0), "end": float(w.end or 0)})
        raw.append({"start": float(s.start), "end": float(s.end), "text": s.text, "words": words})
    _absorb_segments(state, raw, offset)


def _absorb_segments(state: StreamState, raw: list[dict], offset: float) -> None:
    for seg in raw:
        # Drop segments that fall inside the overlap region we already
        # processed in the previous chunk — by their timestamps overlapping
        # with the prior tail. Without this, words at the boundary appear
        # twice in the joined transcript.
        seg_start = float(seg.get("start", 0.0)) + offset
        seg_end = float(seg.get("end", 0.0)) + offset
        if state.segments and seg_start < state.segments[-1]["end"] - 0.25:
            continue
        out = {
            "start": seg_start,
            "end": seg_end,
            "text": (seg.get("text") or "").strip(),
        }
        if seg.get("words"):
            out["words"] = [
                {
                    "word": w.get("word", ""),
                    "start": float(w.get("start", 0.0)) + offset,
                    "end": float(w.get("end", 0.0)) + offset,
                }
                for w in seg["words"]
            ]
        state.segments.append(out)


# --- Output ------------------------------------------------------------------


def _write_outputs(state: StreamState) -> None:
    json_path = state.out_dir / f"{state.stem}.json"
    md_path = state.out_dir / f"{state.stem}.md"

    # Stamp streaming-diarizer speaker labels onto each transcript segment
    # before persisting. When the diarizer is disabled or produced no
    # segments, leave the segments label-less; the orchestrator then
    # decides whether to run offline diarize at finalization.
    diarized = bool(state.diarization_segments)
    if diarized:
        labelled = assign_speakers(state.segments, state.diarization_segments)
    else:
        labelled = list(state.segments)

    structured = {
        "language": state.detected_language or state.language or "en",
        "segments": labelled,
        "audio_path": str(state.out_dir / f"{state.stem}.wav"),
        "audio_seconds": labelled[-1]["end"] if labelled else 0.0,
        "model": state.model,
        "backend": "mlx-stream" if _is_apple_silicon() else "faster-whisper-stream",
        "diarization": diarized,
        "diarization_failed": False,
        "diarization_failure_reason": None,
        "streaming": True,
    }
    json_path.write_text(json.dumps(structured, ensure_ascii=False, indent=2), encoding="utf-8")

    md = render_markdown(structured)
    md_path.write_text(md, encoding="utf-8")
    log.info("Wrote %s and %s (diarized=%s, speakers=%d)", json_path, md_path, diarized,
             len({s.speaker for s in state.diarization_segments}))


# --- WAV file tailing --------------------------------------------------------


class _GrowingWavReader:
    """Read a WAV file as it's still being written by another process.

    AVAudioFile (the daemon's writer) flushes PCM bytes promptly to disk
    even though the RIFF header's `data` size remains stale until close.
    We don't trust the size field; we just track byte position relative
    to the data section start and read raw PCM frames.

    AVAudioFile does NOT emit a flat 44-byte PCM header. The on-disk
    layout is:

        RIFF descriptor (12 bytes)
        JUNK chunk      (8 + 28  bytes; padding placeholder)
        fmt  chunk      (8 + 16  bytes; PCM/IEEE Float format block)
        FLLR chunk      (8 + 4008 bytes; pre-allocated filler for I/O
                         alignment so the data chunk sits on a 4 KB boundary)
        data chunk      (8 bytes header + growing PCM payload)

    So `data` starts at byte ~4088, NOT byte 44. Treating the file as
    if HEADER_SIZE == 44 (the previous behaviour) made the reader pick
    fmt fields out of the JUNK chunk's zero payload, returning
    fmt_code=0 / channels=0 / sample_rate=0; at that point
    bytes_per_frame is 0 and read_new() short-circuits to None
    forever. End-to-end symptom: streaming sidecar exits with
    `segments: []` on every meeting and the orchestrator falls back
    to offline transcribe.

    We parse chunks properly here. Unknown chunks are skipped, fmt is
    cached at first sighting, and the data section's start byte is
    remembered for all subsequent reads.
    """

    def __init__(self, path: Path) -> None:
        self.path = path
        self.format: dict | None = None
        self.data_start: int | None = None
        self.position: int = 0  # bytes consumed from the data section

    def _try_open_header(self) -> bool:
        if not self.path.exists():
            return False
        try:
            with self.path.open("rb") as f:
                if f.read(4) != b"RIFF":
                    return False
                f.read(4)  # RIFF size; unreliable on a growing file
                if f.read(4) != b"WAVE":
                    return False
                fmt_data: bytes | None = None
                data_start: int | None = None
                while True:
                    chunk_hdr = f.read(8)
                    if len(chunk_hdr) < 8:
                        break
                    cid = chunk_hdr[:4]
                    size = struct.unpack_from("<I", chunk_hdr, 4)[0]
                    if cid == b"fmt ":
                        fmt_data = f.read(size)
                        # RIFF chunks are word-aligned; skip a pad byte
                        # if the declared size is odd.
                        if size % 2:
                            f.read(1)
                    elif cid == b"data":
                        data_start = f.tell()
                        break
                    else:
                        f.seek(size + (size % 2), 1)
        except OSError:
            return False
        if fmt_data is None or data_start is None:
            return False
        if len(fmt_data) < 16:
            return False
        fmt_code = struct.unpack_from("<H", fmt_data, 0)[0]
        channels = struct.unpack_from("<H", fmt_data, 2)[0]
        sample_rate = struct.unpack_from("<I", fmt_data, 4)[0]
        bits_per_sample = struct.unpack_from("<H", fmt_data, 14)[0]
        if channels == 0 or sample_rate == 0 or bits_per_sample == 0:
            return False
        self.format = {
            "fmt_code": fmt_code,
            "channels": channels,
            "sample_rate": sample_rate,
            "bits_per_sample": bits_per_sample,
        }
        self.data_start = data_start
        return True

    def read_new(self) -> np.ndarray | None:
        """Return any new PCM frames as float32 mono mixdown (any channels
        averaged), or None if nothing's available yet. Frames are at the
        source sample rate — caller resamples to TARGET_SR.
        """
        if self.format is None or self.data_start is None:
            if not self._try_open_header():
                return None
        try:
            size = self.path.stat().st_size
        except OSError:
            return None
        new_bytes = max(0, size - self.data_start - self.position)
        if new_bytes <= 0:
            return None
        # Read in whole-frame multiples to avoid mid-frame fragments.
        bytes_per_frame = self.format["channels"] * (self.format["bits_per_sample"] // 8)
        if bytes_per_frame == 0:
            return None
        new_bytes -= new_bytes % bytes_per_frame
        if new_bytes <= 0:
            return None
        try:
            with self.path.open("rb") as f:
                f.seek(self.data_start + self.position)
                data = f.read(new_bytes)
        except OSError:
            return None
        if not data:
            return None
        self.position += len(data)
        return self._decode(data)

    def _decode(self, data: bytes) -> np.ndarray:
        fmt_code = self.format["fmt_code"]
        bps = self.format["bits_per_sample"]
        channels = self.format["channels"]
        if fmt_code == 1 and bps == 16:
            arr = np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0
        elif fmt_code == 3 and bps == 32:
            arr = np.frombuffer(data, dtype="<f4")
        elif fmt_code == 1 and bps == 32:
            arr = np.frombuffer(data, dtype="<i4").astype(np.float32) / 2147483648.0
        else:
            log.warning("Unsupported WAV format fmt=%d bps=%d — skipping bytes", fmt_code, bps)
            return np.zeros(0, dtype=np.float32)
        if channels > 1:
            arr = arr.reshape(-1, channels).mean(axis=1)
        return arr.astype(np.float32, copy=False)

    @property
    def sample_rate(self) -> int:
        return self.format["sample_rate"] if self.format else TARGET_SR


def _pull_mixed_block(
    mic: _GrowingWavReader,
    system: _GrowingWavReader | None,
    *,
    target_sr: int,
) -> np.ndarray:
    """Pull whatever new audio is available from each side, resample to
    `target_sr`, and mix to a single mono float32 array."""
    mic_chunk = mic.read_new()
    sys_chunk = system.read_new() if system else None

    if mic_chunk is None and sys_chunk is None:
        return np.zeros(0, dtype=np.float32)

    if mic_chunk is not None:
        mic_chunk = _resample(mic_chunk, mic.sample_rate, target_sr)
    if sys_chunk is not None:
        sys_chunk = _resample(sys_chunk, system.sample_rate, target_sr)

    if mic_chunk is None:
        return sys_chunk.astype(np.float32, copy=False)
    if sys_chunk is None:
        return mic_chunk.astype(np.float32, copy=False)

    # Align to the shorter side and mix; the longer side stays buffered
    # in its source file and is read on the next pass.
    n = min(mic_chunk.size, sys_chunk.size)
    if n == 0:
        return np.zeros(0, dtype=np.float32)
    if mic_chunk.size > n:
        # Roll the unread tail back into position so we don't lose it.
        mic.position -= int((mic_chunk.size - n) * (mic.sample_rate / target_sr)) * (
            mic.format["channels"] * (mic.format["bits_per_sample"] // 8)
        )
    elif sys_chunk.size > n:
        if system is not None:
            system.position -= int((sys_chunk.size - n) * (system.sample_rate / target_sr)) * (
                system.format["channels"] * (system.format["bits_per_sample"] // 8)
            )
    mixed = (mic_chunk[:n] + sys_chunk[:n]) * 0.5
    return mixed.astype(np.float32, copy=False)


def _resample(audio: np.ndarray, src_sr: int, dst_sr: int) -> np.ndarray:
    if src_sr == dst_sr or audio.size == 0:
        return audio
    ratio = dst_sr / src_sr
    new_len = int(round(audio.size * ratio))
    if new_len == 0:
        return np.zeros(0, dtype=np.float32)
    src_idx = np.linspace(0, audio.size - 1, new_len, dtype=np.float64)
    return np.interp(src_idx, np.arange(audio.size), audio).astype(np.float32)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
