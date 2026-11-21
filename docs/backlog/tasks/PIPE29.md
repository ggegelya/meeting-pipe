---
id: PIPE29
title: One meta.json that is valid JSON but not an object crashes every library-wide command, because the pipeline's hand-rolled JSON readers have three failure behaviours
category: Pipeline
status: partial
priority: P2
comment: Shipped 2026-11-18 - storage.read_json_object (plus the tri-state load_json_object) now backs 27 readers; every unguarded one (run sidecar, notion sidecar, doctor's marker, embeddings, roster_cmd, train_adapter, corrections corpus) treats a non-object as absent. RosterStore and VoiceprintStore are left to STOR9 on purpose. Owner still owes the close; tests only, no live run. 2026-11-21 second fix review: owner decision: an unreadable sink sidecar still publishes as new, which for Notion creates a second page and overwrites the only pointer to the first (also STOR9's ground); see the amendment.
---

# PIPE29: One meta.json that is valid JSON but not an object crashes every library-wide command, because the pipeline's hand-rolled JSON readers have three failure behaviours

Band origin: filed 2026-10-25 from the 2026-10-25 code-quality audit band ([code-quality audit](../../audits/2026-10-25-code-quality-audit.md) PIPE29, finder PY1). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

`pipeline/src/mp` reads a per-meeting or config JSON file into a dict with `json.loads(path.read_text(...))` at 38 call sites on 2026-10-25, each with its own error handling. They fall into three behaviours:

1. **Guarded, quietly empty.** The parse is caught and the result is checked with `isinstance(obj, dict)`, returning `None` or `{}` otherwise: `local_server.read_marker`, `mcp_tools._summary`, `prep._read_json`, `publish_fs.load_sidecar`, `publish_notion._load_meta_sidecar`, `publish_obsidian._load_sidecar`, `speaker_overlay.read_overlay`, `transcript_corrections.read_corrections`, `markers._read_marker_offsets`, `orchestrate.existing_daemon_transcript`, `corrections.set_publish_state`, and the inline readers in `actions.discover`, `digest`'s recent-decisions scan and `embed_index._read_title`.
2. **Unguarded, the parse is returned or used as is.** A parse error is caught, but whatever valid JSON comes back is handed on, so a list or string reaches a `.get` call: `workflow.read_meta` (`return json.loads(sidecar.read_text(encoding="utf-8"))`), `corrections.read_run_sidecar`, `publish_notion._load_sidecar` (used for `<stem>.notion.json`, where `upsert` then calls `existing.get("page_id")`), `Voiceprint.load`, `Roster._people`, `diarize_cleanup._load_embeddings`, `roster_cmd`'s enroll read, `train_adapter`'s corrections loop, and `doctor`'s backup-marker check (`data["at"]` on a list raises `TypeError`, outside its `(OSError, ValueError, KeyError)` catch).
3. **Typed error.** `merge_meetings._read_transcript` raises `MergeError("... is not an object")`, the only reader that says what is wrong.

The one that matters most is `workflow.read_meta`, because it is the single reader of `<stem>.meta.json` and it sits under the visibility gate. Reproduced on 2026-10-25 with a library holding one `<stem>.meta.json` of `[1]` next to a healthy meeting:

```
visibility.withheld_reason(root, stem)   AttributeError: 'list' object has no attribute 'get'
workflow.apply_overrides(cfg, path)      AttributeError: 'list' object has no attribute 'get'
actions.discover(root)                   AttributeError: 'list' object has no attribute 'get'
```

`withheld_reason` does `meta = read_meta(...)`, `if not meta: return WITHHELD_NO_SIDECAR`, then `meta.get("workflow_nda_mode")`; a non-empty list passes the falsy check. `visibility.library_visibility` and `visible_stems` call it for every stem, and they gate `mp ask` (`ask.py`), `mp digest` (`digest.py`) and both `mcp_serve` entry points, so one bad sidecar takes down every library-wide command, not just the meeting it belongs to. `actions.discover` and `glossary` call `read_meta(...).get("workflow_name")` directly. `apply_overrides` runs inside `entry.prepare(anchor=...)`, so every per-meeting command on that stem fails too. `summarize._prior_meeting_context` calls `read_meta(summary_json).get("workflow_id")` over every earlier summary in the library, so a bad sidecar on an old meeting also fails the summary of every later meeting that has a `workflow_id`; that path crashes on a `null` sidecar as well, since `read_meta` returns `None` for it.

The daemon writes the sidecar through `MeetingMetaSidecar.build`, so a non-object file comes from a hand edit, a sync conflict or another tool. The crash is out of proportion to the cause: the file is evidence about one meeting.

Re-checked at filing: the audit counted 13 readers with 6 guarded; the full count is 38 file-reading `json.loads` calls, of which the nine in item 2 are the unguarded ones. The class and the crash both stand.

## Scope

1. **`storage.read_json_object(path: Path) -> dict[str, Any] | None`** in `pipeline/src/mp/storage.py`, beside `atomic_write_text`: `None` when the file is missing, unreadable, not valid JSON, or valid JSON that is not an object. For the last case only it logs one warning naming the path and the parsed type, since that state has no log line today. It catches `(OSError, ValueError)` and nothing broader.
2. **Migrate the readers in items 1 and 2 above** to it, each keeping its existing return contract (`or {}` where the caller expects a dict, the existing per-caller warning where one exists). `workflow.read_meta` keeps its signature and returns `{}` for every failure. `merge_meetings._read_transcript` keeps its typed error, raised when the helper returns `None` for an existing file.
3. **Visibility stays fail-closed.** With `read_meta` returning `{}`, `withheld_reason` answers `WITHHELD_NO_SIDECAR` for a non-object sidecar, which is the correct verdict: a meeting whose sidecar cannot be read may not leave the machine.

## Explicitly not / out of scope

- Which exceptions a reader should catch and whether a swallowed failure should log or emit an event: the observability and error-handling audit owns that policy (the report's "Handed to" section names the 46 `except Exception` sites). This task narrows only the readers it migrates, and only to `(OSError, ValueError)` inside the helper.
- Typing the dicts that come back (a `TypedDict` for meta or segments): PIPE33, after ARCH10.
- The writers of the same files: PIPE30 and SEC22. `Voiceprint.load` and `Roster._people` sit in SEC22's files; migrate their reads here and rebase over SEC22's writer change if it lands first.
- Swift's readers of `meta.json`: ARCH10's Codable `MeetingMeta`.
- Manifest and index readers in `embed_index` and `train_adapter`'s split manifest, which are not per-meeting and raise on a corrupt index by design.

## Acceptance

- `test_storage.py`: `read_json_object` returns the dict for an object file and `None` for a missing file, an empty file, invalid JSON, and each of `[1]`, `"x"`, `5`, `true` and `null`; the non-object case logs one warning naming the path.
- `test_visibility.py`: a library with one `[1]` meta sidecar beside a visible meeting returns the visible meeting from `visible_stems` and withholds the bad one as `WITHHELD_NO_SIDECAR` (fails on `main` with `AttributeError`).
- `test_workflow_overlay.py`: `apply_overrides` on a stem whose sidecar is `[1]` returns the input config unchanged.
- One test each that `actions.discover` and `summarize._prior_meeting_context` skip a meeting whose sidecar is `[1]` (and `null` for the latter) instead of raising.
- A test that `NotionRestPublisher.upsert` treats a list-shaped `<stem>.notion.json` as absent instead of raising. Absent means the create path, which is PIPE23's duplicate risk; PIPE23's natural key is what makes that path safe, and this task does not try to.
- `bash scripts/ci-local.sh pipeline` green (ruff, pyright, pytest), with the number of new tests stated in the commit body.

**Progress (2026-11-18):** shipped. `storage.load_json_object` returns `missing` / `ok` / `unreadable` (`kind` io or parse, `not_object` for valid JSON that is not an object) and `read_json_object` collapses it to the dict or None, warning only for the non-object case. Migrated: the guarded readers of item 1, the unguarded ones of item 2 (plus two the count missed: the corrections corpus loader, which crashed on a list, and `local_server.read_token`), and `backup`'s STOR13 marker read; `merge_meetings._read_transcript` keeps its three typed errors through `load_json_object`. Deliberately not migrated:

- `RosterStore._people` and `VoiceprintStore.load`. Reading a non-object as empty there would turn today's crash into the wipe STOR9 describes (the next `enroll` writes the empty-plus-one roster), so they move with STOR9's quarantine instead.
- `workflow.load_meta`: SEC25 already reads `<stem>.meta.json` this way and fails closed. So the visibility, `actions.discover` and `_prior_meeting_context` tests pin behaviour rather than fail on `main`, and `apply_overrides` on a `[1]` sidecar now forces the on-device path (SEC25's verdict) rather than returning the config unchanged as this spec said.
- The index manifests, the split manifest and the transcript `structured` reads, which raise by design.

Red before the fix: 7 reader cases (6 readers plus the Notion upsert) and the 11 helper cases. Pins: 4.

## Amendment 2026-11-21 (second fix review)

Found by the [second fix review](../../audits/2026-11-21-second-fix-review.md) (storage report, M3), confirmed by reading the code at `8426758b`.

PIPE29 kept, and a test now pins, the sink readers' "cannot read the sidecar, so publish as new" path. `publish_notion._load_sidecar` returns `None` for a file that exists but does not parse (`log.warning("Could not parse sidecar %s; treating as new page", p)`), and `NotionPublisher.upsert` then creates a page and writes a fresh `<stem>.notion.json`. The filesystem and Obsidian readers have the same shape, where the cost is only a rewrite. For Notion the result is a duplicate page in the workspace and the loss of the one record of the first page's id, so later republishes update the copy and the original goes stale with nothing pointing at it.

This is the same class STOR9 settled for the stores (a file that is present but unreadable is not the same as a missing one, and `storage.load_json_object` already tells them apart). Owner decision: for the Notion sink, fail the sink with a named reason when the sidecar is present but unreadable, and keep publish-as-new for a missing one. If taken, acceptance: the pinning test is rewritten, a test shows no page is created and the unreadable file is left in place, and the publish result names the file. Pipeline suite green, 2 tests changed or added.
