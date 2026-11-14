---
id: AUTO8
title: The MCP server's `list_actions` returns model-written task text unfenced and uncapped while its own description tells the client returned text is fenced, and meeting titles are unfenced in every tool
category: Automation
status: new
priority: P2
comment: Filed 2026-11-12 ([security review](../../audits/2026-11-12-security-review.md) finding 6): get_meeting fences the same task strings list_actions returns raw; list_meetings lacks UNTRUSTED_NOTE; the AUTO3 promise that returned summary text stays fenced is broken and no test covers list_actions. Fence every model-written string in every tool, cap task length, extend the fence test. [Spec](./AUTO8.md) Amended 2026-11-13 by the audit band: list_actions cuts at the limit before sorting, so with 761 open field actions it returns the oldest 200 with no total or truncated flag (F089); sort then cut, newest undated first, return total and truncated.
---

# AUTO8: the MCP server's `list_actions` returns model-written task text unfenced and uncapped while its own description tells the client returned text is fenced, and meeting titles are unfenced in every tool

Band origin: filed 2026-11-12 from the [2026-11-12 security review](../../audits/2026-11-12-security-review.md), finding 6. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

[AUTO3](./AUTO3.md) promised that "returned transcript and summary text stays fenced as untrusted content". Re-read 2026-11-12:

- `mcp_tools.list_actions` returns each row's `title`, `task` and `owner` raw. `get_meeting` fences the same task strings, and its comment says they share one trust level, so the two tools contradict each other.
- The `list_actions` tool description carries `UNTRUSTED_NOTE`, which says returned text is "fenced in untrusted-content markers"; for this tool that is false. The `list_meetings` description has no note at all.
- `ActionItem.task` has no `max_length` and `SUMMARY_TOOL` no `maxLength`, so `task` is unbounded model text describing meeting speech.
- `title` (model text, capped at 120) is unfenced in `get_meeting`, `get_transcript` (through the shared row builder) and search hits.
- `owner`: `clean_person` runs at write time on the Python backends, but `actions.discover` reads `summary.json` with plain `json.loads`, so a summary written by the Swift Apple Intelligence summarizer passes `owner` unscrubbed.
- `test_returned_meeting_text_is_fenced_as_untrusted` checks only `get_meeting` and `get_transcript`.
- `workflow` in the row is the owner-configured name from the sidecar, not model text.

Exploit: a participant dictates an "action item" that is really an instruction to any AI assistant reading it. Later the owner asks an agent with tools (Claude Code with Bash) "what are my open actions?" and `list_actions` hands it the instruction outside any fence. The server is read-only and stdio-only and the real boundary is the client's permission prompts, so this is a broken defence-in-depth promise rather than a new capability: hence P2.

## Scope

1. In `mcp_tools`, wrap every model-written string returned by any tool (`title`, `task`, `owner`, search-hit `title`) with `prompt_safety.wrap_untrusted`, or fence each tool's rows as one block, whichever keeps the JSON shape readable for clients; document the choice in the tool descriptions.
2. Cap `task` at a fixed length in the MCP output (and note the cap in the description).
3. Add `UNTRUSTED_NOTE` to `list_meetings`, and make every note's wording true for its tool.
4. `actions.discover` validates `owner` through `clean_person` on read, so the Apple path is covered.

## Explicitly not

- Withholding meetings under global regulated mode, or the stale search index: [AUTO6](./AUTO6.md).
- Content scrubbing of links and images inside the text: [SEC28](./SEC28.md), at the schema.

## Acceptance

- Extend `test_returned_meeting_text_is_fenced_as_untrusted` (or add a sibling) to cover every content-bearing tool, including `list_actions`, `list_meetings` and `search_meetings`, with a summary whose `task` and `title` contain an instruction string: each appears only inside markers.
- A test that a 5,000-character `task` comes back at the cap, and that an Apple-written `summary.json` with `owner: "x@y.com"` returns no owner.
- A test that every tool description containing `UNTRUSTED_NOTE` returns only fenced model text (a table-driven check over the registered tools).
- `cd pipeline && uv run --extra dev --extra mcp pytest -q`, ruff and pyright green with the new test count in the commit body; `bash scripts/ci-local.sh` green.

## Amendment 2026-11-13 (audit band)

From the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md), finding F089 (quality, confirmed). Its unfenced `task`, `title` and `owner` half is this task's existing scope and adds nothing here. The new half is row truncation, which the audit found in no task, audit or ADR: this task's cap is on `task` length, not on the number of rows. Re-verified in code at HEAD on 2026-11-14.

**The limit is applied before the sort.** `mcp_tools.list_actions` takes `actions_mod.discover(root, allow_stems=allow_stems)`, which walks `sorted(root.glob("*.summary.json"))`, so actions arrive oldest meeting first. The loop appends rows and stops at `if len(rows) >= max(1, int(limit)): break`, and only after that runs `rows.sort(key=lambda r: (r["due"] is None, r["due"] or "", r["stem"]))`. `mcp_serve.dispatch` passes `limit=_int_or(arguments.get("limit"), 200)`. The result is `{"actions": rows, "count": len(rows)}`, so `count` is the page size, never the total, and nothing marks a cut. `list_meetings` beside it walks `sorted(visibility.library_stems(root), reverse=True)`, newest first, so the two tools keep opposite ends of the library when they hit a limit.

**Field evidence.** The [2026-11-13 field evidence](../../audits/2026-11-13-field-evidence.md) counts 761 action items in 110 summaries, 0 of them ever marked resolved, so every one is open under `filter_actions(..., lifecycle="open")`; `due` is set on 41. Library-wide, `digest_generated` `actions_open` rose from 1,804 (2026-09-14) to 2,493 (2026-11-09). With more than 200 open actions, a client asking what is owed gets the 200 from the earliest meetings, re-sorted by due date so the page looks complete, and nothing from recent weeks.

Correction at filing: the audit's direction, "rank before applying the limit", is not enough with the current sort key. 720 of the 761 field actions have no `due`, and `(due is None, due or "", stem)` orders undated rows by ascending stem, so sorting first and then cutting would still fill most of the page with the oldest undated actions. The ranking has to put newer meetings first inside the undated group, and the result has to say when it is a page.

### Added scope

5. In `mcp_tools.list_actions`, collect every row that passes the filters, sort, then cut to `limit`. Order: dated rows first by soonest `due`, then undated rows newest meeting first (`stem` descending); ties inside the dated group also newest first. State the order in the tool description in `mcp_serve`.
6. Return `total` (rows that passed the filters before the cut) and `truncated` (`total > len(actions)`) beside `count`, and say in the description that a truncated result is a page, not the whole set.

### Explicitly not (this amendment)

- Why no field action is ever resolved. That is the action lifecycle, not this tool; the digest's own bound on the action list is AI10's.
- [AUTO9](./AUTO9.md) counts real MCP use, which decides how much of this tool's surface is worth more work; this fix is small enough to land regardless.

### Added acceptance

- A test over a library with more open actions than `limit`, spread across stems on several dates, most undated and a few dated: the page holds every dated action that fits, then the newest meetings' undated actions; `total` equals the full count and `truncated` is true. With `limit` above the total, `truncated` is false and `total == count`.
- A test where `since` alone brings the matching rows under `limit` returns `truncated: false`, so the filter still runs before the cut.
- `test_list_actions_covers_exactly_the_visible_two` and `test_list_actions_open_only_is_the_default` stay green; `cd pipeline && uv run --extra dev --extra mcp pytest -q`, ruff and pyright green.
