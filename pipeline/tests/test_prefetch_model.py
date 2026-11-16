import json
import sys
import types
from pathlib import Path

import pytest

from mp import local_snapshot, prefetch_model
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


# ----- SEC27: a pinned revision, no code, and a recorded pin for a custom model -----

@pytest.fixture
def _hub(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
    monkeypatch.setattr(prefetch_model.time, "sleep", lambda _s: None)
    return tmp_path


def _fake_hub(monkeypatch: pytest.MonkeyPatch, home: Path, *, code: bool = False,
              live_sha: str = "e" * 40) -> dict:
    """A stand-in `huggingface_hub`: records what `snapshot_download` was asked for
    and lays the snapshot down where the real one would."""
    calls: dict = {}

    def snapshot_download(repo_id, revision=None, tqdm_class=None, ignore_patterns=None):
        calls.update(repo_id=repo_id, revision=revision, ignore_patterns=ignore_patterns)
        sha = revision or live_sha          # real hub: `main` resolves to a commit
        snap = local_snapshot.hf_cache_dir(repo_id, home) / "snapshots" / sha
        snap.mkdir(parents=True, exist_ok=True)
        (snap / "config.json").write_text("{}")
        (snap / "model.safetensors").write_bytes(b"w")
        if code:
            (snap / "modeling.py").write_text("x")
        return str(snap)

    class HfApi:
        def repo_info(self, repo_id, revision=None, files_metadata=False):
            calls["metadata_revision"] = revision
            return types.SimpleNamespace(siblings=[], sha=live_sha)

    mod = types.ModuleType("huggingface_hub")
    mod.snapshot_download = snapshot_download  # type: ignore[attr-defined]
    mod.HfApi = HfApi  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "huggingface_hub", mod)
    return calls


def test_a_preset_downloads_its_reviewed_pin_and_never_python(
    _hub: Path, monkeypatch: pytest.MonkeyPatch, capsys
) -> None:
    repo = "mlx-community/Qwen2.5-7B-Instruct-4bit"
    calls = _fake_hub(monkeypatch, _hub)

    assert prefetch_model.prefetch(repo) == 0

    assert calls["revision"] == local_snapshot.PINNED_REVISIONS[repo]   # not the live `main`
    assert calls["metadata_revision"] == calls["revision"]              # sized at the pin too
    assert "*.py" in calls["ignore_patterns"]
    done = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert done["event"] == "complete" and done["revision"] == calls["revision"]
    assert local_snapshot.snapshot_is_cached(repo, _hub)                # servable with no refs/main


def test_a_custom_model_resolves_once_and_records_the_pin(
    _hub: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = "acme/Custom-7B-4bit"
    calls = _fake_hub(monkeypatch, _hub, live_sha="d" * 40)

    assert prefetch_model.prefetch(repo) == 0

    assert calls["metadata_revision"] is None
    assert local_snapshot.pin_for(repo, _hub) == "d" * 40     # recorded for serve time
    assert local_snapshot.resolve_for_serving(repo, _hub).name == "d" * 40


def test_a_download_that_carries_code_is_failed_not_completed(
    _hub: Path, monkeypatch: pytest.MonkeyPatch, capsys
) -> None:
    _fake_hub(monkeypatch, _hub, code=True)
    assert prefetch_model.prefetch("acme/Custom-7B-4bit") == 1
    last = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert last["event"] == "failed" and last["error_type"] == "SnapshotRefused"
    assert local_snapshot.pin_for("acme/Custom-7B-4bit", _hub) is None   # nothing recorded


def test_bytes_alone_do_not_make_a_model_complete(
    _hub: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The old short-circuit trusted `cached_bytes >= total_bytes`, which a cache
    holding some other revision also satisfies."""
    repo = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    other = local_snapshot.hf_cache_dir(repo, _hub) / "snapshots" / ("f" * 40)
    other.mkdir(parents=True)
    (other / "model.safetensors").write_bytes(b"x" * 10)
    calls = _fake_hub(monkeypatch, _hub)
    monkeypatch.setattr(prefetch_model, "_repo_metadata", lambda r, revision=None: (5, revision))

    assert prefetch_model.prefetch(repo) == 0
    assert calls["revision"] == local_snapshot.PINNED_REVISIONS[repo]   # it still downloaded
