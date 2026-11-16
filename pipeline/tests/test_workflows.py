"""Reading the daemon's workflow TOMLs (SEC12).

`mp doctor` needs to know whether *any* NDA workflow exists, which no per-meeting
sidecar can answer.
"""
from __future__ import annotations

import uuid
from pathlib import Path

from mp.workflows import (
    broken_workflow_files,
    local_backend_workflow_names,
    nda_workflow_names,
    sink_types_in_use,
)


def _write(directory: Path, name: str, *, nda: bool) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"{name}.toml").write_text(
        f'id = "{uuid.uuid4()}"\nname = "{name}"\n\n[flags]\nnda_mode = {str(nda).lower()}\n', encoding="utf-8"
    )


def _write_backend(directory: Path, name: str, *, backend: str, nda: bool = False) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"{name}.toml").write_text(
        f'id = "{uuid.uuid4()}"\nname = "{name}"\nbackend = "{backend}"\n\n[flags]\nnda_mode = {str(nda).lower()}\n',
        encoding="utf-8",
    )


def test_returns_only_nda_workflows_sorted(tmp_path: Path) -> None:
    _write(tmp_path, "Zulu", nda=True)
    _write(tmp_path, "Alpha", nda=True)
    _write(tmp_path, "Standups", nda=False)
    assert nda_workflow_names(tmp_path) == ["Alpha", "Zulu"]


def test_a_workflow_with_no_flags_table_is_not_nda(tmp_path: Path) -> None:
    tmp_path.joinpath("plain.toml").write_text(f'id = "{uuid.uuid4()}"\nname = "Plain"\n', encoding="utf-8")
    assert nda_workflow_names(tmp_path) == []


def test_a_malformed_toml_is_skipped_not_raised(tmp_path: Path) -> None:
    # One bad file must not hide the others, matching WorkflowStore.load on the
    # Swift side.
    _write(tmp_path, "Good", nda=True)
    tmp_path.joinpath("broken.toml").write_text("this is not [ toml", encoding="utf-8")
    assert nda_workflow_names(tmp_path) == ["Good"]


def test_a_missing_directory_is_empty_not_an_error(tmp_path: Path) -> None:
    assert nda_workflow_names(tmp_path / "no-workflows-here") == []


def test_a_workflow_without_a_name_falls_back_to_its_filename(tmp_path: Path) -> None:
    # SEC21: the daemon names every file `<id>.toml`, so a file with no id takes its name.
    stem = "11111111-2222-3333-4444-555555555555"
    tmp_path.joinpath(f"{stem}.toml").write_text(
        "[flags]\nnda_mode = true\n", encoding="utf-8"
    )
    assert nda_workflow_names(tmp_path) == [stem]


# --- local_backend_workflow_names (UX21) --------------------------------------

def test_local_backend_names_includes_local_pins_and_nda_sorted(tmp_path: Path) -> None:
    _write_backend(tmp_path, "PinnedLocal", backend="local")
    _write_backend(tmp_path, "NdaClient", backend="anthropic", nda=True)  # NDA forces local
    _write_backend(tmp_path, "CloudTeam", backend="anthropic")
    _write_backend(tmp_path, "AutoOne", backend="auto")  # auto is not a forced-local
    assert local_backend_workflow_names(tmp_path) == ["NdaClient", "PinnedLocal"]


def test_local_backend_names_empty_when_all_cloud(tmp_path: Path) -> None:
    _write_backend(tmp_path, "CloudA", backend="anthropic")
    _write_backend(tmp_path, "CloudB", backend="auto")
    assert local_backend_workflow_names(tmp_path) == []


def test_local_backend_names_missing_directory_is_empty(tmp_path: Path) -> None:
    assert local_backend_workflow_names(tmp_path / "nope") == []


def test_local_backend_names_skips_a_malformed_toml(tmp_path: Path) -> None:
    _write_backend(tmp_path, "Good", backend="local")
    tmp_path.joinpath("broken.toml").write_text("this is not [ toml", encoding="utf-8")
    assert local_backend_workflow_names(tmp_path) == ["Good"]


def test_sink_types_in_use_reads_every_workflow_and_skips_bad_files(tmp_path) -> None:
    # SEC35: a workflow can publish somewhere the global `output.sinks` does not say.
    (tmp_path / "a.toml").write_text(
        f'id = "{uuid.uuid4()}"\nname = "a"\n\n[[sinks]]\ntype = "filesystem"\n\n[[sinks]]\ntype = "notion"\ndatabase_id = "x"\n',
        encoding="utf-8")
    (tmp_path / "b.toml").write_text(f'id = "{uuid.uuid4()}"\nname = "b"\n\n[[sinks]]\ntype = "obsidian"\n', encoding="utf-8")
    (tmp_path / "bad.toml").write_text("this is [not toml", encoding="utf-8")
    (tmp_path / "odd.toml").write_text(
        f'id = "{uuid.uuid4()}"\nname = "odd"\nsinks = "notion"\n\n[[other]]\ntype = "lan"\n', encoding="utf-8")
    (tmp_path / "typeless.toml").write_text(f'id = "{uuid.uuid4()}"\nname = "t"\n\n[[sinks]]\nfoo = 1\n', encoding="utf-8")
    assert sink_types_in_use(tmp_path) == {"filesystem", "notion", "obsidian"}
    assert sink_types_in_use(tmp_path / "absent") == set()


# --- SEC21: refused files are reported, by the daemon's own rule --------------

def test_each_broken_shape_is_reported_and_good_files_are_unchanged(tmp_path: Path) -> None:
    _write(tmp_path, "Good", nda=True)
    tmp_path.joinpath("garbled.toml").write_text("this is not [ toml", encoding="utf-8")
    tmp_path.joinpath("stringly.toml").write_text(
        f'id = "{uuid.uuid4()}"\nname = "S"\n[flags]\nnda_mode = "true"\n', encoding="utf-8")
    tmp_path.joinpath("typo.toml").write_text(
        f'id = "{uuid.uuid4()}"\nname = "T"\nbackend = "locl"\n', encoding="utf-8")
    tmp_path.joinpath("no-id.toml").write_text('name = "N"\n', encoding="utf-8")
    tmp_path.joinpath("bad-id.toml").write_text('id = "nope"\nname = "B"\n', encoding="utf-8")
    broken = dict(broken_workflow_files(tmp_path))
    assert set(broken) == {"garbled.toml", "stringly.toml", "typo.toml", "no-id.toml", "bad-id.toml"}
    assert all(broken.values())
    assert nda_workflow_names(tmp_path) == ["Good"]


def test_a_file_with_no_flags_and_no_backend_still_loads(tmp_path: Path) -> None:
    tmp_path.joinpath("plain.toml").write_text(f'id = "{uuid.uuid4()}"\nname = "Plain"\n', encoding="utf-8")
    assert broken_workflow_files(tmp_path) == []
