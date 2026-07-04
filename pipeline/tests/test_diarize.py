"""TECH-FEAT3 + FEAT3-VOICEPRINT: speaker-enrollment relabeling, voiceprint match."""
from __future__ import annotations

from pathlib import Path

from mp.diarize import (
    OTHER_SPEAKER,
    USER_SPEAKER,
    _dominant_speaker,
    cosine_similarity,
    identify_user_speaker,
    label_me_speaker,
    match_voiceprint,
)


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


# --- FEAT3-VOICEPRINT: cosine match + label precedence -----------------------


def test_cosine_similarity_basic():
    assert cosine_similarity([1, 0], [1, 0]) == 1.0
    assert abs(cosine_similarity([1, 0], [0, 1])) < 1e-9
    assert cosine_similarity([1, 0], [3, 0]) == 1.0  # scale-invariant
    assert cosine_similarity([], [1]) == 0.0          # length mismatch / empty
    assert cosine_similarity([0, 0], [1, 0]) == 0.0   # zero vector


def test_match_voiceprint_picks_closest_above_threshold():
    emb = {"speaker_0": [0.0, 1.0], "speaker_1": [1.0, 0.0]}
    assert match_voiceprint(emb, [0.95, 0.05]) == "speaker_1"


def test_match_voiceprint_none_when_below_threshold_or_unenrolled():
    emb = {"speaker_0": [1.0, 0.0]}
    assert match_voiceprint(emb, [0.0, 1.0]) is None  # orthogonal, below 0.5
    assert match_voiceprint(emb, None) is None
    assert match_voiceprint({}, [1.0, 0.0]) is None


def test_match_voiceprint_tie_breaks_to_lowest_id():
    emb = {"speaker_1": [1.0, 0.0], "speaker_0": [1.0, 0.0]}
    assert match_voiceprint(emb, [1.0, 0.0]) == "speaker_0"


def test_voiceprint_me_used_when_no_channel_label():
    # Generic FluidAudio labels, user is NOT dominant (speaker_1 talks more),
    # but the voiceprint matched speaker_0, so speaker_0 is "me".
    segs = [_seg("speaker_0", 0, 1), _seg("speaker_1", 1, 10)]
    out = label_me_speaker(segs, "Me", voiceprint_me="speaker_0")
    assert [s["speaker"] for s in out] == ["Me", "speaker_1"]


def test_channel_label_still_beats_voiceprint():
    # The reliable stereo channel label wins over the voiceprint hint.
    segs = [_seg(USER_SPEAKER, 0, 1), _seg("speaker_1", 1, 10)]
    out = label_me_speaker(segs, "Me", voiceprint_me="speaker_1")
    assert [s["speaker"] for s in out] == ["Me", "speaker_1"]


def test_voiceprint_me_ignored_when_not_in_segments():
    # A stale hint pointing at an absent speaker falls through to dominant.
    segs = [_seg("speaker_0", 0, 5), _seg("speaker_1", 5, 6)]
    out = label_me_speaker(segs, "Me", voiceprint_me="speaker_9")
    assert [s["speaker"] for s in out] == ["Me", "speaker_1"]


def test_identify_user_speaker_mono_returns_none(monkeypatch):
    monkeypatch.setattr("mp.diarize.is_stereo_recording", lambda wav: False)
    assert identify_user_speaker([_seg("speaker_0", 0, 2)], Path("x.wav")) is None


def test_identify_user_speaker_cross_tabs_mic_dominant(monkeypatch):
    segs = [_seg("speaker_0", 0, 2), _seg("speaker_1", 2, 4), _seg("speaker_0", 4, 5)]
    monkeypatch.setattr("mp.diarize.is_stereo_recording", lambda wav: True)
    monkeypatch.setattr(
        "mp.diarize.assign_speakers_by_channel",
        lambda segments, wav: [
            {**segments[0], "speaker": USER_SPEAKER},
            {**segments[1], "speaker": OTHER_SPEAKER},
            {**segments[2], "speaker": USER_SPEAKER},
        ],
    )
    assert identify_user_speaker(segs, Path("x.wav")) == "speaker_0"


def test_identify_user_speaker_declines_when_system_silent(monkeypatch):
    # assign_speakers_by_channel collapses everything to USER when the system
    # channel is silent; we can't distinguish speakers, so decline to enroll.
    segs = [_seg("speaker_0", 0, 2), _seg("speaker_1", 2, 4)]
    monkeypatch.setattr("mp.diarize.is_stereo_recording", lambda wav: True)
    monkeypatch.setattr(
        "mp.diarize.assign_speakers_by_channel",
        lambda segments, wav: [{**s, "speaker": USER_SPEAKER} for s in segments],
    )
    assert identify_user_speaker(segs, Path("x.wav")) is None
