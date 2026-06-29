"""Tests for the on-device embedding index (AI2 / AI3).

CI-safe: exercises the numpy `HashingEmbedder` and the pure index machinery; the
MLX path is never imported (it is integration-tested by the real spike run).
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from mp import embed_index
from mp.embed_index import Chunk, EmbeddingIndex, HashingEmbedder, chunk_library, default_embedder


def _meeting(root: Path, stem: str, *, title: str, transcript: str, summary: str = "") -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / f"{stem}.md").write_text(transcript, encoding="utf-8")
    (root / f"{stem}.summary.json").write_text(json.dumps({"title": title}), encoding="utf-8")
    (root / f"{stem}.summary.md").write_text(summary or f"# {title}\n", encoding="utf-8")


# ----- HashingEmbedder -----


def test_hashing_embedder_is_deterministic_and_normalized() -> None:
    e = HashingEmbedder(dim=256)
    a = e.embed(["the budget was cut in Q3"])
    b = e.embed(["the budget was cut in Q3"])
    assert a.shape == (1, 256)
    assert np.allclose(a, b)  # stable across calls (blake2b, not salted hash())
    assert np.isclose(np.linalg.norm(a[0]), 1.0, atol=1e-5)


def test_hashing_embedder_cosine_tracks_lexical_overlap() -> None:
    e = HashingEmbedder(dim=512)
    vecs = e.embed(["postgres migration risk", "postgres migration plan", "lunch menu options"])
    sim_related = float(vecs[0] @ vecs[1])
    sim_unrelated = float(vecs[0] @ vecs[2])
    assert sim_related > sim_unrelated


def test_hashing_embedder_handles_empty_text() -> None:
    e = HashingEmbedder(dim=64)
    v = e.embed([""])
    # zero token vector stays finite (norm clamp), not NaN.
    assert v.shape == (1, 64)
    assert np.all(np.isfinite(v))


# ----- chunk_library -----


def test_chunk_library_reads_summary_and_transcript(tmp_path: Path) -> None:
    _meeting(tmp_path, "20260506-1500", title="Budget review", transcript="A: we cut the budget.\n")
    chunks = chunk_library(tmp_path)
    assert chunks
    assert all(isinstance(c, Chunk) for c in chunks)
    assert chunks[0].stem == "20260506-1500"
    assert chunks[0].title == "Budget review"


def test_chunk_library_skips_meetings_with_no_text(tmp_path: Path) -> None:
    (tmp_path / "20260506-1600.meta.json").write_text("{}", encoding="utf-8")
    assert chunk_library(tmp_path) == []


def test_chunk_library_windows_long_text(tmp_path: Path) -> None:
    long_transcript = "word " * 2000  # ~10k chars -> several windows
    _meeting(tmp_path, "m1", title="Long", transcript=long_transcript)
    chunks = chunk_library(tmp_path, chunk_chars=1200, overlap=200)
    assert len(chunks) > 1
    assert all(c.stem == "m1" for c in chunks)


# ----- EmbeddingIndex -----


def test_index_search_ranks_relevant_chunk_first(tmp_path: Path) -> None:
    _meeting(tmp_path, "hiring", title="Hiring sync", transcript="A: interview loop and offers.\n")
    _meeting(tmp_path, "budget", title="Budget", transcript="A: budget budget cut spending forecast.\n")
    index = EmbeddingIndex.build(tmp_path, HashingEmbedder())
    hits = index.search("budget forecast", k=5)
    assert hits
    assert hits[0].chunk.stem == "budget"
    assert hits[0].score > 0


def test_index_empty_library_is_safe(tmp_path: Path) -> None:
    index = EmbeddingIndex.build(tmp_path, HashingEmbedder())
    assert index.chunks == []
    assert index.search("anything", k=5) == []


def test_index_save_load_round_trip(tmp_path: Path) -> None:
    lib = tmp_path / "lib"
    _meeting(lib, "m1", title="Budget", transcript="A: budget cut spending.\n")
    _meeting(lib, "m2", title="Hiring", transcript="A: interview loop offers.\n")
    built = EmbeddingIndex.build(lib, HashingEmbedder())

    out = tmp_path / "index"
    built.save(out)
    assert (out / "vectors.npy").exists()
    assert (out / "chunks.jsonl").exists()
    manifest = json.loads((out / "manifest.json").read_text())
    assert manifest["count"] == len(built.chunks)
    assert manifest["schema_version"] == 1

    loaded = EmbeddingIndex.load(out, HashingEmbedder())
    assert [c.to_json() for c in loaded.chunks] == [c.to_json() for c in built.chunks]
    assert np.allclose(loaded.vectors, built.vectors)
    # search still works after reload
    assert loaded.search("budget", k=1)[0].chunk.stem == "m1"


def test_search_dim_mismatch_raises(tmp_path: Path) -> None:
    _meeting(tmp_path, "m1", title="Budget", transcript="A: budget.\n")
    index = EmbeddingIndex.build(tmp_path, HashingEmbedder(dim=256))
    # Reload claiming the same vectors but query through a different-width embedder.
    index.embedder = HashingEmbedder(dim=128)
    try:
        index.search("budget", k=1)
        raise AssertionError("expected a dim-mismatch ValueError")
    except ValueError as e:
        assert "dim" in str(e)


# ----- default_embedder selection -----


def test_default_embedder_falls_back_without_mlx(monkeypatch) -> None:
    monkeypatch.setattr(embed_index.importlib.util, "find_spec", lambda name: None)
    assert isinstance(default_embedder(), HashingEmbedder)


def test_default_embedder_uses_mlx_when_present(monkeypatch) -> None:
    monkeypatch.setattr(
        embed_index.importlib.util,
        "find_spec",
        lambda name: object() if name == "mlx_embeddings" else None,
    )
    e = default_embedder("mlx-community/multilingual-e5-small-mlx")
    assert isinstance(e, embed_index.MLXEmbedder)
    assert e.name == "mlx-community/multilingual-e5-small-mlx"
