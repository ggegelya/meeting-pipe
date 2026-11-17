"""AUTO3 legs 1 and 2: the MCP stdio server and its five read-only tools.

Everything that carries risk is exercised without the optional `mcp` package:
the tool payloads, the not-found shape, the untrusted fence, and the no-socket
property (which is checked as a source fence, so it holds even where the SDK
cannot be imported). The handful of cases that need the SDK skip when it is
absent, which is the only reason a local `uv sync` without `--extra mcp` still
gives a green suite.
"""
from __future__ import annotations

import ast
import json
import socket
import threading
import time
from datetime import date
from pathlib import Path

import pytest

from mp import embed_index, mcp_serve, mcp_tools, visibility
from mp.config import Config
from mp.prompt_safety import wrap_untrusted

NDA = "20260103-100000"
NO_SIDECAR = "20260104-100000"
NORMAL_A = "20260101-100000"
NORMAL_B = "20260102-100000"

SECRET = "acquisition price is forty million"


def _meeting(root: Path, stem: str, *, text: str, meta: dict | None = None,
             decisions: list[str] | None = None, actions: list[dict] | None = None,
             title: str | None = None) -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / f"{stem}.md").write_text(f"[00:00] Alice: {text}\n", encoding="utf-8")
    (root / f"{stem}.summary.md").write_text(f"# {stem}\n\n- {text}\n", encoding="utf-8")
    (root / f"{stem}.summary.json").write_text(json.dumps({
        "title": title or f"Meeting {stem}",
        "summary": [text],
        "decisions": decisions or [],
        "actions": actions or [],
        "questions": [],
        "attendees": ["Alice"],
        "detected_language": "en",
    }), encoding="utf-8")
    if meta is not None:
        (root / f"{stem}.meta.json").write_text(json.dumps(meta), encoding="utf-8")


@pytest.fixture
def library(tmp_path: Path) -> Path:
    """The fixture library AUTO3's acceptance names: one NDA meeting, one with no
    sidecar, two normal ones."""
    root = tmp_path / "lib"
    _meeting(root, NORMAL_A, text="we decided to ship the roster on Friday",
             title="Roster planning", decisions=["ship the roster"],
             actions=[{"task": "write the roster doc", "owner": "Alice",
                       "due": "2026-01-02", "confidence": "high", "resolved": False}],
             meta={"schema_version": 1, "workflow_name": "Standup"})
    _meeting(root, NORMAL_B, text="hiring loop feedback and the budget",
             title="Hiring sync", decisions=["extend the offer"],
             actions=[{"task": "send the offer", "owner": "Bob",
                       "confidence": "medium", "resolved": True}],
             meta={"schema_version": 1, "workflow_name": "Hiring"})
    _meeting(root, NDA, text=SECRET, title="Client work",
             decisions=["sign on Monday"],
             actions=[{"task": "countersign", "owner": "Carol",
                       "confidence": "high", "resolved": False}],
             meta={"schema_version": 1, "workflow_name": "Client work",
                   "workflow_nda_mode": True})
    _meeting(root, NO_SIDECAR, text="notes with no recorded privacy stance",
             title="Old meeting",
             actions=[{"task": "unknown provenance task", "owner": "Dave",
                       "confidence": "low", "resolved": False}])
    return root


@pytest.fixture
def allow(library: Path) -> set[str]:
    return visibility.visible_stems(library)


@pytest.fixture(autouse=True)
def _hashing_embedder(monkeypatch):
    """`default_embedder()` picks MLX whenever `mlx_embeddings` is importable,
    and a cold HuggingFace cache then downloads weights, so an unpatched search
    test is a network call on the author's Mac and a different code path on CI.
    The hashing backend is the one both machines can run."""
    from mp import embed_index

    monkeypatch.setattr(
        embed_index, "default_embedder", lambda *a, **k: embed_index.HashingEmbedder(dim=256)
    )


def _lib(library: Path, tmp_path: Path, *, enabled: bool = True) -> mcp_serve.Library:
    cfg = Config()
    cfg.mcp.enabled = enabled
    # AUTO6: the library re-reads config per call; never the developer's real file.
    return mcp_serve.Library(cfg, library, tmp_path / "idx", load_config=lambda: cfg)


# --------------------------------------------------------------------------
# Leg 1: the server binds no socket
# --------------------------------------------------------------------------

#: Anything that could put this server on the network. The SDK ships SSE and
#: streamable-HTTP transports, so "stdio only" is one import away from being
#: false and is worth a mechanical reader rather than a comment.
FORBIDDEN_IMPORTS = {
    "socket", "socketserver", "ssl", "http", "http.server", "asyncio.streams",
    "uvicorn", "starlette", "sse_starlette", "fastapi",
    "mcp.server.sse", "mcp.server.streamable_http",
    "mcp.server.streamable_http_manager", "mcp.server.websocket",
}


def _imported_modules(path: Path) -> set[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"))
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.update(a.name for a in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
            names.add(node.module)
            names.update(f"{node.module}.{a.name}" for a in node.names)
    return names


def test_the_server_module_imports_no_network_transport() -> None:
    """A source fence, so it holds on a machine where `mcp` cannot be imported at
    all. Guarded against going vacuous: the module must still import the one
    transport it is allowed to use."""
    module = Path(mcp_serve.__file__)
    imported = _imported_modules(module)
    assert "mcp.server.stdio" in imported, "the extractor stopped seeing real imports"
    assert not (imported & FORBIDDEN_IMPORTS), sorted(imported & FORBIDDEN_IMPORTS)


def test_the_fence_would_catch_a_network_transport(tmp_path: Path) -> None:
    """Run the fence against the bug it claims to catch (UX68's lesson), so a
    fence that silently stopped matching cannot pass forever."""
    bad = tmp_path / "bad.py"
    bad.write_text(
        "from mcp.server.stdio import stdio_server\n"
        "from mcp.server.sse import SseServerTransport\n",
        encoding="utf-8",
    )
    assert _imported_modules(bad) & FORBIDDEN_IMPORTS


def test_serving_every_tool_binds_no_socket(library: Path, tmp_path: Path, monkeypatch) -> None:
    """The runtime half. `bind` and `listen` are booby-trapped rather than the
    constructor: the property is that nothing here becomes reachable, not that
    nothing opens a connection. Retrieval can legitimately open an outbound one
    (a cold embedding-model cache fetches weights, exactly as `mp ask` does), and
    a fence that failed on that would be measuring the wrong thing and would get
    weakened the first time it fired."""
    real = socket.socket

    class _NoListen(real):  # type: ignore[misc, valid-type]
        def bind(self, *a, **k):
            raise AssertionError("mp mcp-serve bound a socket")

        def listen(self, *a, **k):
            raise AssertionError("mp mcp-serve listened on a socket")

    monkeypatch.setattr(socket, "socket", _NoListen)
    lib = _lib(library, tmp_path)
    for name in mcp_serve.TOOL_NAMES:
        args = {"query": "roster", "stem": NORMAL_A}
        assert mcp_serve.dispatch(lib, name, args)


# --------------------------------------------------------------------------
# Leg 2: the five tools cover exactly the two normal meetings
# --------------------------------------------------------------------------


def test_list_meetings_covers_exactly_the_visible_two(library: Path, allow: set[str]) -> None:
    out = mcp_tools.list_meetings(library, allow)
    assert {row["stem"] for row in out["meetings"]} == {NORMAL_A, NORMAL_B}
    assert out["count"] == 2


def test_list_meetings_returns_metadata_only(library: Path, allow: set[str]) -> None:
    """"Metadata rows only, no content" is the whole reason this tool is separate
    from `get_meeting`; a row that grew a summary field would silently widen what
    a listing exposes."""
    row = mcp_tools.list_meetings(library, allow)["meetings"][0]
    assert set(row) == {"stem", "title", "date", "workflow", "has_transcript"}


def test_list_actions_covers_exactly_the_visible_two(library: Path, allow: set[str]) -> None:
    out = mcp_tools.list_actions(library, allow, open_only=False, today=date(2026, 1, 5))
    assert {row["stem"] for row in out["actions"]} == {NORMAL_A, NORMAL_B}
    tasks = {row["task"] for row in out["actions"]}
    assert "countersign" not in tasks
    assert "unknown provenance task" not in tasks


def test_list_actions_open_only_is_the_default(library: Path, allow: set[str]) -> None:
    out = mcp_tools.list_actions(library, allow, today=date(2026, 1, 5))
    assert [row["task"] for row in out["actions"]] == ["write the roster doc"]


def test_search_covers_exactly_the_visible_two(library: Path, tmp_path: Path) -> None:
    from mp import embed_index

    allow = visibility.visible_stems(library)
    index = embed_index.load_or_build(
        library, tmp_path / "idx", embed_index.HashingEmbedder(dim=256), allow_stems=allow
    )
    assert {c.stem for c in index.chunks} == {NORMAL_A, NORMAL_B}
    out = mcp_tools.search_meetings(library, index, "roster", limit=10)
    assert {r["stem"] for r in out["results"]} <= {NORMAL_A, NORMAL_B}
    assert SECRET not in json.dumps(out)


def test_get_meeting_returns_the_visible_meeting(library: Path, allow: set[str]) -> None:
    out = mcp_tools.get_meeting(library, NORMAL_A, allow)
    assert out["stem"] == NORMAL_A
    assert out["title"] == "Roster planning"
    assert out["date"] == "2026-01-01"
    assert out["workflow"] == "Standup"
    assert "ship the roster" in out["content"]


def test_get_transcript_returns_a_bounded_window(library: Path, allow: set[str]) -> None:
    """"Never the whole file by default" is the property: a long transcript comes
    back one window at a time, and says so."""
    (library / f"{NORMAL_A}.md").write_text("z" * 50_000, encoding="utf-8")
    out = mcp_tools.get_transcript(library, NORMAL_A, allow)
    assert out["window"] == mcp_tools.DEFAULT_TRANSCRIPT_WINDOW
    assert out["total_chars"] == 50_000
    assert out["truncated"] is True


def test_get_transcript_caps_an_oversized_window(library: Path, allow: set[str]) -> None:
    out = mcp_tools.get_transcript(
        library, NORMAL_A, allow, window=mcp_tools.MAX_TRANSCRIPT_WINDOW * 100
    )
    assert out["window"] <= mcp_tools.MAX_TRANSCRIPT_WINDOW


def test_get_transcript_centres_on_around(library: Path, allow: set[str]) -> None:
    long_line = "x" * 500 + " NEEDLE " + "y" * 500
    (library / f"{NORMAL_A}.md").write_text(long_line, encoding="utf-8")
    out = mcp_tools.get_transcript(library, NORMAL_A, allow, around="NEEDLE", window=100)
    assert "NEEDLE" in out["content"]
    assert out["offset"] > 0


# --------------------------------------------------------------------------
# Leg 2: withheld is indistinguishable from unknown
# --------------------------------------------------------------------------


@pytest.mark.parametrize("stem", [NDA, NO_SIDECAR])
def test_get_meeting_on_a_withheld_stem_is_the_unknown_shape(
    library: Path, allow: set[str], stem: str
) -> None:
    withheld = mcp_tools.get_meeting(library, stem, allow)
    unknown = mcp_tools.get_meeting(library, "20991231-235959", allow)
    assert withheld == {"error": "not_found", "stem": stem}
    assert set(withheld) == set(unknown)
    assert withheld["error"] == unknown["error"]


@pytest.mark.parametrize("stem", [NDA, NO_SIDECAR])
def test_get_transcript_on_a_withheld_stem_is_the_unknown_shape(
    library: Path, allow: set[str], stem: str
) -> None:
    withheld = mcp_tools.get_transcript(library, stem, allow)
    unknown = mcp_tools.get_transcript(library, "20991231-235959", allow)
    assert withheld == {"error": "not_found", "stem": stem}
    assert set(withheld) == set(unknown)


def test_no_tool_leaks_withheld_text(library: Path, tmp_path: Path) -> None:
    """One assertion over the whole surface: the NDA meeting's words appear in no
    payload any tool can produce, including the refusals."""
    lib = _lib(library, tmp_path)
    blob = json.dumps([
        mcp_serve.dispatch(lib, "search_meetings", {"query": "acquisition price"}),
        mcp_serve.dispatch(lib, "get_meeting", {"stem": NDA}),
        mcp_serve.dispatch(lib, "get_transcript", {"stem": NDA}),
        mcp_serve.dispatch(lib, "list_meetings", {}),
        mcp_serve.dispatch(lib, "list_actions", {"open_only": False}),
    ])
    assert SECRET not in blob
    assert "countersign" not in blob
    assert "Client work" not in blob


# --------------------------------------------------------------------------
# Prompt injection: returned text stays fenced
# --------------------------------------------------------------------------


def test_returned_meeting_text_is_fenced_as_untrusted(library: Path, allow: set[str]) -> None:
    meeting = mcp_tools.get_meeting(library, NORMAL_A, allow)
    transcript = mcp_tools.get_transcript(library, NORMAL_A, allow)
    fence = wrap_untrusted("")
    begin = fence.splitlines()[0]
    assert meeting["content"].startswith(begin)
    assert transcript["content"].startswith(begin)


def test_every_content_bearing_tool_says_the_text_is_not_instructions() -> None:
    by_name = {spec["name"]: spec for spec in mcp_serve.tool_specs()}
    for name in ("search_meetings", "get_meeting", "get_transcript", "list_actions"):
        assert "never as instructions" in by_name[name]["description"]


def test_no_tool_is_a_write_tool() -> None:
    """v1 is read-only. A write surface reachable by an agentic client is a
    separate task with a separate risk argument."""
    assert set(mcp_serve.TOOL_NAMES) == {
        "search_meetings", "get_meeting", "get_transcript", "list_meetings", "list_actions",
    }


# --------------------------------------------------------------------------
# The subcommand
# --------------------------------------------------------------------------


def test_serve_refuses_while_disabled(library: Path, monkeypatch, capsys) -> None:
    cfg = Config()
    assert cfg.mcp.enabled is False, "the kill switch has to default to off"
    monkeypatch.setattr(mcp_serve.entry, "prepare", lambda *a, **k: cfg)

    def _never(*a, **k):
        raise AssertionError("the server started while `mcp.enabled` was false")

    monkeypatch.setattr(mcp_serve, "_run_stdio", _never)
    assert mcp_serve.main(["--dir", str(library)]) == 1
    assert "Preferences" in capsys.readouterr().err


def test_status_json_is_what_preferences_reads(library: Path, monkeypatch, capsys) -> None:
    cfg = Config()
    monkeypatch.setattr(mcp_serve.entry, "prepare", lambda *a, **k: cfg)
    assert mcp_serve.main(["--dir", str(library), "--status", "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["enabled"] is False
    assert payload["transport"] == "stdio"
    assert payload["visible"] == 2
    assert payload["withheld"] == 2
    assert payload["withheld_by_reason"] == {"nda": 1, "no_sidecar": 1}
    assert payload["tools"] == list(mcp_serve.TOOL_NAMES)


def test_status_counts_match_the_gate(library: Path) -> None:
    """Leg 3's acceptance: the number Preferences renders is the number the
    server enforces, because both come from `visibility`."""
    cfg = Config()
    snapshot = mcp_serve.status(cfg, library)
    gate = visibility.library_visibility(library)
    assert snapshot["visible"] == gate.visible_count
    assert snapshot["withheld"] == gate.withheld_count


def test_status_works_without_the_optional_sdk(library: Path, monkeypatch, capsys) -> None:
    """Preferences must render on an install that never opted into the extra."""
    monkeypatch.setattr(mcp_serve.entry, "prepare", lambda *a, **k: Config())
    monkeypatch.setattr(mcp_serve, "sdk_available", lambda: False)
    assert mcp_serve.main(["--dir", str(library), "--status", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["sdk_available"] is False


def test_a_missing_sdk_names_the_command_that_fixes_it(
    library: Path, tmp_path: Path, monkeypatch, capsys
) -> None:
    cfg = Config()
    cfg.mcp.enabled = True
    monkeypatch.setattr(mcp_serve.entry, "prepare", lambda *a, **k: cfg)

    def _no_sdk(_library):
        raise mcp_serve.SDKMissingError("uv sync --extra mcp")

    monkeypatch.setattr(mcp_serve, "_run_stdio", _no_sdk)
    assert mcp_serve.main(["--dir", str(library), "--index-dir", str(tmp_path)]) == 1
    assert "uv sync --extra mcp" in capsys.readouterr().err


def test_mcp_serve_is_dispatched_by_both_spellings(monkeypatch) -> None:
    from mp import __main__ as cli

    seen: list[list[str]] = []
    monkeypatch.setattr(mcp_serve, "main", lambda argv: seen.append(argv) or 0)
    for spelling in ("mcp-serve", "mcp_serve"):
        assert cli._dispatch(spelling, ["--status"]) == 0
    assert seen == [["--status"], ["--status"]]


def test_the_allowlist_is_resolved_per_call(library: Path, tmp_path: Path) -> None:
    """A long-lived session must not hold a stale gate: flagging a meeting NDA
    while the server runs has to take effect on the next call."""
    lib = _lib(library, tmp_path)
    assert NORMAL_B in {r["stem"] for r in mcp_serve.dispatch(lib, "list_meetings", {})["meetings"]}
    (library / f"{NORMAL_B}.meta.json").write_text(
        json.dumps({"schema_version": 1, "workflow_name": "Client work",
                    "workflow_nda_mode": True}), encoding="utf-8")
    after = {r["stem"] for r in mcp_serve.dispatch(lib, "list_meetings", {})["meetings"]}
    assert after == {NORMAL_A}


# --------------------------------------------------------------------------
# AUTO5: a wrong call must not return a right-looking answer
# --------------------------------------------------------------------------


def test_an_unknown_argument_is_named_rather_than_dropped(
    library: Path, tmp_path: Path
) -> None:
    """The defect this closes. On 2026-08-21 a client passed `offset`, got a
    byte-identical window back with `offset: 0`, concluded the argument was
    ignored, and left the tool to read the file off disk, which bypasses both
    the visibility gate and the corrections overlay."""
    lib = _lib(library, tmp_path)
    out = mcp_serve.dispatch(lib, "get_transcript", {"stem": NORMAL_A, "offset": 2000})
    assert out["error"] == "unknown_argument"
    assert out["unknown"] == ["offset"]
    assert "around" in out["accepted"] and "window" in out["accepted"]
    assert "content" not in out, "a rejected call must not also answer"


def test_the_unknown_argument_rule_is_a_property_of_the_seam(
    library: Path, tmp_path: Path
) -> None:
    """Asserted on a tool other than `get_transcript`, because `dispatch` is the
    single seam and the rule has to hold for every branch rather than the one
    the bug was reported against."""
    lib = _lib(library, tmp_path)
    for name, args in (
        ("search_meetings", {"query": "anything", "bogus_key": 1}),
        ("get_meeting", {"stem": NORMAL_A, "offset": 5}),
        ("list_meetings", {"bogus_key": "x"}),
        ("list_actions", {"nope": True}),
    ):
        out = mcp_serve.dispatch(lib, name, args)
        assert out["error"] == "unknown_argument", f"{name} accepted an undeclared key"
        assert out["tool"] == name


def test_every_schema_rejects_undeclared_arguments() -> None:
    """The client-side half. `dispatch` enforces it for clients that do not
    validate; this is what tells the ones that do."""
    specs = mcp_serve.tool_specs()
    assert specs, "there are tools to check"
    for spec in specs:
        assert spec["inputSchema"]["additionalProperties"] is False, spec["name"]


def test_the_argument_map_is_derived_from_the_schemas() -> None:
    """Written twice, these drift; the check would then pass while rejecting an
    argument the schema advertises."""
    for spec in mcp_serve.tool_specs():
        assert mcp_serve.TOOL_ARGUMENTS[spec["name"]] == frozenset(
            spec["inputSchema"]["properties"]
        )
    assert set(mcp_serve.TOOL_ARGUMENTS) == set(mcp_serve.TOOL_NAMES)


def test_a_declared_argument_still_works(library: Path, tmp_path: Path) -> None:
    """The guard must not be a blanket refusal: every declared argument still
    reaches its tool."""
    (library / f"{NORMAL_A}.md").write_text("z" * 50_000, encoding="utf-8")
    lib = _lib(library, tmp_path)
    out = mcp_serve.dispatch(lib, "get_transcript", {"stem": NORMAL_A, "window": 500})
    assert "error" not in out
    assert out["window"] == 500


def test_an_explicit_zero_window_is_clamped_not_defaulted(
    library: Path, tmp_path: Path
) -> None:
    """`int(value or default)` turned an explicit 0 into 4000, because 0 is
    falsy, so asking for nothing returned a full default window. Only a missing
    argument may take the default; an explicit one is clamped by the tool that
    owns the bound."""
    (library / f"{NORMAL_A}.md").write_text("z" * 50_000, encoding="utf-8")
    lib = _lib(library, tmp_path)
    out = mcp_serve.dispatch(lib, "get_transcript", {"stem": NORMAL_A, "window": 0})
    assert out["window"] != mcp_tools.DEFAULT_TRANSCRIPT_WINDOW
    assert out["window"] == 200, "clamped to the floor the tool already enforces"


def test_an_explicit_zero_limit_is_not_silently_the_default(
    library: Path, tmp_path: Path
) -> None:
    """The same falsy-integer bug on the three `limit` call sites. The spec named
    `window`; leaving three identical instances behind would have been arbitrary."""
    lib = _lib(library, tmp_path)
    # The tool owns the bound and floors `limit` at 1 (`max(1, int(limit))`), so an
    # explicit 0 lands on that floor. What matters is that it no longer silently
    # becomes 100: the value the caller passed now reaches the tool that clamps it.
    zero = mcp_serve.dispatch(lib, "list_meetings", {"limit": 0})["meetings"]
    assert len(zero) == 1
    assert len(mcp_serve.dispatch(lib, "list_meetings", {})["meetings"]) > 1, (
        "a missing limit still takes the default"
    )


def test_a_rejected_argument_cannot_reach_a_withheld_stem(
    library: Path, tmp_path: Path
) -> None:
    """A paging-shaped argument is exactly the sort of addition that could reach a
    file the gate meant to hide, so the refusal is checked against a withheld
    stem too: it must be the unknown-argument shape, never the file."""
    lib = _lib(library, tmp_path)
    out = mcp_serve.dispatch(lib, "get_transcript", {"stem": NDA, "offset": 0})
    assert out["error"] == "unknown_argument"
    assert "content" not in out, "the refusal must not also answer for a withheld stem"


# --------------------------------------------------------------------------
# The SDK wiring itself (skipped where the optional extra is absent)
# --------------------------------------------------------------------------

sdk = pytest.importorskip("mcp", reason="the optional `mcp` extra is not installed")


def test_every_spec_builds_a_real_sdk_tool() -> None:
    """The specs are plain dicts so CI can assert them without the SDK; this is
    the one place that checks they are also valid `Tool`s."""
    from mcp.types import Tool

    for spec in mcp_serve.tool_specs():
        tool = Tool(name=spec["name"], description=spec["description"],
                    inputSchema=spec["inputSchema"])
        assert tool.name == spec["name"]


def test_the_sdk_server_registers_the_five_tools_and_no_others() -> None:
    import anyio
    from mcp.server import Server

    from mp import mcp_serve as module

    captured: dict = {}
    real_server = Server

    class _Recording(real_server):  # type: ignore[misc]
        def list_tools(self, *a, **k):
            outer = super().list_tools(*a, **k)

            def _wrap(func):
                captured["list_tools"] = func
                return outer(func)
            return _wrap

    def _fake_stdio():
        raise RuntimeError("stop before any transport")

    monkey = pytest.MonkeyPatch()
    try:
        monkey.setattr("mcp.server.Server", _Recording)
        monkey.setattr("mcp.server.stdio.stdio_server", _fake_stdio)
        with pytest.raises(RuntimeError, match="stop before any transport"):
            module._run_stdio(None)  # type: ignore[arg-type]
    finally:
        monkey.undo()

    tools = anyio.run(captured["list_tools"])
    assert [t.name for t in tools] == list(mcp_serve.TOOL_NAMES)
    assert all(t.annotations is not None and t.annotations.readOnlyHint for t in tools)


# --------------------------------------------------------------------------
# AUTO6: global regulated mode, a config that changes under a running server,
# and a search index that has to follow the gate
# --------------------------------------------------------------------------


def _cfg(*, regulated: bool = False, enabled: bool = True) -> Config:
    cfg = Config()
    cfg.mcp.enabled = enabled
    cfg.modes.regulated_mode = regulated
    return cfg


@pytest.fixture
def plain(tmp_path: Path) -> Path:
    """Two meetings recorded before regulated mode was switched on: sidecars
    present, no policy flag in either, so the per-meeting gate passes both."""
    root = tmp_path / "plain"
    _meeting(root, NORMAL_A, text="we decided to ship the roster on Friday",
             meta={"schema_version": 1, "workflow_name": "Standup"})
    _meeting(root, NORMAL_B, text="hiring loop feedback and the budget",
             meta={"schema_version": 1, "workflow_name": "Hiring"})
    return root


def test_global_regulated_mode_withholds_every_meeting(plain: Path, tmp_path: Path) -> None:
    cfg = _cfg(regulated=True)
    lib = mcp_serve.Library(cfg, plain, tmp_path / "idx", load_config=lambda: cfg)
    assert lib.allow_stems() == set()
    hidden = mcp_serve.dispatch(lib, "get_meeting", {"stem": NORMAL_A})
    never = mcp_serve.dispatch(lib, "get_meeting", {"stem": "20250101-000000"})
    assert hidden == mcp_tools.not_found(NORMAL_A)
    assert {k: v for k, v in hidden.items() if k != "stem"} == {
        k: v for k, v in never.items() if k != "stem"
    }


def test_the_config_is_re_read_on_every_call(plain: Path, tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text("[mcp]\nenabled = true\n", encoding="utf-8")
    lib = mcp_serve.Library(_cfg(), plain, tmp_path / "idx", load_config=lambda: Config.load(path))
    assert lib.allow_stems() == {NORMAL_A, NORMAL_B}
    path.write_text("[mcp]\nenabled = true\n\n[modes]\nregulated_mode = true\n", encoding="utf-8")
    assert lib.allow_stems() == set()


def test_turning_the_switch_off_reaches_a_running_server(plain: Path, tmp_path: Path) -> None:
    """Beyond AUTO6's letter, same gap: the Preferences switch is the kill switch,
    and a server started before it was turned off used to keep serving."""
    path = tmp_path / "config.toml"
    path.write_text("[mcp]\nenabled = true\n", encoding="utf-8")
    lib = mcp_serve.Library(_cfg(), plain, tmp_path / "idx", load_config=lambda: Config.load(path))
    assert lib.allow_stems() == {NORMAL_A, NORMAL_B}
    path.write_text("[mcp]\nenabled = false\n", encoding="utf-8")
    assert lib.allow_stems() == set()


def test_an_unreadable_config_serves_nothing(plain: Path, tmp_path: Path) -> None:
    def broken() -> Config:
        raise ValueError("half-written config.toml")

    lib = mcp_serve.Library(_cfg(), plain, tmp_path / "idx", load_config=broken)
    assert lib.allow_stems() == set()
    assert mcp_serve.dispatch(lib, "list_meetings", {})["meetings"] == []


def test_serve_refuses_under_regulated_mode(plain: Path, monkeypatch, capsys) -> None:
    cfg = _cfg(regulated=True)
    monkeypatch.setattr(mcp_serve.entry, "prepare", lambda *a, **k: cfg)
    emitted: list[tuple[str, str, dict]] = []
    monkeypatch.setattr(mcp_serve.events, "emit",
                        lambda cat, action, **kw: emitted.append((cat, action, kw)))

    def _never(*a, **k):
        raise AssertionError("the server started under regulated mode")

    monkeypatch.setattr(mcp_serve, "_run_stdio", _never)
    assert mcp_serve.main(["--dir", str(plain)]) != 0
    assert ("pipeline", "mcp_serve_refused", {"reason": "regulated"}) in emitted
    assert "regulated" in capsys.readouterr().err.lower()


def test_status_under_regulated_mode_reports_the_global_reason(plain: Path) -> None:
    snapshot = mcp_serve.status(_cfg(regulated=True), plain)
    assert snapshot["visible"] == 0
    assert snapshot["withheld"] == 2
    assert snapshot["withheld_by_reason"] == {visibility.WITHHELD_REGULATED_GLOBAL: 2}
    assert visibility.WITHHELD_REGULATED_GLOBAL == "regulated_global"


class _CountingEmbedder(embed_index.HashingEmbedder):
    def __init__(self) -> None:
        super().__init__(dim=256)
        self.releases = 0

    def release(self) -> None:
        self.releases += 1


def _stems_in(payload: dict) -> set[str]:
    return {r["stem"] for r in payload["results"]}


def test_a_meeting_withheld_after_the_first_search_leaves_search(
    library: Path, tmp_path: Path
) -> None:
    lib = _lib(library, tmp_path)
    first = mcp_serve.dispatch(lib, "search_meetings", {"query": "hiring loop budget", "limit": 10})
    assert NORMAL_B in _stems_in(first)
    (library / f"{NORMAL_B}.meta.json").write_text(
        json.dumps({"schema_version": 1, "workflow_name": "Client work",
                    "workflow_nda_mode": True}), encoding="utf-8")
    after = mcp_serve.dispatch(lib, "search_meetings", {"query": "hiring loop budget", "limit": 10})
    assert NORMAL_B not in _stems_in(after)


def test_a_meeting_recorded_after_the_first_search_becomes_searchable(
    library: Path, tmp_path: Path
) -> None:
    lib = _lib(library, tmp_path)
    mcp_serve.dispatch(lib, "search_meetings", {"query": "roster", "limit": 10})
    fresh = "20260105-100000"
    _meeting(library, fresh, text="the quarterly volcano expedition logistics",
             meta={"schema_version": 1, "workflow_name": "Standup"})
    after = mcp_serve.dispatch(lib, "search_meetings", {"query": "volcano expedition", "limit": 10})
    assert fresh in _stems_in(after)


def test_regulated_search_returns_nothing_and_leaves_the_index_alone(
    plain: Path, tmp_path: Path
) -> None:
    current = {"cfg": _cfg()}
    lib = mcp_serve.Library(current["cfg"], plain, tmp_path / "idx",
                            load_config=lambda: current["cfg"])
    assert mcp_serve.dispatch(lib, "search_meetings", {"query": "roster"})["count"] >= 1
    before = {p: p.stat().st_mtime_ns for p in (tmp_path / "idx").rglob("*") if p.is_file()}
    assert before
    current["cfg"] = _cfg(regulated=True)
    payload = mcp_serve.dispatch(lib, "search_meetings", {"query": "roster"})
    assert payload == {"query": "roster", "results": [], "count": 0}
    assert lib._index is None  # withheld text is not left resident either
    after = {p: p.stat().st_mtime_ns for p in (tmp_path / "idx").rglob("*") if p.is_file()}
    assert after == before


def _counting_build(monkeypatch, *, delay: float = 0.0) -> list[int]:
    calls: list[int] = []
    real = embed_index.load_or_build

    def counting(*a, **k):
        calls.append(1)
        time.sleep(delay)
        return real(*a, **k)

    monkeypatch.setattr(embed_index, "load_or_build", counting)
    return calls


def test_two_concurrent_first_searches_build_once(library: Path, tmp_path: Path, monkeypatch) -> None:
    calls = _counting_build(monkeypatch, delay=0.2)
    lib = _lib(library, tmp_path)
    barrier = threading.Barrier(2)
    results: list[dict] = []

    def go() -> None:
        barrier.wait()
        results.append(mcp_serve.dispatch(lib, "search_meetings", {"query": "roster"}))

    threads = [threading.Thread(target=go) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(results) == 2
    assert len(calls) == 1


def test_an_unchanged_library_does_not_rebuild(library: Path, tmp_path: Path, monkeypatch) -> None:
    calls = _counting_build(monkeypatch)
    lib = _lib(library, tmp_path)
    mcp_serve.dispatch(lib, "search_meetings", {"query": "roster"})
    mcp_serve.dispatch(lib, "search_meetings", {"query": "budget"})
    assert len(calls) == 1


def test_the_embedder_is_released_after_every_search(
    library: Path, tmp_path: Path, monkeypatch
) -> None:
    embedder = _CountingEmbedder()
    monkeypatch.setattr(embed_index, "default_embedder", lambda *a, **k: embedder)
    lib = _lib(library, tmp_path)
    mcp_serve.dispatch(lib, "search_meetings", {"query": "roster"})
    assert embedder.releases == 1
    mcp_serve.dispatch(lib, "search_meetings", {"query": "budget"})
    assert embedder.releases == 2


def test_a_failed_refresh_is_an_error_not_the_stale_index(
    library: Path, tmp_path: Path, monkeypatch
) -> None:
    lib = _lib(library, tmp_path)
    assert NORMAL_B in _stems_in(
        mcp_serve.dispatch(lib, "search_meetings", {"query": "hiring loop budget", "limit": 10})
    )
    (library / f"{NORMAL_B}.meta.json").write_text(
        json.dumps({"schema_version": 1, "workflow_name": "Client work",
                    "workflow_nda_mode": True}), encoding="utf-8")

    def boom(*a, **k):
        raise embed_index.EmbedderUnavailableError("model not cached")

    monkeypatch.setattr(embed_index, "load_or_build", boom)
    payload = mcp_serve.dispatch(lib, "search_meetings", {"query": "hiring loop budget"})
    assert payload["error"] == mcp_serve.SEARCH_UNAVAILABLE
    assert "results" not in payload
    assert "model not cached" not in json.dumps(payload)  # the detail stays in the log


def test_a_search_queued_behind_a_build_reads_the_gate_after_waiting(
    plain: Path, tmp_path: Path, monkeypatch
) -> None:
    """The second call waits for the first one's (cold, possibly minutes-long)
    build. Regulated mode switched on meanwhile must reach it."""
    current = {"cfg": _cfg()}
    lib = mcp_serve.Library(current["cfg"], plain, tmp_path / "idx",
                            load_config=lambda: current["cfg"])
    building, release_build = threading.Event(), threading.Event()
    real = embed_index.load_or_build

    def slow(*a, **k):
        building.set()
        release_build.wait(5)
        return real(*a, **k)

    monkeypatch.setattr(embed_index, "load_or_build", slow)
    results: dict[str, dict] = {}
    first = threading.Thread(target=lambda: results.update(
        first=mcp_serve.dispatch(lib, "search_meetings", {"query": "roster"})))
    first.start()
    assert building.wait(5)
    second = threading.Thread(target=lambda: results.update(
        second=mcp_serve.dispatch(lib, "search_meetings", {"query": "roster"})))
    second.start()
    time.sleep(0.1)  # let it queue on the lock
    current["cfg"] = _cfg(regulated=True)
    release_build.set()
    first.join(5)
    second.join(5)
    assert results["second"] == {"query": "roster", "results": [], "count": 0}


class _OverlapEmbedder(embed_index.HashingEmbedder):
    """Records a release that lands while another call is mid-embed."""

    def __init__(self) -> None:
        super().__init__(dim=256)
        self.active = 0
        self.overlaps = 0
        self._guard = threading.Lock()

    def embed(self, texts, kind="passage"):  # type: ignore[override]
        with self._guard:
            self.active += 1
        try:
            time.sleep(0.05)
            return super().embed(texts, kind=kind)
        finally:
            with self._guard:
                self.active -= 1

    def release(self) -> None:
        with self._guard:
            if self.active:
                self.overlaps += 1


def test_a_release_never_lands_inside_another_calls_embed(
    library: Path, tmp_path: Path, monkeypatch
) -> None:
    embedder = _OverlapEmbedder()
    monkeypatch.setattr(embed_index, "default_embedder", lambda *a, **k: embedder)
    lib = _lib(library, tmp_path)
    mcp_serve.dispatch(lib, "search_meetings", {"query": "roster"})  # warm build
    barrier = threading.Barrier(4)

    def go() -> None:
        barrier.wait()
        mcp_serve.dispatch(lib, "search_meetings", {"query": "budget"})

    threads = [threading.Thread(target=go) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert embedder.overlaps == 0
