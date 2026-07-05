"""TECH-FEAT3 + FEAT3-VOICEPRINT: speaker-enrollment relabeling, voiceprint match."""
from __future__ import annotations

from pathlib import Path

from mp.diarize import (
    OTHER_SPEAKER,
    USER_SPEAKER,
    _dominant_speaker,
    apply_speaker_labels,
    cosine_similarity,
    identify_user_speaker,
    label_me_speaker,
    match_voiceprint,
    resolve_speaker_labels,
    them_label,
)


class _FakeRoster:
    """Match by exact embedding value, for deterministic resolve_labels tests."""

    def __init__(self, matches: list[tuple[list[float], str]]):
        self._matches = matches

    def match(self, emb):
        for vec, name in self._matches:
            if emb == vec:
                return name
        return None


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


# --- FEAT3-ROSTER: label resolution (me + roster names + THEM clusters) -------


def test_them_label_sequence():
    assert [them_label(i) for i in range(3)] == ["THEM-A", "THEM-B", "THEM-C"]
    assert them_label(26) == "THEM-AA"


def test_resolve_labels_me_and_unknown_them():
    segs = [_seg("speaker_0", 0, 5), _seg("speaker_1", 5, 6), _seg("speaker_2", 6, 7)]
    emb = {"speaker_0": [1.0], "speaker_1": [2.0], "speaker_2": [3.0]}
    # speaker_0 is dominant -> "Me"; the other two carry embeddings but no roster
    # match -> stable THEM-A / THEM-B in first-appearance order.
    mapping = resolve_speaker_labels(segs, emb, None, user_label="Me")
    assert mapping == {"speaker_0": "Me", "speaker_1": "THEM-A", "speaker_2": "THEM-B"}


def test_resolve_labels_roster_names_win_over_them():
    segs = [_seg("speaker_0", 0, 5), _seg("speaker_1", 5, 6), _seg("speaker_2", 6, 7)]
    emb = {"speaker_0": [1.0], "speaker_1": [2.0], "speaker_2": [3.0]}
    roster = _FakeRoster([([2.0], "Bob")])  # speaker_1 -> Bob
    mapping = resolve_speaker_labels(segs, emb, roster, user_label="Me")
    assert mapping == {"speaker_0": "Me", "speaker_1": "Bob", "speaker_2": "THEM-A"}


def test_resolve_labels_me_never_roster_matched():
    segs = [_seg("speaker_0", 0, 10), _seg("speaker_1", 10, 11)]
    emb = {"speaker_0": [1.0], "speaker_1": [2.0]}
    # speaker_0 is dominant, so it stays "Me" even though the roster would match
    # it; speaker_1 gets its roster name.
    roster = _FakeRoster([([1.0], "Alice"), ([2.0], "Bob")])
    mapping = resolve_speaker_labels(segs, emb, roster, user_label="Me")
    assert mapping["speaker_0"] == "Me"
    assert mapping["speaker_1"] == "Bob"


def test_resolve_labels_no_embedding_keeps_raw_id():
    # Fallback-branch speakers (no embeddings) are never turned into THEM clusters.
    segs = [_seg("speaker_user", 0, 5), _seg("speaker_other", 5, 6)]
    mapping = resolve_speaker_labels(
        segs, None, None, user_label="Me", channel_me="speaker_user"
    )
    assert mapping == {"speaker_user": "Me"}  # speaker_other unmapped -> raw id kept


def test_apply_speaker_labels_replaces_only_mapped():
    segs = [_seg("speaker_0", 0, 1), _seg("speaker_1", 1, 2)]
    out = apply_speaker_labels(segs, {"speaker_0": "Me"})
    assert [s["speaker"] for s in out] == ["Me", "speaker_1"]
