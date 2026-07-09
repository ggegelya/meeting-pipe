"""Reading the daemon's workflow TOMLs (SEC12).

`mp doctor` needs to know whether *any* NDA workflow exists, which no per-meeting
sidecar can answer.
"""
from __future__ import annotations

from pathlib import Path

from mp.workflows import nda_workflow_names


def _write(directory: Path, name: str, *, nda: bool) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"{name}.toml").write_text(
        f'name = "{name}"\n\n[flags]\nnda_mode = {str(nda).lower()}\n', encoding="utf-8"
    )


def test_returns_only_nda_workflows_sorted(tmp_path: Path) -> None:
    _write(tmp_path, "Zulu", nda=True)
    _write(tmp_path, "Alpha", nda=True)
    _write(tmp_path, "Standups", nda=False)
    assert nda_workflow_names(tmp_path) == ["Alpha", "Zulu"]


def test_a_workflow_with_no_flags_table_is_not_nda(tmp_path: Path) -> None:
    tmp_path.joinpath("plain.toml").write_text('name = "Plain"\n', encoding="utf-8")
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
    tmp_path.joinpath("11111111-2222.toml").write_text(
        "[flags]\nnda_mode = true\n", encoding="utf-8"
    )
    assert nda_workflow_names(tmp_path) == ["11111111-2222"]
