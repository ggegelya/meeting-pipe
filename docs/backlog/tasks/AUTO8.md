---
id: AUTO8
title: The MCP server's `list_actions` returns model-written task text unfenced and uncapped while its own description tells the client returned text is fenced, and meeting titles are unfenced in every tool
category: Automation
status: new
priority: P2
comment: Filed 2026-11-12 ([security review](../../audits/2026-11-12-security-review.md) finding 6): get_meeting fences the same task strings list_actions returns raw; list_meetings lacks UNTRUSTED_NOTE; the AUTO3 promise that returned summary text stays fenced is broken and no test covers list_actions. Fence every model-written string in every tool, cap task length, extend the fence test. [Spec](./AUTO8.md)
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
