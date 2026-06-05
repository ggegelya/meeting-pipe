"""TECH-FEAT3: speaker-enrollment relabeling (label_me_speaker)."""
from __future__ import annotations

from mp.diarize import OTHER_SPEAKER, USER_SPEAKER, _dominant_speaker, label_me_speaker


def _seg(speaker, start, end, text="x"):
    return {"speaker": speaker, "start": start, "end": end, "text": text}


def test_channel_user_speaker_gets_the_enrolled_name():
    segs = [_seg(USER_SPEAKER, 0, 2), _seg(OTHER_SPEAKER, 2, 4), _seg(USER_SPEAKER, 4, 5)]
    out = label_me_speaker(segs, "Heorhii")
    assert [s["speaker"] for s in out] == ["Heorhii", OTHER_SPEAKER, "Heorhii"]


def test_channel_user_wins_even_when_not_dominant():
    # speaker_other talks more, but the mic channel (speaker_user) is still "me":
    # the channel label takes precedence over the dominant-time heuristic.
    segs = [_seg(USER_SPEAKER, 0, 1), _seg(OTHER_SPEAKER, 1, 10)]
    out = label_me_speaker(segs, "Me")
    assert [s["speaker"] for s in out] == ["Me", OTHER_SPEAKER]


def test_dominant_speaker_fallback_when_no_channel_label():
    # FluidAudio generic labels; speaker_0 speaks the most, so it is "me".
    segs = [_seg("speaker_0", 0, 6), _seg("speaker_1", 6, 7), _seg("speaker_0", 7, 9)]
    out = label_me_speaker(segs, "Me")
    assert [s["speaker"] for s in out] == ["Me", "speaker_1", "Me"]


def test_dominant_speaker_picks_most_spoken_time():
    assert _dominant_speaker([_seg("a", 0, 1), _seg("b", 1, 10)]) == "b"


def test_dominant_ignores_unknown_and_empty_labels():
    assert _dominant_speaker([_seg("Speaker?", 0, 10), _seg(None, 0, 9), _seg("a", 10, 11)]) == "a"


def test_noop_when_user_label_empty():
    segs = [_seg(USER_SPEAKER, 0, 2)]
    out = label_me_speaker(segs, "")
    assert out == segs and out is not segs  # copied, content unchanged


def test_noop_when_no_usable_speaker():
    segs = [_seg("Speaker?", 0, 2), _seg(None, 2, 3)]
    out = label_me_speaker(segs, "Me")
    assert [s["speaker"] for s in out] == ["Speaker?", None]


def test_noop_when_me_already_has_the_label():
    segs = [_seg("Me", 0, 5), _seg("speaker_1", 5, 6)]
    out = label_me_speaker(segs, "Me")
    assert [s["speaker"] for s in out] == ["Me", "speaker_1"]
