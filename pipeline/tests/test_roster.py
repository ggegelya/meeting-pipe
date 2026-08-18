"""FEAT3-ROSTER: named-speaker roster store, k-means centroids, two-gate match."""
from __future__ import annotations

import json
import math

from mp.roster import (
    EMBEDDING_DIM,
    MATCH_MARGIN,
    MATCH_MIN,
    SUGGEST_MIN,
    RosterStore,
    kmeans_centroids,
)


def _axis(i: int, *, tilt: float = 0.0, tilt_axis: int = 1) -> list[float]:
    """A 256-d unit vector pointing mostly along axis `i`, optionally tilted
    toward another axis so two people can be made near or far apart."""
    v = [0.0] * EMBEDDING_DIM
    v[i] = 1.0
    if tilt:
        v[tilt_axis] = tilt
    norm = math.sqrt(sum(x * x for x in v))
    return [x / norm for x in v]


def test_empty_roster_matches_nothing(tmp_path):
    roster = RosterStore(tmp_path / "roster.json")
    assert roster.names() == []
    assert roster.match(_axis(0)) is None


def test_enroll_then_match_single_person(tmp_path):
    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("Alice", _axis(0))
    assert roster.names() == ["Alice"]
    # A query close to Alice's direction matches; an orthogonal one does not.
    assert roster.match(_axis(0, tilt=0.05, tilt_axis=2)) == "Alice"
    assert roster.match(_axis(50)) is None  # orthogonal -> below MATCH_MIN


def test_two_gate_leaves_ambiguous_unknown(tmp_path):
    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("Alice", _axis(0))
    roster.enroll("Carol", _axis(0, tilt=0.15))  # very close to Alice
    # A query near both clears MATCH_MIN for each, but the runner-up margin
    # fails, so the roster refuses to guess and leaves it unknown.
    assert roster.match(_axis(0)) is None


def test_well_separated_people_each_match(tmp_path):
    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("Alice", _axis(0))
    roster.enroll("Bob", _axis(1))
    assert roster.match(_axis(0, tilt=0.05, tilt_axis=2)) == "Alice"
    assert roster.match(_axis(1, tilt=0.05, tilt_axis=2)) == "Bob"


def test_enroll_accumulates_samples_and_recomputes_centroids(tmp_path):
    path = tmp_path / "roster.json"
    roster = RosterStore(path)
    roster.enroll("Alice", _axis(0))
    roster.enroll("Alice", _axis(0, tilt=0.1))
    people = json.loads(path.read_text(encoding="utf-8"))["people"]
    assert len(people) == 1
    assert people[0]["name"] == "Alice"
    assert len(people[0]["samples"]) == 2
    assert 1 <= len(people[0]["centroids"]) <= 3


def test_enroll_ignores_wrong_dimension(tmp_path):
    path = tmp_path / "roster.json"
    roster = RosterStore(path)
    roster.enroll("Alice", [1.0, 2.0, 3.0])  # not 256-d
    assert roster.names() == []
    assert not path.exists()


def test_forget_removes_person(tmp_path):
    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("Alice", _axis(0))
    roster.enroll("Bob", _axis(1))
    assert roster.forget("Alice") is True
    assert roster.names() == ["Bob"]
    assert roster.forget("Nobody") is False


def test_rename_keeps_samples_and_centroids(tmp_path):
    path = tmp_path / "roster.json"
    roster = RosterStore(path)
    roster.enroll("Alice", _axis(0))
    roster.enroll("Alice", _axis(0, tilt=0.1))
    before = json.loads(path.read_text(encoding="utf-8"))["people"][0]
    assert roster.rename("Alice", "Alicia") is True
    after = json.loads(path.read_text(encoding="utf-8"))["people"][0]
    assert after["name"] == "Alicia"
    assert after["samples"] == before["samples"]
    assert after["centroids"] == before["centroids"]
    # The voiceprint still matches under the new name.
    assert roster.match(_axis(0, tilt=0.05, tilt_axis=2)) == "Alicia"


def test_rename_absent_person_is_false(tmp_path):
    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("Alice", _axis(0))
    assert roster.rename("Nobody", "Somebody") is False
    assert roster.names() == ["Alice"]


def test_rename_collision_refuses_to_merge(tmp_path):
    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("Alice", _axis(0))
    roster.enroll("Bob", _axis(1))
    assert roster.rename("Alice", "Bob") is False
    assert sorted(roster.names()) == ["Alice", "Bob"]


def test_rename_to_same_name_is_true_noop(tmp_path):
    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("Alice", _axis(0))
    assert roster.rename("Alice", "Alice") is True
    assert roster.names() == ["Alice"]


def test_rename_empty_new_is_false(tmp_path):
    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("Alice", _axis(0))
    assert roster.rename("Alice", "  ") is False
    assert roster.names() == ["Alice"]


def test_malformed_file_is_empty_roster(tmp_path):
    path = tmp_path / "roster.json"
    path.write_text("{ not json", encoding="utf-8")
    assert RosterStore(path).names() == []
    assert RosterStore(path).match(_axis(0)) is None


def test_kmeans_caps_at_three_centroids():
    samples = [_axis(i) for i in range(6)]  # 6 distinct directions
    centroids = kmeans_centroids(samples, k=3)
    assert len(centroids) == 3
    for c in centroids:
        assert math.isclose(math.sqrt(sum(x * x for x in c)), 1.0, abs_tol=1e-6)


def test_kmeans_single_sample_returns_one_centroid():
    assert len(kmeans_centroids([_axis(0)], k=3)) == 1
    assert kmeans_centroids([], k=3) == []


def test_write_shape_has_schema_version(tmp_path):
    path = tmp_path / "roster.json"
    RosterStore(path).enroll("Alice", _axis(0))
    data = json.loads(path.read_text(encoding="utf-8"))
    assert data["schema_version"] == 1
    assert data["people"][0]["name"] == "Alice"


# --- FEAT14: the near miss the two-gate rule used to throw away ----------------
#
# Every test below is an assertion about a *decline*. The accept rule is what
# names people automatically and it is deliberately untouched here: the first
# test pins that, and the rest describe what the roster now says about the voices
# it still refuses to name.


def _at_cosine(c: float, *, axis: int = 0, filler: int = 200) -> list[float]:
    """A 256-d unit vector whose cosine with `_axis(axis)` is exactly `c`.

    `_axis` tilts are fine for "near" and "far", but a suggestion has thresholds
    on both sides of it, so these tests need to sit a query at a stated distance
    rather than near one.
    """
    v = [0.0] * EMBEDDING_DIM
    v[axis] = c
    v[filler] = math.sqrt(max(0.0, 1.0 - c * c))
    return v


def test_the_two_gates_still_decline_exactly_what_they_declined(tmp_path):
    # The honesty rule is the feature; FEAT14 surfaces what matching already knew
    # and must not buy suggestions by lowering the bar for a name. Both gate
    # constants and both decline shapes, pinned against a change in either.
    assert (MATCH_MIN, MATCH_MARGIN) == (0.65, 0.07)
    assert SUGGEST_MIN < MATCH_MIN, "a suggestion lives below the accept floor"

    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("Alice", _axis(0))
    # Gate one: under the similarity floor, however alone Alice is on the roster.
    assert roster.match(_at_cosine(MATCH_MIN - 0.01)) is None
    assert roster.match(_at_cosine(MATCH_MIN)) == "Alice"

    roster.enroll("Carol", _axis(1))
    both = [0.0] * EMBEDDING_DIM
    both[0], both[1] = 0.80, 0.80 - (MATCH_MARGIN - 0.01)
    # Gate two: clears the floor for Alice by a mile, and still declines, because
    # Carol is level with her.
    assert roster.match(both) is None
    assert roster.match_detail(both).similarity is not None


def test_a_near_miss_is_reported_when_only_the_floor_declined_it(tmp_path):
    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("Alice", _axis(0))
    # The measured shape of the stalled loop: a colleague scores 0.62 against
    # their own centroid, under the 0.65 floor, and the meeting renders them as an
    # unnamed cluster with nothing saying who they nearly were.
    result = roster.match_detail(_at_cosine(0.62))
    assert result.name is None, "the verdict is still to decline"
    assert result.near_miss == "Alice"


def test_a_stranger_is_not_a_near_miss(tmp_path):
    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("Alice", _axis(0))
    # Somebody who has never been enrolled is still *closest* to Alice, since every
    # roster has a nearest person to any voice. Offering her name for every unknown
    # voice in every meeting is how a suggestion becomes noise.
    result = roster.match_detail(_at_cosine(0.30))
    assert (result.name, result.near_miss) == (None, None)


def test_an_ambiguous_pair_suggests_neither_of_them(tmp_path):
    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("Alice", _axis(0))
    roster.enroll("Carol", _axis(1))
    query = [0.0] * EMBEDDING_DIM
    query[0], query[1] = 0.62, 0.60  # both under the floor, and level with each other
    query[200] = math.sqrt(1.0 - 0.62**2 - 0.60**2)
    result = roster.match_detail(query)
    # A top candidate the runner-up is level with is a coin flip between two real
    # people. Naming one of them from a menu is exactly the wrong-name outcome the
    # margin gate exists to prevent, so the margin gates the suggestion too.
    assert (result.name, result.near_miss) == (None, None)


def test_an_accepted_match_carries_no_near_miss(tmp_path):
    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("Alice", _axis(0))
    result = roster.match_detail(_at_cosine(0.90))
    assert result.name == "Alice"
    assert result.near_miss is None, "a name and a suggestion are not both on offer"


def test_an_empty_roster_suggests_nobody(tmp_path):
    # FEAT11's honesty rule at the source: with nobody enrolled the answer is
    # "nobody is enrolled", never a guess.
    roster = RosterStore(tmp_path / "roster.json")
    assert roster.match_detail(_axis(0)) == (None, None, None)
    assert roster.match_detail(None) == (None, None, None)


def test_match_is_the_verdict_half_of_match_detail(tmp_path):
    # `match` is kept as the one-value reader so no caller that only wants the
    # verdict can accidentally act on the suggestion.
    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("Alice", _axis(0))
    for c in (0.30, 0.62, 0.90):
        query = _at_cosine(c)
        assert roster.match(query) == roster.match_detail(query).name
