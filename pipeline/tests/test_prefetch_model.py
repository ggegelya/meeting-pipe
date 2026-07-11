from pathlib import Path

from mp.prefetch_model import _bytes_on_disk, _incremental_bytes


def _write(path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"x" * size)


def test_incremental_matches_full_walk_on_first_pass(tmp_path: Path):
    _write(tmp_path / "blobs" / "a", 100)
    _write(tmp_path / "blobs" / "b", 50)
    counted: dict[str, int] = {}
    assert _incremental_bytes(tmp_path, counted) == _bytes_on_disk(tmp_path) == 150


def test_incremental_picks_up_new_files_across_ticks(tmp_path: Path):
    _write(tmp_path / "a", 100)
    counted: dict[str, int] = {}
    assert _incremental_bytes(tmp_path, counted) == 100
    _write(tmp_path / "b", 25)
    # A second tick reuses the cached size for "a" and only measures "b".
    assert _incremental_bytes(tmp_path, counted) == 125


def test_incomplete_rename_does_not_double_count(tmp_path: Path):
    # HF writes `<blob>.incomplete`, then renames it to the final name on finish.
    inc = tmp_path / "blobs" / "deadbeef.incomplete"
    _write(inc, 40)
    counted: dict[str, int] = {}
    assert _incremental_bytes(tmp_path, counted) == 40
    inc.rename(tmp_path / "blobs" / "deadbeef")
    # The finished blob counts once; the vanished `.incomplete` entry is dropped.
    assert _incremental_bytes(tmp_path, counted) == 40


def test_missing_dir_is_zero(tmp_path: Path):
    assert _incremental_bytes(tmp_path / "nope", {}) == 0
