"""STOR7: `mp index-prune` drops a deleted meeting's rows from the search-index cache and
leaves every other meeting's rows (and vectors) as they were."""

from __future__ import annotations

from pathlib import Path

import numpy as np

from mp import embed_index, index_prune
from mp.embed_index import EmbeddingIndex, HashingEmbedder, prune_stems


def _meeting(root: Path, stem: str, transcript: str) -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / f"{stem}.md").write_text(transcript, encoding="utf-8")


def _built(tmp_path: Path) -> tuple[Path, EmbeddingIndex]:
    lib = tmp_path / "lib"
    _meeting(lib, "m1", "A: budget cut spending forecast.\n")
    _meeting(lib, "m2", "A: interview loop and offers.\n")
    _meeting(lib, "m3", "A: release train and hotfix.\n")
    index = EmbeddingIndex.build(lib, HashingEmbedder())
    index.stems = {"m1": "a", "m2": "b", "m3": "c"}
    out = tmp_path / "index"
    index.save(out)
    return out, index


def test_prune_removes_the_stems_rows_and_keeps_the_rest(tmp_path: Path) -> None:
    out, before = _built(tmp_path)
    kept_rows = [i for i, c in enumerate(before.chunks) if c.stem != "m2"]
    removed = prune_stems(out, ["m2"])

    after = EmbeddingIndex.load(out, HashingEmbedder())
    assert removed == len(before.chunks) - len(kept_rows) > 0
    assert {c.stem for c in after.chunks} == {"m1", "m3"}
    assert "m2" not in after.stems and set(after.stems) == {"m1", "m3"}
    assert np.array_equal(after.vectors, before.vectors[kept_rows])


def test_prune_never_loads_the_real_embedder(tmp_path: Path, monkeypatch) -> None:
    out, _ = _built(tmp_path)

    def boom(*_a, **_k):
        raise AssertionError("a prune must not construct the embedding model")

    monkeypatch.setattr(embed_index, "default_embedder", boom)
    assert prune_stems(out, ["m1"]) > 0


def test_prune_of_an_unknown_stem_writes_nothing(tmp_path: Path) -> None:
    out, _ = _built(tmp_path)
    manifest = (out / embed_index.MANIFEST_NAME).read_bytes()
    assert prune_stems(out, ["nope"]) == 0
    assert (out / embed_index.MANIFEST_NAME).read_bytes() == manifest


def test_prune_with_no_index_is_a_no_op(tmp_path: Path) -> None:
    assert prune_stems(tmp_path / "missing", ["m1"]) == 0
    assert not (tmp_path / "missing").exists()


def test_cli_accepts_the_daemons_argv(tmp_path: Path) -> None:
    """`PipelineLauncher.pruneSearchIndex` sends `index-prune -- <stems>`; never run without
    `--index-dir` here, since the default is the owner's real cache."""
    out, _ = _built(tmp_path)
    assert index_prune.main(["--index-dir", str(out), "--", "m1"]) == 0
    assert {c.stem for c in EmbeddingIndex.load(out, HashingEmbedder()).chunks} == {"m2", "m3"}


def test_cli_prunes_and_exits_zero(tmp_path: Path, capsys) -> None:
    out, _ = _built(tmp_path)
    assert index_prune.main(["--index-dir", str(out), "m1", "m3"]) == 0
    assert {c.stem for c in EmbeddingIndex.load(out, HashingEmbedder()).chunks} == {"m2"}
    assert "pruned" in capsys.readouterr().out
