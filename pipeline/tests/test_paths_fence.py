"""ARCH18: the app's folders are spelled once, in `Endpoints.Paths` (`truth_fences.py sources`).

Every case but the last runs against a scratch tree, never the real sources, so a change to the real
allowlist cannot make these pass or fail by accident. Loaded by path, the `test_nserror_fence.py`
precedent.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

_FENCES = Path(__file__).resolve().parents[2] / "scripts" / "truth_fences.py"
_spec = importlib.util.spec_from_file_location("truth_fences_paths", _FENCES)
assert _spec and _spec.loader
fences = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fences)

_APP = "daemon/Sources/MeetingPipe"
_NOTIFIER = f"{_APP}/Notifier.swift"
_COPY = 'content.body = "See ~/Library/Logs/MeetingPipe/recorder.log for errors."\n'
_SEEDED = {(_NOTIFIER, "Logs folder"): (2, "user-visible copy naming the folder for a person")}


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for rel, text in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return tmp_path


def test_each_hand_spelled_folder_fails(tmp_path):
    repo = _tree(tmp_path, {
        f"{_APP}/A.swift": 'let a = home.appendingPathComponent(".config/meeting-pipe/workflows")\n',
        f"{_APP}/B.swift": 'let b = home.appendingPathComponent("Library/Application Support/MeetingPipe")\n',
        f"{_APP}/C.swift": 'let c = home.appendingPathComponent("Library/Caches/MeetingPipe/x.json")\n',
        f"{_APP}/D.swift": 'let d = home.appendingPathComponent("Library/Logs/MeetingPipe").path\n',
    })
    out = fences.path_failures(repo, {})
    assert len(out) == 4
    for rel, name in (("A", "config"), ("B", "Application Support"), ("C", "Caches"), ("D", "Logs")):
        assert any(f"{_APP}/{rel}.swift:1" in msg and name in msg for msg in out)


def test_a_bare_component_after_a_system_folder_fails(tmp_path):
    repo = _tree(tmp_path, {f"{_APP}/Cache.swift": (
        "let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!\n"
        'let a = base.appendingPathComponent("MeetingPipe/search/index.sqlite")\n'
        'let b = base.appendingPathComponent("MeetingPipe", isDirectory: true)\n'
        'let c = base.appending(path: "MeetingPipe/waveforms")\n'
    )})
    out = fences.path_failures(repo, {})
    assert len(out) == 1 and f"{_APP}/Cache.swift:2, {_APP}/Cache.swift:3, {_APP}/Cache.swift:4" in out[0]


def test_lookalikes_and_comments_do_not_count(tmp_path):
    repo = _tree(tmp_path, {
        f"{_APP}/Logger.swift": 'let t = tmp.appendingPathComponent("MeetingPipe-test-logs", isDirectory: true)\n',
        f"{_APP}/Doc.swift": (
            "/// Lives in `~/.config/meeting-pipe/workflows`, beside `config.toml`.\n"
            "// ~/Library/Caches/MeetingPipe/search\n"
            "/* ~/Library/Application Support/MeetingPipe\n   ~/Library/Logs/MeetingPipe */\n"
            'let label = "MeetingPipe.SearchIndexer"\n'
        ),
        f"{_APP}/Endpoints.swift": 'static let configDirRelative = ".config/meeting-pipe"\n',
    })
    assert fences.path_failures(repo, {}) == []


def test_the_seeded_entry_passes_at_its_count(tmp_path):
    repo = _tree(tmp_path, {_NOTIFIER: _COPY * 2})
    assert fences.path_failures(repo, _SEEDED) == []


def test_one_more_line_than_listed_fails(tmp_path):
    out = fences.path_failures(_tree(tmp_path, {_NOTIFIER: _COPY * 3}), _SEEDED)
    assert len(out) == 1 and "3 line(s)" in out[0] and "expects 2" in out[0]


def test_a_listed_entry_whose_file_holds_none_fails_as_stale(tmp_path):
    out = fences.path_failures(_tree(tmp_path, {_NOTIFIER: "enum Notifier {}\n"}), _SEEDED)
    assert len(out) == 1 and "stale" in out[0]


def test_an_entry_with_no_reason_fails(tmp_path):
    out = fences.path_failures(_tree(tmp_path, {_NOTIFIER: _COPY}), {(_NOTIFIER, "Logs folder"): (1, " ")})
    assert len(out) == 1 and "no reason" in out[0]


def test_the_real_tree_passes():
    assert fences.path_failures(fences.REPO, fences.PATHS_ALLOWLIST) == []
