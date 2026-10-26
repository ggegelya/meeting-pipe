---
id: AUTO5
title: `get_transcript` cannot page a transcript, and silently swallows the `offset` a client reaches for
category: Automation
status: partial
priority: P2
comment: Filed 2026-08-21 from the owner exercising AUTO3's MCP server in a Claude Code session: the client passed `offset`, got `offset: 0` back, said the parameter was being ignored, and left the tool to read the transcript `.md` off disk instead. Verified by probe, not inferred. `offset` is an **output** of `mcp_tools.get_transcript` (the computed window start, nonzero only when `around` matched) and is not an input at any layer; `mcp_serve.tool_specs()` advertises only `stem`, `around` and `window`, and the payload function raises `TypeError` on an `offset` keyword. The transport accepts it anyway and drops it in silence, because the `get_transcript` branch of `mcp_serve.dispatch` reads the three keys it knows and no `inputSchema` sets `additionalProperties: false`, so a wrong call returns a plausible right-looking answer instead of an error. That holds for all five tools. The substantive half is that the response is a pagination envelope (`offset`, `window`, `total_chars`, `truncated`) with no cursor input to act on it, so `truncated: true` is a dead end and the only positioning control is `around`, a substring the caller must already know appears in text it has not read. Leaving the tool is what costs: a direct file read skips `visibility.visible_stems` (leg 0's NDA and no-stance withholding) and `transcript_corrections.overlaid_markdown`, so quoted text is stale against the Library. Bounded honestly in the spec: that bypass needs the agent to hold its own file-read tool, so leg 0 is not broken and a bare MCP client cannot do it; what is damaged is that the guarded route is the one an agent gives up on. Not an AUTO3 regression, which shipped `get_transcript(stem, around, window)` exactly as filed. Scope: a position input wired through `tool_specs`, `dispatch` and `mcp_tools.get_transcript`, clamped and with its `around` composition written down; one decision on unknown arguments applied at the `dispatch` seam for all five tools (`window: 0` silently becoming 4000 rides along); tests, since `test_mcp_serve.py` pins the bounded window, the cap, `around` centering and the withheld-stem shape but nothing about argument handling. Owner-gated on one half only: a working `offset` turns `MAX_TRANSCRIPT_WINDOW` from a cap on total reach into a cap per call, which is the owner's call to make explicitly, though the spec records that the cap is already walkable via successive `around` phrases and wholly bypassable via the file read. Docs checked at filing and none appear owed (README, GUIDE and CONVENTIONS describe the surface without enumerating parameters). Spec in [`tasks/AUTO5.md`](./AUTO5.md). **Half shipped 2026-08-22.** The spec's own gate held: its walkthrough step 1 says the position input cannot be built until the owner picks a shape, and that the unknown-argument half can be built before it is answered, so only that half landed. Every `inputSchema` now carries `additionalProperties: false`, applied in a loop so a sixth tool inherits it, and `dispatch` rejects any argument the called tool does not declare, naming the key and listing what is accepted; the accepted set derives from the schemas (`TOOL_ARGUMENTS`) so check and advertisement cannot drift, and the rule sits at the seam rather than in one branch. The falsy-integer bug is fixed with `_int_or`: `window: 0` no longer becomes 4000, and the three `limit` sites were fixed with it, since they are the same line and the same wrong answer (a deviation from the spec, which named only `window`). +8 tests in `test_mcp_serve.py`, 6 measured red by reverting the check and the fix. Two of the new tests were wrong first and were corrected against real behaviour rather than the other way round: `window` reports the slice length on a short transcript, and `list_meetings` already floors `limit` at 1. ruff clean, pyright 0 errors, 1352 pytest green, truth fences green. `CONVENTIONS.md` gained the new client-visible `unknown_argument` payload (the spec's own trigger for owing it); `README.md` and `docs/GUIDE.md` re-checked and owe nothing, as the spec predicted. **Remainder, and it is a decision before it is code:** the owner picks the position-input shape (plain `offset`, a server-issued cursor, or no input plus honest `truncated` wording), because it changes `MAX_TRANSCRIPT_WINDOW` from a cap on reach to a cap per call. Then a session builds that half against the spec's remaining acceptance bars.
---

# AUTO5: `get_transcript` cannot page a transcript, and silently swallows the `offset` a client reaches for

Band origin: filed 2026-08-21 (AUTO3's MCP server, found by the owner exercising it from a Claude Code session). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

On 2026-08-21 the owner pointed a Claude Code session at the shipped MCP server and watched it call `get_transcript`. The client passed an `offset` argument, got `offset: 0` back, concluded in the transcript that "the offset parameter is being ignored (it returns offset: 0 regardless)", and then abandoned the tool and read the meeting's `.md` off disk directly with its own file-read tool.

This is not a regression. [`AUTO3`](AUTO3.md) specified the signature as `get_transcript(stem, around, window)` in its Leg 2 tool table and shipped exactly that. The gap only becomes visible when a real agentic client meets the response shape, which is why no test caught it and no reviewer flagged it.

Three facts, verified against the code and by running `mcp_serve.dispatch` over a scratch library on 2026-08-21, not inferred from reading:

**1. `offset` is not an input, anywhere.** `mcp_serve.tool_specs()` advertises exactly three properties for this tool, `stem`, `around` and `window`, with `"required": ["stem"]`. Calling the payload function directly with one raises `TypeError: get_transcript() got an unexpected keyword argument 'offset'`, because `mcp_tools.get_transcript(root, stem, allow_stems, *, around, window)` has no such parameter.

**2. `offset` is an output.** `mcp_tools.get_transcript` returns `"offset": start`, where `start` is the computed window start and is nonzero only when `around` matched a substring (`start = max(0, found - window // 2)`).

**3. The transport accepts the argument and drops it in silence.** The `get_transcript` branch of `mcp_serve.dispatch` reads `arguments.get("stem")`, `arguments.get("around")` and `arguments.get("window")` and never looks at the rest of the dict, and no `inputSchema` in `tool_specs()` sets `additionalProperties: false`, so nothing rejects the extra key either. Probe result on a 13,890-character scratch transcript: `{"stem": S, "window": 300, "offset": 2000}` and `{"stem": S, "window": 300}` return byte-identical `content`, both with `offset: 0` and `truncated: true`. A `bogus_key` behaves the same. This is a property of `dispatch` as a whole, so it holds for all five tools, not just this one.

## Why the response shape is the defect, not just the client

The response is a textbook pagination envelope. It carries `offset`, `window`, `total_chars` and `truncated`, which is exactly the set a client needs to know there is more text and where it stopped, and it pairs that with no input that can act on any of it. The only positioning control is `around`, a literal substring the caller has to already know appears in the part it has not read yet.

So `truncated: true` is a dead end. The tool tells the client there is more and gives it no way to ask for it, and the field the client then guesses at is one the tool itself put in the response under that exact name. Treating this as the client hallucinating a parameter is the wrong reading: a well-behaved agent looking at that envelope will reach for `offset` almost every time, and the observed session did.

What follows from the dead end is the part worth fixing. An agent that still needs the rest of the transcript has two moves: guess an `around` phrase and walk the file by trial, or leave the tool. The observed session left the tool.

## What leaving the tool costs, stated precisely

Reading `<stem>.md` directly bypasses both things `mcp_tools.get_transcript` exists to interpose. It skips `visibility.visible_stems`, which is leg 0 of AUTO3's egress inversion and the reason NDA-flagged and no-stance meetings are withheld. It also skips `transcript_corrections.overlaid_markdown`, so the text quoted back is the raw file rather than the overlaid view, and speaker renames and text corrections (PIPE9, FEAT3) are missing from it. The Library shows one thing and the agent quotes another.

The honest bound on that claim: this bypass needs the agent to hold a filesystem read tool of its own, as Claude Code does and as a bare MCP client does not. The server's own guarantee is intact and leg 0 is not broken. What is damaged is narrower and still real: in the configuration the owner actually runs, the guarded path is the one an agent gives up on, and the unguarded path is the one it falls back to. A gate only holds while the guarded route is the easier route.

## Scope

**A real position input on `get_transcript`, wired through all three layers.** The property in `tool_specs()`, the read in the `get_transcript` branch of `dispatch`, and the parameter on `mcp_tools.get_transcript`. Clamp it to `[0, total_chars]` rather than erroring on an out-of-range value, matching how `window` is already clamped by `max(200, min(int(window), MAX_TRANSCRIPT_WINDOW))`. Decide and write down how it composes with `around`: the two are both position controls and the natural rule is that `around` wins when it matches, with the offset as the fallback start, but whatever is chosen belongs in the docstring rather than in a reader's head.

**A decision on unknown arguments, applied to all five tools rather than to this one.** Either reject them (`additionalProperties: false` on each `inputSchema`, or an explicit check in `dispatch` returning an error payload naming the offending key) or keep ignoring them deliberately and say so in the tool descriptions. What must not survive is the current state, where a wrong call returns a plausible right-looking answer. `dispatch` is the single seam for this, the same way it is already the single seam for read-only-ness.

**One adjacent case the same probe turned up**: `window: 0` silently becomes 4000, because `dispatch` reads `int(arguments.get("window") or mcp_tools.DEFAULT_TRANSCRIPT_WINDOW)` and `0` is falsy. Fix it in whatever shape the unknown-argument decision takes.

**Docs.** Checked on 2026-08-21 and recorded here so the pickup session does not re-derive it: `README.md`'s "Letting an AI tool read your meetings" and `docs/GUIDE.md`'s "Asking from another app" both describe the surface in prose ("pull a slice of a transcript", "pull part of a transcript") without enumerating parameters, and `CONVENTIONS.md`'s `mp mcp-serve --status --json` section lists tool names only. So no doc change is expected to be owed. Re-check rather than trust this paragraph, and if the unknown-argument decision changes an error shape a client can see, `CONVENTIONS.md` is where it goes.

## The open decision, which is the owner's and gates one half of the scope

`MAX_TRANSCRIPT_WINDOW` is 20000, and `mcp_tools.get_transcript`'s docstring gives the reason: "Never the whole file by default, and never more than `MAX_TRANSCRIPT_WINDOW` even when asked: an agentic client that can pull an entire transcript in one call has the same reach as a client that can pull the library, one meeting at a time."

A working `offset` changes what that cap means. It stays a cap on a single call and stops being a cap on total reach, since a client can pull a whole transcript in `ceil(total_chars / 20000)` calls.

Two things the owner should weigh alongside that, both measured rather than argued. The cap is already walkable today by feeding successive `around` phrases, so per-call is closer to what it already enforces than the docstring implies. And it is wholly bypassable by the file read this task exists to stop, which is to say the current design buys its reach limit at the cost of pushing agents onto the unguarded path.

The reach question does not gate the unknown-argument half of the scope, which should be fixed either way. It gates the position-input half, and specifically its shape: a plain `offset`, an opaque cursor the server issues (which keeps the server in control of stride and lets it stop handing them out), or a decision that the reach change is unacceptable and the right fix is to make `truncated: true` say in words that `around` is the only way forward.

## Explicitly not in scope

**The visibility gate.** `visibility.visible_stems` is not touched, and no argument here is a reason to widen or narrow what it withholds. AUTO3 declined a per-workflow opt-in on 2026-07-27 and that stands.

**Any write tool, and any non-stdio transport.** Both were declined by AUTO3 with reasons, and neither is reopened by a paging bug. `test_mcp_serve.py`'s source-level import fence stays as it is.

**Making the file-read bypass impossible.** It cannot be done from inside this repo: the client's own tools are not ours to remove. The goal is to make the guarded route good enough that an agent has no reason to leave it, which is a different and achievable thing.

**Argument validation as a general framework.** The fix is a decision applied at one seam in `dispatch`, not a schema-validation layer. The SDK already carries `jsonschema` transitively, which makes reaching for a framework tempting and is not a reason to.

## Acceptance

`cd pipeline && uv run --extra dev pytest -q` green, `uv run --extra dev ruff check src tests` clean, and `uv run --extra dev --extra mcp pyright` at 0 errors. The landing session states how many tests it added.

New tests in `pipeline/tests/test_mcp_serve.py`, pinning at minimum:

- A position argument at a nonzero value returns content that starts where it was asked to start, and reports that value back in `offset`. This is the test that fails today, and it must be shown red before the fix.
- Two windows requested back to back at successive positions cover the transcript with no gap and no overlap, so `truncated` walks to `false` at the end. Paging that does not actually reach the end of the file is the failure mode a single-call test cannot see.
- An out-of-range position clamps rather than raising, at both ends.
- Whatever the `around` composition rule turns out to be, asserted directly, since it is the one behaviour a reader cannot infer from the schema.
- The unknown-argument decision, asserted at `dispatch` for a tool other than `get_transcript` as well, so the rule is pinned as a property of the seam rather than of one branch.
- `window: 0` behaves as decided rather than silently becoming 4000.

The existing `get_transcript` tests stay green unchanged: `test_get_transcript_returns_a_bounded_window`, `test_get_transcript_caps_an_oversized_window`, `test_get_transcript_centres_on_around` and `test_get_transcript_on_a_withheld_stem_is_the_unknown_shape`. If the withheld-stem test needs an edit to accommodate a new argument, that is a signal the change reached leg 0 and needs a second look, not a test to update.

`test_no_tool_leaks_withheld_text` and `test_no_tool_is_a_write_tool` stay green, and the position argument must be exercised against a withheld stem in the leak test's shape, since a paging parameter is precisely the sort of addition that could reach a file the gate meant to hide.

Not an acceptance bar: that the tool "works with offset". A run that returns a window is not evidence the window is the one that was asked for.

## Owner walkthrough

**Step 1, the decision above, and it gates building.** Read "The open decision" and pick one of the three shapes: a plain `offset`, a server-issued cursor, or no position input plus honest wording on `truncated`. The unknown-argument half can be built before this is answered; the position half cannot, and a session that picks for itself has made a reach decision on the owner's behalf.

**Step 2, after it ships, and this one only confirms.** From a Claude Code session with the server connected, ask for something that sits late in a long meeting's transcript, past the first window. A pass is the client paging to it through the tool. A fail is the client announcing it will read the file directly, which is the exact behaviour on 2026-08-21 and the thing this task exists to remove.
