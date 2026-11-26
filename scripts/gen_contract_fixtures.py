#!/usr/bin/env python3
"""Regenerate the CI4 cross-tree golden fixtures from the real Python writers.

Three Swift-Python surfaces had no shared fixture, so each tree pinned its own
hand-authored expectations and a coordinated rename passed both suites:

  publish-result-golden.json    `<stem>.publish.json`, written by
                                `publish_router._write_publish_sidecar`, read by
                                Swift's `PipelineLauncher.PublishResult.load`.
  prefetch-progress-golden.json the `mp prefetch-model` stdout JSONL stream,
                                written by `prefetch_model._emit`, read by
                                Swift's `ModelDownloadSupervisor.handleEvent`.
  speaker-overlay-golden.json   `<stem>.speaker_labels.json` resolution, applied
                                by `speaker_overlay.apply_overlay`, mirrored by
                                Swift's `SpeakerLabelStore.displayLabel`.
  summary-limits-golden.json    PIPE54: the `MeetingSummary` limits (title length, summary
                                bullets, confidence values) Swift's summary writers respect.
  reachability-golden.json      UX107: which secret, binary or Notion database each
                                backend and sink needs (`mp.reachability`, read by
                                `mp doctor`), replayed by Swift's `SetupChecklist`.
  restore-plan-golden.json      T18: the `mp restore --dry-run --json` payload, written by
                                `restore.plan_restore` over a real archive, decoded by
                                Swift's `RestorePlan` (the in-app restore's confirm).
  run-sidecar-golden.json       OBS8: `<stem>.run.json`, written by
                                `corrections.write_run_sidecar`, decoded by Swift's
                                `MeetingStore` (provenance, fallback, usage, shares).
  glossary-golden.json          `glossary.toml` resolution, read by
                                `glossary.load_glossary`, mirrored by Swift's
                                `GlossaryStore.resolvedTerms` (FEAT11). The one
                                surface here Swift also WRITES, so a drift means
                                the Vocabulary editor promises a substitution the
                                pipeline never makes.

Every byte a fixture pins is produced by CALLING the shipping Python code, so a
writer change lands in the fixture rather than being silently absent from it.
Two families take their INPUTS from somewhere other than a live run, and say so
(T18): the prefetch events and field names are AST-walked from `prefetch_model`'s
`_emit` call sites, then each line is produced by calling `_emit` with stdout
captured; and most publish cases run hand-written `fanout` results through the
real `_write_publish_sidecar`, while the failed-sink case runs `fanout` itself
with a publisher that raises, so its `error` and `failure` come from
`emit_failure`. `pipeline/tests/test_ci4_contracts.py` regenerates in-memory and diffs
against the committed files, so forgetting to run this is a red Python build;
`daemon/Tests/MeetingPipeTests/CI4ContractFixtureTests.swift` parses the same
committed files with the real Swift readers, so a regenerated fixture the Swift
side does not understand is a red Swift build.

Usage (from the repo root):

    cd pipeline && uv run python ../scripts/gen_contract_fixtures.py

Writes into `daemon/Tests/MeetingPipeTests/Fixtures/`. Diff before committing.
"""
from __future__ import annotations

import ast
import contextlib
import io
import json
import os
import shutil
import sys
from collections.abc import Iterator
from datetime import datetime
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[1]
FIXTURES = REPO / "daemon" / "Tests" / "MeetingPipeTests" / "Fixtures"
PIPELINE_SRC = REPO / "pipeline" / "src"

sys.path.insert(0, str(PIPELINE_SRC))

from mp import prefetch_model, publish_router, speaker_overlay  # noqa: E402
from mp.schemas import MeetingSummary  # noqa: E402

# `_write_publish_sidecar` stamps `datetime.now()`. The value cannot be golden,
# so it is replaced by this sentinel and its FORMAT is asserted separately.
TS_SENTINEL = "2026-01-01T00:00:00+00:00"


@contextlib.contextmanager
def _scratch_env(tmp: Path) -> Iterator[None]:
    """Keep generation off the owner's machine state: the event log goes to `tmp`
    (the writers called here emit events, and outside pytest `events.logs_dir` is
    the real `~/Library/Logs/MeetingPipe`), and `MP_FAILURE_PATH` is unset so
    `emit_failure` writes no file."""
    saved = {k: os.environ.get(k) for k in ("MEETINGPIPE_LOGS_DIR", "MP_FAILURE_PATH")}
    os.environ["MEETINGPIPE_LOGS_DIR"] = str(tmp / "logs")
    os.environ.pop("MP_FAILURE_PATH", None)
    try:
        yield
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def _envelope(
    comment: str, cases: list[dict[str, Any]], contract: dict[str, Any] | None = None
) -> str:
    doc: dict[str, Any] = {"_comment": comment}
    if contract is not None:
        doc["contract"] = contract
    doc["cases"] = cases
    return json.dumps(doc, indent=2, sort_keys=False) + "\n"


# --------------------------------------------------------------------------
# 1. <stem>.publish.json
# --------------------------------------------------------------------------

# Each case is a `publish_router.fanout` result shape, run through the real
# sidecar writer. The five cover every `publish_state` branch plus the
# local-only (no page URL) case the daemon renders differently.
PUBLISH_CASES: list[tuple[str, dict[str, Any]]] = [
    (
        "full_one_sink_with_page",
        {
            "page_url": "https://www.notion.so/Meeting-abc123",
            "sinks": {"notion": {"page_url": "https://www.notion.so/Meeting-abc123"}},
        },
    ),
    (
        "partial_notion_ok_obsidian_failed",
        {
            "page_url": "https://www.notion.so/Meeting-abc123",
            "sinks": {
                "notion": {"page_url": "https://www.notion.so/Meeting-abc123"},
                "obsidian": {"error": "vault path not writable"},
            },
        },
    ),
    (
        "none_every_sink_failed",
        {
            "page_url": None,
            "sinks": {
                "notion": {"error": "401 Unauthorized"},
                "obsidian": {"error": "vault path not writable"},
            },
        },
    ),
    (
        "full_local_only_no_page_url",
        {"page_url": None, "sinks": {"filesystem": {}}},
    ),
    (
        # WF10: no sink configured at all (a workflow saved with no
        # destinations), which `fanout` marks. Settled, not a failure.
        "local_no_sink_configured",
        {"page_url": None, "sinks": {}, "no_sinks_configured": True},
    ),
]


# The keys Swift may reach for in the sidecar. `PublishResult.load` reads the
# first two today; the rest are pinned so a rename is caught here rather than by
# a future reader finding them gone.
PUBLISH_KEYS = {"schema_version", "state", "page_url", "ts", "sinks"}


#: T18: a failed sink as `fanout` records it. Every case above hands the writer a
#: result with only `error`, so `failure` was null in every sink of the golden; this
#: one runs `fanout` with a publisher that raises, so `error`, `error_type` and
#: `failure` (from `emit_failure`) are what the shipping path writes.
FANOUT_FAILED_CASE = "partial_failed_sink_from_fanout"


class _StubPublisher:
    def __init__(self, name: str, *, raises: BaseException | None = None,
                 result: dict[str, Any] | None = None) -> None:
        self.name = name
        self._raises = raises
        self._result = result or {}

    def upsert(self, **_kwargs: Any) -> dict[str, Any]:
        if self._raises is not None:
            raise self._raises
        return self._result


def _fanout_with_a_failing_sink(summary_json: Path) -> dict[str, Any]:
    import httpx

    from mp.config import Config

    summary = MeetingSummary(title="Weekly sync", summary=["A point."], detected_language="en")
    summary_json.write_text(summary.model_dump_json(), encoding="utf-8")
    publishers = [
        _StubPublisher("filesystem", result={"path": "/synthetic/out/meeting.md"}),
        _StubPublisher("notion", raises=httpx.ConnectError("synthetic connection failure")),
    ]
    return publish_router.fanout(
        summary_json=summary_json, cfg=Config(), transcript_md=None,
        publishers=publishers,
    )


#: PIPE34: the marker `fanout` writes before any sink runs, and what a run whose final write
#: failed leaves on disk. Written by its own writer, not from a fanout result.
PENDING_MARKER_CASE = "unknown_pending_marker_before_sinks"


def gen_publish(tmp: Path) -> str:
    with _scratch_env(tmp):
        return _gen_publish(tmp)


def _gen_publish(tmp: Path) -> str:
    cases: list[dict[str, Any]] = []
    for name, result in [*PUBLISH_CASES, (FANOUT_FAILED_CASE, None), (PENDING_MARKER_CASE, None)]:
        summary_json = tmp / f"{name}.summary.json"
        summary_json.write_text("{}", encoding="utf-8")
        if name == FANOUT_FAILED_CASE:
            # `fanout` writes the sidecar itself.
            result = _fanout_with_a_failing_sink(summary_json)
        elif result is None:
            publish_router._write_pending_marker(summary_json)
            result = {"sinks": {}}
        else:
            publish_router._write_publish_sidecar(summary_json, result)
        written = json.loads(
            publish_router.publish_sidecar_path(summary_json).read_text(encoding="utf-8")
        )
        if set(written) != PUBLISH_KEYS:
            missing = sorted(PUBLISH_KEYS - set(written))
            added = sorted(set(written) - PUBLISH_KEYS)
            raise SystemExit(
                f"`{name}`: the publish sidecar's key set changed (missing={missing}, "
                f"new={added}). Swift's PipelineLauncher.PublishResult.load reads "
                "`state` and `page_url`; update it and CONVENTIONS.md's "
                "'Publish result' section, then update PUBLISH_KEYS here."
            )
        # The wall-clock stamp cannot be golden, so it is validated here and
        # then replaced. Keeping a real sample in the fixture would make the
        # file differ on every regeneration and the byte comparison worthless.
        parsed = datetime.fromisoformat(written["ts"])
        if parsed.tzinfo is None or parsed.microsecond != 0:
            raise SystemExit(
                f"publish sidecar `ts` is no longer tz-aware second-resolution ISO8601: "
                f"{written['ts']!r}. Swift does not parse it today, but the shape is "
                "part of the documented contract; update CONVENTIONS.md if this is intended."
            )
        written["ts"] = TS_SENTINEL
        cases.append(
            {
                "name": name,
                "payload": written,
                # What Swift's `PublishResult.load` must pull out of `payload`.
                # It reads two of the five keys; the other three are pinned by
                # the payload comparison so a rename still breaks the build.
                "expected_state": written["state"],
                "expected_page_url": written["page_url"],
                # T18: per sink, what the RESULT handed to the writer carried (for the
                # fanout case, what `emit_failure` produced), not what the writer wrote,
                # so a writer that drops `error` or `failure` is a red Swift build.
                "expected_sinks": {
                    sink: {
                        "error": res.get("error") if isinstance(res, dict) else None,
                        "failure": res.get("failure") if isinstance(res, dict) else None,
                    }
                    for sink, res in sorted((result.get("sinks") or {}).items())
                },
                "all_sinks_failed": publish_router.all_sinks_failed(result),
            }
        )
    # The full `state` vocabulary, derived by exercising every `publish_state`
    # branch rather than transcribed. Six Swift call sites compare against these
    # literals (MeetingRow's badge + retry action, AudioRetention.isSettled,
    # LibraryScope.needsYou, MeetingDetailView+Header), and every one of them
    # silently takes the wrong branch if the vocabulary changes: a publish that
    # landed nowhere would render as a clean success.
    vocabulary = sorted(
        {
            publish_router.publish_state({"sinks": {}}),
            publish_router.publish_state({"sinks": {"a": {}}}),
            publish_router.publish_state({"sinks": {"a": {}, "b": {"error": "x"}}}),
            publish_router.publish_state({"sinks": {"a": {"error": "x"}}}),
            publish_router.publish_state({"sinks": {}, "no_sinks_configured": True}),
            publish_router.PUBLISH_STATE_UNKNOWN,
        }
    )
    return _envelope(
        "CI4 golden vectors for the `<stem>.publish.json` outcome contract (PIPE1). "
        "Generated by scripts/gen_contract_fixtures.py from publish_router."
        "_write_publish_sidecar; do not hand-edit. `ts` is replaced by a fixed "
        "sentinel because the writer stamps the wall clock, and its real format "
        "is asserted at generation time instead. `contract.publish_states` is the "
        "complete vocabulary Swift branches on; `unknown` (PIPE34) is the marker "
        "written before any sink runs, left in place when the final write fails. "
        "Swift reads this via "
        "PipelineLauncher.PublishResult.load.",
        cases,
        contract={"publish_states": vocabulary, "keys": sorted(PUBLISH_KEYS)},
    )


# --------------------------------------------------------------------------
# 2. `mp prefetch-model` progress JSONL
# --------------------------------------------------------------------------

# Deterministic stand-ins, by field name, for the runtime expressions at the
# `_emit` call sites. A NEW field name at a call site has no entry here and
# fails loudly rather than being quietly omitted from the fixture.
PREFETCH_FIELD_VALUES: dict[str, Any] = {
    "total_bytes": 4_294_967_296,
    "cached_bytes": 1_073_741_824,
    "downloaded_bytes": 2_147_483_648,
    "revision": "a1b2c3d4",
    "path": "/Users/me/.cache/huggingface/hub/models--mlx-community--x/snapshots/a1b2c3d4",
    "percent": 0.5,
    "error": "connection reset by peer",
    "error_type": "ConnectionError",
}

REPO_ID = "mlx-community/Qwen2.5-7B-Instruct-4bit"


def _emit_call_sites() -> list[tuple[str, list[str]]]:
    """Every `_emit(...)` call in prefetch_model.py, as (event, field names).

    AST-extracted rather than transcribed, so adding an event or renaming a
    field at a call site changes the fixture on the next regeneration. Mirrors
    how `test_entry_contract.py` walks `__main__.py`'s dispatch.
    """
    tree = ast.parse((PIPELINE_SRC / "mp" / "prefetch_model.py").read_text(encoding="utf-8"))
    sites: list[tuple[str, list[str]]] = []
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)):
            continue
        if node.func.id != "_emit" or not node.args:
            continue
        event = node.args[0]
        if not (isinstance(event, ast.Constant) and isinstance(event.value, str)):
            raise SystemExit(f"_emit call at line {node.lineno} has a non-literal event name")
        fields = [kw.arg for kw in node.keywords if kw.arg]
        sites.append((event.value, fields))
    if not sites:
        raise SystemExit("no _emit call sites found; the extractor has gone stale")
    return sites


def _emitted_line(event: str, fields: dict[str, Any]) -> str:
    """The exact bytes `prefetch_model._emit` puts on stdout, which is what Swift
    parses. Called, not re-serialized here (T18): a change to `_emit`'s envelope
    (its `event` or `repo_id` key, or how it serializes) lands in the golden."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        prefetch_model._emit(event, REPO_ID, **fields)
    text = out.getvalue()
    if text.count("\n") != 1 or not text.endswith("\n"):
        raise SystemExit(f"_emit('{event}') no longer writes exactly one line to stdout: {text!r}")
    return text[:-1]


def gen_prefetch(tmp: Path) -> str:
    with _scratch_env(tmp):
        return _gen_prefetch()


def _gen_prefetch() -> str:
    cases: list[dict[str, Any]] = []
    seen: set[str] = set()
    for event, fields in _emit_call_sites():
        # One case per distinct (event, field set): the two `complete` sites and
        # the two `failed` sites carry identical shapes.
        key = f"{event}:{','.join(sorted(fields))}"
        if key in seen:
            continue
        seen.add(key)
        missing = [f for f in fields if f not in PREFETCH_FIELD_VALUES]
        if missing:
            raise SystemExit(
                f"_emit('{event}') carries unknown field(s) {missing}; add them to "
                "PREFETCH_FIELD_VALUES so the fixture can pin them"
            )
        line = _emitted_line(event, {f: PREFETCH_FIELD_VALUES[f] for f in fields})
        record = json.loads(line)

        # Language-neutral facts about the state Swift must reach. Derived from
        # the record, so a field rename moves them too.
        if event in ("started", "progress"):
            downloaded = record.get("downloaded_bytes", record.get("cached_bytes", 0))
            total = record.get("total_bytes", 0)
            expect = {
                "kind": "downloading",
                "downloaded_bytes": downloaded,
                "total_bytes": total,
                "progress": round(downloaded / total, 6) if total else None,
            }
        elif event == "complete":
            expect = {"kind": "completed"}
        elif event == "failed":
            expect = {"kind": "failed", "error": record["error"]}
        else:
            raise SystemExit(
                f"_emit('{event}') is a new event; teach the Swift supervisor to "
                "handle it, then add its expectation here"
            )
        expect["model_id"] = REPO_ID
        cases.append({"name": key.replace(":", "_with_").replace(",", "_"),
                      "line": line, "expect": expect})
    return _envelope(
        "CI4 golden vectors for the `mp prefetch-model` stdout JSONL progress "
        "stream. Generated by scripts/gen_contract_fixtures.py, which AST-walks "
        "every `_emit(...)` call site in pipeline/src/mp/prefetch_model.py for the "
        "event and field inventory and then calls `_emit` with stdout captured; do "
        "not hand-edit. `line` is the exact stdout bytes; `expect` is the state "
        "Swift's ModelDownloadSupervisor.handleEvent must reach. A new event "
        "name or a renamed field appears here on the next regeneration and "
        "breaks the Swift suite until the supervisor handles it.",
        cases,
    )


# --------------------------------------------------------------------------
# 3. speaker-label overlay resolution
# --------------------------------------------------------------------------

# `sidecar` is the raw on-disk `<stem>.speaker_labels.json`; `speakers` are the
# per-segment diarization labels in array order (null = a segment with no
# speaker). The cases deliberately include the shapes a hand-edited or
# truncated sidecar can carry, since both readers are fail-open.
OVERLAY_CASES: list[tuple[str, dict[str, Any], list[str | None]]] = [
    ("no_overlay", {}, ["THEM-A", "THEM-B"]),
    ("names_a_cluster", {"labels": {"THEM-A": "Alice"}}, ["THEM-A", "THEM-B"]),
    (
        "segment_override_wins_over_cluster",
        {"labels": {"THEM-A": "Alice"}, "segments": {"1": "THEM-B"}},
        ["THEM-A", "THEM-A", "THEM-A"],
    ),
    (
        "segment_reassigned_to_named_cluster_chains",
        {"labels": {"THEM-A": "Alice"}, "segments": {"0": "THEM-A"}},
        ["THEM-B", "THEM-B"],
    ),
    (
        "new_person_absent_from_labels_resolves_to_itself",
        {"labels": {"THEM-A": "Alice"}, "segments": {"1": "Dana"}},
        ["THEM-A", "THEM-A"],
    ),
    ("segment_with_no_speaker_and_no_override", {"labels": {"THEM-A": "Alice"}}, [None, "THEM-A"]),
    # Fail-open shapes. Both readers must DROP these rather than resolve a
    # segment to an empty or non-string name.
    ("empty_label_value_is_dropped", {"labels": {"THEM-A": ""}}, ["THEM-A"]),
    ("empty_label_key_is_dropped", {"labels": {"": "Alice"}}, ["THEM-A"]),
    ("non_string_label_value_is_dropped", {"labels": {"THEM-A": 42}}, ["THEM-A"]),
    ("empty_segment_value_is_dropped", {"segments": {"0": ""}}, ["THEM-A"]),
    ("non_integer_segment_key_is_dropped", {"segments": {"first": "Alice"}}, ["THEM-A"]),
    (
        "zero_padded_segment_key_is_canonicalized",
        {"segments": {"01": "Alice"}},
        ["THEM-A", "THEM-A"],
    ),
    ("labels_not_an_object", {"labels": ["THEM-A"]}, ["THEM-A"]),
    ("segments_not_an_object", {"segments": "nope"}, ["THEM-A"]),
]


def gen_overlay(tmp: Path) -> str:
    cases: list[dict[str, Any]] = []
    for name, sidecar, speakers in OVERLAY_CASES:
        md = tmp / f"{name}.md"
        md.write_text("", encoding="utf-8")
        speaker_overlay.overlay_path(md).write_text(
            json.dumps(sidecar, sort_keys=True), encoding="utf-8"
        )
        overlay = speaker_overlay.read_overlay(md)
        segments: list[dict[str, Any]] = [{"speaker": s} for s in speakers]
        changed = speaker_overlay.apply_overlay(segments, overlay)
        cases.append(
            {
                "name": name,
                "sidecar": sidecar,
                "speakers": speakers,
                "read_labels": overlay["labels"],
                "read_segments": overlay["segments"],
                "resolved": [s.get("speaker") for s in segments],
                "changed": changed,
            }
        )
    return _envelope(
        "CI4 golden vectors for the `<stem>.speaker_labels.json` resolution "
        "(FEAT3-UNDO / FEAT3-SEGMENT). Generated by "
        "scripts/gen_contract_fixtures.py from speaker_overlay.read_overlay + "
        "apply_overlay; do not hand-edit. Swift's SpeakerLabelStore.read + "
        ".displayLabel must produce the same `read_*` maps and the same "
        "`resolved` labels, including for the fail-open shapes a hand-edited "
        "sidecar can carry.",
        cases,
    )


# --------------------------------------------------------------------------
# 4. glossary.toml resolution
# --------------------------------------------------------------------------

# `toml` is the whole file as a user (or the in-app editor) would leave it;
# `workflow` is the meeting's workflow name, or null for a meeting with none.
# The pairs the pipeline would apply are produced by the real reader, so a
# change to the merge rule lands here and then breaks the Swift editor's
# preview of what it is about to write.
GLOSSARY_CASES: list[tuple[str, str, str | None]] = [
    ("empty_file", "", None),
    (
        "global_terms_only",
        '[terms]\n"kubernetes" = "Kubernetes"\n"post gres" = "PostgreSQL"\n',
        None,
    ),
    (
        "workflow_terms_stack_on_global",
        '[terms]\n"acme" = "ACME"\n\n[workflow."Client work".terms]\n"ps" = "PS Corp"\n',
        "Client work",
    ),
    (
        "workflow_term_wins_a_clash",
        '[terms]\n"acme" = "ACME"\n\n[workflow."Client work".terms]\n"acme" = "ACME Corp"\n',
        "Client work",
    ),
    (
        "another_workflows_terms_are_not_applied",
        '[terms]\n"acme" = "ACME"\n\n[workflow."Client work".terms]\n"ps" = "PS Corp"\n',
        "General",
    ),
    (
        "no_workflow_gets_global_only",
        '[terms]\n"acme" = "ACME"\n\n[workflow."Client work".terms]\n"ps" = "PS Corp"\n',
        None,
    ),
    (
        "keys_are_lower_cased_for_matching",
        '[terms]\n"Kubernetes" = "Kubernetes"\n"CUBE kernetes" = "Kubernetes"\n',
        None,
    ),
    # The skip rules. Both sides must drop exactly these, or the editor shows a
    # row the pipeline silently ignores.
    ("blank_key_is_dropped", '[terms]\n"   " = "Kubernetes"\n', None),
    ("empty_value_is_dropped", '[terms]\n"kubernetes" = ""\n', None),
    ("non_string_value_is_dropped", '[terms]\n"kubernetes" = 42\n', None),
    (
        "unknown_sections_are_ignored_by_the_reader",
        '[terms]\n"acme" = "ACME"\n\n[fuzzy]\nenabled = true\nmax_distance = 2\n\n'
        '[future]\nwhatever = "keep me"\n',
        None,
    ),
    (
        "workflow_table_without_terms",
        '[terms]\n"acme" = "ACME"\n\n[workflow."Client work"]\nnote = "no terms here"\n',
        "Client work",
    ),
]


# WF11: a meeting resolves its glossary table through its sidecar's `workflow_id`
# to the workflow's *current* name, then the recorded `workflow_name`: the first of
# the two whose table yields a usable term wins alone. `workflows` is the live
# (id, name) set; `meta` is the meeting's sidecar. Swift's
# `GlossaryStore.resolvedTerms(at:workflowNames:)` over
# `WorkflowIdentity.glossaryNames` must pick the same table.
GLOSSARY_RENAME_CASES: list[tuple[str, str, dict[str, str], list[tuple[str, str]]]] = [
    (
        "renamed_workflow_resolves_by_id",
        '[terms]\n"acme" = "ACME"\n\n[workflow."Team Sync".terms]\n"standup" = "Stand-up"\n',
        {"workflow_id": "6f1c2b9a-0d3e-4f5a-9b8c-7d6e5f4a3b2c", "workflow_name": "Weekly Sync"},
        [("6F1C2B9A-0D3E-4F5A-9B8C-7D6E5F4A3B2C", "Team Sync")],
    ),
    (
        "unknown_id_falls_back_to_the_recorded_name",
        '[terms]\n"acme" = "ACME"\n\n[workflow."Weekly Sync".terms]\n"standup" = "Stand-up"\n',
        {"workflow_id": "00000000-0000-0000-0000-000000000000", "workflow_name": "Weekly Sync"},
        [("6F1C2B9A-0D3E-4F5A-9B8C-7D6E5F4A3B2C", "Team Sync")],
    ),
    # The 2026-11-21 amendment: renamed before WF11 moved tables, so the current name has
    # no table and the recorded name's table still applies.
    (
        "table_stranded_by_an_earlier_rename_falls_back_to_the_recorded_name",
        '[terms]\n"acme" = "ACME"\n\n[workflow."Weekly Sync".terms]\n"standup" = "Stand-up"\n',
        {"workflow_id": "6f1c2b9a-0d3e-4f5a-9b8c-7d6e5f4a3b2c", "workflow_name": "Weekly Sync"},
        [("6F1C2B9A-0D3E-4F5A-9B8C-7D6E5F4A3B2C", "Team Sync")],
    ),
    # An empty table under the current name (the editor leaves one when its last term is
    # deleted) is as good as none.
    (
        "empty_current_table_falls_back_to_the_recorded_name",
        '[workflow."Team Sync".terms]\n\n[workflow."Weekly Sync".terms]\n"standup" = "Stand-up"\n',
        {"workflow_id": "6f1c2b9a-0d3e-4f5a-9b8c-7d6e5f4a3b2c", "workflow_name": "Weekly Sync"},
        [("6F1C2B9A-0D3E-4F5A-9B8C-7D6E5F4A3B2C", "Team Sync")],
    ),
    # Both tables have terms: the current name's wins alone, nothing merged from the other.
    (
        "current_table_with_terms_wins_alone",
        '[workflow."Team Sync".terms]\n"standup" = "Daily"\n\n'
        '[workflow."Weekly Sync".terms]\n"standup" = "Stand-up"\n"retro" = "Retro"\n',
        {"workflow_id": "6f1c2b9a-0d3e-4f5a-9b8c-7d6e5f4a3b2c", "workflow_name": "Weekly Sync"},
        [("6F1C2B9A-0D3E-4F5A-9B8C-7D6E5F4A3B2C", "Team Sync")],
    ),
]


def gen_glossary(tmp: Path) -> str:
    from mp import glossary as glossary_mod
    from mp import workflows as workflows_mod

    cases: list[dict[str, Any]] = []
    for name, toml_text, workflow in GLOSSARY_CASES:
        path = tmp / f"{name}.glossary.toml"
        path.write_text(toml_text, encoding="utf-8")
        loaded = glossary_mod.load_glossary(path=path, workflow_name=workflow)
        cases.append(
            {
                "name": name,
                "toml": toml_text,
                "workflow": workflow,
                "terms": loaded.terms,
                "fuzzy_enabled": loaded.fuzzy_enabled,
                "fuzzy_max_distance": loaded.fuzzy_max_distance,
            }
        )
    saved_dir = workflows_mod.WORKFLOWS_DIR
    try:
        for name, toml_text, meta, workflows in GLOSSARY_RENAME_CASES:
            case_dir = tmp / f"{name}.case"
            wdir = case_dir / "workflows"
            wdir.mkdir(parents=True)
            for wid, wname in workflows:
                (wdir / f"{wid}.toml").write_text(f'id = "{wid}"\nname = "{wname}"\n', encoding="utf-8")
            workflows_mod.WORKFLOWS_DIR = wdir
            path = case_dir / "glossary.toml"
            path.write_text(toml_text, encoding="utf-8")
            (case_dir / "m.meta.json").write_text(json.dumps(meta), encoding="utf-8")
            loaded = glossary_mod.load_glossary(case_dir / "m.wav", path=path)
            cases.append(
                {
                    "name": name,
                    "toml": toml_text,
                    "workflow": None,
                    "meta": meta,
                    "workflows": [{"id": wid, "name": wname} for wid, wname in workflows],
                    "terms": loaded.terms,
                    "fuzzy_enabled": loaded.fuzzy_enabled,
                    "fuzzy_max_distance": loaded.fuzzy_max_distance,
                }
            )
    finally:
        workflows_mod.WORKFLOWS_DIR = saved_dir
    return _envelope(
        "CI4 golden vectors for `~/.config/meeting-pipe/glossary.toml` resolution "
        "(ASR1, edited in-app since FEAT11). Generated by "
        "scripts/gen_contract_fixtures.py from glossary.load_glossary; do not "
        "hand-edit. `terms` is what the pipeline would apply at finalize, keyed by "
        "the lower-cased 'as heard' form; Swift's GlossaryStore.resolvedTerms must "
        "produce the same map, including the skip rules, so the Vocabulary editor "
        "cannot promise a substitution the pipeline will not make. A case with "
        "`meta` and `workflows` resolves its workflow through the sidecar's id "
        "to the current name, then the recorded name, the first whose table has a "
        "usable term winning alone (WF11, Swift WorkflowIdentity.glossaryNames) "
        "instead of `workflow`. `fuzzy_*` is "
        "pinned because the editor must leave that section untouched on a write.",
        cases,
    )


# PIPE42: how `config.toml` decides regulated mode, the one key both trees read and
# the one where a disagreement is a privacy failure. Each case is a whole file.
REGULATED_CASES: list[tuple[str, str]] = [
    ("top_level_true", "[modes]\nregulated_mode = true\n"),
    ("top_level_false", "[modes]\nregulated_mode = false\n"),
    ("absent", '[summarization]\nbackend = "local"\n'),
    ("appended_after_transcription", '[transcription]\nlanguage = "auto"\nmodes.regulated_mode = true\n'),
    ("appended_after_mcp", "[mcp]\nenabled = false\nmodes.regulated_mode = true\n"),
    ("appended_after_a_last_modes_table", "[modes]\nregulated_mode = false\nmodes.regulated_mode = true\n"),
    ("above_every_table", "regulated_mode = true\n\n[modes]\n"),
    (
        "inside_an_array_of_tables",
        '[[summarization.extra_sections]]\nname = "Risks"\ninstruction = "List them"\n'
        "modes.regulated_mode = true\n",
    ),
    ("string_true", '[modes]\nregulated_mode = "true"\n'),
    ("string_false", '[modes]\nregulated_mode = "false"\n'),
    ("integer_one", "[modes]\nregulated_mode = 1\n"),
    ("integer_zero", "[modes]\nregulated_mode = 0\n"),
    ("syntax_error", "[modes]\nregulated_mode = true\n[summarization\n"),
    ("unknown_key_elsewhere", '[modes]\nregulated_mode = true\n\n[summarization]\nbackedn = "local"\n'),
]


def gen_regulated(tmp: Path) -> str:
    from mp import config as config_mod

    # `Config.load` reports unknown keys to the event log; keep generation out of
    # the owner's real `pipeline_events.jsonl`.
    with _scratch_env(tmp):
        cases: list[dict[str, Any]] = []
        for name, toml_text in REGULATED_CASES:
            path = tmp / f"{name}.config.toml"
            path.write_text(toml_text, encoding="utf-8")
            try:
                cfg = config_mod.Config.load(path)
            except Exception:  # noqa: BLE001 - any refusal is the outcome under test
                cases.append({"name": name, "toml": toml_text, "loads": False, "regulated_mode": None})
            else:
                cases.append({
                    "name": name, "toml": toml_text, "loads": True,
                    "regulated_mode": cfg.modes.regulated_mode,
                })
        return _envelope(
            "CI4 golden vectors for `modes.regulated_mode` in `config.toml` (PIPE42). Generated by "
            "scripts/gen_contract_fixtures.py from config.Config.load; do not hand-edit. "
            "Every case is about the regulated switch. `loads: false` is a pipeline that refuses to "
            "run on the file (syntax error, the switch misplaced or not a boolean); Swift's "
            "ConfigStore must then set `parseError` and read regulated mode as on, so neither tree "
            "runs a meeting as unregulated on a file whose switch it could not read. `loads: true` "
            "must read the same boolean in both trees with no `parseError`. Files the pipeline "
            "refuses for reasons unrelated to the switch (a misspelt sink) are out of scope: Swift "
            "loads those.",
            cases,
        )


def gen_failures() -> str:
    import anthropic
    import httpx

    from mp.config import ConfigUnreadableError, MissingSecretError
    from mp.failure_details import describe
    from mp.publish_router import SyncedTargetError
    from mp.summarize import OverlayUnreadable

    request = httpx.Request("POST", "https://api.anthropic.com/v1/messages")
    cases = []
    for name, status, message, expected in [
        ("credits", 400, "Your credit balance is too low to access the Anthropic API.", "credits"),
        ("generic_400", 400, "Invalid argument", "unknown"),
        ("rejected_key", 401, "Invalid x-api-key", "rejected_key"),
        ("expired_key", 401, "API key has expired", "expired_key"),
        ("temporary_limit", 429, "Too many requests", "rate_limit"),
        ("service_outage", 503, "Unavailable", "service_unavailable"),
    ]:
        error = anthropic.APIStatusError(message, response=httpx.Response(status, request=request,
            headers={"request-id": "req_0123456789abcdef"}), body={"error": {"message": message}})
        cases.append({"name": name, "payload": describe(error, operation="summary"), "cause": expected})
    # PIPE28: a retired or mistyped model id, as the API answers it (a 404 whose type names it).
    rejected = anthropic.NotFoundError("model: claude-synthetic-retired", response=httpx.Response(
        404, request=request, headers={"request-id": "req_0123456789abcdef"}),
        body={"type": "error", "error": {"type": "not_found_error", "message": "model: claude-synthetic-retired"}})
    cases.append({"name": "model_rejected", "payload": describe(rejected, operation="summary"),
                  "cause": "model_rejected"})
    for name, error in [("missing_key", MissingSecretError("ANTHROPIC_API_KEY")),
                        ("connection", httpx.ConnectError("synthetic connection failure")),
                        ("timeout", httpx.ReadTimeout("synthetic timeout")),
                        ("memory", RuntimeError("not enough memory: synthetic refusal")),
                        ("model_missing", RuntimeError("not in the local HuggingFace cache")),
                        ("unknown", RuntimeError("synthetic unknown failure"))]:
        cases.append({"name": name, "payload": describe(error, operation="summary"), "cause": name})
    # UX94: a config.toml that does not parse.
    cases.append({
        "name": "config",
        "payload": describe(ConfigUnreadableError(Path("/synthetic/config.toml"), line=2, column=1),
                            operation="summary"),
        "cause": "config",
    })
    cases.append({
        "name": "synced_target",
        "payload": describe(SyncedTargetError("filesystem", Path("/synthetic/synced"), "Dropbox"),
                            operation="publish", provider="filesystem"),
        "cause": "synced_target",
    })
    # STOR9: a meeting's edit overlay is present and will not read, so summarize refused.
    cases.append({
        "name": "overlay_unreadable",
        "payload": describe(OverlayUnreadable("synthetic: the speaker names file can't be read"),
                            operation="summary"),
        "cause": "overlay_unreadable",
    })
    return _envelope("Generated synthetic failure metadata from mp.failure_details.describe. No owner data.", cases)


def gen_summary_limits() -> str:
    """PIPE54: the three `MeetingSummary` limits Swift's writers must respect, read off the
    schema the pipeline validates `mp publish`'s input against, not restated."""
    from mp.schemas import SUMMARY_MIN_ITEMS, TITLE_MIN_LENGTH, MeetingSummary

    schema = MeetingSummary.model_json_schema()
    props = schema["properties"]
    confidence = schema["$defs"]["ActionItem"]["properties"]["confidence"]
    contract = {
        "title_max_length": props["title"]["maxLength"],
        "summary_max_items": props["summary"]["maxItems"],
        # PIPE43 (F176): the lower bounds, so an editor save cannot write a file publish refuses.
        # They apply to generated output only, so they are module constants, not schema fields.
        "title_min_length": TITLE_MIN_LENGTH,
        "summary_min_items": SUMMARY_MIN_ITEMS,
        "confidence_values": confidence["enum"],
    }
    return _envelope(
        "PIPE54 limits on `<stem>.summary.json`, generated by scripts/gen_contract_fixtures.py "
        "from schemas.MeetingSummary.model_json_schema(); do not hand-edit. `mp publish` "
        "validates the file against the schema before any sink runs, so a Swift writer "
        "(the Summary editor, the Apple summarizer) that exceeds one fails every later "
        "publish of that meeting. Swift mirrors these as MeetingSummary.titleMaxLength, "
        "summaryMaxItems, confidenceValues, titleMinLength and summaryMinItems (SummaryLimitsTests).",
        [],
        contract,
    )


# --------------------------------------------------------------------------
# UX107: setup reachability (doctor and the Finish setup checklist)
# --------------------------------------------------------------------------

_ALL_PRESENT = {
    "anthropic_key": True, "openai_key": True, "notion_token": True,
    "claude_binary": True, "local_model": True,
}


def _wf(name: str, backend: str | None, sinks: list[dict[str, str]], nda: bool = False) -> dict[str, Any]:
    doc: dict[str, Any] = {"name": name, "sinks": sinks}
    if backend is not None:
        doc["backend"] = backend
    if nda:
        doc["flags"] = {"nda_mode": True}
    return doc


# (name, regulated, global backend, global sinks, global db id, workflows, missing)
REACHABILITY_CASES: list[tuple[str, bool, str, list[str], str, list[dict[str, Any]], list[str]]] = [
    ("global_anthropic_notion_fully_configured", False, "anthropic", ["notion"], "db-global", [], []),
    ("global_anthropic_notion_missing_key_and_token", False, "anthropic", ["notion"], "db-global", [],
     ["anthropic_key", "notion_token"]),
    ("local_mlx_folder_fully_configured", False, "anthropic", ["notion"], "",
     [_wf("Local", "local", [{"type": "filesystem"}])], ["anthropic_key", "notion_token", "openai_key"]),
    ("local_mlx_folder_model_missing", False, "anthropic", ["notion"], "",
     [_wf("Local", "local", [{"type": "filesystem"}])], ["local_model"]),
    ("global_openai_no_key", False, "openai", ["filesystem"], "",
     [_wf("General", None, [{"type": "filesystem"}])], ["openai_key"]),
    ("per_workflow_openai_no_key", False, "anthropic", ["notion"], "db-global",
     [_wf("General", None, [{"type": "notion", "database_id": ""}]),
      _wf("Vendors", "openai", [{"type": "filesystem"}])], ["openai_key"]),
    ("claude_cli_workflow_no_binary", False, "anthropic", ["notion"], "db-global",
     [_wf("Personal", "claude_cli", [{"type": "obsidian"}])], ["claude_binary"]),
    ("own_notion_database_empty_global", False, "anthropic", ["notion"], "",
     [_wf("Clients", None, [{"type": "notion", "database_id": "db-clients"}])], []),
    ("own_notion_database_empty_and_global_empty", False, "anthropic", ["notion"], "",
     [_wf("Clients", None, [{"type": "notion", "database_id": "db-clients"}]),
      _wf("Internal", None, [{"type": "notion", "database_id": ""}])], []),
    ("regulated_with_notion_sink", True, "anthropic", ["notion"], "",
     [_wf("General", None, [{"type": "notion", "database_id": ""}])],
     ["anthropic_key", "notion_token", "openai_key", "claude_binary"]),
    ("regulated_with_notion_sink_model_missing", True, "anthropic", ["notion"], "",
     [_wf("General", "claude_cli", [{"type": "notion", "database_id": ""}])],
     ["anthropic_key", "notion_token", "claude_binary", "local_model"]),
    ("nda_workflow_needs_only_the_model", False, "anthropic", ["notion"], "",
     [_wf("Legal", "anthropic", [{"type": "notion", "database_id": ""}], nda=True)],
     ["anthropic_key", "notion_token", "local_model"]),
    ("auto_without_a_key", False, "auto", ["filesystem"], "", [], ["anthropic_key"]),
    ("apple_intelligence_folder_needs_nothing", False, "apple_intelligence", ["lan"], "", [],
     ["anthropic_key", "openai_key", "notion_token", "claude_binary", "local_model"]),
    ("workflow_with_no_sinks_publishes_nowhere", False, "anthropic", ["notion"], "",
     [_wf("Scratch", None, [])], ["notion_token"]),
]


def gen_reachability() -> str:
    """UX107: the table `mp doctor` reads (`mp.reachability`) and the gaps it yields over
    the combinations the spec names, for Swift's `SetupChecklist.decide` to replay."""
    from mp import reachability
    from mp.config import Config
    from mp.provider_claude_cli import CLAUDE_SEARCH_DIRS

    cases: list[dict[str, Any]] = []
    for name, regulated, backend, sinks, db_id, wfs, missing in REACHABILITY_CASES:
        cfg = Config.model_validate({
            "summarization": {"backend": backend},
            "output": {"sinks": sinks},
            "notion": {"database_id": db_id},
            "modes": {"regulated_mode": regulated},
        })
        present = {k: k not in missing for k in _ALL_PRESENT}
        routes = reachability.routes(cfg, wfs)
        cases.append({
            "name": name,
            "regulated": regulated,
            "global_backend": backend,
            "global_sinks": sinks,
            "global_notion_database_id": db_id,
            "workflows": [
                {
                    "name": w["name"],
                    "backend": w.get("backend"),
                    "nda": bool(w.get("flags", {}).get("nda_mode")),
                    "sinks": w["sinks"],
                }
                for w in wfs
            ],
            "present": present,
            "gaps": reachability.gaps(
                routes, regulated=regulated, global_database_id=db_id, present=present
            ),
        })
    contract = {
        "gap_order": list(reachability.GAP_ORDER),
        "backend_needs": {k: list(v) for k, v in reachability.BACKEND_NEEDS.items()},
        "sink_needs": {k: list(v) for k, v in reachability.SINK_NEEDS.items()},
        "zero_egress_backend": "local",
        "zero_egress_sinks": ["filesystem"],
        "claude_search_dirs": list(CLAUDE_SEARCH_DIRS),
    }
    return _envelope(
        "UX107 setup reachability, generated by scripts/gen_contract_fixtures.py from "
        "mp.reachability (the table mp doctor reads); do not hand-edit. Each case's `gaps` "
        "is what doctor fails on; SetupChecklistTests replays the same inputs through "
        "SetupChecklist.decide and must name the same gaps. With workflows present they "
        "decide (a null backend inherits the global one, sinks replace the global list); "
        "regulated mode or a workflow's NDA flag clamps a route to local + filesystem.",
        cases,
        contract,
    )


# --------------------------------------------------------------------------
# T18. `mp restore --dry-run --json` (STOR5)
# --------------------------------------------------------------------------

# What the Swift tests read off the plan is a backup of two meeting files and a
# roster, restored onto a Mac that already has one of those files and its own
# config.toml. The archive name and `created_at` are stamped by the writer, so they
# are fixed after the run, and the scratch home is rewritten to `/Users/x`.
RESTORE_ARCHIVE_NAME = "meeting-pipe-backup-20260803-105419.tar.gz"
RESTORE_CREATED_AT_SENTINEL = "2026-08-03T10:54:19.738612+00:00"
RESTORE_HOME_SENTINEL = "/Users/x"


def gen_restore_plan(tmp: Path) -> str:
    with _scratch_env(tmp):
        return _gen_restore_plan(tmp)


def _gen_restore_plan(tmp: Path) -> str:
    from mp import storage
    from mp.backup import create_backup
    from mp.config import Config
    from mp.restore import plan_restore

    def cfg(home: Path) -> Config:
        return Config.model_validate({"recording": {"output_dir": str(home / "Meetings" / "raw")}})

    source = tmp / "restore-old-mac"
    (source / "Meetings" / "raw").mkdir(parents=True)
    (source / "Meetings" / "raw" / "20260801-1030.wav").write_bytes(b"RIFF" + b"\0" * 64)
    (source / "Meetings" / "raw" / "20260801-1030.md").write_text("# transcript", encoding="utf-8")
    source_config = storage.config_dir(source)
    source_config.mkdir(parents=True)
    (source_config / "config.toml").write_text('[recording]\noutput_dir = "~/Meetings/raw"\n')
    (source_config / "roster.json").write_text('{"people": []}')

    target = tmp / "restore-this-mac"
    (target / "Meetings" / "raw").mkdir(parents=True)
    (target / "Meetings" / "raw" / "20260801-1030.md").write_text("# kept", encoding="utf-8")
    storage.config_dir(target).mkdir(parents=True)
    (storage.config_dir(target) / "config.toml").write_text("[recording]\n")

    backups = tmp / "restore-backups"
    backups.mkdir()
    made = create_backup(cfg(source), tmp / "restore-out", home=source)
    archive = backups / RESTORE_ARCHIVE_NAME
    shutil.move(str(made), archive)

    plan = dict(plan_restore(archive, cfg(target), home=target))
    created = datetime.fromisoformat(plan["created_at"])
    if created.tzinfo is None:
        raise SystemExit(f"restore plan `created_at` is no longer tz-aware: {plan['created_at']!r}")
    plan["created_at"] = RESTORE_CREATED_AT_SENTINEL
    text = json.dumps(plan, indent=2)
    for real, shown in ((str(backups), f"{RESTORE_HOME_SENTINEL}/Backups"),
                        (str(target), RESTORE_HOME_SENTINEL)):
        text = text.replace(real, shown)
    if str(tmp) in text:
        raise SystemExit("restore plan still carries a scratch path after normalising")
    return _envelope(
        "T18 golden for the `mp restore --dry-run --json` payload (STOR5). Generated by "
        "scripts/gen_contract_fixtures.py, which builds a real archive with backup.create_backup "
        "and calls restore.plan_restore; do not hand-edit. `created_at` is replaced by a fixed "
        "sentinel, and the scratch paths by `/Users/x`. Swift's RestorePlan decodes `plan` "
        "(RestoreFlowTests): a renamed key here is an empty confirm for the app's most "
        "destructive button.",
        [{"name": "two_files_one_already_here_config_kept", "plan": json.loads(text)}],
    )


def gen_run_sidecar(tmp: Path) -> str:
    """OBS8 (with OBS2, PIPE25, PIPE27): `<stem>.run.json` through the live
    `corrections.write_run_sidecar`, so the keys Swift's `MeetingStore` decodes for the
    detail header (provenance, fallback, token usage, citation and relabel shares) are
    pinned on both sides. Paths and the timestamp are fixed so the output is golden."""
    from mp import corrections

    common = {
        "transcript_path": Path("/library/20260101-090000.md"),
        "transcript_chars": 1200,
        "summary_json_path": Path("/library/20260101-090000.summary.json"),
        "ts": TS_SENTINEL,
    }
    cases_in: list[tuple[str, dict[str, Any]]] = [
        ("bare_anthropic_run", {"backend": "anthropic", "model": "claude-x"}),
        ("cloud_run_with_usage_and_shares", {
            "backend": "anthropic", "model": "claude-x",
            "usage": {"calls": 3, "input_tokens": 41200, "output_tokens": 2310,
                      "cache_read_input_tokens": 9000},
            "evidence_kept": 6, "evidence_dropped": 15, "cleanup": (40, 120),
        }),
        ("auto_fell_back_to_local", {
            "backend": "local", "model": "qwen-x",
            "fallback_from": "anthropic", "fallback_cause": "rejected_key",
            "evidence_kept": 9, "evidence_dropped": 1,
        }),
        ("apple_language_substitution", {
            "backend": "local", "model": "qwen-x",
            "fallback_from": "apple_intelligence", "fallback_cause": "unsupported_language",
            "fallback_language": "uk",
        }),
    ]
    cases = []
    for name, kwargs in cases_in:
        out = corrections.write_run_sidecar(recordings_dir=tmp, stem=name, **common, **kwargs)
        cases.append({"name": name, "payload": json.loads(out.read_text(encoding="utf-8"))})
    return _envelope(
        "`<stem>.run.json`, generated by scripts/gen_contract_fixtures.py from "
        "corrections.write_run_sidecar; do not hand-edit. Swift's MeetingStore decodes "
        "backend, model, fallback_from/cause/language, usage, evidence_kept/dropped and "
        "cleanup_segments_changed/cleanup_segments from it (RunSidecarFixtureTests).",
        cases,
    )


def main() -> int:
    import tempfile

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        written = {
            "publish-result-golden.json": gen_publish(tmp),
            "prefetch-progress-golden.json": gen_prefetch(tmp),
            "speaker-overlay-golden.json": gen_overlay(tmp),
            "glossary-golden.json": gen_glossary(tmp),
            "failure-metadata-golden.json": gen_failures(),
            "regulated-mode-golden.json": gen_regulated(tmp),
            "summary-limits-golden.json": gen_summary_limits(),
            "reachability-golden.json": gen_reachability(),
            "restore-plan-golden.json": gen_restore_plan(tmp),
            "run-sidecar-golden.json": gen_run_sidecar(tmp),
        }
    for name, text in written.items():
        (FIXTURES / name).write_text(text, encoding="utf-8")
        print(f"wrote {FIXTURES / name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
