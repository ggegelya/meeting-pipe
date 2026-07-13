"""Tests for `mp merge-meetings` (FEAT9)."""
from __future__ import annotations

import json
import sys
import types
from pathlib import Path

import pytest

from mp.config import Config, OutputCfg, Recording
from mp.markdown import render_markdown
from mp.merge_meetings import (
    GAP_TEXT,
    MergeError,
    concat_audio,
    merge_meetings,
    merge_transcripts,
)
from mp.schemas import ActionItem, MeetingSummary


def _transcript(*segs: dict, **top) -> dict:
    return {"language": "en", "backend": "fluidaudio", "segments": list(segs), **top}


def _seg(start: float, end: float, text: str, speaker: str) -> dict:
    return {"start": start, "end": end, "text": text, "speaker": speaker}


# --- merge_transcripts (pure) ---------------------------------------------

def test_merge_transcripts_offsets_and_gap_marker():
    a = _transcript(_seg(0.0, 2.0, "hello", "Me"), _seg(2.0, 4.0, "how are you", "Alice"))
    b = _transcript(_seg(0.0, 3.0, "we are back", "Me"))
    merged = merge_transcripts([a, b], [10.0, 20.0])

    segs = merged["segments"]
    # a (2) + gap (1) + b (1)
    assert len(segs) == 4
    gap = segs[2]
    assert gap["kind"] == "gap"
    assert gap["text"] == GAP_TEXT
    assert gap["start"] == 10.0 == gap["end"]
    # b's segment is offset by a's full audio duration (10s), not its transcript end (4s).
    assert segs[3]["start"] == 10.0
    assert segs[3]["end"] == 13.0
    # a's segments are untouched (offset 0).
    assert segs[0]["start"] == 0.0
    assert merged["backend"] == "fluidaudio"
    assert merged["finalized"] is True


def test_merge_transcripts_diarization_banner_only_when_all_failed():
    good = _transcript(_seg(0.0, 1.0, "x", "Me"), diarization=True)
    bad = _transcript(_seg(0.0, 1.0, "y", "Speaker?"), diarization_failed=True)
    # one good, one failed -> not a global failure
    assert merge_transcripts([good, bad], [1.0, 1.0])["diarization_failed"] is False
    # both failed -> banner
    assert merge_transcripts([bad, bad], [1.0, 1.0])["diarization_failed"] is True


def test_merge_transcripts_rejects_mismatched_counts():
    with pytest.raises(MergeError):
        merge_transcripts([_transcript()], [1.0, 2.0])


# --- render_markdown gap handling -----------------------------------------

def test_render_markdown_renders_gap_as_divider_not_speaker():
    structured = _transcript(
        _seg(0.0, 1.0, "before", "Me"),
        {"start": 1.0, "end": 1.0, "speaker": None, "text": GAP_TEXT, "kind": "gap"},
        _seg(1.0, 2.0, "after", "Me"),
    )
    md = render_markdown(structured)
    assert "---" in md
    assert f"_{GAP_TEXT}_" in md
    # The gap never becomes a speaker line or a speaker count.
    assert f"**{GAP_TEXT}**" not in md
    assert "Recording gap:" not in md.split("Speakers (segment counts)")[-1]


# --- concat_audio / verify guards (fake soundfile) ------------------------

class _FakeInfo:
    def __init__(self, samplerate: int, channels: int, frames: int, subtype: str = "PCM_16"):
        self.samplerate = samplerate
        self.channels = channels
        self.frames = frames
        self.subtype = subtype


def _install_fake_soundfile(monkeypatch, infos: dict[str, _FakeInfo]):
    fake = types.ModuleType("soundfile")
    fake.info = lambda path: infos[Path(path).name]  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "soundfile", fake)
    return fake


def test_concat_audio_rejects_format_mismatch(monkeypatch, tmp_path: Path):
    a, b = tmp_path / "a.wav", tmp_path / "b.wav"
    a.touch()
    b.touch()
    _install_fake_soundfile(monkeypatch, {
        "a.wav": _FakeInfo(16000, 2, 16000),
        "b.wav": _FakeInfo(48000, 2, 48000),  # different sample rate
    })
    with pytest.raises(MergeError, match="differs from"):
        concat_audio([a, b], tmp_path / "out.wav")


def test_verify_concat_flags_short_output(monkeypatch, tmp_path: Path):
    from mp import merge_meetings as mm

    out = tmp_path / "out.wav"
    out.touch()
    # inputs sum to 30s; merged claims only 5s -> refuse.
    _install_fake_soundfile(monkeypatch, {"out.wav": _FakeInfo(16000, 2, 16000 * 5)})
    with pytest.raises(MergeError, match="refusing to replace"):
        mm._verify_concat(out, [10.0, 20.0])


# --- merge_meetings orchestration (fake concat + fake client) -------------

def _make_summary() -> MeetingSummary:
    return MeetingSummary(
        title="Merged sync",
        summary=["Combined the two halves of the call."],
        decisions=[],
        actions=[ActionItem(task="Follow up", owner=None, confidence="low")],
        questions=[],
        attendees=["Me", "Alice"],
        detected_language="en",
    )


class _FakeClient:
    def __init__(self) -> None:
        self.calls = 0

    def summarize(self, *, system_prompt, transcript, model, max_tokens):
        self.calls += 1
        return _make_summary()


def _local_cfg(tmp_path: Path) -> Config:
    # No sinks -> publish_fanout is local-only, no network.
    return Config(output=OutputCfg(sinks=[]), recording=Recording(output_dir=tmp_path))


def _fake_concat(inputs, out_path):
    out_path.write_bytes(b"RIFFmerged")
    # one duration per input; the primary is 10s, fragment 20s.
    return [10.0 * (i + 1) for i in range(len(inputs))]


def _write_meeting(dir: Path, stem: str, *segs: dict) -> Path:
    wav = dir / f"{stem}.wav"
    wav.write_bytes(b"RIFF")
    (dir / f"{stem}.json").write_text(json.dumps(_transcript(*segs)), encoding="utf-8")
    return wav


def test_merge_meetings_produces_one_meeting(monkeypatch, tmp_path: Path):
    monkeypatch.setattr("mp.merge_meetings.concat_audio", _fake_concat)
    monkeypatch.setattr("mp.merge_meetings._verify_concat", lambda *a, **k: None)

    primary = _write_meeting(tmp_path, "20260101-0900", _seg(0.0, 2.0, "start", "Me"))
    frag = _write_meeting(tmp_path, "20260101-0930", _seg(0.0, 2.0, "back again", "Me"))

    client = _FakeClient()
    result = merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=client)

    assert client.calls == 1
    assert "publish_failed" not in result  # no sinks configured is a clean, local-only success

    merged = json.loads(primary.with_suffix(".json").read_text(encoding="utf-8"))
    assert merged["merged_from"] == ["20260101-0930"]
    assert any(s.get("kind") == "gap" for s in merged["segments"])
    # fragment segment offset by the primary's 10s audio duration
    assert merged["segments"][-1]["start"] == 10.0

    md = primary.with_suffix(".md").read_text(encoding="utf-8")
    assert GAP_TEXT in md
    assert (tmp_path / "20260101-0900.summary.json").exists()


def test_merge_meetings_is_idempotent_after_publish_failure(monkeypatch, tmp_path: Path):
    """A retry when the primary already carries the fragments must NOT concat the
    audio again (that would double the recording); it just re-publishes."""
    def _explode(*a, **k):
        raise AssertionError("concat_audio must not run on a resumed merge")

    monkeypatch.setattr("mp.merge_meetings.concat_audio", _explode)

    primary = _write_meeting(tmp_path, "20260101-0900", _seg(0.0, 2.0, "start", "Me"))
    # simulate a prior committed merge: transcript already carries the provenance
    merged = json.loads(primary.with_suffix(".json").read_text(encoding="utf-8"))
    merged["merged_from"] = ["20260101-0930"]
    primary.with_suffix(".json").write_text(json.dumps(merged), encoding="utf-8")
    primary.with_suffix(".md").write_text("# Transcript\n\n**Me**: start\n", encoding="utf-8")
    frag = _write_meeting(tmp_path, "20260101-0930", _seg(0.0, 2.0, "back", "Me"))

    client = _FakeClient()
    result = merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=client)
    assert client.calls == 1
    assert "publish_failed" not in result


def test_merge_meetings_retry_after_crash_between_commits_does_not_double_concat(
    monkeypatch, tmp_path: Path
):
    """PIPE8: the transcript carrying `merged_from` is committed BEFORE the audio
    swap. A crash in that window (the audio `os.replace` fails) still records the
    merge, so a retry takes the re-publish-only branch instead of concatenating
    the fragments a second time onto already-merged audio."""
    import mp.merge_meetings as mm

    concat_calls = {"n": 0}

    def _counting_concat(inputs, out_path):
        concat_calls["n"] += 1
        return _fake_concat(inputs, out_path)

    monkeypatch.setattr("mp.merge_meetings.concat_audio", _counting_concat)
    monkeypatch.setattr("mp.merge_meetings._verify_concat", lambda *a, **k: None)

    primary = _write_meeting(tmp_path, "20260101-0900", _seg(0.0, 2.0, "start", "Me"))
    frag = _write_meeting(tmp_path, "20260101-0930", _seg(0.0, 2.0, "back", "Me"))

    # Fail only the audio swap (dst ends in .wav), and only once, so the atomic
    # transcript writes (.json/.md) still land before the simulated crash.
    real_replace = mm.os.replace
    crashed = {"done": False}

    def _flaky_replace(src, dst):
        if str(dst).endswith(".wav") and not crashed["done"]:
            crashed["done"] = True
            raise OSError("simulated crash during the audio swap")
        return real_replace(src, dst)

    monkeypatch.setattr(mm.os, "replace", _flaky_replace)

    with pytest.raises(OSError):
        merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=_FakeClient())

    # The transcript recorded the merge despite the crash on the audio swap.
    merged = json.loads(primary.with_suffix(".json").read_text(encoding="utf-8"))
    assert merged["merged_from"] == ["20260101-0930"]
    assert concat_calls["n"] == 1

    # Retry: the guard sees merged_from and re-publishes only; no second concat.
    result = merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=_FakeClient())
    assert concat_calls["n"] == 1
    assert "publish_failed" not in result


def test_merge_meetings_requires_a_fragment(tmp_path: Path):
    primary = _write_meeting(tmp_path, "20260101-0900", _seg(0.0, 1.0, "x", "Me"))
    with pytest.raises(MergeError):
        merge_meetings(primary, [], cfg=_local_cfg(tmp_path))


# --- real audio (skipped on CI, which ships no soundfile) -----------------

def test_merge_meetings_real_audio_end_to_end(tmp_path: Path):
    """Exercise the real soundfile concat + duration verify + offset alignment,
    with no faking. Skipped where soundfile is unavailable (the Linux CI runner)."""
    sf = pytest.importorskip("soundfile")
    np = pytest.importorskip("numpy")
    sr = 16000

    def _wav(stem: str, seconds: float, *segs: dict) -> Path:
        wav = tmp_path / f"{stem}.wav"
        sf.write(str(wav), np.zeros((int(sr * seconds), 2), dtype="float32"), sr)
        (tmp_path / f"{stem}.json").write_text(json.dumps(_transcript(*segs)), encoding="utf-8")
        return wav

    primary = _wav("20260101-0900", 1.0, _seg(0.0, 0.9, "first half", "Me"))
    frag = _wav("20260101-0930", 2.0, _seg(0.0, 1.8, "second half", "Me"))

    result = merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=_FakeClient())
    assert "publish_failed" not in result

    # Continuous audio: the primary is now the 3s concatenation.
    assert sf.info(str(primary)).frames == sr * 3
    merged = json.loads(primary.with_suffix(".json").read_text(encoding="utf-8"))
    # The fragment's segment is offset by the primary's real 1.0s audio duration.
    last = merged["segments"][-1]
    assert last["text"] == "second half"
    assert last["start"] == pytest.approx(1.0, abs=0.01)
    assert (tmp_path / "20260101-0900.summary.json").exists()
