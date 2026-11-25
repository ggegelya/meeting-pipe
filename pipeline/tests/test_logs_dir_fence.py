"""T9: every write under the logs folder goes through `events.logs_dir`.

`orchestrate._configure_logging` and `local_server.marker_path` used to build
`~/Library/Logs/MeetingPipe` themselves, so a child spawned with
`MEETINGPIPE_LOGS_DIR` still wrote the real `pipeline.log` (31,984 `synthetic frame`
lines on the dev Mac, 85 percent of the work laptop's file). The source fence below
fails on the next hand-built logs path; the subprocess cases pin the two writers.
"""
from __future__ import annotations

import ast
import os
import subprocess
import sys
from pathlib import Path

_SRC = Path(__file__).resolve().parents[1] / "src" / "mp"

#: The only places under `src/mp` allowed to spell the logs path, each with why.
ALLOWED = {
    "events.py::logs_dir": "the one resolver every writer asks",
    "analyze_detection.py::main": "argparse help naming the default, writes nothing",
    "local_server.py::marker_path": "only the explicit-`home` branch, which tests pass",
}


class _Sites(ast.NodeVisitor):
    """Collects `<scope>` for every non-docstring string spelling the logs path: a
    `Library/Logs` literal, or a bare `"Logs"` path component. The scope is the
    innermost function, else the module-level assignment's name."""

    def __init__(self) -> None:
        self.scope: list[str] = []
        self.hits: set[str] = set()

    def _scoped(self, name: str, node: ast.AST) -> None:
        self.scope.append(name)
        self.generic_visit(node)
        self.scope.pop()

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        self._skip_docstring(node)
        self._scoped(node.name, node)

    visit_AsyncFunctionDef = visit_FunctionDef  # type: ignore[assignment]

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        self._skip_docstring(node)
        self._scoped(node.name, node)

    def visit_Module(self, node: ast.Module) -> None:
        self._skip_docstring(node)
        for stmt in node.body:
            tgt = stmt.targets[0] if isinstance(stmt, ast.Assign) else getattr(stmt, "target", None)
            if isinstance(tgt, ast.Name):
                self._scoped(tgt.id, stmt)
            else:
                self.visit(stmt)

    def _skip_docstring(self, node) -> None:
        body = node.body
        if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant):
            body[0].value.value = None  # a docstring names the path, it writes nothing

    def visit_Constant(self, node: ast.Constant) -> None:
        if isinstance(node.value, str) and ("Library/Logs" in node.value or node.value == "Logs"):
            self.hits.add(self.scope[-1] if self.scope else f"line{node.lineno}")


def logs_path_sites(src: Path) -> set[str]:
    """`<file>::<scope>` for every site under `src` that spells the logs path."""
    sites: set[str] = set()
    for path in sorted(src.rglob("*.py")):
        visitor = _Sites()
        visitor.visit(ast.parse(path.read_text(encoding="utf-8")))
        sites |= {f"{path.relative_to(src).as_posix()}::{scope}" for scope in visitor.hits}
    return sites


def test_only_the_named_sites_spell_the_logs_path():
    sites = logs_path_sites(_SRC)
    assert sites - set(ALLOWED) == set()
    assert set(ALLOWED) - sites == set(), "a stale allowlist row hides nothing; drop it"


def test_the_fence_catches_a_planted_bypass(tmp_path):
    (tmp_path / "orchestrate.py").write_text(
        "import os\nfrom pathlib import Path\n"
        "def _configure_logging():\n"
        '    """Writes ~/Library/Logs/MeetingPipe/pipeline.log."""\n'
        '    d = Path(os.path.expanduser("~/Library/Logs/MeetingPipe"))\n'
        '    (d / "pipeline.log").touch()\n'
    )
    (tmp_path / "marker.py").write_text(
        "from pathlib import Path\n"
        'MARKER = Path.home() / "Library" / "Logs" / "MeetingPipe" / "x.json"\n'
    )
    assert logs_path_sites(tmp_path) == {"orchestrate.py::_configure_logging", "marker.py::MARKER"}


def _run(code: str, logs: Path) -> subprocess.CompletedProcess[str]:
    env = {k: v for k, v in os.environ.items() if k != "MP_PIPELINE_LOG_OWNER"}
    env["MEETINGPIPE_LOGS_DIR"] = str(logs)
    return subprocess.run(
        [sys.executable, "-c", code], env=env, capture_output=True, text=True, timeout=60, check=True
    )


def test_configure_logging_honours_meetingpipe_logs_dir(tmp_path):
    # A fresh process: `_configure_logging` no-ops when the root logger already has
    # handlers, which it always does under pytest.
    _run("from mp import orchestrate; orchestrate._configure_logging()", tmp_path)
    assert (tmp_path / "pipeline.log").is_file()


def test_marker_path_defaults_to_logs_dir(tmp_path):
    # A fresh process too, because conftest's PIPE22 fixture wraps `marker_path`.
    out = _run("from mp import local_server; print(local_server.marker_path())", tmp_path)
    assert Path(out.stdout.strip()) == tmp_path / "mlx-server.json"
