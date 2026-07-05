"""FEAT3-ROSTER: named-speaker roster store, k-means centroids, two-gate match."""
from __future__ import annotations

import json
import math

from mp.roster import EMBEDDING_DIM, RosterStore, kmeans_centroids


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
