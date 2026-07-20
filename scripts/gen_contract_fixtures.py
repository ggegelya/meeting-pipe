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

Every case here is produced by CALLING the shipping Python code, never by hand,
so a writer change lands in the fixture rather than being silently absent from
it. `pipeline/tests/test_ci4_contracts.py` regenerates in-memory and diffs
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
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[1]
FIXTURES = REPO / "daemon" / "Tests" / "MeetingPipeTests" / "Fixtures"
PIPELINE_SRC = REPO / "pipeline" / "src"

sys.path.insert(0, str(PIPELINE_SRC))

from mp import prefetch_model, publish_router, speaker_overlay  # noqa: E402

# `_write_publish_sidecar` stamps `datetime.now()`. The value cannot be golden,
# so it is replaced by this sentinel and its FORMAT is asserted separately.
TS_SENTINEL = "2026-01-01T00:00:00+00:00"


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
# sidecar writer. The four cover every `publish_state` branch plus the
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
]


# The keys Swift may reach for in the sidecar. `PublishResult.load` reads the
# first two today; the rest are pinned so a rename is caught here rather than by
# a future reader finding them gone.
PUBLISH_KEYS = {"schema_version", "state", "page_url", "ts", "sinks"}


def gen_publish(tmp: Path) -> str:
    cases: list[dict[str, Any]] = []
    for name, result in PUBLISH_CASES:
        summary_json = tmp / f"{name}.summary.json"
        summary_json.write_text("{}", encoding="utf-8")
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
        }
    )
    return _envelope(
        "CI4 golden vectors for the `<stem>.publish.json` outcome contract (PIPE1). "
        "Generated by scripts/gen_contract_fixtures.py from publish_router."
        "_write_publish_sidecar; do not hand-edit. `ts` is replaced by a fixed "
        "sentinel because the writer stamps the wall clock, and its real format "
        "is asserted at generation time instead. `contract.publish_states` is the "
        "complete vocabulary Swift branches on. Swift reads this via "
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


def gen_prefetch() -> str:
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
        record = {"event": event, "repo_id": REPO_ID}
        record.update({f: PREFETCH_FIELD_VALUES[f] for f in fields})
        # The exact bytes `_emit` puts on stdout, which is what Swift parses.
        line = json.dumps(record, sort_keys=True)

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
        "every `_emit(...)` call site in pipeline/src/mp/prefetch_model.py; do "
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


def main() -> int:
    import tempfile

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        written = {
            "publish-result-golden.json": gen_publish(tmp),
            "prefetch-progress-golden.json": gen_prefetch(),
            "speaker-overlay-golden.json": gen_overlay(tmp),
        }
    for name, text in written.items():
        (FIXTURES / name).write_text(text, encoding="utf-8")
        print(f"wrote {FIXTURES / name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
