"""What a working setup needs, given the backends and sinks actually in use (UX107).

`mp doctor` and the menu bar's **Finish setup** checklist (`SetupChecklist` in
Swift) answer the same question, "what is still missing before a meeting can be
summarized and published?". They used to answer it from two models that
disagreed in both directions: the checklist had no OpenAI or `claude` item and
read only the global Notion database id, while doctor failed the Anthropic key
and the Notion token whatever the backend and sinks. This module is the one
table both read. `scripts/gen_contract_fixtures.py` dumps it, with a set of
combinations and the gaps each produces, into `reachability-golden.json`, which
Swift's `SetupChecklistTests` replays through `SetupChecklist.decide`.

A *route* is one way a meeting can be processed: each workflow, or the global
config when there are no workflows (a nil backend pin inherits the global
backend; a workflow's sink list replaces the global one, an empty list meaning
publish nowhere). Zero egress (regulated mode, or a workflow's NDA flag) clamps a
route to the on-device backend and the filesystem sink before its needs are read,
through the same `effective_backend` / `effective_sinks` rule the pipeline runs.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .config import Config

# The gap ids, in the order doctor and the checklist list them. Swift's
# `SetupChecklist.Gap` raw values are these strings.
ANTHROPIC_KEY = "anthropic_key"
OPENAI_KEY = "openai_key"
CLAUDE_BINARY = "claude_binary"
NOTION_TOKEN = "notion_token"  # noqa: S105 - a gap id, not a credential
NOTION_DATABASE = "notion_database"
LOCAL_MODEL = "local_model"
GAP_ORDER: tuple[str, ...] = (
    ANTHROPIC_KEY, OPENAI_KEY, CLAUDE_BINARY, NOTION_TOKEN, NOTION_DATABASE, LOCAL_MODEL,
)

# What each summarization backend needs. `auto` tries Anthropic and falls back to
# the on-device model, so both halves are relevant to it.
BACKEND_NEEDS: dict[str, tuple[str, ...]] = {
    "anthropic": (ANTHROPIC_KEY,),
    "auto": (ANTHROPIC_KEY, LOCAL_MODEL),
    "openai": (OPENAI_KEY,),
    "claude_cli": (CLAUDE_BINARY,),
    "local": (LOCAL_MODEL,),
    "apple_intelligence": (),
}

# What each publish sink needs. A folder sink's destination (exists, writable) is
# doctor's own check (`check_sink_destinations`); it has no checklist item.
SINK_NEEDS: dict[str, tuple[str, ...]] = {
    "notion": (NOTION_TOKEN, NOTION_DATABASE),
    "obsidian": (),
    "filesystem": (),
    "lan": (),
}

# The Keychain account behind each secret gap.
SECRET_ACCOUNT: dict[str, str] = {
    ANTHROPIC_KEY: "ANTHROPIC_API_KEY",
    OPENAI_KEY: "OPENAI_API_KEY",
    NOTION_TOKEN: "NOTION_TOKEN",
}


@dataclass(frozen=True)
class Route:
    """One workflow (or the global config standing in for none)."""

    name: str
    backend: str
    sinks: tuple[str, ...]
    nda: bool = False
    # The workflow's own Notion database id; empty falls back to the global one.
    notion_database_id: str = ""


def clamp(route: Route, regulated: bool) -> tuple[str, tuple[str, ...]]:
    """The route's effective (backend, sinks) after the zero-egress rule (SEC18)."""
    if regulated or route.nda:
        return "local", ("filesystem",)
    return route.backend, route.sinks


def routes(cfg: Config, workflow_docs: list[dict]) -> list[Route]:
    """The routes for this config and these workflow docs (`workflows.load_workflows`)."""
    global_backend = cfg.summarization.backend
    if not workflow_docs:
        return [Route(name="(global config)", backend=global_backend, sinks=tuple(cfg.output.sinks))]
    out: list[Route] = []
    for doc in workflow_docs:
        backend = doc.get("backend")
        sinks: list[str] = []
        db_id = ""
        for entry in doc.get("sinks") or []:
            kind = entry.get("type") if isinstance(entry, dict) else None
            if not isinstance(kind, str) or not kind:
                continue
            sinks.append(kind)
            if kind == "notion" and not db_id and isinstance(entry.get("database_id"), str):
                db_id = entry["database_id"]
        flags = doc.get("flags")
        out.append(Route(
            name=str(doc.get("name") or "?"),
            backend=backend if isinstance(backend, str) and backend else global_backend,
            sinks=tuple(sinks),
            nda=isinstance(flags, dict) and flags.get("nda_mode") is True,
            notion_database_id=db_id,
        ))
    return out


def route_needs(route: Route, regulated: bool) -> set[str]:
    backend, sinks = clamp(route, regulated)
    needs = set(BACKEND_NEEDS.get(backend, ()))
    for sink in sinks:
        needs.update(SINK_NEEDS.get(sink, ()))
    return needs


def required(all_routes: list[Route], regulated: bool) -> set[str]:
    """Every gap id some route needs filled."""
    out: set[str] = set()
    for route in all_routes:
        out |= route_needs(route, regulated)
    return out


def backends_in_use(all_routes: list[Route], regulated: bool) -> set[str]:
    return {clamp(r, regulated)[0] for r in all_routes}


def sinks_in_use(all_routes: list[Route], regulated: bool) -> set[str]:
    return {s for r in all_routes for s in clamp(r, regulated)[1]}


def notion_routes_without_database(
    all_routes: list[Route], regulated: bool, global_database_id: str
) -> list[str]:
    """Names of the routes that publish to Notion with no database id of their own
    and an empty global fallback."""
    return [
        r.name for r in all_routes
        if NOTION_DATABASE in route_needs(r, regulated)
        and not (r.notion_database_id or global_database_id)
    ]


def gaps(
    all_routes: list[Route],
    *,
    regulated: bool,
    global_database_id: str,
    present: dict[str, bool],
) -> list[str]:
    """The unmet gap ids in `GAP_ORDER`. `present` maps each of anthropic_key,
    openai_key, notion_token, claude_binary and local_model to whether it is there;
    the Notion database is derived per route from the ids themselves."""
    need = required(all_routes, regulated)
    out: list[str] = []
    for gap in GAP_ORDER:
        if gap not in need:
            continue
        if gap == NOTION_DATABASE:
            if notion_routes_without_database(all_routes, regulated, global_database_id):
                out.append(gap)
        elif not present.get(gap, False):
            out.append(gap)
    return out


def config_routes(cfg: Config, workflows_dir: Path | None = None) -> list[Route]:
    """`routes` over the workflow files on this Mac (the daemon's own directory)."""
    from . import workflows
    return routes(cfg, workflows.load_workflows(workflows_dir)[0])
