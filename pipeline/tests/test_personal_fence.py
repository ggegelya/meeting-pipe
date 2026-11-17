"""HYG21: the owner-machine `personal` fence in `scripts/truth_fences.py`.

Loaded by path (the `test_link_fence.py` precedent) and run on a temp tree with an injected roster,
config and library, so the owner's real data never decides these. Synthetic names only.
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

_FENCES = Path(__file__).resolve().parents[2] / "scripts" / "truth_fences.py"
_spec = importlib.util.spec_from_file_location("truth_fences_personal", _FENCES)
assert _spec and _spec.loader
fences = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fences)

NAME = "Quillon"
STEM = "20250102-030405"


def _setup(tmp_path: Path, files: dict[str, str]) -> tuple[Path, Path, Path, Path]:
    root = tmp_path / "repo"
    for rel, text in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
    roster = tmp_path / "roster.json"
    roster.write_text(json.dumps({"schema_version": 1, "people": [{"name": f"{NAME} Example"}]}))
    config = tmp_path / "config.toml"
    config.write_text('[summarization]\nuser_label = "Me"\n')
    library = tmp_path / "raw"
    library.mkdir()
    (library / f"{STEM}.wav").write_bytes(b"")
    return root, roster, config, library


def _run(root, roster, config, library, capsys) -> tuple[bool, str]:
    ok = fences.check_personal(root, roster, config, library)
    return ok, capsys.readouterr().out


def test_a_roster_name_in_a_test_file_fails_without_printing_it(tmp_path, capsys):
    root, *src = _setup(tmp_path, {"pipeline/tests/test_x.py": f'speaker = "{NAME}"\n'})
    ok, out = _run(root, *src, capsys)
    assert not ok
    assert "pipeline/tests/test_x.py:1: roster name #1" in out
    assert NAME not in out


def test_a_library_stem_under_tests_fails(tmp_path, capsys):
    root, *src = _setup(tmp_path, {"pipeline/tests/test_x.py": f'stem = "{STEM}"\n'})
    ok, out = _run(root, *src, capsys)
    assert not ok
    assert "library stem" in out and STEM not in out


def test_the_same_stem_in_a_doc_outside_tests_and_scripts_passes(tmp_path, capsys):
    root, *src = _setup(tmp_path, {"pipeline/docs/gotchas.md": f"measured on `{STEM}`\n"})
    ok, _ = _run(root, *src, capsys)
    assert ok


def test_a_name_inside_a_longer_word_passes(tmp_path, capsys):
    root, *src = _setup(tmp_path, {"scripts/x.py": f"x = '{NAME}ing'\n"})
    ok, _ = _run(root, *src, capsys)
    assert ok


def test_no_sources_skips_and_passes(tmp_path, capsys):
    root = tmp_path / "repo"
    (root / "pipeline/tests").mkdir(parents=True)
    (root / "pipeline/tests/test_x.py").write_text(f'"{NAME}" "{STEM}"\n')
    ok, out = _run(root, tmp_path / "nope.json", tmp_path / "nope.toml", tmp_path / "nolib", capsys)
    assert ok
    assert "SKIP" in out


def test_synthetic_names_pass(tmp_path, capsys):
    root, *src = _setup(tmp_path, {"pipeline/tests/test_x.py": 'speakers = ["Avery", "Blake"]\n'})
    ok, _ = _run(root, *src, capsys)
    assert ok
