"""FEAT3-VOICEPRINT: the persisted running-average self-voiceprint."""
from __future__ import annotations

import json
import math

from mp.diarize import cosine_similarity
from mp.voiceprint import EMBEDDING_DIM, VoiceprintStore


def _unit(seed: float) -> list[float]:
    """A deterministic unit vector of the right dimension."""
    v = [math.sin(seed + i) for i in range(EMBEDDING_DIM)]
    norm = math.sqrt(sum(x * x for x in v))
    return [x / norm for x in v]


def test_absent_file_reads_as_unenrolled(tmp_path):
    store = VoiceprintStore(tmp_path / "vp.json")
    assert store.load() == (None, 0)
    assert store.embedding() is None
    assert store.meetings() == 0


def test_first_update_persists_normalized_and_counts_one(tmp_path):
    store = VoiceprintStore(tmp_path / "vp.json")
    assert store.update(_unit(0.1)) == 1
    emb, meetings = store.load()
    assert meetings == 1
    assert emb is not None and len(emb) == EMBEDDING_DIM
    assert math.isclose(math.sqrt(sum(x * x for x in emb)), 1.0, abs_tol=1e-6)


def test_running_mean_moves_toward_new_sample_and_increments(tmp_path):
    store = VoiceprintStore(tmp_path / "vp.json")
    a, b = _unit(0.0), _unit(5.0)  # two different directions
    store.update(a)
    store.update(b)
    assert store.meetings() == 2
    emb = store.embedding()
    # The mean sits between the two samples: positively similar to both, but
    # no longer identical to either.
    assert cosine_similarity(emb, a) > 0.0
    assert cosine_similarity(emb, b) > 0.0
    assert cosine_similarity(emb, a) < 0.9999


def test_wrong_dimension_sample_is_ignored(tmp_path):
    store = VoiceprintStore(tmp_path / "vp.json")
    store.update(_unit(0.2))
    assert store.update([1.0, 2.0, 3.0]) == 1  # count unchanged
    assert store.meetings() == 1


def test_reset_forgets_the_profile(tmp_path):
    path = tmp_path / "vp.json"
    store = VoiceprintStore(path)
    store.update(_unit(0.3))
    assert path.exists()
    store.reset()
    assert not path.exists()
    assert store.load() == (None, 0)
    store.reset()  # idempotent on an absent file


def test_malformed_or_wrong_dim_file_reads_as_unenrolled(tmp_path):
    path = tmp_path / "vp.json"
    path.write_text("{ not json", encoding="utf-8")
    assert VoiceprintStore(path).load() == (None, 0)
    path.write_text(json.dumps({"embedding": [1.0, 2.0], "meetings": 3}), encoding="utf-8")
    assert VoiceprintStore(path).load() == (None, 0)


def test_write_shape_has_schema_version(tmp_path):
    path = tmp_path / "vp.json"
    VoiceprintStore(path).update(_unit(0.4))
    data = json.loads(path.read_text(encoding="utf-8"))
    assert data["schema_version"] == 1
    assert data["meetings"] == 1
    assert len(data["embedding"]) == EMBEDDING_DIM
