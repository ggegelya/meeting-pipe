"""TECH-FEAT3 + FEAT3-VOICEPRINT: speaker-enrollment relabeling, voiceprint match."""
from __future__ import annotations

from pathlib import Path

from mp.diarize import (
    MIN_MIC_SPEECH_SEC,
    OTHER_SPEAKER,
    RUNNER_UP_SHARE,
    USER_SPEAKER,
    _resolve_me,
    apply_speaker_labels,
    cosine_similarity,
    identify_user_speaker,
    label_me_speaker,
    match_voiceprint,
    pick_mic_speaker,
    resolve_speaker_labels,
    them_label,
)
from mp.roster import MatchResult


class _FakeRoster:
    """Match by exact embedding value, for deterministic resolve_labels tests.

    `near` is FEAT14's other half: embeddings the two-gate rule declined and came
    close on, which `resolve_speaker_labels` reports without naming anybody.
    """

    def __init__(
        self,
        matches: list[tuple[list[float], str]],
        near: list[tuple[list[float], str]] | None = None,
    ):
        self._matches = matches
        self._near = near or []

    def match_detail(self, emb):
        for vec, name in self._matches:
            if emb == vec:
                return MatchResult(name, None, 0.9)
        for vec, name in self._near:
            if emb == vec:
                return MatchResult(None, name, 0.6)
        return MatchResult(None, None, None)


def _seg(speaker, start, end, text="x"):
    return {"speaker": speaker, "start": start, "end": end, "text": text}


def test_channel_user_speaker_gets_the_enrolled_name():
    segs = [_seg(USER_SPEAKER, 0, 2), _seg(OTHER_SPEAKER, 2, 4), _seg(USER_SPEAKER, 4, 5)]
    out = label_me_speaker(segs, "Avery")
    assert [s["speaker"] for s in out] == ["Avery", OTHER_SPEAKER, "Avery"]


def test_channel_user_wins_even_when_talking_less():
    # speaker_other talks more, but the mic channel (speaker_user) is still "me":
    # the channel label is physical evidence, not a share-of-talk guess.
    segs = [_seg(USER_SPEAKER, 0, 1), _seg(OTHER_SPEAKER, 1, 10)]
    out = label_me_speaker(segs, "Me")
    assert [s["speaker"] for s in out] == ["Me", OTHER_SPEAKER]


def test_no_name_when_no_signal_identifies_the_user():
    # The silent-owner case: generic FluidAudio labels, no channel label, no mic
    # identification and no voiceprint match, i.e. nothing places the user in
    # this meeting. Talking most is NOT evidence of being the owner, so nobody
    # is given the user's name and every voice stays available for a THEM
    # cluster the user can name in the app.
    segs = [_seg("speaker_0", 0, 6), _seg("speaker_1", 6, 7), _seg("speaker_0", 7, 9)]
    out = label_me_speaker(segs, "Me")
    assert [s["speaker"] for s in out] == ["speaker_0", "speaker_1", "speaker_0"]


def test_mic_me_identifies_the_user_when_no_channel_label():
    # FluidAudio generic labels: the mic-channel cross-tab found speaker_1, who
    # is "me" despite speaker_0 talking far more.
    segs = [_seg("speaker_0", 0, 9), _seg("speaker_1", 9, 10)]
    out = label_me_speaker(segs, "Me", mic_me="speaker_1")
    assert [s["speaker"] for s in out] == ["speaker_0", "Me"]


def test_mic_me_alone_names_the_mic_speaker():
    segs = [_seg("speaker_0", 0, 5), _seg("speaker_1", 5, 6)]
    out = label_me_speaker(segs, "Me", mic_me="speaker_0")
    assert [s["speaker"] for s in out] == ["Me", "speaker_1"]


def test_a_disagreeing_voiceprint_without_mic_side_evidence_names_nobody():
    # DIAR11: the mic pick used to override the voiceprint, and the mic tier has no
    # voiceprint-style gates. Now a disagreement is settled by the voiceprint, provided
    # its own cluster is mic-side; without that evidence nobody is named.
    segs = [_seg("speaker_0", 0, 5), _seg("speaker_1", 5, 6)]
    out = label_me_speaker(segs, "Me", mic_me="speaker_0", voiceprint_me="speaker_1")
    assert [s["speaker"] for s in out] == ["speaker_0", "speaker_1"]


def test_mic_me_ignored_when_not_in_segments():
    # A hint pointing at an absent speaker is not evidence; fall to voiceprint.
    segs = [_seg("speaker_0", 0, 5), _seg("speaker_1", 5, 6)]
    out = label_me_speaker(segs, "Me", mic_me="speaker_9", voiceprint_me="speaker_1")
    assert [s["speaker"] for s in out] == ["speaker_0", "Me"]


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


def test_match_voiceprint_none_when_runner_up_is_too_close():
    # Two speakers of near-identical similarity fail the margin and leave "me"
    # unresolved. Taken from the real library, where 0.506 vs 0.495 would
    # otherwise have decided the owner's identity by 0.011.
    emb = {"speaker_0": [1.0, 0.02], "speaker_1": [1.0, 0.0]}
    assert match_voiceprint(emb, [1.0, 0.01]) is None


def test_match_voiceprint_lone_candidate_only_faces_the_threshold():
    # With nobody to be confused with, the margin gate has no runner-up to
    # measure against and a clear match is still accepted.
    emb = {"speaker_0": [1.0, 0.0]}
    assert match_voiceprint(emb, [1.0, 0.0]) == "speaker_0"


def test_voiceprint_me_used_when_no_channel_or_mic_label():
    # Generic FluidAudio labels, user talks far less than speaker_1, but the
    # voiceprint matched speaker_0, so speaker_0 is "me".
    segs = [_seg("speaker_0", 0, 1), _seg("speaker_1", 1, 10)]
    out = label_me_speaker(segs, "Me", voiceprint_me="speaker_0")
    assert [s["speaker"] for s in out] == ["Me", "speaker_1"]


def test_channel_label_still_beats_voiceprint():
    # The reliable stereo channel label wins over the voiceprint hint.
    segs = [_seg(USER_SPEAKER, 0, 1), _seg("speaker_1", 1, 10)]
    out = label_me_speaker(segs, "Me", voiceprint_me="speaker_1")
    assert [s["speaker"] for s in out] == ["Me", "speaker_1"]


def test_voiceprint_me_ignored_when_not_in_segments():
    # A stale hint pointing at an absent speaker is not evidence the user spoke,
    # so nobody is named rather than the name landing on whoever talked most.
    segs = [_seg("speaker_0", 0, 5), _seg("speaker_1", 5, 6)]
    out = label_me_speaker(segs, "Me", voiceprint_me="speaker_9")
    assert [s["speaker"] for s in out] == ["speaker_0", "speaker_1"]


def test_identify_user_speaker_mono_returns_none(monkeypatch):
    monkeypatch.setattr("mp.diarize.is_stereo_recording", lambda wav: False)
    assert identify_user_speaker([_seg("speaker_0", 0, 2)], Path("x.wav")) is None


def test_identify_user_speaker_cross_tabs_mic_dominant(monkeypatch):
    # Long enough to clear the mic tier's speech floor (DIAR11): 30 s on the mic.
    segs = [_seg("speaker_0", 0, 20), _seg("speaker_1", 20, 40), _seg("speaker_0", 40, 50)]
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
    # The mic channel identified speaker_0 -> "Me"; the other two carry
    # embeddings but no roster match -> stable THEM-A / THEM-B in
    # first-appearance order.
    mapping = resolve_speaker_labels(
        segs, emb, None, user_label="Me", mic_me="speaker_0"
    ).mapping
    assert mapping == {"speaker_0": "Me", "speaker_1": "THEM-A", "speaker_2": "THEM-B"}


def test_resolve_labels_no_me_when_user_did_not_speak():
    # The silent-owner case at the mapping seam: no signal identifies the user,
    # so `user_label` is applied to nobody and every voice clusters as unknown.
    segs = [_seg("speaker_0", 0, 5), _seg("speaker_1", 5, 6)]
    emb = {"speaker_0": [1.0], "speaker_1": [2.0]}
    mapping = resolve_speaker_labels(segs, emb, None, user_label="Me").mapping
    assert mapping == {"speaker_0": "THEM-A", "speaker_1": "THEM-B"}
    assert "Me" not in mapping.values()


def test_an_identified_owner_with_no_name_set_takes_the_reserved_label_UX83():
    # FluidAudio names clusters "1", "2", ... An unnamed owner used to keep "1", which the
    # app counted as a roster match and the summarizer listed as an attendee.
    segs = [_seg("1", 0, 5), _seg("2", 5, 6)]
    emb = {"1": [1.0], "2": [2.0]}
    resolved = resolve_speaker_labels(segs, emb, None, user_label="", mic_me="1")
    assert resolved.mapping == {"1": USER_SPEAKER, "2": "THEM-A"}
    assert resolved.owner_id == "1"
    assert not any(v.isdigit() for v in resolved.mapping.values())


def test_a_set_name_still_wins_over_the_reserved_label_UX83():
    segs = [_seg("1", 0, 5), _seg("2", 5, 6)]
    emb = {"1": [1.0], "2": [2.0]}
    mapping = resolve_speaker_labels(segs, emb, None, user_label="  Alex ", mic_me="1").mapping
    assert mapping == {"1": "Alex", "2": "THEM-A"}


def test_with_nobody_identified_no_voice_takes_the_reserved_label_UX83():
    segs = [_seg("1", 0, 5), _seg("2", 5, 6)]
    emb = {"1": [1.0], "2": [2.0]}
    mapping = resolve_speaker_labels(segs, emb, None, user_label="").mapping
    assert mapping == {"1": "THEM-A", "2": "THEM-B"}


def test_resolve_labels_roster_names_win_over_them():
    segs = [_seg("speaker_0", 0, 5), _seg("speaker_1", 5, 6), _seg("speaker_2", 6, 7)]
    emb = {"speaker_0": [1.0], "speaker_1": [2.0], "speaker_2": [3.0]}
    roster = _FakeRoster([([2.0], "Bob")])  # speaker_1 -> Bob
    mapping = resolve_speaker_labels(
        segs, emb, roster, user_label="Me", mic_me="speaker_0"
    ).mapping
    assert mapping == {"speaker_0": "Me", "speaker_1": "Bob", "speaker_2": "THEM-A"}


def test_resolve_labels_me_never_roster_matched():
    segs = [_seg("speaker_0", 0, 10), _seg("speaker_1", 10, 11)]
    emb = {"speaker_0": [1.0], "speaker_1": [2.0]}
    # speaker_0 is "me" by the mic channel, so it keeps the user's name even
    # though the roster would match it; speaker_1 gets its roster name.
    roster = _FakeRoster([([1.0], "Alice"), ([2.0], "Bob")])
    mapping = resolve_speaker_labels(
        segs, emb, roster, user_label="Me", mic_me="speaker_0"
    ).mapping
    assert mapping["speaker_0"] == "Me"
    assert mapping["speaker_1"] == "Bob"


def test_resolve_labels_no_embedding_keeps_raw_id():
    # Fallback-branch speakers (no embeddings) are never turned into THEM clusters.
    segs = [_seg("speaker_user", 0, 5), _seg("speaker_other", 5, 6)]
    mapping = resolve_speaker_labels(
        segs, None, None, user_label="Me", channel_me="speaker_user"
    ).mapping
    assert mapping == {"speaker_user": "Me"}  # speaker_other unmapped -> raw id kept


def test_resolve_labels_reports_a_near_miss_without_naming_anybody():
    # FEAT14: the roster declined speaker_1 and came closest to Bob. The label on
    # disk is unchanged, a THEM cluster exactly as before, and the suggestion
    # rides beside the mapping keyed by that label rather than replacing it.
    segs = [_seg("speaker_0", 0, 5), _seg("speaker_1", 5, 6)]
    emb = {"speaker_0": [1.0], "speaker_1": [2.0]}
    roster = _FakeRoster([], near=[([2.0], "Bob")])
    resolved = resolve_speaker_labels(
        segs, emb, roster, user_label="Me", mic_me="speaker_0"
    )
    assert resolved.mapping == {"speaker_0": "Me", "speaker_1": "THEM-A"}
    assert resolved.near_misses == {"THEM-A": "Bob"}


def test_resolve_labels_has_no_near_miss_for_a_voice_it_named():
    segs = [_seg("speaker_0", 0, 5), _seg("speaker_1", 5, 6)]
    emb = {"speaker_0": [1.0], "speaker_1": [2.0]}
    roster = _FakeRoster([([2.0], "Bob")])
    resolved = resolve_speaker_labels(
        segs, emb, roster, user_label="Me", mic_me="speaker_0"
    )
    assert resolved.mapping["speaker_1"] == "Bob"
    assert resolved.near_misses == {}


def test_resolve_labels_never_suggests_the_owner_for_another_voice():
    # The owner is identified by their own voiceprint, never by the roster, so a
    # near miss on their name is the one case the roster cannot arbitrate. Same
    # guard the accept path has always applied, now applied to the suggestion.
    segs = [_seg("speaker_0", 0, 5), _seg("speaker_1", 5, 6)]
    emb = {"speaker_0": [1.0], "speaker_1": [2.0]}
    roster = _FakeRoster([], near=[([2.0], "Me")])
    resolved = resolve_speaker_labels(
        segs, emb, roster, user_label="Me", mic_me="speaker_0"
    )
    assert resolved.mapping["speaker_1"] == "THEM-A"
    assert resolved.near_misses == {}


def test_resolve_labels_without_a_roster_has_no_near_misses():
    segs = [_seg("speaker_0", 0, 5), _seg("speaker_1", 5, 6)]
    emb = {"speaker_0": [1.0], "speaker_1": [2.0]}
    resolved = resolve_speaker_labels(segs, emb, None, user_label="Me", mic_me="speaker_0")
    assert resolved.near_misses == {}


def test_apply_speaker_labels_replaces_only_mapped():
    segs = [_seg("speaker_0", 0, 1), _seg("speaker_1", 1, 2)]
    out = apply_speaker_labels(segs, {"speaker_0": "Me"})
    assert [s["speaker"] for s in out] == ["Me", "speaker_1"]


# --- DIAR11: the owner cluster is picked by mic speech time, with a floor and a runner-up ----


def _tier(mic: dict[str, float], total: dict[str, float]):
    return pick_mic_speaker(mic, total)


def test_two_local_voices_on_one_mic_decline_the_pick():
    # F096: a hybrid call, two people at the laptop. Both read near 1.0 on the mic and
    # have similar mic time, so whichever was heard first used to be named the owner.
    tier = _tier({"a": 300.0, "b": 260.0}, {"a": 300.0, "b": 270.0})
    assert tier.winner is None


def test_two_local_voices_with_a_voiceprint_match_name_that_one_only():
    segs = [_seg("a", 0, 300), _seg("b", 300, 560)]
    tier = _tier({"a": 300.0, "b": 260.0}, {"a": 300.0, "b": 260.0})
    me, why = _resolve_me(segs, mic_me=tier.winner, voiceprint_me="b")
    assert (me, why) == ("b", "voiceprint")
    out = label_me_speaker(segs, "Me", mic_me=tier.winner, voiceprint_me="b")
    assert [s["speaker"] for s in out] == ["a", "Me"]


def test_a_three_second_cluster_at_full_fraction_loses_to_the_main_cluster():
    # The shape of the field's 26 small non-matching clusters: one clipped utterance
    # at mic fraction 1.0 beat the owner's 600 s cluster at 0.85.
    tier = _tier({"clip": 3.0, "main": 510.0}, {"clip": 3.0, "main": 600.0})
    assert tier.winner == "main"


def test_a_cluster_under_the_speech_floor_is_not_evidence_of_a_voice():
    assert _tier({"clip": MIN_MIC_SPEECH_SEC - 1}, {"clip": MIN_MIC_SPEECH_SEC - 1}).winner is None
    assert _tier({"ok": MIN_MIC_SPEECH_SEC}, {"ok": MIN_MIC_SPEECH_SEC}).winner == "ok"


def test_a_tie_on_fraction_goes_to_the_most_mic_speech_not_the_first_heard():
    # `max` over an insertion-ordered dict used to break the tie to whoever spoke first.
    tier = _tier({"first": 20.0, "second": 100.0}, {"first": 20.0, "second": 100.0})
    assert tier.winner == "second"


def test_a_brief_second_mic_voice_does_not_stop_the_owner_being_picked():
    tier = _tier({"owner": 400.0, "aside": 400.0 * RUNNER_UP_SHARE - 1}, {"owner": 400.0, "aside": 100.0})
    assert tier.winner == "owner"
    # At the share ("a quarter or more"), or above, it is a second local voice.
    assert _tier({"owner": 400.0, "other": 400.0 * RUNNER_UP_SHARE}, {"owner": 400.0, "other": 110.0}).winner is None
    assert _tier({"owner": 400.0, "other": 400.0 * RUNNER_UP_SHARE + 1}, {"owner": 400.0, "other": 110.0}).winner is None


def test_a_remote_voice_never_competes_for_the_mic_tier():
    tier = _tier({"owner": 200.0, "remote": 5.0}, {"owner": 210.0, "remote": 800.0})
    assert tier.winner == "owner"


def test_the_voiceprint_pick_wins_a_disagreement_when_it_is_mic_side():
    segs = [_seg("a", 0, 100), _seg("b", 100, 200)]
    assert _resolve_me(segs, mic_me="a", voiceprint_me="b", mic_fractions={"a": 1.0, "b": 0.9}) == ("b", "voiceprint")


def test_a_system_side_voiceprint_pick_names_nobody_against_a_mic_pick():
    segs = [_seg("a", 0, 100), _seg("b", 100, 200)]
    assert _resolve_me(segs, mic_me="a", voiceprint_me="b", mic_fractions={"a": 1.0, "b": 0.1}) == (None, "none")
    # And never falls back to the mic pick against a voiceprint that disagrees with it.
    out = label_me_speaker(segs, "Me", mic_me="a", voiceprint_me="b")
    assert "Me" not in [s["speaker"] for s in out]


def test_agreement_and_single_signals_resolve_as_before():
    segs = [_seg("a", 0, 100), _seg("b", 100, 200)]
    assert _resolve_me(segs, mic_me="a", voiceprint_me="a") == ("a", "mic")
    assert _resolve_me(segs, mic_me="a") == ("a", "mic")
    assert _resolve_me(segs, voiceprint_me="b") == ("b", "voiceprint")
    assert _resolve_me(segs) == (None, "none")
    assert _resolve_me([_seg(USER_SPEAKER, 0, 5)], mic_me="a")[1] == "channel"


def _unit_at(cos_to_axis0: float) -> list[float]:
    """A 256-d unit vector at the given cosine to axis 0."""
    v = [0.0] * 256
    v[0] = cos_to_axis0
    v[1] = (1 - cos_to_axis0**2) ** 0.5
    return v


def _fold_case(second_mic_fraction: float, second_cos: float = 0.7, roster=None):
    vp = _unit_at(1.0)
    embs = {"a": _unit_at(1.0), "b": _unit_at(second_cos)}
    mic = {"a": 300.0, "b": 30.0 * second_mic_fraction}
    total = {"a": 300.0, "b": 30.0}
    segs = [_seg("a", 0, 300), _seg("b", 300, 330)]
    tier = pick_mic_speaker(mic, total)
    assert tier.winner == "a"
    return resolve_speaker_labels(
        segs, embs, roster or _FakeRoster([]), user_label="Me",
        mic_me=tier.winner, mic_tier=tier, voiceprint=vp,
    )


def test_an_owner_matching_mic_side_cluster_is_folded_into_the_owner():
    # 0.1 mic fraction is system-side, so use a mic-side fraction for the over-split case.
    res = _fold_case(second_mic_fraction=0.9)
    assert res.mapping == {"a": "Me", "b": "Me"}
    assert (res.owner.folded, res.owner.flagged) == (1, 0)


def test_an_over_split_unnamed_owner_folds_into_the_reserved_label_UX83():
    # An empty label used to switch DIAR11's folds off; the fallback turns them on, so the
    # owner's fragment folds into `speaker_user` exactly as it folds into a set name.
    vp = _unit_at(1.0)
    embs = {"a": _unit_at(1.0), "b": _unit_at(0.7)}
    tier = pick_mic_speaker({"a": 300.0, "b": 27.0}, {"a": 300.0, "b": 30.0})
    res = resolve_speaker_labels(
        [_seg("a", 0, 300), _seg("b", 300, 330)], embs, _FakeRoster([]), user_label="",
        mic_me=tier.winner, mic_tier=tier, voiceprint=vp,
    )
    assert res.mapping == {"a": USER_SPEAKER, "b": USER_SPEAKER}
    assert res.owner.folded == 1


def test_an_owner_matching_system_side_cluster_is_left_alone_and_flagged():
    # A remote voice that sounds like the owner must never take the owner's name.
    res = _fold_case(second_mic_fraction=0.1)
    assert res.mapping == {"a": "Me", "b": "THEM-A"}
    assert (res.owner.folded, res.owner.flagged) == (0, 1)


def test_a_cluster_below_the_same_person_bar_is_not_folded_or_flagged():
    res = _fold_case(second_mic_fraction=0.9, second_cos=0.5)
    assert res.mapping["b"] == "THEM-A"
    assert (res.owner.folded, res.owner.flagged) == (0, 0)


def test_a_cluster_the_roster_already_names_is_never_folded():
    emb = _unit_at(0.7)
    res = _fold_case(second_mic_fraction=0.9, roster=_FakeRoster([(emb, "Dana")]))
    assert res.mapping["b"] == "Dana"
    assert res.owner.folded == 0


def test_owner_choice_reports_the_evidence_and_no_label_text():
    res = _fold_case(second_mic_fraction=0.9)
    owner = res.owner
    assert owner.tier == "mic"
    assert owner.mic_fraction == 1.0 and owner.mic_seconds == 300.0
    assert owner.voiceprint_score == 1.0
    assert owner.runner_up_seconds == 27.0 and owner.runner_up_fraction == 0.9
    assert all(isinstance(v, (int, float, str, type(None))) for v in owner._asdict().values())
    assert not any(v == "Me" for v in owner._asdict().values())


def test_no_mic_tier_and_no_owner_still_reports_a_none_choice():
    res = resolve_speaker_labels([_seg("a", 0, 5)], None, _FakeRoster([]), user_label="Me")
    assert res.owner is not None and res.owner.tier == "none"
    assert res.owner.mic_fraction is None and res.owner.runner_up_seconds is None


def test_an_owner_over_split_into_two_mic_side_clusters_names_both_when_the_pick_declined():
    # Two big mic-side clusters that both match the voiceprint: the mic tier declines
    # (two local voices?), the voiceprint's own margin gate declines (two near scores), and
    # the fold is what gives the owner back the speech the two-gate rule would not name.
    vp = _unit_at(1.0)
    embs = {"a": _unit_at(1.0), "b": _unit_at(0.9)}
    tier = pick_mic_speaker({"a": 300.0, "b": 250.0}, {"a": 300.0, "b": 250.0})
    assert tier.winner is None
    res = resolve_speaker_labels(
        [_seg("a", 0, 300), _seg("b", 300, 550)], embs, _FakeRoster([]), user_label="Me",
        mic_tier=tier, voiceprint=vp,
    )
    assert res.mapping == {"a": "Me", "b": "Me"}
    assert res.owner.tier == "none" and res.owner.folded == 2


def test_a_second_local_voice_that_only_matches_the_voiceprint_is_not_folded():
    # A cluster at 0.7 to the voiceprint but unlike the owner's own cluster: with an owner already
    # named, the fold also asks the candidate to sound like THAT cluster (the colleague case).
    vp = _unit_at(1.0)
    owner = _unit_at(0.8)            # 0.8 to the voiceprint
    like_owner = _unit_at(0.8)       # same voice as the named cluster: folded
    unlike = [0.0] * 256             # 0.7 to the voiceprint, but 0.56 to the owner's cluster
    unlike[0] = 0.7
    unlike[2] = (1 - 0.7**2) ** 0.5
    tier = pick_mic_speaker({"a": 300.0, "b": 30.0}, {"a": 300.0, "b": 30.0})
    segs = [_seg("a", 0, 300), _seg("b", 300, 330)]
    folded = resolve_speaker_labels(
        segs, {"a": owner, "b": like_owner}, _FakeRoster([]), user_label="Me",
        mic_me="a", mic_tier=tier, voiceprint=vp)
    assert folded.mapping["b"] == "Me"
    kept = resolve_speaker_labels(
        segs, {"a": owner, "b": unlike}, _FakeRoster([]), user_label="Me",
        mic_me="a", mic_tier=tier, voiceprint=vp)
    assert kept.mapping["b"] == "THEM-A"


def test_a_disagreeing_pair_that_named_nobody_folds_nobody():
    # The mic winner matches the voiceprint too, but the picks disagreed and the voiceprint's own
    # cluster is system-side: nobody is named, so nobody may be folded in either.
    vp = _unit_at(1.0)
    embs = {"a": _unit_at(0.9), "b": _unit_at(1.0)}
    tier = pick_mic_speaker({"a": 300.0, "b": 0.0}, {"a": 300.0, "b": 300.0})
    res = resolve_speaker_labels(
        [_seg("a", 0, 300), _seg("b", 300, 600)], embs, _FakeRoster([]), user_label="Me",
        mic_me="a", voiceprint_me="b", mic_tier=tier, voiceprint=vp)
    assert "Me" not in res.mapping.values()
    assert res.owner.tier == "none" and res.owner.folded == 0
    assert res.owner_id is None


# --- DIAR11 amendment 2026-11-17: no voiceprint and two mic-side clusters = one over-split owner --


def test_the_tier_reports_the_split_when_the_runner_up_share_declined_the_pick():
    tier = _tier({"a": 300.0, "b": 260.0, "c": 20.0}, {"a": 300.0, "b": 270.0, "c": 20.0})
    assert tier.winner is None
    assert tier.split == ("a", "b")                       # leader first; c is under the share
    # A clear winner, a sub-floor leader and a remote voice have no split.
    assert _tier({"a": 400.0, "b": 10.0}, {"a": 400.0, "b": 10.0}).split == ()
    assert _tier({"a": 10.0, "b": 9.0}, {"a": 10.0, "b": 9.0}).split == ()
    assert _tier({"a": 300.0, "remote": 0.0}, {"a": 300.0, "remote": 300.0}).split == ()


def test_with_no_voiceprint_an_over_split_owner_is_named_on_both_clusters():
    # The owner decision of 2026-11-17: fold both, accepting audit F096 (a second person on the
    # owner's mic gets the owner's name until a print exists).
    segs = [_seg("a", 0, 300), _seg("b", 300, 560), _seg("r", 560, 600)]
    tier = _tier({"a": 300.0, "b": 260.0, "r": 0.0}, {"a": 300.0, "b": 260.0, "r": 40.0})
    res = resolve_speaker_labels(
        segs, {"a": _unit_at(1.0), "b": _unit_at(0.3), "r": _unit_at(0.0)}, _FakeRoster([]),
        user_label="Me", mic_me=tier.split[0], mic_tier=tier, voiceprint=None)
    assert res.mapping["a"] == "Me" and res.mapping["b"] == "Me"
    assert res.mapping["r"].startswith("THEM-")            # the remote voice is never folded
    assert res.owner.tier == "mic" and res.owner.folded == 1


def test_a_split_is_not_folded_once_a_voiceprint_exists():
    # With a print the tier declines and the voiceprint decides alone: the two-voices case stays two.
    segs = [_seg("a", 0, 300), _seg("b", 300, 560)]
    tier = _tier({"a": 300.0, "b": 260.0}, {"a": 300.0, "b": 260.0})
    res = resolve_speaker_labels(
        segs, {"a": _unit_at(1.0), "b": _unit_at(0.0)}, _FakeRoster([]), user_label="Me",
        voiceprint_me="b", mic_tier=tier, voiceprint=_unit_at(0.0))
    assert res.mapping["b"] == "Me" and res.mapping["a"].startswith("THEM-")


def test_a_below_floor_owner_is_unnamed_without_a_voiceprint_through_resolve_speaker_labels():
    # Item 4 of the amendment: the owner spoke 10 s on the mic, under the 15 s floor.
    segs = [_seg("owner", 0, 10), _seg("remote", 10, 300)]
    tier = _tier({"owner": 10.0, "remote": 0.0}, {"owner": 10.0, "remote": 290.0})
    assert tier.winner is None and tier.split == ()
    res = resolve_speaker_labels(
        segs, {"owner": _unit_at(1.0), "remote": _unit_at(0.0)}, _FakeRoster([]), user_label="Me",
        mic_me=tier.winner, mic_tier=tier, voiceprint=None)
    assert "Me" not in res.mapping.values()
    assert res.owner.tier == "none" and res.owner_id is None


def test_a_below_floor_owner_is_named_by_the_voiceprint_tier_when_one_matches():
    segs = [_seg("owner", 0, 10), _seg("remote", 10, 300)]
    tier = _tier({"owner": 10.0, "remote": 0.0}, {"owner": 10.0, "remote": 290.0})
    vp = _unit_at(1.0)
    res = resolve_speaker_labels(
        segs, {"owner": _unit_at(1.0), "remote": _unit_at(0.0)}, _FakeRoster([]), user_label="Me",
        mic_me=tier.winner, voiceprint_me="owner", mic_tier=tier, voiceprint=vp)
    assert res.mapping["owner"] == "Me" and res.mapping["remote"].startswith("THEM-")
    assert res.owner.tier == "voiceprint" and res.owner.mic_seconds == 10.0


def test_owner_pick_promotes_the_split_leader_only_without_a_voiceprint():
    tier = _tier({"a": 300.0, "b": 260.0}, {"a": 300.0, "b": 260.0})
    assert tier.owner_pick(None) == "a"
    assert tier.owner_pick(_unit_at(1.0)) is None
    assert _tier({"a": 400.0, "b": 10.0}, {"a": 400.0, "b": 10.0}).owner_pick(None) == "a"


def test_a_voiceprint_decides_a_split_alone_and_folds_nothing():
    # Stronger than the case above: the voiceprint names the LEADER, so a fold gated only on the
    # tier would still pull the contender in. With a print, tier is `voiceprint`, never `mic`.
    segs = [_seg("a", 0, 300), _seg("b", 300, 560)]
    tier = _tier({"a": 300.0, "b": 260.0}, {"a": 300.0, "b": 260.0})
    res = resolve_speaker_labels(
        segs, {"a": _unit_at(1.0), "b": _unit_at(0.0)}, _FakeRoster([]), user_label="Me",
        mic_me=tier.owner_pick(_unit_at(1.0)), voiceprint_me="a", mic_tier=tier, voiceprint=_unit_at(1.0))
    assert res.mapping["a"] == "Me" and res.mapping["b"].startswith("THEM-")
    assert res.owner.tier == "voiceprint" and res.owner.folded == 0
