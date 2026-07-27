# AUTO3: MCP server exposing the library to Claude and other AI tools

Band origin: filed 2026-07-27 (owner ask: "I want to have MCP/connector from my meeting-pipe to claude/other AI tools"). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

The library is a good corpus and a closed one. 217 transcripts sit on disk with summaries, open actions, a semantic index and cited retrieval, and the only ways to reach any of it are the Library window, the `mp` CLI, and the `meetingpipe://` URL scheme. None of those help while the owner is working somewhere else, which is where the questions actually arise.

Owner-selected use cases, 2026-07-27, three of four offered:

1. Meetings and code together in Claude Code: while working in a repo, ask what was decided about a feature or pull the context behind a ticket without leaving the editor.
2. Standup and status drafting: feed the daily and weekly summary work from real meeting content rather than git history alone.
3. Cross-meeting research: trace a topic or a decision across months of meetings, with citations back to stems.

The fourth option offered, turning meeting actions into Jira tickets or PR descriptions, was not selected and is out of scope below.

**Most of the work already exists.** `mp ask` does semantic retrieval over the on-device embedding index and returns cited answers ([ask.py](../../pipeline/src/mp/ask.py), [embed_index.py](../../pipeline/src/mp/embed_index.py), [rag.py](../../pipeline/src/mp/rag.py)). `mp actions` lists open commitments, `mp digest` narrates a review window, `mp prep` recaps a workflow. An MCP server over these is a transport, not a new capability.

**The reason this is worth doing rather than waiting for the automation surface already filed.** AUTO1's `meetingpipe://` half is done and hardware-verified, but its native App Intents leg is blocked on a Developer ID and was deferred by the owner on 2026-07-20 when their signing plan slipped. Code signing sits in the deferred selling-machinery pile per the repo's out-of-scope rule. An MCP stdio server needs no signing, no notarization and no entitlement, so it is the external surface that can actually function on this build today.

## The problem this task exists to solve carefully

MCP inverts the egress model. Everywhere else in this codebase, meeting-pipe decides what may leave: `zero_egress` pins the on-device backend, drops the Notion sink, blocks non-loopback HTTP and scrubs cloud tokens, and it is the single owner of that decision (TECH-ARCH1). An MCP server hands the decision to the client. Claude Desktop or Claude Code chooses what to pull, and anything it pulls has reached a cloud provider by definition. The in-process egress guard cannot see it, which is the same reason the `claude_cli` backend is fail-closed at the policy layer rather than in the transport patch: it egresses through a child process outside the httpx patch.

So the visibility filter is the task. The transport is the easy half.

**A prerequisite gap, found while assessing this on 2026-07-27.** Two shipped library-wide commands already have the hole this server would industrialize. `mp ask` ([ask.py:159](../../pipeline/src/mp/ask.py)) and `mp digest` ([digest.py:434](../../pipeline/src/mp/digest.py)) both call `entry.prepare()` with no meeting anchor, and say so in an inline comment ("Library-wide, so no meeting anchor"). `zero_egress` is `regulated_mode or workflow_nda_mode`, and `workflow_nda_mode` is only ever set by `workflow.apply_overrides` from a meeting's meta sidecar, so with no anchor it can never become true. Only the global `regulated_mode` can clamp those two commands, and it is `false` in the owner's config while `summarization.backend` is `anthropic`. `embed_index.chunk_library` applies no policy filter at all. The owner's three NDA meetings (`20260722-150021`, `20260727-103155`, `20260727-140126`, all under the NDA-flagged "Client work" workflow) each have a transcript and a summary on disk, so they are in that corpus.

Both files' docstrings claim "regulated / NDA force the on-device path with no cloud fallback". For a library-wide command that is only half true: regulated works, per-meeting NDA structurally cannot fire. This is a reading of the code path, not an observed egress; it was deliberately not confirmed by running `mp ask`, because confirming it would mean sending the owner's NDA content to a cloud provider.

That gap and this server want the same seam, which is why it is leg 0 here rather than a note. It is worth its own ID if the owner wants it fixed before or without the server.

## Scope

**Leg 0, the visibility gate (prerequisite, fixes `ask` and `digest` too).** One function that answers "which stems may leave this machine", with a single owner in the way `zero_egress` is the single owner of the clamp, so a later tool cannot forget it. Fail closed, per the owner's decision on 2026-07-27: a meeting whose meta sidecar flags `workflow_nda_mode`, and a meeting with no meta sidecar at all, are both withheld. On today's library that exposes 175 meetings and withholds 42 (3 NDA-flagged plus 39 with no recorded policy stance, which predate the workflow feature and whose status is genuinely unknown). Give `embed_index.chunk_library` and `load_or_build` an optional stem allowlist so retrieval never ranks or snippets withheld text, rather than filtering results after the fact. Route `mp ask` and `mp digest` through the same gate when `zero_egress` cannot be resolved per meeting.

**Leg 1, the server.** A new `mp mcp-serve` subcommand speaking MCP over stdio. Stdio only: never bind a port, never listen on a socket, so the surface is reachable exactly by a process the owner launched and by nothing on the network. It gets a row in the ARCHITECTURE subcommand table in the same commit, per the standing rule.

**Leg 2, the tools.** Read-only, five of them, chosen to cover the three selected use cases and nothing else:

| Tool | Serves | Returns |
|---|---|---|
| `search_meetings(query, limit)` | use cases 1 and 3 | cited excerpts from the on-device index, stems as citations |
| `get_meeting(stem)` | 1 and 3 | title, date, workflow, summary points, decisions, actions, attendees |
| `get_transcript(stem, around, window)` | 1 and 3 | a bounded transcript window, never the whole file by default |
| `list_meetings(since, until, workflow)` | 2 | metadata rows only, no content |
| `list_actions(open_only, since)` | 2 | open commitments across the visible set |

Every one takes its stem set from leg 0. A stem that is withheld must be indistinguishable from a stem that does not exist, so the server never reveals that a meeting it will not show exists.

**Leg 3, the UI affordance.** The de-CLI standing rule says a user-facing capability ships its UI affordance in the same task and a CLI-only ship is `partial`. An MCP server is neither CLI nor UI, so the rule does not apply cleanly, but its spirit does: a Preferences control that shows whether the server is enabled, what it exposes, and the withheld count, so the owner can see at a glance that 42 meetings are not reachable and why. A number the owner can read is what makes a fail-closed filter trustworthy.

**Prompt injection.** Transcripts are untrusted input and the codebase already treats them that way for its own prompts (TECH-SEC6, `prompt_safety.wrap_untrusted`). An MCP client is agentic and can act on what it reads, so returned transcript and summary text stays fenced as untrusted content, and each tool description says the content is meeting speech and not instructions. This does not make injection impossible; it makes the boundary explicit rather than implicit.

**Dependency decision, owner gate.** MCP over stdio is JSON-RPC on stdin and stdout and can be implemented with stdlib alone, which fits the repo's deliberately small dependency surface. The official `mcp` Python SDK is the alternative and is a new dependency, which the repo's rules say needs an explicit ask. Decide before building, do not default.

## Explicitly not in scope

**Any write tool.** No re-summarize, no reassign, no publish, no delete. Read-only for v1. A write surface reachable by an agentic client is a separate task with a separate risk argument, and nothing in the three selected use cases needs one.

**Exposing NDA meetings, under any flag.** The owner chose fail-closed on 2026-07-27 with the alternatives (fail open on unknowns, expose everything, per-workflow opt-in) named and declined. A per-workflow opt-in toggle is the natural later evolution if 42 withheld meetings proves too blunt, and it is a sidecar schema change plus Preferences UI, so it is its own task, not a stretch goal here.

**Jira and PR-description generation.** Offered and not selected. `list_actions` returns enough for the owner to do it by hand if they want.

**A second index.** Reuse the AI2 embedding index with an allowlist. Building a separate MCP-only index doubles the rebuild cost and creates two corpora that can disagree about what a meeting says.

**Network transport.** No HTTP, no SSE, no port. If a remote client is ever wanted, that is a new task and a new threat model.

## Acceptance

Leg 0: a single named function owns stem visibility, and a test asserts that an NDA-flagged stem and a stem with no meta sidecar are both withheld, and that a normal stem is not. A test asserts `chunk_library` with an allowlist produces no chunk from a withheld stem. `mp ask` and `mp digest` gain a test that a withheld stem's text cannot appear in their retrieval set even with `regulated_mode = false`.

Leg 1: `mp mcp-serve` starts, speaks MCP over stdio, and is listed in the ARCHITECTURE subcommand table. A test asserts the server binds no socket.

Leg 2: each of the five tools has a test over a fixture library containing one NDA meeting, one meeting with no sidecar, and two normal meetings, asserting that results cover exactly the two normal meetings. `get_meeting` and `get_transcript` on a withheld stem return the same not-found shape as an unknown stem, pinned by a test, so withholding does not leak existence.

Leg 3: the Preferences control shows the enabled state and the visible and withheld counts, and the withheld count matches what leg 0 computes.

End to end, verified by hand on the real library: Claude Code answers "what did we decide about X" from a real meeting with a stem citation that resolves, and a question whose only answer lives in a Client work meeting returns nothing rather than the answer.

Both suites green, `swift test` and `pytest`, plus ruff, pyright and `scripts/truth_fences.py`.
