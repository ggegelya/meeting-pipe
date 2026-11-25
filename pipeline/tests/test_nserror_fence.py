"""HYG15: no hand-rolled `NSError(domain:` under daemon/Sources (`truth_fences.py sources`).

`scripts/truth_fences.py` is a script, so it is loaded by path (the `test_link_fence.py` precedent).
Every case but the last runs against a scratch tree, never the real sources, so a change to the real
allowlist cannot make these pass or fail by accident.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

_FENCES = Path(__file__).resolve().parents[2] / "scripts" / "truth_fences.py"
_spec = importlib.util.spec_from_file_location("truth_fences_nserror", _FENCES)
assert _spec and _spec.loader
fences = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fences)

_LAUNCHER = "daemon/Sources/MeetingPipe/PipelineLauncher.swift"
_STUB = 'completion(.failure(NSError(\n    domain: "PipelineDriver", code: 1,\n    userInfo: [:]\n)))\n'
_SEEDED = {(_LAUNCHER, "PipelineDriver"): (16, "A7 in ARCH5 removes the PipelineDriver default stubs")}


# HYG18: `check_sources` also holds the Core island, which fails on a missing `Package.swift` rather
# than passing vacuously, so every scratch tree carries a minimal island that keeps its rules.
_ISLAND = {
    "daemon/Package.swift": ('.target(\n    name: "MeetingPipeCore",\n'
                             '    dependencies: [.product(name: "TOMLKit", package: "TOMLKit")],\n'
                             '    swiftSettings: [.unsafeFlags(["-strict-concurrency=targeted"])]\n)\n'),
    "daemon/Sources/MeetingPipeCore/Island.swift": "import Foundation\n",
}


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for rel, text in {**_ISLAND, **files}.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return tmp_path


def _passes(repo: Path, allowlist: dict, capsys) -> tuple[bool, str]:
    ok = fences.check_sources(repo, allowlist)
    return ok, capsys.readouterr().out


def test_a_new_single_line_construction_fails(tmp_path, capsys):
    repo = _tree(tmp_path, {"daemon/Sources/MeetingPipe/Foo.swift":
                            'let a = 1\nthrow NSError(domain: "Foo", code: 1)\n'})
    ok, out = _passes(repo, {}, capsys)
    assert not ok
    assert "daemon/Sources/MeetingPipe/Foo.swift:2" in out and "Foo" in out


def test_a_new_multi_line_construction_fails(tmp_path, capsys):
    repo = _tree(tmp_path, {"daemon/Sources/MeetingPipeCore/Bar.swift":
                            'throw NSError(\n    domain: "Bar",\n    code: 2\n)\n'})
    ok, out = _passes(repo, {}, capsys)
    assert not ok
    assert "daemon/Sources/MeetingPipeCore/Bar.swift:1" in out


def test_an_apple_domain_constant_is_keyed_by_its_identifier(tmp_path, capsys):
    repo = _tree(tmp_path, {"daemon/Sources/MeetingPipe/Hot.swift":
                            "Log.failure(error: NSError(domain: NSOSStatusErrorDomain, code: Int(status)))\n"})
    ok, out = _passes(repo, {}, capsys)
    assert not ok and "NSOSStatusErrorDomain" in out
    listed = {("daemon/Sources/MeetingPipe/Hot.swift", "NSOSStatusErrorDomain"): (1, "an OSStatus")}
    assert _passes(repo, listed, capsys)[0]


def test_comments_do_not_count(tmp_path, capsys):
    repo = _tree(tmp_path, {"daemon/Sources/MeetingPipe/Doc.swift": (
        '/// Replaces `NSError(domain: "Doc", code: 1)` throws.\n'
        '// NSError(domain: "Doc", code: 2)\n'
        '/* NSError(\n   domain: "Doc", code: 3) */\n'
        'let url = "https://example.invalid" // NSError(domain: "Doc", code: 4)\n'
    )})
    ok, _ = _passes(repo, {}, capsys)
    assert ok


def test_the_seeded_entry_passes_at_its_count(tmp_path, capsys):
    repo = _tree(tmp_path, {_LAUNCHER: _STUB * 16})
    ok, _ = _passes(repo, _SEEDED, capsys)
    assert ok


def test_one_more_stub_than_listed_fails(tmp_path, capsys):
    repo = _tree(tmp_path, {_LAUNCHER: _STUB * 17})
    ok, out = _passes(repo, _SEEDED, capsys)
    assert not ok and "17" in out and "expects 16" in out


def test_a_listed_entry_whose_file_holds_none_fails_as_stale(tmp_path, capsys):
    repo = _tree(tmp_path, {_LAUNCHER: "protocol PipelineDriver {}\n"})
    ok, out = _passes(repo, _SEEDED, capsys)
    assert not ok and "stale" in out


def test_an_entry_with_no_reason_fails(tmp_path, capsys):
    repo = _tree(tmp_path, {_LAUNCHER: _STUB})
    ok, out = _passes(repo, {(_LAUNCHER, "PipelineDriver"): (1, " ")}, capsys)
    assert not ok and "no reason" in out


def test_the_real_tree_passes():
    assert fences.check_sources()
