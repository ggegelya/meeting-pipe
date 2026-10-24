# HYG10: comments and always-loaded rules state things the code does not do, several about security, and two of the rules are counts that have already drifted

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) D2, [AI harness audit](../../audits/2026-10-24-ai-harness-audit.md) failure mode 9 and proposal A5). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Each claim below was re-read against the tree on 2026-10-24. A false comment next to a security boundary is worse than none: the next session reads it as the invariant and builds on it.

| Where | What it says | What is true |
|---|---|---|
| `ClaudeCLIProvider._run` in [`provider_claude_cli.py`](../../../pipeline/src/mp/provider_claude_cli.py) | "`--allowed-tools ""` disables tool use; a summary is a pure text turn." | An empty `--allowed-tools` adds no auto-approve rule; it does not remove any tool, and read-only tools need no approval in print mode. [SEC20](./SEC20.md) owns the behaviour. |
| Same module's docstring, and `SecretsStore.openaiAPIKey`'s doc comment in [`SecretsStore.swift`](../../../daemon/Sources/MeetingPipe/SecretsStore.swift) | "needs no API key (it rides the user's existing Claude Code auth)"; "claude_cli needs no key at all" | `egress_guard.child_env()` returns `os.environ` unchanged when the guard is not armed, which is the only time this backend runs, so the child inherits `ANTHROPIC_API_KEY` whenever the daemon has mirrored one from the Keychain, and Claude Code bills that key ahead of a subscription login. |
| `daemon/CLAUDE.md` Don't list, and `CONVENTIONS.md` | "Don't call Anthropic / Notion APIs from the daemon. Outbound HTTP belongs in the pipeline."; "The daemon stays offline" | `NotionDatabaseList` calls the Notion API over `URLSession.shared` (its `fetch` paths take `session: URLSession = .shared`), and FluidAudio downloads models from the daemon. |
| `daemon/CLAUDE.md` "Strict concurrency" rule | "Two documented `@unchecked Sendable` exist; don't add a third." | Seven in the `MeetingPipe` target: `OneWayFlag`, `PipelineRunSlots`, `PipelineRunSlots.RunHandle` (all `PipelineLauncher.swift`), `MeetingSessionController`, `SystemAudioCapture`, `SinkDispatcher`, `PrefetchModelsCommand.ProgressReporter`. Plus escape hatches the count does not see: `OSAllocatedUnfairLock(uncheckedState:)` in `CallTeardownWatcher` and `GuardedTapInstall`, and `nonisolated(unsafe)` on `AppGlyphView.glyphCache`. `CallTeardownWatcher`'s comment says its `uncheckedState` was chosen so the conformances "stay two": a count rule being gamed, not followed. |
| `pipeline/CLAUDE.md` "Lazy heavy imports" | "top-level imports are stdlib + pydantic + httpx + anthropic; everything else lives inside the function that uses it." | `tenacity` is top-level in `summarize.py` and `publish_notion.py`; `numpy` is top-level in `embed_index.py`, which `ask.py`, `rag.py`, `mcp_tools.py` and `mcp_serve.py` import at module top. `__main__` dispatches lazily, so `mp --help` may still be cheap; nothing checks it. |
| `App.swift` (SecretsStore construction) and `NotionDatabaseList`'s refresh doc comment | "a missing secrets.env is normal on first run; the file is created (mode 0600) on the first Preferences save"; "Apply keeps the env in sync with `secrets.env`" | SEC8 moved secrets to the Keychain; `SecretsStore` migrates a legacy file once and deletes it. No `secrets.env` is ever created. |
| `MeetingSessionController`, the doc comment above `teardownHold` | Describes "True while an async `beginRecording` start is in flight ... stops a second Record/toggle press" | That text belongs to `recordingStartInFlight`, three properties lower; `teardownHold` and `pendingEndTrimAt` sit between them, so the comment documents the wrong property. |
| `run_with_local_fallback` in [`backend_fallback.py`](../../../pipeline/src/mp/backend_fallback.py) | `require_env` "exits the process on a miss" | `config.require_env` raises `MissingSecretError` ("Raises ... rather than exiting"). |

The consent string that names a process tap is DOC16's (shipped 2026-10-24, archived in [q6-final.md](../q6-final.md)) and is not repeated here.

## Scope

1. **Correct every line in the table in one commit**, by rewriting the comment or rule to what the code does. For the claude_cli pair, if [SEC20](./SEC20.md) has landed and changed the flags or the child env, re-read and make the comment match its result; if it has not, the comment says what the flag actually does and points at SEC20.
2. **Replace the two count rules with allowlist fences**, added to `scripts/truth_fences.py` as a `sources` check run by `both`:
   - `@unchecked Sendable`, `uncheckedState:` and `nonisolated(unsafe)` under `daemon/Sources`: a dict of `file -> [symbol, reason]`. A new site fails; a listed site that is gone fails (the stale-entry contract `CLAUDE_ALLOWLIST` already uses).
   - `URLSession` under `daemon/Sources`: same shape, starting with `NotionDatabaseList.swift`.
   - Raw `Process()` under `daemon/Sources`: same shape, seeded with the 14 current sites. [CONC5](./CONC5.md) replaces them with one runner and shrinks the list; whichever of the two lands second rebases the list.
   The `daemon/CLAUDE.md` and `MeetingPipeCore/CLAUDE.md` rules then name the fence instead of a number.
3. **The Notion rule needs an owner call before step 1 can finish.** Either the rule allows the in-daemon database picker (and names it as the one sanctioned daemon HTTP call, beside FluidAudio's model fetch), or the picker moves behind `mp` the way publish does. Default if the owner does not choose: amend the rule, since moving the picker is a feature change with no defect behind it.
4. **The lazy-import rule**: replace the stated contract with a pytest that runs `python -c "import mp.__main__"` in a subprocess (and `mp --help`) and asserts `numpy`, `mlx_lm`, `soundfile` and `tenacity` are absent from `sys.modules`. If that passes, the rule is rewritten to say "the CLI entry must not load X" and names the test; if it fails, fix the import that leaks, not the test.

## Explicitly not / out of scope

- Changing the claude_cli flags or env scrub. That is [SEC20](./SEC20.md).
- Changing which types are `@unchecked Sendable`. The fence records the current seven with their reasons; [CONC6](./CONC6.md) owns `SystemAudioCapture`'s statics and the `complete` concurrency measurement.
- Ticket narration in comments generally. That is [HYG9](./HYG9.md)'s ratchet; corrections here lower its count.
- Moving the Notion picker, unless the owner picks that branch in scope item 3.

## Acceptance

- Every row of the table is corrected, and a grep for each quoted false phrase returns nothing.
- `python3 scripts/truth_fences.py sources` passes with the three allowlists seeded; a test beside [`test_link_fence.py`](../../../pipeline/tests/test_link_fence.py) shows a new `@unchecked Sendable` in a scratch file fails it, a removed listed site fails it, and a `URLSession` mention inside a comment does not count.
- The lazy-import pytest exists and passes (1 new test minimum, plus the fence tests).
- `daemon/CLAUDE.md` and `pipeline/CLAUDE.md` rules name the fence or the test, not a count, and `python3 scripts/truth_fences.py claude` stays green.
- `bash scripts/ci-local.sh` green (Swift comments change, so the daemon job runs).
