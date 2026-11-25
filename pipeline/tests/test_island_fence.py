"""HYG18: the MeetingPipeCore island rules (`truth_fences.py sources`).

`daemon/Sources/MeetingPipeCore/CLAUDE.md` says Core imports only a short list of system modules plus
TOMLKit, has exactly one `import AppKit` (in `WorkspaceSignal.swift`), no SwiftUI, depends on TOMLKit
alone, and compiles with `-strict-concurrency=targeted`. Every case but the last runs against a scratch
tree, never the real sources. Loaded by path, the `test_nserror_fence.py` precedent.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

_FENCES = Path(__file__).resolve().parents[2] / "scripts" / "truth_fences.py"
_spec = importlib.util.spec_from_file_location("truth_fences_island", _FENCES)
assert _spec and _spec.loader
fences = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fences)

_CORE = "daemon/Sources/MeetingPipeCore"
_PACKAGE = (
    "let package = Package(\n"
    "    products: [.library(name: \"MeetingPipeCore\", targets: [\"MeetingPipeCore\"])],\n"
    "    targets: [\n"
    "        // MeetingPipeCore: the island. Not `complete` yet.\n"
    "        .target(\n"
    "            name: \"MeetingPipeCore\",\n"
    "            dependencies: [.product(name: \"TOMLKit\", package: \"TOMLKit\")],\n"
    "            path: \"Sources/MeetingPipeCore\",\n"
    "            swiftSettings: [.unsafeFlags([\"-strict-concurrency=FLAG\"])]\n"
    "        ),\n"
    "        .executableTarget(\n"
    "            name: \"MeetingPipe\",\n"
    "            dependencies: [\"MeetingPipeCore\", .product(name: \"FluidAudio\", package: \"FluidAudio\")]\n"
    "        ),\n"
    "    ]\n"
    ")\n"
)
_WORKSPACE = f"{_CORE}/Lifecycle/Signals/WorkspaceSignal.swift"


def _tree(tmp_path: Path, files: dict[str, str] | None = None, *, flag: str = "targeted") -> Path:
    base = {
        "daemon/Package.swift": _PACKAGE.replace("FLAG", flag),
        f"{_CORE}/MicGate/MicGate.swift": "import Foundation\n@preconcurrency import CoreAudio\nimport os.log\n",
        _WORKSPACE: "import AppKit\nimport Foundation\n",
    }
    for rel, text in {**base, **(files or {})}.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return tmp_path


def test_a_tree_keeping_the_rules_passes(tmp_path):
    assert fences.island_failures(_tree(tmp_path)) == []


def test_a_second_appkit_import_fails(tmp_path):
    out = fences.island_failures(_tree(tmp_path, {f"{_CORE}/MicGate/Probe.swift": "import AppKit\n"}))
    assert len(out) == 1 and "MicGate/Probe.swift:1" in out[0] and "AppKit" in out[0]


def test_swiftui_fails_however_it_is_imported(tmp_path):
    out = fences.island_failures(_tree(tmp_path, {f"{_CORE}/Infra/View.swift":
                                                  "import Foundation\n@preconcurrency import struct SwiftUI.Color\n"}))
    assert len(out) == 1 and "SwiftUI" in out[0] and "Infra/View.swift:2" in out[0]


def test_an_import_in_a_comment_does_not_count(tmp_path):
    out = fences.island_failures(_tree(tmp_path, {f"{_CORE}/Doc.swift":
                                                  "// import SwiftUI\n/*\nimport AppKit\n*/\nimport Foundation\n"}))
    assert out == []


def test_a_second_dependency_fails(tmp_path):
    repo = _tree(tmp_path)
    package = repo / "daemon/Package.swift"
    package.write_text(package.read_text().replace(
        '.product(name: "TOMLKit", package: "TOMLKit")',
        '.product(name: "TOMLKit", package: "TOMLKit"), "MeetingPipeObjC"', 1))
    out = fences.island_failures(repo)
    assert len(out) == 1 and "MeetingPipeObjC" in out[0]


def test_strict_concurrency_must_be_targeted_or_stricter(tmp_path):
    assert fences.island_failures(_tree(tmp_path / "t", flag="targeted")) == []
    assert fences.island_failures(_tree(tmp_path / "c", flag="complete")) == []
    out = fences.island_failures(_tree(tmp_path / "m", flag="minimal"))
    assert len(out) == 1 and "strict-concurrency" in out[0]


def test_a_missing_package_or_no_imports_fails_rather_than_passing(tmp_path):
    repo = _tree(tmp_path)
    (repo / "daemon/Package.swift").unlink()
    assert any("Package.swift" in msg for msg in fences.island_failures(repo))
    empty = tmp_path / "empty"
    (empty / _CORE).mkdir(parents=True)
    (empty / "daemon/Package.swift").write_text(_PACKAGE.replace("FLAG", "targeted"))
    assert any("no `import`" in msg for msg in fences.island_failures(empty))


def test_the_real_tree_passes():
    assert fences.island_failures(fences.REPO) == []
