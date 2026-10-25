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

## Amended 2026-10-25 (performance review)

The 2026-10-25 performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified) recorded 71 perf-relevant comments, docstrings and rules that state something the code does not do. Deduplicated across the finders (four of them reported the `launchctl` rule), they are about 50 distinct claims, none of them already in the table above. Each quoted phrase below was found again by grep at 01e904a on 2026-10-25. They split by who should correct them, and only groups A and B add work to this task.

### A. Always-loaded rules: correct in this task's first commit, beside the table above

- **`daemon/CLAUDE.md`, the UX67 entry**: "Every `launchctl` call is watchdogged and off-main". False at three sites. `StatusBarController.refreshMenuBeforeDisplay` runs `launchAgentEnabled = launchAtLogin.status().isOn` (a watchdogged `launchctl print-disabled`) on main from `menuNeedsUpdate` on every status-menu open. `LaunchAtLoginModel.init` reads `service.status()` synchronously on main, on purpose by its own comment ("one bounded `print-disabled` at view construction"). `LaunchAgentScheduler.launchctl` calls `p.waitUntilExit()` with no bound, from the Preferences digest and backup bindings on main ([CONC5](./CONC5.md) bounds it but leaves it on main; review findings SUBPROCESS-8 ([CONC5](./CONC5.md)), UI-2 ([PERF24](./PERF24.md)), MAINTHREAD-3 ([PERF24](./PERF24.md)) own the behaviour). The same claim sits in `LaunchAtLoginService`'s type comment ("UX67 moved the calls off the main thread") and its runner comment ("`LaunchAtLoginModel` also keeps these calls off the main thread"). Rewrite all three to what holds: the Preferences toggle's refresh and write run off main behind a 5 s watchdog; the two reads above are bounded but on main; the scheduler's call is neither.
- **`daemon/CLAUDE.md`**: "Don't call `AVAudioEngine` synchronously and unbounded from anywhere". A prescription, and it stays, but the start and recovery paths break it (`MeetingRecorder.start()` and `buildMicChain`, `unwindFailedEngineStart`, `replaceCondemnedEngine`, `handleDidWake`, `InputDeviceRecovery.evaluateConfigurationChange`, `recoverCapture`, `checkTapLiveness`; review RECORDING-1 ([REC27](./REC27.md))), and `MeetingRecorder`'s "every wait below is a suspension, not a block" is true of `stop()` only. Say that these are known violators owned by the RECORDING-1 filing, in `daemon/docs/gotchas.md` under the rule's anchor if the CLAUDE.md entry cannot grow inside CI5's 800 B.

### B. Comments no pending fix will touch: rewrite to what the code does

- `MeetingAXHandleBuilder`'s type comment ("The tree is walked once at start; later changes flow through observers + health polls") and `RealAXBackend`'s header ("walked exactly once per meeting"): the tree is re-walked about once a second by `MeetingAXWindowWatcher`, every 5 s by the `AXLeaveButtonSignal` and `AXMuteButtonProbe` resolvers when stale, every 3 to 12 s by discovery, and 2 to 4 times at recording start.
- `MeetingAXHandleBuilder` ("at negligible walk cost (well under 100 nodes total)"): every walk that misses (each idle discovery walk, each window without the control) runs to the 4,000-node budget per window; the figure was never measured.
- `AXObserverBus.reset()` ("Called at shutdown and after each meeting"): its only caller is `MeetingLifecycleCoordinator.shutdown`.
- `MeetingStore.tightenArtifactPermissions` ("Best-effort one-time tightening") and its `Coordinator` caller: it chmods every `.json` and `.md` on every launch.
- `WaveformPeaks` ("a 60-min file stays well under 1 MB"): at 50 bins a second, two channels and 4 bytes it is 1.44 MB an hour.
- `OriginalsReaper.maxTotalBytes` ("~10 GB, roughly 14 h of stereo audio"): the originals are copies of the 16 kHz 16-bit stereo final (64,000 bytes a second), so 10 GiB is about 46 h.
- `WorkflowStore`'s type comment ("disk writes hop to a private queue so the UI never blocks"): `writeQueue` is declared and never used, and `persistAll()` runs synchronously on the caller, main, for every upsert and reorder. (`SavedSearchStore`'s same sentence is true.)
- `summarize_local.py`'s window budget ("Cyrillic tokenizes at ~1.7 tokens/char"): `ask.py` records LOCAL13's measurement of 0.47 to 0.49 tokens per character for Ukrainian, about 3.5 times lower. Correct the comment only; whether the window size should change is a summarize-behaviour question, not this task's. `AppleIntelligenceSummarizer`'s doc comment carries the same 1.7 for Apple's tokenizer, which LOCAL13 did not measure: check it, do not assume it is wrong.

### C. Comments whose behaviour another task changes: that task corrects them

The task that changes the behaviour corrects or confirms the comment in its own commit. This task re-checks each row at pickup: where the owner has landed, confirm the comment now matches (or fix it); where it has not, rewrite the comment to describe today's code and name the owning task, rather than waiting.

Open tasks:

- [PERF10](./PERF10.md): `AXMuteButtonProbe`'s header ("poll fires on the scheduler's queue"), the "probe and `onChange` fire on the HAL bus queue or poll timer queue" line in `ProcessAudioSignal` and `MeetingLifecycleCoordinator`, `App.swift`'s messaging-timeout comment (it names the Leave-button poll as the main-thread walker, which now runs on `AXLeaveButtonSignal`'s queue, and says "the run loop always recovers" when the 2 s timeout bounds each call, not a walk of thousands), and MIC16's "a wedged meeting client can never stall the run loop" in `MeetingSessionController` and `MeetingAXWindowWatcher`, true only of the window watcher.
- [PERF13](./PERF13.md): `DiagnosticsLog`'s "Cap the rendered set so a multi-megabyte log cannot stall the window" (item 5), `Logger.swift`'s "a writer that loses a rotation race just appends to a fresh file" (item 3), and `events.emit_progress`'s sentinel docstring (its 2026-10-25 observability amendment). PERF13's 2026-10-25 performance amendment names the first two.
- [CONC5](./CONC5.md): `AudioTranscoder.runFFmpeg` documents drain-before-wait while `RecordingPostProcessor.runFFmpeg` and `MuteRedactor.runFFmpeg` still wait first; `StopStallWatchdog`'s "the ffmpeg merge at its own ceiling" (the ceiling abandons the await and never kills ffmpeg; the redaction ffmpeg has no ceiling).
- [REC19](./REC19.md): the 4 GiB RIFF claim in `WriteFailureTracker`, `MeetingRecorder` and `Coordinator` that every write fails at about 3 h, which nothing verifies; `AVAudioFile`'s reserved JUNK chunk suggests CoreAudio may promote to RF64, in which case `audioDurationSec` (which requires `RIFF`) returns nil.
- [REC20](./REC20.md): `FluidAudioRunner`'s "Halves the readMonoFloat32 peak", true against the old code only; the peak is still the full-length stereo Float32 buffer plus the mono copy, about 2.1 GB for 3 h.
- [PIPE24](./PIPE24.md): `summarize._create_message`'s "stalled connection fails in ~2 min ... Paired with max_retries=0" and "`diarize_cleanup` calls this same seam, so it inherits the fix", while the cleanup client keeps the SDK defaults (600 s, 2 retries).
- [PIPE22](./PIPE22.md): `LocalServerReaper`'s header (every clean `mp` exit kills the server, the only gap is the watchdog's SIGKILL, two triggers): a user Cancel's SIGTERM skips Python cleanup too, the watchdog sends SIGTERM first, and `reapStorage` is a third trigger.
- [ARCH15](./ARCH15.md): `LibraryWindow`'s "rapidly-changing values live on `ProcessingTracker`" while `activeProcessing` is still `@Published` on `LibraryWindowModel`.

Findings filed from the same review on 2026-10-25 (by review finding id):

- RECORDING-1: `InputDeviceRecovery`'s "NOT recreate it here: its config-change observer is bound to it", stale since REC16's `replaceEngine(reason:)` re-arms the observer.
- RECORDING-2 ([REC28](./REC28.md)): `SystemAudioCapture`'s REC17 comment implying `stop()` pre-empts delivery; true only for a start still in flight.
- RECORDING-3 ([REC25](./REC25.md)) (with PERSISTENCE-10 ([REC25](./REC25.md))): `SerialBufferWriter`'s "The unbounded backing queue never drops or blocks the producer", with no stated memory cost, and its and `MeetingRecorder`'s account of an abandoned drain as safe, which omits that the abandoned writer keeps calling the shared `noteWriteOutcome` tracker that the next `start()` resets.
- RECORDING-7 ([CONC5](./CONC5.md)): `StopStallWatchdog.defaultCeilingSeconds` ("the two waits that legitimately take time are already bounded well below this") against a 300 s merge ceiling and a 90 s alarm.
- RECORDING-9 ([REC28](./REC28.md)): `SystemAudioChannel`'s "main for every entry point", while the `systemStartTask` body runs on the cooperative pool and writes `systemCapture`, `systemDegraded`, `systemFile` and `systemWriter`.
- RECORDING-6 ([REC24](./REC24.md)) (with MAINTHREAD-5 ([REC24](./REC24.md)), SUBPROCESS-15 ([CONC5](./CONC5.md))): `Coordinator.reapStorage`'s "Runs off-main" (the orphan scan runs synchronously on main before the detach) and "at launch and after every job completion", plus `AudioRetentionSweep`'s "after every pipeline job", while `onDone` fires on success only.
- DETECTION-2 ([PERF15](./PERF15.md)): `ShareableContentSignal`'s header and "Safe because the scheduler dispatches probes off main in production" (`start()` runs `evaluate(reason: "initial")` on main at engage, for up to 2 s), and `AXLeaveButtonSignal`'s run-sync comment ("bounded by the AX messaging timeout, and only contended at the infrequent start/stop/arm"), while main can wait behind a whole multi-window walk.
- DETECTION-3: `MeetingDiscoveryWatcher`'s header ("a 3 s poll"; it is adaptive 3 or 12 s) and "no longer AX-walked every 3 s all day" (a lone idle Teams is still walked every 12 s, every 3 s after any activation), and `MeetingSourceScanner.shouldWalkControlAX` (PERF6), whose gate is always open for a single native app.
- DETECTION-11 ([PERF19](./PERF19.md)): `AdaptivePollCadence` and `AXLeaveButtonSignal` describe backing off while the listener delivers; with edge-only notifications the backoff lasts one poll.
- LIBRARY-1 ([PERF20](./PERF20.md)): `SearchIndexReconciler`'s "a relaunch does not reindex the whole library", and `SearchIndexer`'s `.building` to `.ready` after the first reconcile, which is the empty-snapshot wipe.
- LIBRARY-3 ([PERF22](./PERF22.md)) (with UI-5 ([PERF22](./PERF22.md))): `MeetingStore.stop()` and `LibraryWindow`'s "Suspend the watcher while hidden", while `QuickFindModel.refresh()` re-attaches it and nothing detaches it.
- LIBRARY-4 ([PERF23](./PERF23.md)): the talk-cache comment in `StatsView` and `MeetingStats` ("would otherwise re-parse all of it several times over"): revisions before the first pass ends each start empty, and the cache is lost on every rail switch.
- LIBRARY-5 ([PERF22](./PERF22.md)): `MeetingStore`'s "once per signature change rather than once per scan": the cache is in memory, so every launch re-parses, and age-inferred `.failed` rows pay it every scan.
- LIBRARY-6 ([PERF20](./PERF20.md)): `SearchIndex` and `SearchIndexer`'s "a plain FTS lookup, no I/O" (a disk-backed SQLite prefix query ranked by bm25 through `queue.sync` on main), and `QuickFindRanker`'s "Word-boundary boost", which runs only after `hay.contains(q)` returned false and can never fire.
- LIBRARY-7 ([STOR7](./STOR7.md)) (with PERSISTENCE-5 ([STOR7](./STOR7.md))): `BatchActionsPane`'s progress count and Cancel for Move to Trash, which cannot update or act while the `@MainActor` loop never yields.
- LIBRARY-8 ([ARCH10](./ARCH10.md)): `MeetingLibraryService.reassignWorkflow`'s "keeping the source, title, and regulated flag", true only when the read succeeds.
- LIBRARY-11 ([PERF13](./PERF13.md)) (with UI-2, MAINTHREAD-3): `MeetingLibraryService.failedMeetingCount`'s "cheap enough to run on every menu open" and `StatusBarController`'s note that the menu populates on `menuNeedsUpdate` so a rebuild does not pay a directory scan: every rebuild, including each 2 s download tick, lists `raw/` on main.
- MAINTHREAD-9 ([PIPE36](./PIPE36.md)) (with SUBPROCESS-4 ([PIPE36](./PIPE36.md)), SUBPROCESS-5 ([PIPE36](./PIPE36.md))): `PipelineLauncher.defaultMaxRuntime`'s "ensures the daemon never sits in `.handoff` indefinitely" (it bounds only the `mp` subprocess), and `SinkDispatcher`'s "a Cancel that cannot stop the work is worse than no Cancel", while the redaction ffmpeg and the Apple Intelligence summarize sit in no cancel slot.
- UI-4 ([PERF24](./PERF24.md)) (with SUBPROCESS-10 ([PERF24](./PERF24.md))): `DoctorRunner`'s "Daemon self-check first (fast, in-process)": AX IPC to every running meeting app at 2 s each, a new SQLite connection with a 2 s busy timeout, and a full orphan scan, on the main actor.
- PERSISTENCE-8 ([PERF21](./PERF21.md)): `AudioPlaybackController`'s "a cold cache computes once, shared with the Audio tab": nothing coalesces them, so `AudioTab.reload` and `loadSilentSpans` each decode the whole file on a cold cache.
- PERSISTENCE-11 ([PERF13](./PERF13.md)): `StorageStatsStore`'s "so it never happens on the main queue", while `planMove` runs `LibraryMover.plan`, with its full recursive `measure()`, on the main actor.
- PYTHON-2 ([LOCAL23](./LOCAL23.md)): `ask.py`'s "one table is what keeps the summarize path and the ask path agreeing": only `ask.py` reads `context_token_ceiling`; the local summarize path routes on `skip_above_chars`.
- PYTHON-5 ([AI13](./AI13.md)): `embed_index.py`'s "The checkpoint IS the index: a complete, loadable one", while `save()` overwrites three files in place.
- PYTHON-6 ([AUTO6](./AUTO6.md)): `mcp_serve.py`'s per-call visibility gate, while the index the search reads is built once with the first call's allowlist.
- PYTHON-8 ([LOCAL23](./LOCAL23.md)): `summarize.py`'s LANG1 "cheap check" for the local client, which can be a second full map-reduce on a long meeting.
- PYTHON-11 ([PIPE30](./PIPE30.md)): `storage.py`'s "A crash mid-write leaves the previous file intact": true for a process crash, not a power loss (no fsync before `os.replace`).
- PYTHON-13 ([LOCAL21](./LOCAL21.md)): `local_server.py`'s "rotated by the same helper as the event log, so it self-bounds", while rotation runs only when the log is opened and the warm server holds it open for the daemon's lifetime.

### Added scope

5. Group A in the first commit, with the table above. Group B in the same commit or the next.
6. Group C at pickup, per the rule at the head of that group. The commit body lists every group C row with "fixed by <task>" or "rewritten". This task may land as two commits (the original table plus group A, then B and C); the comment rewrites lower [HYG9](./HYG9.md)'s ceiling wherever they drop ticket narration.

### Added acceptance

- A grep for each quoted group A and group B phrase returns nothing, or the commit body shows the rewritten sentence.
- The commit body accounts for every group C row.
- `python3 scripts/truth_fences.py claude` green after the `daemon/CLAUDE.md` edit, with no entry over CI5's 800 B.
