"""Tests for the on-device embedding index (AI2 / AI3).

CI-safe: exercises the numpy `HashingEmbedder` and the pure index machinery; the
MLX path is never imported (it is integration-tested by the real spike run).
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from mp import embed_index, resource_guard
from mp.embed_index import Chunk, EmbeddingIndex, HashingEmbedder, chunk_library, default_embedder
from mp.resource_guard import LOW_MEMORY_MARKER, LowMemoryError, MemorySample, MemoryWatchdog


def _meeting(root: Path, stem: str, *, title: str, transcript: str, summary: str = "") -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / f"{stem}.md").write_text(transcript, encoding="utf-8")
    (root / f"{stem}.summary.json").write_text(json.dumps({"title": title}), encoding="utf-8")
    (root / f"{stem}.summary.md").write_text(summary or f"# {title}\n", encoding="utf-8")


class CountingEmbedder(HashingEmbedder):
    """A `HashingEmbedder` that records every text it was handed. AI11's whole
    claim is about what a refresh does NOT re-embed, and the only way to observe
    that is to count the calls."""

    def __init__(self, dim: int = 64) -> None:
        super().__init__(dim=dim)
        self.embedded: list[str] = []
        self.batches = 0
        self.releases = 0

    def embed(self, texts: list[str], kind: str = "passage") -> np.ndarray:  # type: ignore[override]
        self.batches += 1
        self.embedded.extend(texts)
        return super().embed(texts, kind)  # type: ignore[arg-type]

    def release(self) -> None:
        self.releases += 1


class KilledEmbedder(CountingEmbedder):
    """Stops dead after `survive` batches, standing in for the daemon's SIGTERM
    at the ten-minute mark. Whatever the run had checkpointed is what survives."""

    def __init__(self, *, survive: int, dim: int = 64) -> None:
        super().__init__(dim=dim)
        self.survive = survive

    def embed(self, texts: list[str], kind: str = "passage") -> np.ndarray:  # type: ignore[override]
        if self.batches >= self.survive:
            raise RuntimeError("simulated kill mid-build")
        return super().embed(texts, kind)


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
    assert manifest["schema_version"] == embed_index.INDEX_SCHEMA_VERSION
    # AI11: the per-stem freshness map is what a later refresh diffs against.
    assert set(manifest["stems"]) == {"m1", "m2"}

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


# ----- AI11: incremental refresh -----


def test_plan_refresh_is_a_pure_three_way_diff() -> None:
    plan = embed_index.plan_refresh(
        prior={"same": "a", "edited": "b", "gone": "c"},
        current={"same": "a", "edited": "b2", "new": "d"},
    )
    assert plan.stale == ["edited", "new"]
    assert plan.removed == ["gone"]
    assert plan.unchanged == ["same"]
    assert not plan.is_noop
    assert embed_index.plan_refresh({"a": "1"}, {"a": "1"}).is_noop


def test_only_the_changed_meeting_is_re_embedded(tmp_path: Path) -> None:
    """The headline AI11 fix: one edited meeting used to invalidate all 400."""
    lib, idx_dir = tmp_path / "lib", tmp_path / "idx"
    _meeting(lib, "m1", title="One", transcript="alpha budget cut spending")
    _meeting(lib, "m2", title="Two", transcript="beta hiring interview loop")
    embed_index.load_or_build(lib, idx_dir, CountingEmbedder())

    (lib / "m1.md").write_text("alpha budget cut spending much more deeply", encoding="utf-8")
    second = CountingEmbedder()
    index = embed_index.load_or_build(lib, idx_dir, second)

    assert any("deeply" in t for t in second.embedded)          # the edit was picked up
    assert not any("hiring" in t for t in second.embedded)      # its neighbour was not
    assert {c.stem for c in index.chunks} == {"m1", "m2"}
    assert index.vectors.shape[0] == len(index.chunks)
    assert "deeply" in "\n".join(c.text for c in index.chunks)


def test_a_removed_meeting_loses_its_vectors(tmp_path: Path) -> None:
    lib, idx_dir = tmp_path / "lib", tmp_path / "idx"
    _meeting(lib, "m1", title="One", transcript="alpha budget cut spending")
    _meeting(lib, "m2", title="Two", transcript="beta hiring interview loop")
    embed_index.load_or_build(lib, idx_dir, CountingEmbedder())

    for p in lib.glob("m2.*"):
        p.unlink()
    third = CountingEmbedder()
    index = embed_index.load_or_build(lib, idx_dir, third)

    assert {c.stem for c in index.chunks} == {"m1"}
    assert "m2" not in index.stems
    assert index.vectors.shape[0] == len(index.chunks)
    assert third.embedded == []  # a deletion re-embeds nothing at all
    assert all(hit.chunk.stem == "m1" for hit in index.search("hiring interview", k=5))


def test_a_killed_build_resumes_from_its_checkpoint(tmp_path: Path, monkeypatch) -> None:
    """Kill it mid-build, run it again, it finishes from where it was. Before
    this the index was saved only after a complete build, so a library too big
    for the daemon's ten-minute cap rebuilt from zero on every ask, forever."""
    monkeypatch.setattr(embed_index, "CHECKPOINT_EVERY_STEMS", 1)
    lib, idx_dir = tmp_path / "lib", tmp_path / "idx"
    for i in range(4):
        _meeting(lib, f"m{i}", title=f"T{i}", transcript=f"topic-{i} discussion " * 30)

    killed = KilledEmbedder(survive=2)
    with pytest.raises(RuntimeError):
        embed_index.load_or_build(lib, idx_dir, killed)
    assert killed.batches == 2

    resumed = CountingEmbedder()
    index = embed_index.load_or_build(lib, idx_dir, resumed)

    # Only the two meetings the kill never reached were embedded again.
    assert resumed.batches == 2
    assert not any("topic-0" in t or "topic-1" in t for t in resumed.embedded)
    assert {c.stem for c in index.chunks} == {"m0", "m1", "m2", "m3"}
    # And a resumed index is the same index a single pass would have produced.
    clean = EmbeddingIndex.build(lib, CountingEmbedder())
    assert [c.to_json() for c in index.chunks] == [c.to_json() for c in clean.chunks]
    assert np.allclose(index.vectors, clean.vectors)


def test_a_checkpoint_is_not_mistaken_for_a_finished_index(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(embed_index, "CHECKPOINT_EVERY_STEMS", 1)
    lib, idx_dir = tmp_path / "lib", tmp_path / "idx"
    for i in range(3):
        _meeting(lib, f"m{i}", title=f"T{i}", transcript=f"topic-{i} discussion")
    with pytest.raises(RuntimeError):
        embed_index.load_or_build(lib, idx_dir, KilledEmbedder(survive=1))

    manifest = json.loads((idx_dir / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["fingerprint"] == ""       # the completeness stamp is withheld
    assert set(manifest["stems"]) == {"m0"}    # exactly what got embedded


def test_a_v1_index_is_rebuilt_once_rather_than_trusted(tmp_path: Path) -> None:
    """A cache written before AI11 has no per-stem map, so its rows cannot be
    attributed to a meeting. Rebuild it once instead of guessing."""
    lib, idx_dir = tmp_path / "lib", tmp_path / "idx"
    _meeting(lib, "m1", title="One", transcript="alpha budget")
    embed_index.load_or_build(lib, idx_dir, CountingEmbedder())
    manifest_path = idx_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["schema_version"] = 1
    manifest.pop("stems")
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

    again = CountingEmbedder()
    index = embed_index.load_or_build(lib, idx_dir, again)
    assert again.embedded, "a v1 cache must be re-embedded, not reused blind"
    assert index.stems and set(index.stems) == {"m1"}


def test_a_meeting_with_no_text_stays_current_instead_of_retrying(tmp_path: Path) -> None:
    lib, idx_dir = tmp_path / "lib", tmp_path / "idx"
    (lib).mkdir(parents=True, exist_ok=True)
    (lib / "empty.summary.json").write_text(json.dumps({"title": "T"}), encoding="utf-8")
    _meeting(lib, "m1", title="One", transcript="alpha budget")
    index = embed_index.load_or_build(lib, idx_dir, CountingEmbedder())
    assert "empty" in index.stems
    again = CountingEmbedder()
    embed_index.load_or_build(lib, idx_dir, again)
    assert again.embedded == []  # nothing stale, so nothing re-embedded


def test_refresh_reports_progress_per_batch(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(embed_index, "CHECKPOINT_EVERY_STEMS", 1)
    lib, idx_dir = tmp_path / "lib", tmp_path / "idx"
    for i in range(3):
        _meeting(lib, f"m{i}", title=f"T{i}", transcript=f"topic-{i}")
    seen: list[embed_index.IndexProgress] = []
    embed_index.load_or_build(lib, idx_dir, CountingEmbedder(), on_progress=seen.append)
    assert [p.stems_done for p in seen] == [1, 2, 3]
    assert all(p.stems_total == 3 for p in seen)
    assert seen[-1].chunks_done > 0


# ----- AI11: memory bounds -----


def _sample(free_pct: float, total: int = 32 * 1024 ** 3) -> MemorySample:
    return MemorySample(free_bytes=int(total * free_pct / 100), total_bytes=total)


def test_the_embed_pass_aborts_on_the_free_ram_floor(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv(resource_guard.OVERRIDE_ENV, "1")  # the suite disables it by default
    monkeypatch.setenv("MEETINGPIPE_LOGS_DIR", str(tmp_path / "logs"))
    lib, idx_dir = tmp_path / "lib", tmp_path / "idx"
    _meeting(lib, "m1", title="One", transcript="alpha budget")

    watchdog = MemoryWatchdog(floor_pct=10.0, sampler=lambda: _sample(3.0))
    with pytest.raises(LowMemoryError) as excinfo:
        embed_index.load_or_build(lib, idx_dir, CountingEmbedder(), watchdog=watchdog)
    message = str(excinfo.value)
    assert LOW_MEMORY_MARKER in message          # the phrase the daemon matches
    assert embed_index.EMBED_STAGE in message    # ... and where it happened

    rows = [
        json.loads(line)
        for line in (tmp_path / "logs" / "pipeline_events.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    aborted = [r for r in rows if r["action"] == "memory_guard_aborted"]
    assert len(aborted) == 1
    assert aborted[0]["stage"] == embed_index.EMBED_STAGE


def test_an_abort_keeps_the_work_already_checkpointed(tmp_path: Path, monkeypatch) -> None:
    """The guard fires between batches, so everything before it is already on
    disk: an abort costs the current batch, not the whole build."""
    monkeypatch.setenv(resource_guard.OVERRIDE_ENV, "1")
    monkeypatch.setattr(embed_index, "CHECKPOINT_EVERY_STEMS", 1)
    lib, idx_dir = tmp_path / "lib", tmp_path / "idx"
    for i in range(3):
        _meeting(lib, f"m{i}", title=f"T{i}", transcript=f"topic-{i} discussion")

    free = {"pct": 50.0}
    watchdog = MemoryWatchdog(
        floor_pct=10.0, sampler=lambda: _sample(free["pct"]),
        min_interval_sec=0.0, clock=lambda: 0.0,
    )

    class _PressureEmbedder(CountingEmbedder):
        def embed(self, texts, kind="passage"):  # type: ignore[override]
            vectors = super().embed(texts, kind)
            free["pct"] = 2.0  # memory collapses as the first meeting finishes
            return vectors

    with pytest.raises(LowMemoryError):
        embed_index.load_or_build(lib, idx_dir, _PressureEmbedder(), watchdog=watchdog)
    manifest = json.loads((idx_dir / "manifest.json").read_text(encoding="utf-8"))
    assert set(manifest["stems"]) == {"m0"}
    # And the next run picks up the other two rather than starting over.
    resumed = CountingEmbedder()
    index = embed_index.load_or_build(lib, idx_dir, resumed)
    assert {c.stem for c in index.chunks} == {"m0", "m1", "m2"}
    assert not any("topic-0" in t for t in resumed.embedded)


def test_the_embedder_can_be_released_and_reloaded(tmp_path: Path) -> None:
    lib, idx_dir = tmp_path / "lib", tmp_path / "idx"
    _meeting(lib, "m1", title="One", transcript="alpha budget cut")
    embedder = CountingEmbedder()
    index = embed_index.load_or_build(lib, idx_dir, embedder)
    index.release_embedder()
    assert embedder.releases == 1
    # Release is not a close: retrieval still works if anything asks again.
    assert index.search("budget", k=1)[0].chunk.stem == "m1"


# ----- AI11: the embedder preflight under an armed egress guard -----


def test_mlx_embedder_refuses_an_uncached_model_under_the_guard(monkeypatch) -> None:
    monkeypatch.setattr(embed_index.egress_guard, "is_armed", lambda: True)
    monkeypatch.setattr(embed_index, "model_is_cached", lambda repo_id: False)
    embedder = embed_index.MLXEmbedder("mlx-community/multilingual-e5-small-mlx")
    with pytest.raises(embed_index.EmbedderUnavailableError) as excinfo:
        embedder.embed(["anything"])
    message = str(excinfo.value)
    # UX21's shape: what happened, why it cannot be fixed now, and the one command.
    assert "not in the local HuggingFace cache" in message
    assert "mp prefetch-model mlx-community/multilingual-e5-small-mlx" in message


def test_mlx_embedder_does_not_refuse_a_cached_model(monkeypatch) -> None:
    monkeypatch.setattr(embed_index.egress_guard, "is_armed", lambda: True)
    monkeypatch.setattr(embed_index, "model_is_cached", lambda repo_id: True)
    loaded: list[str] = []

    def _fake_load(repo_id: str):
        loaded.append(repo_id)
        return object(), object()

    monkeypatch.setitem(
        __import__("sys").modules, "mlx_embeddings.utils", type("M", (), {"load": staticmethod(_fake_load)})
    )
    monkeypatch.setitem(__import__("sys").modules, "mlx_embeddings", type("P", (), {}))
    embedder = embed_index.MLXEmbedder("some/model")
    embedder._ensure_loaded()
    assert loaded == ["some/model"]
