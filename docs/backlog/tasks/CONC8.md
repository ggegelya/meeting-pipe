# CONC8: The debounced-save template is copied three times, and the SecretsStore copy runs three blocking security subprocesses on the main thread per Preferences edit

Band origin: filed 2026-10-25 from the 2026-10-25 code-quality audit band ([code-quality audit](../../audits/2026-10-25-code-quality-audit.md) SW2, SW3). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-read in code on 2026-10-25 (base `01e904a`). `daemon/CLAUDE.md` names `ConfigStore.scheduleSave` as the template for `ObservableObject` + `@Published` debounced writes ("500 ms timer gated on `isInitialized`"), and `CONVENTIONS.md` repeats it. The template has been copied by hand into three stores, and the copies have already diverged:

| Store | Gate | Where `persist` runs | Failure goes to | Flush on close |
|---|---|---|---|---|
| `ConfigStore.scheduleSave` | `isInitialized`, `parseError == nil` (ARCH9) | `writeQueue.async` (utility), after `writeBack()` on main | `Log.main.error`; `didPersist.send()` on main | none |
| `GlossaryStore.scheduleSave` | `isInitialized` | `writeQueue.async` (utility), after `writeBack()` on main | `saveError` published on main | `flush()` invalidates the timer and saves now |
| `SecretsStore.scheduleSave` | `isInitialized` | **inside the `Timer` callback, on main** | `Log.main.error` only | none |

All three share the same skeleton line for line: `guard Thread.current.isMainThread else { DispatchQueue.main.async { [weak self] in self?.scheduleSave() } }`, `saveTimer?.invalidate()`, `Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false)`.

**The SecretsStore copy blocks main.** Its timer body calls `try self.persist()` directly, and `persist()` calls `write` for `ANTHROPIC_API_KEY`, `NOTION_TOKEN` and `OPENAI_API_KEY` unconditionally. Each `write` is either `backend.set` (`add-generic-password -U ...`) or, for an empty field, `backend.remove` (`delete-generic-password`), and both go through `KeychainBackend.run`, which does `process.run()` then `process.waitUntilExit()` with no ceiling. So every debounced edit in any token field runs three `/usr/bin/security` round-trips back to back on the main run loop. On a healthy keychain on 2026-10-25 a `security find-generic-password` round-trip measured about 10 ms (`/usr/bin/time`, five runs), so about 30 ms per save, two frames at 60 Hz. The real cost is the unbounded case: a locked login keychain asking to unlock, or a wedged `securityd`, freezes the whole menu-bar app until it answers. That is the shape UX67 recorded and `daemon/CLAUDE.md` now forbids ("Don't run a `Process` round-trip on main because the control around it looks cheap"; [gotchas](../../../daemon/docs/gotchas.md#a-preferences-control-that-shells-out-is-on-the-freeze-list-too)). The `-strict-concurrency=complete` measurement also flags this function (capture of non-Sendable `SecretsStore?` in the `@Sendable` timer closure).

**What is already filed, and what is not.** SEC23 owns *what* `persist` writes: it makes it write only the accounts whose value changed (so one edit is one `security` call, not three) and moves the secret from argv to `security -i` stdin. CONC5 owns bounding `KeychainBackend.run` with a ceiling and the launch-time reads (`SecretsStore.init` and `Secrets.loadIfPresent` before `NSApplication` exists). Neither says the save runs on main, and neither removes the copies, so after both land a single slow `security` call on save still freezes the UI for up to CONC5's ceiling.

## Scope

1. **One `DebouncedSaver`** in a new `daemon/Sources/MeetingPipe/DebouncedSaver.swift`, owning the skeleton and nothing else: the main-thread hop, the invalidate-and-rearm `Timer` at `interval` (default 0.5 s), a private serial utility queue, and `flush()` (cancel the pending timer, run the save now, synchronously). On fire it calls a store-supplied `prepare: () -> (() throws -> Void)?` **on main**, which snapshots the published state and returns the work to run (or `nil` to skip, which is how a gate is expressed), runs that work on its queue, and reports `Result<Void, Error>` back on main. Saves are serial, so a later snapshot never lands before an earlier one.
2. **Each store keeps its own policy.** `ConfigStore` keeps its `isInitialized` and `parseError` gates and `didPersist`; `GlossaryStore` keeps `saveError` and its `flush()` becomes the saver's; `SecretsStore` snapshots its three values on main, runs `persist` on the saver's queue, and sends `didPersist` on main after success. The two `writeQueue`s these stores declare today go away in favour of the saver's.
3. **Repoint the rule.** Edit the existing debounce entry in `daemon/CLAUDE.md` to name `DebouncedSaver` instead of `ConfigStore.scheduleSave`, and the matching gotchas section and `CONVENTIONS.md` line. Edit in place, no new entry: the file is at 23,122 of its 24,000 B cap (DOC15 owns the cap).

## Explicitly not / out of scope

- SEC23's write-only-what-changed, stdin-not-argv, and `setenv` removal. This task changes where the save runs, not what it writes; if SEC23 lands first its diffing lives inside the `prepare` snapshot, and if second it edits `persist` without touching the debounce.
- CONC5's ceiling on `KeychainBackend.run` and the three launch-time `security` reads in `SecretsStore.init`. With this task the save no longer blocks main; with CONC5 it no longer blocks its queue forever either. Both are needed, neither subsumes the other.
- `WorkflowStore`, `SavedSearchStore` and `WorkflowCorrectionStore`, which have their own `writeQueue`s but no `@Published`-driven debounce; they may adopt the saver when touched.
- Surfacing a `SecretsStore` persist failure in the Preferences UI: handed to the observability and error-handling audit by the 2026-10-25 report.

## Acceptance

- New `DebouncedSaverTests`: five `schedule()` calls 20 ms apart produce exactly one save; the save's work runs off main (`XCTAssertFalse(Thread.isMainThread)` inside it) and its result callback on main; a `prepare` returning `nil` runs nothing; `flush()` with a pending timer saves exactly once and the timer then fires nothing; a `schedule()` from a background queue still yields exactly one save.
- A `SecretsStoreTests` case with a recording `SecretsBackend` fake that blocks each `set` for 500 ms: after an edit and the debounce, a `DispatchQueue.main.async` block posted while the fake is blocked runs within 100 ms (fails on `main`, where the fake blocks the main run loop), every recorded backend call ran off main, and `didPersist` fires on main after the last one.
- Existing `ConfigStoreTests`, `ConfigStoreFenceTests` and `GlossaryStoreTests` unchanged and green, including `test_switching_scope_keeps_the_edit_that_had_not_been_saved_yet`. `GlossaryStore.flush()` (called from `VocabularyEditor`'s `.onDisappear`) has no test today; add one: an edit followed at once by `flush()` is on disk before `flush()` returns.
- `grep -n "Timer.scheduledTimer(withTimeInterval: 0.5" daemon/Sources` returns only `DebouncedSaver.swift`.
- `cd daemon && swift build` and `swift test` green, about 7 new tests with the count in the commit body; `python3 scripts/truth_fences.py claude` green after the `CLAUDE.md` edit; `bash scripts/ci-local.sh daemon` green.

## Amended 2026-10-25 (performance review)

The 2026-10-25 performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified) drafted these items before this task landed the same day; they are folded in here rather than filed twice.

**The TOML render races the main-thread writer (MAINTHREAD-13).** **`ConfigStore` renders its TOML tree on `writeQueue` while main can mutate it.** The debounced `scheduleSave` timer calls `self.writeBack()` on main (which mutates `rawDocument`), then `self.writeQueue.async { try self.persistToDisk() }`, and `persistToDisk` reads the same tree with `rawDocument.convert(to: .toml, ...)` off main with no copy or lock. `saveNow()` (the Apply buttons) runs `writeBack()` and `persistToDisk()` synchronously on main, so it can mutate the tree while a queued persist converts it, and both write the same `config.toml.writing` temp before `replaceItemAt`. Two threads inside one toml++ tree can crash or render a corrupt file, and a `config.toml` that then fails to parse sets `parseError`, which fail-closes every later save (ARCH9). It needs an Apply during a pending persist or a stalled disk, so it is rare.

**Scope addition, inside the `DebouncedSaver` move.** `ConfigStore`: render the TOML `String` on main right after `writeBack()` and hand only that immutable string to the write half of `persistToDisk` on `writeQueue`; `saveNow` renders the same way and performs its write through `writeQueue.sync`, so the two writers never use the `.writing` temp at once. [UX91](./UX91.md) edits the same `scheduleSave` closure; whichever lands second rebases.

**Acceptance addition.**

- `ConfigStoreTests` (with the write queue injectable): the write half writes exactly the string it is given; with the queue held by the test, a debounced save, a further mutation and `saveNow()` leave `config.toml` holding the `saveNow` state and no `.writing` file.
