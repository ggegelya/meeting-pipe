"""Tests for the streaming transcribe sidecar — covers the file-tailing
header parser, the chunk-flushing state machine, and the orchestrator's
streamed-transcript handoff. Heavy ASR paths stay mocked."""
from __future__ import annotations

import json
import struct
from pathlib import Path

import numpy as np

from mp.transcribe_stream import (
    CHUNK_SECONDS,
    OVERLAP_SECONDS,
    TARGET_SR,
    StreamState,
    _GrowingWavReader,
    _absorb_segments,
    _maybe_flush_chunks,
    _resample,
    _write_outputs,
)


# --- WAV header parsing ------------------------------------------------------


def _write_wav_header(buf: bytearray, *, channels: int, sample_rate: int, bps: int, fmt_code: int) -> None:
    """Minimal canonical 44-byte WAV header. Data size is left at zero
    (matches the daemon's growing-file behavior)."""
    byte_rate = sample_rate * channels * (bps // 8)
    block_align = channels * (bps // 8)
    buf += b"RIFF"
    buf += struct.pack("<I", 36)  # chunk size — will be wrong, that's the point
    buf += b"WAVE"
    buf += b"fmt "
    buf += struct.pack("<I", 16)
    buf += struct.pack("<H", fmt_code)
    buf += struct.pack("<H", channels)
    buf += struct.pack("<I", sample_rate)
    buf += struct.pack("<I", byte_rate)
    buf += struct.pack("<H", block_align)
    buf += struct.pack("<H", bps)
    buf += b"data"
    buf += struct.pack("<I", 0)  # data size 0 — file is still being written


def _make_int16_pcm(samples: np.ndarray, channels: int) -> bytes:
    """Pack a mono float-in-[-1, 1] array into interleaved int16 PCM bytes
    of `channels` channels (duplicating the same content per channel —
    fine for tests)."""
    int_data = (samples * 32767).astype("<i2")
    if channels == 1:
        return int_data.tobytes()
    interleaved = np.repeat(int_data, channels)
    return interleaved.tobytes()


def test_wav_reader_parses_header_and_decodes_int16(tmp_path: Path):
    wav = tmp_path / "mic.wav"
    buf = bytearray()
    _write_wav_header(buf, channels=1, sample_rate=16000, bps=16, fmt_code=1)
    samples = np.linspace(-0.5, 0.5, 1600, dtype=np.float32)  # 0.1 s of audio
    buf += _make_int16_pcm(samples, channels=1)
    wav.write_bytes(buf)

    reader = _GrowingWavReader(wav)
    out = reader.read_new()
    assert out is not None
    assert out.dtype == np.float32
    assert out.size == 1600
    # Round-trip precision through int16 is ~3e-5; 1e-3 is plenty of margin.
    assert np.allclose(out, samples, atol=1e-3)
    # Second call returns nothing (no growth).
    assert reader.read_new() is None


def test_wav_reader_picks_up_appended_data(tmp_path: Path):
    """The whole point: simulate the daemon writing more samples after
    we've already consumed the existing data."""
    wav = tmp_path / "growing.wav"
    buf = bytearray()
    _write_wav_header(buf, channels=1, sample_rate=16000, bps=16, fmt_code=1)
    first = np.zeros(800, dtype=np.float32)
    buf += _make_int16_pcm(first, channels=1)
    wav.write_bytes(buf)

    reader = _GrowingWavReader(wav)
    a = reader.read_new()
    assert a is not None and a.size == 800

    # Daemon appends another 800 samples.
    second = np.ones(800, dtype=np.float32) * 0.25
    with wav.open("ab") as f:
        f.write(_make_int16_pcm(second, channels=1))

    b = reader.read_new()
    assert b is not None and b.size == 800
    assert np.allclose(b, second, atol=1e-3)


def test_wav_reader_mixes_stereo_to_mono(tmp_path: Path):
    """Mic is typically 48 kHz stereo; we mix-down on read so callers
    don't have to think about channel layout downstream."""
    wav = tmp_path / "stereo.wav"
    buf = bytearray()
    _write_wav_header(buf, channels=2, sample_rate=48000, bps=16, fmt_code=1)
    n = 100
    left = np.full(n, 0.5, dtype=np.float32)
    right = np.full(n, -0.5, dtype=np.float32)
    interleaved = np.empty(2 * n, dtype="<i2")
    interleaved[0::2] = (left * 32767).astype("<i2")
    interleaved[1::2] = (right * 32767).astype("<i2")
    buf += interleaved.tobytes()
    wav.write_bytes(buf)

    out = _GrowingWavReader(wav).read_new()
    assert out is not None
    assert out.size == n
    # 0.5 + (-0.5) averaged = 0 (within int16 quantization noise).
    assert np.allclose(out, 0, atol=1e-3)


def test_wav_reader_handles_missing_file(tmp_path: Path):
    """The system audio path may not exist when Screen Recording is
    denied. The reader must NOT crash — return None until the file
    appears (which it never will in that case)."""
    reader = _GrowingWavReader(tmp_path / "absent.wav")
    assert reader.read_new() is None
    assert reader.read_new() is None  # still safe on repeated polls


def test_wav_reader_handles_partial_header(tmp_path: Path):
    """The file may be observed mid-write with fewer than 44 header
    bytes. Don't crash; just defer until next poll."""
    wav = tmp_path / "partial.wav"
    wav.write_bytes(b"RIFF" + b"\x00" * 10)
    reader = _GrowingWavReader(wav)
    assert reader.read_new() is None


def _write_avaudio_style_wav(
    buf: bytearray,
    *,
    channels: int,
    sample_rate: int,
    bps: int,
    fmt_code: int,
    junk_size: int = 28,
    fllr_size: int = 4008,
) -> None:
    """Mirror Apple AVAudioFile's on-disk layout:

        RIFF / WAVE
        JUNK chunk (padding placeholder)
        fmt  chunk (16-byte PCM/Float fmt body)
        FLLR chunk (filler so data sits on a 4 KB boundary)
        data chunk (size 0; caller appends PCM bytes after).

    This is the layout that broke the previous `HEADER_SIZE = 44`
    reader: bytes 20-44 of this layout fall inside JUNK, not fmt.
    """
    byte_rate = sample_rate * channels * (bps // 8)
    block_align = channels * (bps // 8)
    buf += b"RIFF"
    buf += struct.pack("<I", 0)  # RIFF size; stale during growth
    buf += b"WAVE"
    # JUNK chunk
    buf += b"JUNK"
    buf += struct.pack("<I", junk_size)
    buf += b"\x00" * junk_size
    # fmt chunk
    buf += b"fmt "
    buf += struct.pack("<I", 16)
    buf += struct.pack("<H", fmt_code)
    buf += struct.pack("<H", channels)
    buf += struct.pack("<I", sample_rate)
    buf += struct.pack("<I", byte_rate)
    buf += struct.pack("<H", block_align)
    buf += struct.pack("<H", bps)
    # FLLR padding chunk
    buf += b"FLLR"
    buf += struct.pack("<I", fllr_size)
    buf += b"\x00" * fllr_size
    # data chunk header (no payload yet)
    buf += b"data"
    buf += struct.pack("<I", 0)


def test_wav_reader_handles_avaudio_layout(tmp_path: Path):
    """AVAudioFile (the daemon's writer) emits RIFF / JUNK / fmt /
    FLLR / data instead of a flat 44-byte PCM header. The reader must
    walk chunks to find `data` rather than assuming a fixed offset;
    otherwise it parses fmt fields out of the JUNK chunk's zeros and
    bytes_per_frame ends up 0, which is the exact failure mode that
    silently turned every streaming run into segments=[]."""
    wav = tmp_path / "avaudio.wav"
    buf = bytearray()
    _write_avaudio_style_wav(buf, channels=1, sample_rate=48000, bps=32, fmt_code=3)
    samples = np.linspace(-0.4, 0.4, 4800, dtype=np.float32)  # 0.1 s @ 48 kHz
    buf += samples.astype("<f4").tobytes()
    wav.write_bytes(buf)

    reader = _GrowingWavReader(wav)
    out = reader.read_new()
    assert out is not None, "reader returned None on AVAudioFile layout"
    assert out.dtype == np.float32
    assert out.size == 4800
    assert np.allclose(out, samples, atol=1e-5)
    assert reader.sample_rate == 48000

    # Appended frames are picked up on the next poll, same as the
    # flat-header case but using data_start instead of HEADER_SIZE.
    more = np.full(2400, 0.1, dtype=np.float32)
    with wav.open("ab") as f:
        f.write(more.astype("<f4").tobytes())
    second = reader.read_new()
    assert second is not None and second.size == 2400
    assert np.allclose(second, more, atol=1e-5)


def test_wav_reader_avaudio_layout_with_missing_data_chunk(tmp_path: Path):
    """Mid-write the file may have JUNK + fmt + FLLR but no data chunk
    yet (the daemon's recorder is still flushing). Reader must return
    None and retry on next poll, not crash."""
    wav = tmp_path / "pre-data.wav"
    buf = bytearray()
    # Write everything except the data chunk header.
    byte_rate = 48000 * 1 * (32 // 8)
    buf += b"RIFF" + struct.pack("<I", 0) + b"WAVE"
    buf += b"JUNK" + struct.pack("<I", 28) + b"\x00" * 28
    buf += b"fmt " + struct.pack("<I", 16)
    buf += struct.pack("<H", 3) + struct.pack("<H", 1)
    buf += struct.pack("<I", 48000) + struct.pack("<I", byte_rate)
    buf += struct.pack("<H", 4) + struct.pack("<H", 32)
    wav.write_bytes(buf)

    reader = _GrowingWavReader(wav)
    assert reader.read_new() is None


# --- Resampling --------------------------------------------------------------


def test_resample_passthrough_at_same_rate():
    arr = np.arange(100, dtype=np.float32)
    out = _resample(arr, 16000, 16000)
    assert out is arr or np.array_equal(out, arr)


def test_resample_3to1_decimation_preserves_shape():
    """48 kHz → 16 kHz is exact 3:1; the output length should be 1/3."""
    arr = np.arange(900, dtype=np.float32)
    out = _resample(arr, 48000, 16000)
    assert out.size == 300


# --- Chunk flushing state machine --------------------------------------------


def _state(language: str | None = None) -> StreamState:
    return StreamState(
        stem="20260506-1430",
        out_dir=Path("/tmp/_unused"),
        language=language,
        model="mlx-community/whisper-large-v3-turbo",
        fallback_model="large-v3",
    )


def test_flush_does_not_fire_below_chunk_size():
    """Don't pay an mlx-whisper inference cost on a trickle of audio."""
    state = _state()
    state.buffer = np.zeros(int(5 * TARGET_SR), dtype=np.float32)  # 5 s

    called = {"n": 0}

    def fake_transcribe(s, chunk, offset):  # noqa: ARG001
        called["n"] += 1

    import mp.transcribe_stream as ts
    orig = ts._transcribe_chunk
    ts._transcribe_chunk = fake_transcribe
    try:
        _maybe_flush_chunks(state, force=False)
    finally:
        ts._transcribe_chunk = orig

    assert called["n"] == 0
    # Buffer untouched.
    assert state.buffer.size == int(5 * TARGET_SR)


def test_flush_fires_on_full_chunk_and_keeps_overlap():
    """Once we've buffered 30 s, run mlx-whisper once and retain the
    last 5 s as overlap context for the next chunk."""
    state = _state()
    state.buffer = np.zeros(int(CHUNK_SECONDS * TARGET_SR), dtype=np.float32)

    chunks: list[tuple[int, float]] = []

    def fake_transcribe(s, chunk, offset):
        chunks.append((chunk.size, offset))

    import mp.transcribe_stream as ts
    orig = ts._transcribe_chunk
    ts._transcribe_chunk = fake_transcribe
    try:
        _maybe_flush_chunks(state, force=False)
    finally:
        ts._transcribe_chunk = orig

    assert len(chunks) == 1
    assert chunks[0][0] == int(CHUNK_SECONDS * TARGET_SR)
    # Buffer retains the OVERLAP_SECONDS tail and advances buffer_start.
    assert state.buffer.size == int(OVERLAP_SECONDS * TARGET_SR)
    assert state.buffer_start == CHUNK_SECONDS - OVERLAP_SECONDS


def test_flush_force_drains_residual_tail():
    """At shutdown we must process whatever's left in the buffer even
    if it's shorter than a full chunk — otherwise the last few seconds
    of the meeting are dropped from the transcript."""
    state = _state()
    state.buffer = np.zeros(int(7 * TARGET_SR), dtype=np.float32)  # 7 s

    fired = {"n": 0}

    def fake_transcribe(s, chunk, offset):  # noqa: ARG001
        fired["n"] += 1

    import mp.transcribe_stream as ts
    orig = ts._transcribe_chunk
    ts._transcribe_chunk = fake_transcribe
    try:
        _maybe_flush_chunks(state, force=True)
    finally:
        ts._transcribe_chunk = orig

    assert fired["n"] >= 1
    assert state.buffer.size == 0


# --- Segment absorption ------------------------------------------------------


def test_absorb_segments_offsets_timestamps_to_global_clock():
    """mlx-whisper produces chunk-relative timestamps. The streamer must
    add the buffer offset so the joined transcript times match the wall
    clock — diarization later assumes the same time base."""
    state = _state()
    raw = [
        {"start": 0.0, "end": 1.0, "text": "Hi.",
         "words": [{"word": "Hi.", "start": 0.0, "end": 1.0}]},
        {"start": 2.0, "end": 3.5, "text": "There.", "words": []},
    ]
    _absorb_segments(state, raw, offset=30.0)
    assert len(state.segments) == 2
    assert state.segments[0]["start"] == 30.0
    assert state.segments[0]["end"] == 31.0
    assert state.segments[1]["start"] == 32.0
    assert state.segments[0]["words"][0]["start"] == 30.0


def test_absorb_segments_drops_overlap_duplicates():
    """When we keep 5 s of overlap, the next chunk's first segment can
    overlap the previous chunk's last segment. Drop those duplicates so
    the joined transcript doesn't repeat words at every chunk boundary."""
    state = _state()
    state.segments = [
        {"start": 25.0, "end": 30.0, "text": "First chunk tail."},
    ]
    new = [
        # Overlap with previous tail — drop.
        {"start": 0.5, "end": 4.5, "text": "First chunk tail."},
        # New content.
        {"start": 5.0, "end": 7.0, "text": "Second chunk."},
    ]
    _absorb_segments(state, new, offset=25.0)
    # Originally one + one new (the 5.0+25.0=30.0 segment, which lines up).
    assert len(state.segments) == 2
    assert state.segments[1]["start"] == 30.0
    assert state.segments[1]["text"] == "Second chunk."


# --- Output finalization -----------------------------------------------------


def test_write_outputs_emits_streaming_marker(tmp_path: Path):
    """The orchestrator distinguishes a streaming transcript from a
    pre-streaming offline one by the `streaming: true` field. Without
    that flag the at-stop path can't tell whether to skip transcribe."""
    state = _state()
    state.out_dir = tmp_path
    state.detected_language = "en"
    state.segments = [
        {"start": 0.0, "end": 1.0, "text": "Hi."},
        {"start": 1.0, "end": 2.0, "text": "There."},
    ]
    _write_outputs(state)

    json_path = tmp_path / f"{state.stem}.json"
    md_path = tmp_path / f"{state.stem}.md"
    assert json_path.exists()
    assert md_path.exists()

    data = json.loads(json_path.read_text(encoding="utf-8"))
    assert data["streaming"] is True
    assert data["language"] == "en"
    assert len(data["segments"]) == 2
    # The MD should not have a diarization-failed warning banner — that
    # belongs to the at-stop diarize step, which hasn't run yet.
    md = md_path.read_text(encoding="utf-8")
    assert "Diarization failed" not in md
