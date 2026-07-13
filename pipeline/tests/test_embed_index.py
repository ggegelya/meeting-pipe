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


def test_chunk_library_embeds_corrected_transcript_text(tmp_path: Path) -> None:
    """PIPE9: the index embeds the transcript the Library shows (corrections
    applied), so `mp ask` cites corrected text, not the raw pipeline transcript."""
    stem = "20260506-1700"
    tmp_path.mkdir(parents=True, exist_ok=True)
    (tmp_path / f"{stem}.json").write_text(
        json.dumps({"language": "en", "segments": [
            {"start": 0.0, "end": 1.0, "text": "helo wrld", "speaker": "Me"},
        ]}), encoding="utf-8")
    (tmp_path / f"{stem}.md").write_text("**Me**: helo wrld\n", encoding="utf-8")
    (tmp_path / f"{stem}.summary.json").write_text(json.dumps({"title": "T"}), encoding="utf-8")
    (tmp_path / f"{stem}.transcript_corrections.json").write_text(
        json.dumps({"schema_version": 1, "segments": [
            {"index": 0, "original_text": "helo wrld", "edited_text": "hello world"},
        ]}), encoding="utf-8")

    text = "\n".join(c.text for c in chunk_library(tmp_path))
    assert "hello world" in text
    assert "helo wrld" not in text


def test_library_fingerprint_changes_when_a_correction_is_added(tmp_path: Path) -> None:
    """PIPE9: a correction rewrites only the sidecar, not `<stem>.md`, so the
    fingerprint must fold the sidecar in or `mp ask` keeps a stale cached index."""
    stem = "20260506-1700"
    _meeting(tmp_path, stem, title="T", transcript="**Me**: helo wrld\n")
    before = embed_index.library_fingerprint(tmp_path)
    (tmp_path / f"{stem}.transcript_corrections.json").write_text(
        json.dumps({"schema_version": 1, "segments": [
            {"index": 0, "original_text": "helo wrld", "edited_text": "hello world"},
        ]}), encoding="utf-8")
    assert embed_index.library_fingerprint(tmp_path) != before


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


# ----- library_fingerprint + load_or_build (AI3 index reuse) -----


def test_fingerprint_changes_when_a_meeting_is_added(tmp_path: Path) -> None:
    _meeting(tmp_path, "m1", title="One", transcript="alpha")
    fp1 = embed_index.library_fingerprint(tmp_path)
    _meeting(tmp_path, "m2", title="Two", transcript="beta")
    fp2 = embed_index.library_fingerprint(tmp_path)
    assert fp1 != fp2
    assert embed_index.library_fingerprint(tmp_path) == fp2  # stable when unchanged


def test_load_or_build_reuses_a_fresh_index(tmp_path: Path, monkeypatch) -> None:
    _meeting(tmp_path, "m1", title="One", transcript="alpha budget")
    idx_dir = tmp_path / "idx"
    e = HashingEmbedder(dim=128)
    first = embed_index.load_or_build(tmp_path, idx_dir, e)
    # A second call must NOT rebuild: fail the test if build() is invoked.
    def _fail_if_built(*a, **k):  # pragma: no cover - only runs if reuse is broken
        raise AssertionError("load_or_build rebuilt a fresh index instead of reusing it")
    monkeypatch.setattr(EmbeddingIndex, "build", classmethod(_fail_if_built))
    second = embed_index.load_or_build(tmp_path, idx_dir, HashingEmbedder(dim=128))
    assert second.fingerprint == first.fingerprint
    assert len(second.chunks) == len(first.chunks)


def test_load_or_build_rebuilds_when_library_changes(tmp_path: Path) -> None:
    _meeting(tmp_path, "m1", title="One", transcript="alpha")
    idx_dir = tmp_path / "idx"
    e = HashingEmbedder(dim=128)
    first = embed_index.load_or_build(tmp_path, idx_dir, e)
    _meeting(tmp_path, "m2", title="Two", transcript="beta gamma delta")
    second = embed_index.load_or_build(tmp_path, idx_dir, HashingEmbedder(dim=128))
    assert second.fingerprint != first.fingerprint
    assert len(second.chunks) > len(first.chunks)


def test_load_or_build_rebuilds_on_embedder_model_mismatch(tmp_path: Path) -> None:
    _meeting(tmp_path, "m1", title="One", transcript="alpha")
    idx_dir = tmp_path / "idx"
    built = embed_index.load_or_build(tmp_path, idx_dir, HashingEmbedder(dim=64))
    assert built.model == "hashing-64"
    # A different embedder name must not reuse vectors of a different dimension.
    reloaded = embed_index.load_or_build(tmp_path, idx_dir, HashingEmbedder(dim=256))
    assert reloaded.model == "hashing-256"
    assert reloaded.dim == 256
