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
    _fingerprint,
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


# FEAT24: per-sample provenance and `unenroll`, the inverse of one `enroll`.


def _roster_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def _person(path, name):
    return next(p for p in _roster_json(path)["people"] if p["name"] == name)


def test_enroll_records_provenance_aligned_with_samples(tmp_path):
    path = tmp_path / "roster.json"
    roster = RosterStore(path)
    roster.enroll("Alice", _axis(0), stem="m1", label="THEM-A")
    roster.enroll("Alice", _axis(1), stem="m2", label="THEM-B")
    roster.enroll("Alice", _axis(2))  # no provenance given: stays legacy-shaped
    p = _person(path, "Alice")
    assert len(p["samples"]) == len(p["sources"]) == 3
    assert [(x["stem"], x["label"]) if x else None for x in p["sources"]] == [
        ("m1", "THEM-A"),
        ("m2", "THEM-B"),
        None,
    ]


def test_unenroll_removes_only_this_meetings_sample(tmp_path):
    path = tmp_path / "roster.json"
    roster = RosterStore(path)
    for i, stem in enumerate(("m1", "m2", "m3")):
        roster.enroll("Alice", _axis(i), stem=stem, label="THEM-A")
    removed, person_removed = roster.unenroll("Alice", "m2", "THEM-A")
    assert (removed, person_removed) == (1, False)
    p = _person(path, "Alice")
    assert [s["stem"] for s in p["sources"]] == ["m1", "m3"]
    assert len(p["samples"]) == 2
    assert p["centroids"] == kmeans_centroids(p["samples"])
    # Still recognised from the meetings that remain.
    assert roster.match(_axis(0, tilt=0.05, tilt_axis=5)) == "Alice"


def test_unenroll_sole_sample_removes_the_person(tmp_path):
    path = tmp_path / "roster.json"
    roster = RosterStore(path)
    roster.enroll("Alice", _axis(0), stem="m1", label="THEM-A")
    roster.enroll("Bob", _axis(1), stem="m1", label="THEM-B")
    assert roster.unenroll("Alice", "m1", "THEM-A") == (1, True)
    assert roster.names() == ["Bob"]


def test_unenroll_other_label_or_stem_or_person_is_byte_identical(tmp_path):
    path = tmp_path / "roster.json"
    roster = RosterStore(path)
    roster.enroll("Alice", _axis(0), stem="m1", label="THEM-A")
    before = path.read_bytes()
    assert roster.unenroll("Alice", "m1", "THEM-B") == (0, False)
    assert roster.unenroll("Alice", "m9", "THEM-A") == (0, False)
    assert roster.unenroll("Nobody", "m1", "THEM-A") == (0, False)
    assert path.read_bytes() == before


def test_unenroll_legacy_sample_needs_a_matching_vector(tmp_path):
    path = tmp_path / "roster.json"
    roster = RosterStore(path)
    roster.enroll("Alice", _axis(0))  # no provenance
    roster.enroll("Alice", _axis(1), stem="m2", label="THEM-A")
    before = path.read_bytes()
    # No vector given: legacy samples are never touched.
    assert roster.unenroll("Alice", "m1", "THEM-A") == (0, False)
    # A different voice does not match the legacy sample.
    assert roster.unenroll("Alice", "m1", "THEM-A", _axis(7)) == (0, False)
    assert path.read_bytes() == before
    # The same vector (unnormalised, as a sidecar holds it) does.
    assert roster.unenroll("Alice", "m1", "THEM-A", [3.0 * x for x in _axis(0)]) == (1, False)
    p = _person(path, "Alice")
    assert [s["stem"] for s in p["sources"]] == ["m2"]


def test_a_roster_written_before_provenance_loads_matches_and_enrolls(tmp_path):
    path = tmp_path / "roster.json"
    path.write_text(json.dumps({
        "schema_version": 1,
        "people": [{
            "name": "Alice",
            "samples": [_axis(0), _axis(0, tilt=0.05, tilt_axis=2)],
            "centroids": kmeans_centroids([_axis(0), _axis(0, tilt=0.05, tilt_axis=2)]),
        }],
    }))
    roster = RosterStore(path)
    assert roster.match(_axis(0)) == "Alice"
    roster.enroll("Alice", _axis(0, tilt=0.1, tilt_axis=3), stem="m1", label="THEM-A")
    p = _person(path, "Alice")
    assert len(p["samples"]) == 3
    assert p["sources"][:2] == [None, None] and p["sources"][2]["stem"] == "m1"


def test_eviction_and_dimension_filter_keep_provenance_aligned(tmp_path):
    from mp.roster import _MAX_SAMPLES

    path = tmp_path / "roster.json"
    roster = RosterStore(path)
    for i in range(_MAX_SAMPLES + 3):
        roster.enroll("Alice", _axis(i % 200), stem=f"m{i}", label="THEM-A")
    p = _person(path, "Alice")
    assert len(p["samples"]) == len(p["sources"]) == _MAX_SAMPLES
    assert p["sources"][0]["stem"] == "m3" and p["sources"][-1]["stem"] == f"m{_MAX_SAMPLES + 2}"

    # A wrong-dimension sample already on disk goes with its provenance, not another's.
    p["samples"].insert(0, [1.0, 2.0])
    p["sources"].insert(0, {"stem": "bad", "label": "X", "fp": _fingerprint([1.0, 2.0])})
    path.write_text(json.dumps({"schema_version": 1, "people": [p]}))
    roster.enroll("Alice", _axis(150), stem="fresh", label="THEM-A")
    p = _person(path, "Alice")
    assert all(len(s) == EMBEDDING_DIM for s in p["samples"])
    assert len(p["samples"]) == len(p["sources"])
    assert all(src is None or src["stem"] != "bad" for src in p["sources"])
    assert p["sources"][-1]["stem"] == "fresh"


def test_misaligned_sources_read_as_legacy_never_shifted(tmp_path):
    path = tmp_path / "roster.json"
    a, b = _axis(0), _axis(1)
    # An entry carrying the fingerprint of the *other* sample is a shifted list.
    path.write_text(json.dumps({"schema_version": 1, "people": [{
        "name": "Alice", "samples": [a, b],
        "sources": [{"stem": "m1", "label": "THEM-A", "fp": _fingerprint(b)}], "centroids": [],
    }]}))
    roster = RosterStore(path)
    assert roster.unenroll("Alice", "m1", "THEM-A") == (0, False)


def test_a_source_list_shorter_than_the_samples_keeps_the_earlier_provenance(tmp_path):
    # An older install enrolling below the cap appends a sample and leaves `sources` alone:
    # the earlier entries still sit beside their own samples and stay believed.
    path = tmp_path / "roster.json"
    roster = RosterStore(path)
    roster.enroll("Alice", _axis(0), stem="m1", label="L")
    p = _person(path, "Alice")
    p["samples"].append(_axis(9))  # old enroll: no matching sources entry
    path.write_text(json.dumps({"schema_version": 1, "people": [p]}))
    assert roster.unenroll("Alice", "m1", "L") == (1, False)
    assert len(_person(path, "Alice")["samples"]) == 1


def test_rename_keeps_provenance(tmp_path):
    path = tmp_path / "roster.json"
    roster = RosterStore(path)
    roster.enroll("Alice", _axis(0), stem="m1", label="THEM-A")
    assert roster.rename("Alice", "Alicia")
    assert roster.unenroll("Alicia", "m1", "THEM-A") == (1, True)


def test_an_older_writer_that_shifted_the_samples_is_never_believed(tmp_path):
    # An install from before provenance appends a sample, trims to the cap and rewrites the
    # person without touching `sources`: both lists stay the same length but every entry now
    # sits beside the wrong vector. The fingerprint is what stops m6's sample being removed
    # when m5 is undone.
    from mp.roster import _MAX_SAMPLES

    path = tmp_path / "roster.json"
    roster = RosterStore(path)
    for i in range(_MAX_SAMPLES):
        roster.enroll("A", _axis(i), stem=f"m{i}", label="L")
    p = _person(path, "A")
    p["samples"] = (p["samples"] + [_axis(100)])[-_MAX_SAMPLES:]  # old enroll: sources untouched
    path.write_text(json.dumps({"schema_version": 1, "people": [p]}))
    assert roster.unenroll("A", "m5", "L") == (0, False)
    assert len(_person(path, "A")["samples"]) == _MAX_SAMPLES


def test_unenroll_after_the_label_moved_falls_back_to_the_vector(tmp_path):
    # A relabel or re-transcribe can re-key the meeting's embedding to the name, so the
    # daemon asks with a label the sample was not recorded under. Same stem + same vector
    # still removes it; another meeting's sample never does.
    path = tmp_path / "roster.json"
    roster = RosterStore(path)
    roster.enroll("A", _axis(0), stem="m1", label="THEM-A")
    roster.enroll("A", _axis(1), stem="m2", label="THEM-A")
    assert roster.unenroll("A", "m1", "A") == (0, False)  # no vector: provenance only
    assert roster.unenroll("A", "m2", "A", _axis(0)) == (0, False)  # vector is m1's, stem is m2
    assert roster.unenroll("A", "m1", "A", _axis(0)) == (1, False)
    assert [s["stem"] for s in _person(path, "A")["sources"]] == ["m2"]


def test_a_stem_alone_is_kept_as_partial_provenance(tmp_path):
    path = tmp_path / "roster.json"
    roster = RosterStore(path)
    roster.enroll("A", _axis(0), stem="m1")
    assert _person(path, "A")["sources"][0]["stem"] == "m1"


def test_unenroll_ignores_a_vector_that_is_not_a_list(tmp_path):
    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("A", _axis(0), stem="m1", label="L")
    assert roster.unenroll("A", "m1", "L", 5) == (1, True)  # type: ignore[arg-type]


def test_unenroll_ignores_a_non_numeric_vector(tmp_path):
    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("A", _axis(0), stem="m1", label="L")
    assert roster.unenroll("A", "m1", "L", ["x"] * EMBEDDING_DIM) == (1, True)
