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


# PIPE48: a file-driven fake soundfile. An audio "file" is the bytes `WAV<seconds>`,
# so the real `_verify_concat` and the resume logic run with no codec, and a test
# can compare the primary's bytes to the audio it should now hold.

def _wav_seconds(path: Path) -> float:
    return float(path.read_bytes()[3:].decode())


def _put_wav(path: Path, seconds: float) -> Path:
    path.write_bytes(f"WAV{float(seconds)}".encode())
    return path


def _install_wav_fakes(monkeypatch, counter: dict | None = None) -> None:
    fake = types.ModuleType("soundfile")
    fake.info = lambda path: _FakeInfo(1000, 2, int(_wav_seconds(Path(path)) * 1000))  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "soundfile", fake)

    def _concat(inputs, out_path):
        if counter is not None:
            counter["n"] = counter.get("n", 0) + 1
        durations = [_wav_seconds(p) for p in inputs]
        _put_wav(out_path, sum(durations))
        return durations

    monkeypatch.setattr("mp.merge_meetings.concat_audio", _concat)


def _gap_seg(at: float) -> dict:
    return {"start": at, "end": at, "speaker": None, "text": GAP_TEXT, "kind": "gap"}


def _two_meetings(tmp_path: Path, primary_s: float = 10.0, frag_s: float = 20.0):
    primary = _write_meeting(tmp_path, "20260101-0900", _seg(0.0, 2.0, "start", "Me"))
    frag = _write_meeting(tmp_path, "20260101-0930", _seg(0.0, 2.0, "back", "Me"))
    _put_wav(primary, primary_s)
    _put_wav(frag, frag_s)
    return primary, frag


def _commit_merged_transcript(primary: Path, primary_s: float = 10.0) -> None:
    """The transcript a merge that crashed after its first commit leaves behind."""
    jp = primary.with_suffix(".json")
    t = json.loads(jp.read_text(encoding="utf-8"))
    t["merged_from"] = ["20260101-0930"]
    t["segments"] = [*t["segments"], _gap_seg(primary_s),
                     {**_seg(primary_s, primary_s + 2.0, "back", "Me")}]
    jp.write_text(json.dumps(t), encoding="utf-8")


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
    """A retry when the primary already carries the fragments AND already holds the
    merged audio must NOT concat again (that would double the recording); it just
    re-renders the markdown and re-publishes."""
    counter: dict = {}
    _install_wav_fakes(monkeypatch, counter)

    primary, frag = _two_meetings(tmp_path)
    _commit_merged_transcript(primary)
    _put_wav(primary, 30.0)  # a prior run fully swapped the audio, then failed at publish
    primary.with_suffix(".md").write_text("# stale\n", encoding="utf-8")

    client = _FakeClient()
    result = merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=client)
    assert client.calls == 1
    assert counter.get("n", 0) == 0
    assert "publish_failed" not in result
    assert _wav_seconds(primary) == 30.0
    assert GAP_TEXT in primary.with_suffix(".md").read_text(encoding="utf-8")


def test_merge_meetings_retry_after_crash_between_commits_does_not_double_concat(
    monkeypatch, tmp_path: Path
):
    """PIPE8 + PIPE48 (F116): the transcript carrying `merged_from` is committed
    BEFORE the audio swap. A crash in that window leaves the verified temp, and the
    retry finishes the swap from it: one concat, the primary holds the merged
    audio (not part one), and no temp is left behind."""
    import mp.merge_meetings as mm

    counter: dict = {}
    _install_wav_fakes(monkeypatch, counter)
    primary, frag = _two_meetings(tmp_path)
    tmp_file = primary.with_name(primary.name + ".merging.tmp")

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

    merged = json.loads(primary.with_suffix(".json").read_text(encoding="utf-8"))
    assert merged["merged_from"] == ["20260101-0930"]
    assert _wav_seconds(primary) == 10.0  # still part one
    assert tmp_file.exists()  # the verified merged audio is kept for the resume
    assert counter["n"] == 1

    result = merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=_FakeClient())
    assert "publish_failed" not in result
    assert counter["n"] == 1  # no second concat
    assert primary.read_bytes() == b"WAV30.0"  # the merged audio, not part one
    assert not tmp_file.exists()


def test_merge_meetings_resumes_after_the_markdown_write_fails(monkeypatch, tmp_path: Path):
    """PIPE48: the JSON commit succeeds, then the markdown write raises. The retry
    re-renders `<stem>.md` from the committed JSON (gap divider included) and swaps
    the audio in; the publishers never see the primary's old part-one markdown."""
    import mp.merge_meetings as mm

    _install_wav_fakes(monkeypatch)
    primary, frag = _two_meetings(tmp_path)
    primary.with_suffix(".md").write_text("# part one only\n", encoding="utf-8")

    real_write = mm.storage.atomic_write_text
    failed = {"done": False}

    def _flaky_write(path, text, *a, **k):
        if str(path).endswith(".md") and not failed["done"]:
            failed["done"] = True
            raise OSError("disk full")
        return real_write(path, text, *a, **k)

    monkeypatch.setattr(mm.storage, "atomic_write_text", _flaky_write)
    with pytest.raises(OSError):
        merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=_FakeClient())
    assert "part one only" in primary.with_suffix(".md").read_text(encoding="utf-8")

    merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=_FakeClient())
    md = primary.with_suffix(".md").read_text(encoding="utf-8")
    assert GAP_TEXT in md and "part one only" not in md
    assert primary.read_bytes() == b"WAV30.0"
    assert not primary.with_name(primary.name + ".merging.tmp").exists()


def test_merge_meetings_resume_with_short_primary_and_no_temp_refuses(
    monkeypatch, tmp_path: Path, capsys
):
    """PIPE48: `merged_from` is recorded but the primary is still part one and no
    merged audio is left. The retry must not publish and exit 0 (the daemon would
    then trash the fragments): it fails with exit 1 and touches nothing."""
    import mp.merge_meetings as mm

    _install_wav_fakes(monkeypatch)
    primary, frag = _two_meetings(tmp_path)
    _commit_merged_transcript(primary)
    before = {p: p.read_bytes() for p in tmp_path.iterdir()}

    with pytest.raises(MergeError, match="no merged audio is left"):
        merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=_FakeClient())
    assert {p: p.read_bytes() for p in tmp_path.iterdir()} == before

    monkeypatch.setattr(mm.entry, "prepare", lambda cfg, audio: _local_cfg(tmp_path))
    assert mm.main([str(primary), str(frag)]) == 1
    assert "merge failed" in capsys.readouterr().err
    assert {p: p.read_bytes() for p in tmp_path.iterdir()} == before


def test_merge_meetings_resume_rejects_a_leftover_temp_that_fails_verification(
    monkeypatch, tmp_path: Path
):
    """A leftover temp of the wrong length is never swapped in, and is removed."""
    _install_wav_fakes(monkeypatch)
    primary, frag = _two_meetings(tmp_path)
    _commit_merged_transcript(primary)
    tmp_file = primary.with_name(primary.name + ".merging.tmp")
    _put_wav(tmp_file, 12.0)  # a truncated concat

    with pytest.raises(MergeError, match="refusing to replace"):
        merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=_FakeClient())
    assert primary.read_bytes() == b"WAV10.0"
    assert not tmp_file.exists()


def test_merge_meetings_resume_catches_a_short_fragment_on_a_long_call(
    monkeypatch, tmp_path: Path
):
    """PIPE48: a 20 s fragment rejoined to a one-hour call is under 1% of the whole,
    so a percentage slack would call the part-one primary full length."""
    _install_wav_fakes(monkeypatch)
    primary, frag = _two_meetings(tmp_path, primary_s=3600.0, frag_s=20.0)
    _commit_merged_transcript(primary, primary_s=3600.0)
    with pytest.raises(MergeError, match="no merged audio is left"):
        merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=_FakeClient())


def test_merge_meetings_resume_with_two_fragments_swaps_the_temp(monkeypatch, tmp_path: Path):
    """The expected length comes from the LAST gap marker plus the last fragment, so
    pin it with two fragments: a crash at the swap, then a retry."""
    import mp.merge_meetings as mm

    counter: dict = {}
    _install_wav_fakes(monkeypatch, counter)
    primary, frag1 = _two_meetings(tmp_path)
    frag2 = _write_meeting(tmp_path, "20260101-1000", _seg(0.0, 2.0, "third", "Me"))
    _put_wav(frag2, 5.0)

    real_replace = mm.os.replace
    crashed = {"done": False}

    def _flaky_replace(src, dst):
        if str(dst).endswith(".wav") and not crashed["done"]:
            crashed["done"] = True
            raise OSError("simulated crash during the audio swap")
        return real_replace(src, dst)

    monkeypatch.setattr(mm.os, "replace", _flaky_replace)
    with pytest.raises(OSError):
        merge_meetings(primary, [frag1, frag2], cfg=_local_cfg(tmp_path), client=_FakeClient())
    merge_meetings(primary, [frag1, frag2], cfg=_local_cfg(tmp_path), client=_FakeClient())
    assert counter["n"] == 1
    assert primary.read_bytes() == b"WAV35.0"
    assert not primary.with_name(primary.name + ".merging.tmp").exists()


def test_merge_meetings_refuses_before_writing_when_disk_is_short(monkeypatch, tmp_path: Path):
    """PIPE48: too little free space on the primary's volume raises MergeError
    before the temp or any transcript is written."""
    counter: dict = {}
    _install_wav_fakes(monkeypatch, counter)
    primary, frag = _two_meetings(tmp_path)
    before = {p: p.read_bytes() for p in tmp_path.iterdir()}
    monkeypatch.setattr("mp.merge_meetings.storage.free_bytes", lambda path: 1024)

    with pytest.raises(MergeError, match="free disk space"):
        merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=_FakeClient())
    assert counter.get("n", 0) == 0
    assert {p: p.read_bytes() for p in tmp_path.iterdir()} == before


@pytest.mark.parametrize("fail_at", ["merge_transcripts", "json_commit"])
def test_merge_meetings_failure_after_concat_leaves_no_temp(
    monkeypatch, tmp_path: Path, fail_at: str
):
    """PIPE48: anything failing after the concat but before the transcript commit
    deletes the temp (a copy of every input) instead of orphaning it."""
    import mp.merge_meetings as mm

    _install_wav_fakes(monkeypatch)
    primary, frag = _two_meetings(tmp_path)
    if fail_at == "merge_transcripts":
        monkeypatch.setattr(mm, "merge_transcripts",
                            lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
    else:
        real_write = mm.storage.atomic_write_text

        def _write(path, text, *a, **k):
            if str(path).endswith(".json"):
                raise OSError("disk full")
            return real_write(path, text, *a, **k)

        monkeypatch.setattr(mm.storage, "atomic_write_text", _write)

    with pytest.raises(Exception):
        merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=_FakeClient())
    assert not primary.with_name(primary.name + ".merging.tmp").exists()
    assert primary.read_bytes() == b"WAV10.0"
    assert "merged_from" not in json.loads(primary.with_suffix(".json").read_text(encoding="utf-8"))


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


# --- PIPE47: labels, overlays, markers and voiceprints ---------------------

def _jw(path: Path, obj) -> Path:
    path.write_text(json.dumps(obj), encoding="utf-8")
    return path


def _meeting_with(dir: Path, stem: str, seconds: float, *segs: dict) -> Path:
    wav = _write_meeting(dir, stem, *segs)
    return _put_wav(wav, seconds)


def _merged_json(primary: Path) -> dict:
    return json.loads(primary.with_suffix(".json").read_text(encoding="utf-8"))


def test_fragment_label_maps_renumber_only_per_recording_labels():
    from mp.merge_meetings import fragment_label_maps

    primary = _transcript(_seg(0, 1, "a", "THEM-A"), _seg(1, 2, "b", "THEM-B"),
                          _seg(2, 3, "c", "Me"))
    frag1 = _transcript(_seg(0, 1, "d", "THEM-A"), _seg(1, 2, "e", "speaker_1"),
                        _seg(2, 3, "f", "Me"), _seg(3, 4, "g", "Alice"),
                        _seg(4, 5, "h", "speaker_unknown"), _seg(5, 6, "i", "speaker_user"))
    frag2 = _transcript(_seg(0, 1, "j", "THEM-B"), _seg(1, 2, "k", "THEM-A"))
    maps = fragment_label_maps([primary, frag1, frag2])
    assert maps[0] == {}
    # the owner, a named person, and the channel/catch-all labels are one label everywhere
    assert maps[1] == {"THEM-A": "THEM-C", "speaker_1": "speaker_1-f1"}
    # numbering continues, in order of first speech within the fragment
    assert maps[2] == {"THEM-B": "THEM-D", "THEM-A": "THEM-E"}


def test_fragment_label_maps_continue_past_z():
    from mp.diarize import them_label
    from mp.merge_meetings import fragment_label_maps

    primary = _transcript(*[_seg(i, i + 1, "x", them_label(i)) for i in range(27)])
    frag = _transcript(_seg(0, 1, "y", "THEM-A"))
    assert fragment_label_maps([primary, frag])[1] == {"THEM-A": "THEM-AB"}


def test_merge_keeps_two_voices_with_the_same_them_label_apart(monkeypatch, tmp_path: Path):
    """Each recording's THEM-A is whoever spoke first in it. After the merge they are
    two labels, so the primary's name for THEM-A names only the primary's segments."""
    _install_wav_fakes(monkeypatch)
    primary = _meeting_with(tmp_path, "20260101-0900", 10.0,
                            _seg(0, 2, "hello", "THEM-A"), _seg(2, 4, "hi", "Me"))
    frag = _meeting_with(tmp_path, "20260101-0930", 20.0,
                         _seg(0, 2, "back", "THEM-A"), _seg(2, 4, "yes", "Me"))
    _jw(primary.with_suffix(".speaker_labels.json"), {"labels": {"THEM-A": "Pat"}})

    merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=_FakeClient())
    merged = _merged_json(primary)
    speakers = [s["speaker"] for s in merged["segments"] if s.get("kind") != "gap"]
    assert speakers == ["THEM-A", "Me", "THEM-B", "Me"]

    from mp import speaker_overlay
    shown = speaker_overlay.apply_overlay(
        merged["segments"], speaker_overlay.read_overlay(primary.with_suffix(".md")))
    assert shown
    named = [s["speaker"] for s in merged["segments"] if s.get("kind") != "gap"]
    assert named == ["Pat", "Me", "THEM-B", "Me"]


def test_merge_bakes_the_fragments_names_and_text_corrections(monkeypatch, tmp_path: Path):
    _install_wav_fakes(monkeypatch)
    primary = _meeting_with(tmp_path, "20260101-0900", 10.0, _seg(0, 2, "start", "Me"))
    frag = _meeting_with(tmp_path, "20260101-0930", 20.0,
                         _seg(0, 2, "the Acme deal", "THEM-A"), _seg(2, 4, "ok", "THEM-B"))
    _jw(frag.with_suffix(".speaker_labels.json"), {"labels": {"THEM-A": "Bob"}})
    _jw(frag.with_suffix(".transcript_corrections.json"), {
        "schema_version": 1,
        "segments": [{"index": 0, "original_text": "the Acme deal", "edited_text": "the ACME deal"}],
    })

    merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=_FakeClient())
    segs = [s for s in _merged_json(primary)["segments"] if s.get("kind") != "gap"]
    assert (segs[1]["speaker"], segs[1]["text"]) == ("Bob", "the ACME deal")
    assert segs[2]["speaker"] == "THEM-A"  # its only unnamed voice, and the primary has no THEM label to clear
    md = primary.with_suffix(".md").read_text(encoding="utf-8")
    assert "Bob" in md and "the ACME deal" in md


def test_merge_refuses_when_a_fragments_overlay_cannot_be_read(monkeypatch, tmp_path: Path):
    _install_wav_fakes(monkeypatch)
    primary = _meeting_with(tmp_path, "20260101-0900", 10.0, _seg(0, 2, "start", "Me"))
    frag = _meeting_with(tmp_path, "20260101-0930", 20.0, _seg(0, 2, "back", "Me"))
    frag.with_suffix(".speaker_labels.json").write_text("{not json", encoding="utf-8")
    before = {p: p.read_bytes() for p in tmp_path.iterdir()}

    with pytest.raises(Exception, match="speaker names"):
        merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=_FakeClient())
    assert {p: p.read_bytes() for p in tmp_path.iterdir()} == before


def test_merge_carries_flagged_moments_shifted_by_the_audio_offset(monkeypatch, tmp_path: Path):
    from mp.markers import flagged_moments_block

    _install_wav_fakes(monkeypatch)
    primary = _meeting_with(tmp_path, "20260101-0900", 10.0, _seg(0, 4, "opening point", "Me"))
    frag = _meeting_with(tmp_path, "20260101-0930", 20.0,
                         _seg(0, 4, "budget is approved", "Me"), _seg(10, 14, "ship in March", "Me"))
    _jw(primary.with_suffix(".markers.json"), {"schema_version": 1, "markers": [{"t_seconds": 1.0}]})
    _jw(frag.with_suffix(".markers.json"),
        {"schema_version": 1, "markers": [{"t_seconds": 1.0}, {"t_seconds": 11.0}]})

    merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=_FakeClient())
    got = json.loads(primary.with_suffix(".markers.json").read_text(encoding="utf-8"))
    assert [m["t_seconds"] for m in got["markers"]] == [1.0, 11.0, 21.0]
    block = flagged_moments_block(primary.with_suffix(".md")) or ""
    assert "opening point" in block and "budget is approved" in block and "ship in March" in block


def test_merge_carries_voiceprints_under_the_mapped_labels(monkeypatch, tmp_path: Path):
    _install_wav_fakes(monkeypatch)
    primary = _meeting_with(tmp_path, "20260101-0900", 10.0,
                            _seg(0, 2, "a", "THEM-A"), _seg(2, 4, "b", "Me"))
    frag = _meeting_with(tmp_path, "20260101-0930", 20.0,
                         _seg(0, 2, "c", "THEM-A"), _seg(2, 4, "d", "THEM-B"), _seg(4, 6, "e", "Me"))
    _jw(primary.with_suffix(".embeddings.json"),
        {"schema_version": 2, "embeddings": {"THEM-A": [1.0], "Me": [0.5]}, "near_misses": {"THEM-A": "Pat"}})
    _jw(frag.with_suffix(".embeddings.json"),
        {"schema_version": 2, "embeddings": {"THEM-A": [2.0], "THEM-B": [3.0], "Me": [9.0]}})
    # the fragment's Library rename of THEM-B: its voiceprint follows the name
    _jw(frag.with_suffix(".speaker_labels.json"), {"labels": {"THEM-B": "Bob"}})

    merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=_FakeClient())
    got = json.loads(primary.with_suffix(".embeddings.json").read_text(encoding="utf-8"))
    assert got["embeddings"] == {"THEM-A": [1.0], "Me": [0.5], "THEM-B": [2.0], "Bob": [3.0]}
    assert got["near_misses"] == {"THEM-A": "Pat"}  # the primary's own record is untouched


def test_carrying_sidecars_twice_adds_nothing(monkeypatch, tmp_path: Path):
    """A crash before the transcript commit re-runs the merge, so the carry must be
    idempotent: no duplicated marker, no overwritten voiceprint."""
    import mp.merge_meetings as mm

    primary = _meeting_with(tmp_path, "20260101-0900", 10.0, _seg(0, 4, "x", "Me"))
    frag = _meeting_with(tmp_path, "20260101-0930", 20.0, _seg(0, 4, "y", "THEM-A"))
    _jw(frag.with_suffix(".markers.json"), {"schema_version": 1, "markers": [{"t_seconds": 1.0}]})
    _jw(frag.with_suffix(".embeddings.json"), {"schema_version": 2, "embeddings": {"THEM-A": [2.0]}})
    structured = [_read_json(primary), _read_json(frag)]

    mm._carry_sidecars(primary, [frag], structured, [10.0, 20.0])
    first = {p.name: p.read_bytes() for p in tmp_path.iterdir()}
    mm._carry_sidecars(primary, [frag], structured, [10.0, 20.0])
    assert {p.name: p.read_bytes() for p in tmp_path.iterdir()} == first


def _read_json(wav: Path) -> dict:
    return json.loads(wav.with_suffix(".json").read_text(encoding="utf-8"))


def test_merge_refuses_before_writing_when_a_carried_sidecar_is_unreadable(monkeypatch, tmp_path: Path):
    """An unreadable primary markers file is not an empty one: refuse, write nothing."""
    _install_wav_fakes(monkeypatch)
    primary = _meeting_with(tmp_path, "20260101-0900", 10.0, _seg(0, 2, "start", "Me"))
    frag = _meeting_with(tmp_path, "20260101-0930", 20.0, _seg(0, 2, "back", "Me"))
    _jw(frag.with_suffix(".markers.json"), {"schema_version": 1, "markers": [{"t_seconds": 1.0}]})
    primary.with_suffix(".embeddings.json").write_text("[1]", encoding="utf-8")
    primary.with_suffix(".markers.json").write_text("{broken", encoding="utf-8")
    before = {p: p.read_bytes() for p in tmp_path.iterdir()}

    with pytest.raises(MergeError, match="cannot be read"):
        merge_meetings(primary, [frag], cfg=_local_cfg(tmp_path), client=_FakeClient())
    assert {p: p.read_bytes() for p in tmp_path.iterdir()} == before


def test_a_merged_transcript_keeps_the_speaker_fallback_only_when_every_fragment_agrees_DIAR8():
    def frag(fallback):
        return {**_transcript(_seg(0.0, 1.0, "x", "speaker_user"), diarization_failed=True),
                **({"speaker_fallback": fallback} if fallback else {})}

    same = merge_transcripts([frag("channel"), frag("channel")], [1.0, 1.0])
    mixed = merge_transcripts([frag("channel"), frag("none")], [1.0, 1.0])
    healthy = merge_transcripts([{**frag("channel"), "diarization_failed": False}, frag("channel")], [1.0, 1.0])

    assert same["speaker_fallback"] == "channel"
    assert "speaker_fallback" not in mixed
    assert "speaker_fallback" not in healthy


def test_a_merge_writes_the_summed_audio_length_and_the_last_word_end_ASR10():
    first = {**_transcript(_seg(0.0, 4.0, "a", "speaker_user")), "audio_seconds": 4.0}
    second = {**_transcript(_seg(0.0, 7.5, "b", "speaker_user")), "audio_seconds": 7.5}

    merged = merge_transcripts([first, second], [10.0, 20.0])

    assert merged["audio_seconds"] == 30.0, "the fragments laid end to end, not the first fragment's value"
    assert merged["last_speech_sec"] == 10.0 + 7.5
