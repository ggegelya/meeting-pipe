"""SEC27: pinned offline snapshots for the local summarizer."""
from __future__ import annotations

import json
import os
import stat
from pathlib import Path

import pytest

from mp import local_snapshot as ls

SHA = "a" * 40
REPO = "acme/Custom-7B-4bit"


def _make_snapshot(home: Path, repo: str, sha: str, *, config: dict | None = None,
                   extra: dict[str, str] | None = None, weights: bool = True) -> Path:
    snap = ls.hf_cache_dir(repo, home) / "snapshots" / sha
    snap.mkdir(parents=True)
    (snap / "config.json").write_text(json.dumps(config if config is not None else {"model_type": "qwen2"}))
    if weights:
        (snap / "model.safetensors").write_bytes(b"w")
    for name, body in (extra or {}).items():
        target = snap / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body)
    return snap


def test_every_preset_carries_a_full_sha_pin() -> None:
    from mp import resource_guard

    for _label, repo in resource_guard.PRESETS:
        assert repo in ls.PINNED_REVISIONS, f"{repo} has no reviewed revision"
    assert all(len(v) == 40 and set(v) <= set("0123456789abcdef") for v in ls.PINNED_REVISIONS.values())


def test_a_pinned_snapshot_is_cached_without_a_refs_main(tmp_path: Path) -> None:
    """The functional bug: a sha-pinned prefetch writes no `refs/main`, so a
    machine that only ever ran `mp prefetch-model` could fail an offline load."""
    repo = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    sha = ls.PINNED_REVISIONS[repo]
    _make_snapshot(tmp_path, repo, sha)
    assert not (ls.hf_cache_dir(repo, tmp_path) / "refs" / "main").exists()
    assert ls.snapshot_is_cached(repo, tmp_path) is True
    assert ls.resolve_for_serving(repo, tmp_path).name == sha


def test_a_snapshot_at_another_revision_is_not_the_pinned_one(tmp_path: Path) -> None:
    repo = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    _make_snapshot(tmp_path, repo, "b" * 40)
    assert ls.snapshot_is_cached(repo, tmp_path) is False
    with pytest.raises(ls.SnapshotMissing) as exc:
        ls.resolve_for_serving(repo, tmp_path)
    # UX21: Swift keys the in-app "Download model" button off this phrase.
    assert "not in the local HuggingFace cache" in str(exc.value)
    assert f"mp prefetch-model {repo}" in str(exc.value)


def test_model_file_in_config_json_is_refused(tmp_path: Path) -> None:
    snap = _make_snapshot(tmp_path, REPO, SHA, config={"model_type": "x", "model_file": "evil.py"})
    with pytest.raises(ls.SnapshotRefused, match="model_file"):
        ls.verify_snapshot(snap)


@pytest.mark.parametrize(
    "name", ["evil.py", "sub/dir/hook.py", "pkg.PY", "x.pyc", "native.so", "lib.dylib"]
)
def test_code_in_the_snapshot_is_refused(tmp_path: Path, name: str) -> None:
    snap = _make_snapshot(tmp_path, REPO, SHA, extra={name: "print(1)"})
    with pytest.raises(ls.SnapshotRefused, match="Python files"):
        ls.verify_snapshot(snap)


@pytest.mark.parametrize("name", ["config.json", "tokenizer_config.json"])
def test_an_auto_map_is_refused(tmp_path: Path, name: str) -> None:
    snap = _make_snapshot(tmp_path, REPO, SHA)
    (snap / name).write_text(json.dumps({"auto_map": {"AutoModel": "mod.Cls"}}))
    with pytest.raises(ls.SnapshotRefused, match="auto_map"):
        ls.verify_snapshot(snap)


def test_the_cache_root_honours_hf_hub_cache_and_hf_home(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("HF_HOME", str(tmp_path / "hf"))
    monkeypatch.delenv("HF_HUB_CACHE", raising=False)
    assert ls.hf_cache_dir("a/b") == tmp_path / "hf" / "hub" / "models--a--b"
    monkeypatch.setenv("HF_HUB_CACHE", str(tmp_path / "hub2"))
    assert ls.hf_cache_dir("a/b") == tmp_path / "hub2" / "models--a--b"


def test_a_snapshot_without_weights_or_config_is_refused(tmp_path: Path) -> None:
    with pytest.raises(ls.SnapshotRefused, match="safetensors"):
        ls.verify_snapshot(_make_snapshot(tmp_path, REPO, SHA, weights=False))
    empty = tmp_path / "empty"
    empty.mkdir()
    with pytest.raises(ls.SnapshotRefused, match="config.json"):
        ls.verify_snapshot(empty)


def test_a_symlinked_python_file_cannot_hide_from_the_scan(tmp_path: Path) -> None:
    snap = _make_snapshot(tmp_path, REPO, SHA)
    blob = tmp_path / "blob"
    blob.write_text("print(1)")
    os.symlink(blob, snap / "linked.py")
    with pytest.raises(ls.SnapshotRefused):
        ls.verify_snapshot(snap)


def test_resolve_refuses_a_cached_snapshot_that_carries_code(tmp_path: Path) -> None:
    repo = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    _make_snapshot(tmp_path, repo, ls.PINNED_REVISIONS[repo], extra={"modeling.py": "x"})
    assert ls.snapshot_is_cached(repo, tmp_path) is False
    with pytest.raises(ls.SnapshotRefused):
        ls.resolve_for_serving(repo, tmp_path)


def test_a_custom_model_uses_the_pin_recorded_at_prefetch(tmp_path: Path) -> None:
    _make_snapshot(tmp_path, REPO, SHA)
    _make_snapshot(tmp_path, REPO, "c" * 40)   # a later unpinned fetch is ignored
    ls.record_pin(REPO, SHA, tmp_path)
    assert ls.resolve_for_serving(REPO, tmp_path).name == SHA
    mode = stat.S_IMODE(ls.pins_path(tmp_path).stat().st_mode)
    assert mode == 0o600


def test_a_custom_model_with_one_snapshot_and_no_pin_serves_it(tmp_path: Path) -> None:
    """A model prefetched before SEC27: read off disk, never resolved online."""
    _make_snapshot(tmp_path, REPO, SHA)
    assert ls.resolve_for_serving(REPO, tmp_path).name == SHA


def test_a_custom_model_with_several_snapshots_and_no_pin_is_ambiguous(tmp_path: Path) -> None:
    _make_snapshot(tmp_path, REPO, SHA)
    _make_snapshot(tmp_path, REPO, "c" * 40)
    with pytest.raises(ls.SnapshotMissing):
        ls.resolve_for_serving(REPO, tmp_path)


def test_a_malformed_pins_file_is_ignored(tmp_path: Path) -> None:
    p = ls.pins_path(tmp_path)
    p.parent.mkdir(parents=True)
    p.write_text(json.dumps({REPO: "not-a-sha"}))
    assert ls.pin_for(REPO, tmp_path) is None
    with pytest.raises(ValueError):
        ls.record_pin(REPO, "main", tmp_path)


def test_repo_id_round_trips_through_a_snapshot_path() -> None:
    path = f"/h/.cache/huggingface/hub/models--mlx-community--Qwen2.5-7B-Instruct-4bit/snapshots/{SHA}"
    assert ls.repo_id_from_snapshot(path) == "mlx-community/Qwen2.5-7B-Instruct-4bit"
    assert ls.repo_id_from_snapshot("/some/local/model") is None


def test_swift_pins_mirror_the_python_pins() -> None:
    """`ModelDownloadSupervisor.pinnedRevisions` decides whether the daemon
    prefetches; a drift from `PINNED_REVISIONS` would skip a needed download (or
    repeat a done one)."""
    import re

    swift = (Path(__file__).resolve().parents[2] / "daemon" / "Sources" / "MeetingPipe"
             / "ModelDownloadSupervisor.swift").read_text(encoding="utf-8")
    block = swift[swift.index("static let pinnedRevisions"):]
    block = block[: block.index("]\n")]
    found = dict(re.findall(r'"([^"]+)":\s*"([0-9a-f]{40})"', block))
    assert found == ls.PINNED_REVISIONS
