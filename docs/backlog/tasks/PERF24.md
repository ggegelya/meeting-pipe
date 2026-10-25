# PERF24: The status menu spawns launchctl and lists the whole recordings folder on the main thread at every open, rebuilds and discards the whole menu on every queue, state and download tick, and the in-app doctor runs its self-check on main

Band origin: filed 2026-10-25 from the performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-verified against HEAD `01e904a` on 2026-10-25 by code reading. Review findings UI-2 and MAINTHREAD-3 (the status menu, confirmed at medium and low) and SUBPROCESS-10 and UI-4 (the doctor, confirmed at low).

**Every open runs a subprocess on main.** AppKit calls `StatusMenuDelegate.menuNeedsUpdate` on main before each display, and it calls `StatusBarController.refreshMenuBeforeDisplay`: `PermissionsCenter.shared.refreshMenuRelevantSync()`, then `launchAgentEnabled = launchAtLogin.status().isOn`, then `populateMenu(menu, state: lastMenuState)`. `LaunchAtLoginService.status()` runs `ProcessLaunchctl.run(["print-disabled", domain])`, which spawns `/bin/launchctl`, blocks in `readDataToEndOfFile()` and `waitUntilExit()`, and is bounded only by UX67's kill at `ProcessLaunchctl.ceilingSeconds` (5 s). UX67 found `launchctl` blocking exactly like this on 2026-08-04 while `scripts/rebuild.sh` had the agent's domain busy, so a menu opened in that window freezes main, the hotkeys included, for up to 5 s. UX55 put the read here deliberately, so the quit rows are decided against launchd as the user looks. `daemon/CLAUDE.md`'s UX67 rule (every `launchctl` call is watchdogged and off main) and `LaunchAtLoginService`'s own comment describe a world without this caller.

**Every open, and every rebuild, lists the library on main.** `populateMenu` calls `menuInputs`, which calls `coordinator?.failedMeetingCount()`: `MeetingLibraryService.failedMeetingCount` runs `FileManager.default.contentsOfDirectory(atPath: dir.path)` over `raw/` and then `MeetingStore.unrecoveredFailureStems(fileNames:)`. `populateMenu` also calls `finishSetupItems()`, which reads config, secrets and the model cache (`ModelDownloadSupervisor.isCached`, a Hugging Face cache listing).

**Most of that work is thrown away.** `rebuildMenu(state:)` builds a fresh `NSMenu`, populates it and assigns it to `item.menu` on every state setter, every `setQueueActivity`, every permission change and every `setModelDownload` (`prefetch_model.py` emits progress about every 2 s while bytes arrive, for the whole of a multi-GB download). Because `menuNeedsUpdate` repopulates on open, a menu built by a rebuild is never shown unless the user opens it before the next rebuild. `MeetingLibraryService.failedMeetingCount`'s comment ("cheap enough to run on every menu open") is about the open; it also runs on every rebuild.

**Magnitude.** `raw/` held 61 files for 9 stems on 2026-10-25, about 7 per meeting, so a year at 2 to 8 meetings a day is 5,000 to 20,000 entries, in a folder the owner's Mac syncs to iCloud. That is tens of milliseconds per listing, paid twice per open and every 2 s during a model download, growing with the library, plus up to 5 s on a busy launchd. Degradation over months rather than a freeze, except in the launchctl case.

**The doctor's self-check also runs on main.** `DoctorRunner` is `@MainActor`, and `run()` calls `DoctorCommand.execute(probes: DoctorCommand.daemonSelfCheckProbes(), writer:)` inline under the comment "Daemon self-check first (fast, in-process)". The probes include `probeAppReachable(bundleID:)` for each known meeting app (an `AXUIElementCopyAttributeValue` against each running one, bounded by the process-wide 2 s `AXUIElementSetMessagingTimeout` set in `App.swift`), `probeOrphans` (an `OrphanScan` of `raw/`) and `probeSearchIndex` (a second `SearchIndex(url:)` connection with `sqlite3_busy_timeout(handle, 2000)` and a full `indexedSignatures()` read). On a healthy Mac that is tens of milliseconds, since the index is WAL and the read does not wait on the indexer; with a hung Teams it is about 2 s per hung app, and a doctor run is what the owner reaches for when something is wrong. Doctor runs are on record on 2026-10-24 (`doctor` `probe` rows at 13:08Z and 13:10Z in `events.jsonl`).

## Scope

1. **Rebuilds stop building.** State, queue, permission and download setters update the title and icon (`applyTitle`) and mark the menu stale; `populateMenu` runs only from `menuNeedsUpdate`. Assign one persistent `NSMenu` with `menuDelegate` at setup instead of a new one per rebuild, so an open always repopulates in place. [UX79](./UX79.md)'s contract (`setStopping` hands the menu the state its title shows) now reaches the next open, and its test keeps passing.
2. **The failed count is cached and computed off main.** `StatusBarController` holds the last count; it is recomputed on a utility queue at launch, when a job completes, on retry, delete and restore, and each time the menu opens (the open shows the cached value and updates the row in place if the count changed). [UX90](./UX90.md) changes what the count reads and caches decoded state per stem, [ARCH20](./ARCH20.md) extracts the failure rule, and [STOR11](./STOR11.md) logs an unreadable folder from the same function; whichever lands second keeps the others' rules, computed off main.
3. **The launch-agent state is read off main.** `LaunchAtLoginModel` pushes the state it has just written to the controller (the Preferences toggle is the common way it changes), and `menuNeedsUpdate` shows the cached value while an off-main `ProcessLaunchctl` read refreshes it and updates the quit rows in place when it lands. A change made outside the app (a terminal `launchctl`, `install.sh`), which is what UX55 re-reads for, is then caught within the same open.
4. **The doctor's probes run off main.** `DoctorRunner` takes its probe list as an init parameter defaulting to `DoctorCommand.daemonSelfCheckProbes()`, and `run()` executes them on a utility queue, appends each line to `output` on main in probe order, then spawns `mp doctor` as today, so the sheet keeps its order. [CONC7](./CONC7.md) adds an `invocation` parameter to the same init for its spawn drain; the two compose.

## Explicitly not

- `LaunchAtLoginModel.init`'s synchronous first read. UX67 kept it on purpose: a placeholder rendered before launchd has answered is the defect UX42 removed.
- The Recent meetings submenu's listing in `RecentMeetingsMenuDelegate.menuNeedsUpdate`, paid only when that submenu opens, by design.
- `PermissionsCenter.refreshMenuRelevantSync()` on open: not measured; leave it unless a trace shows it.
- DET14's per-open candidate read, which stays per open.
- The Library's own listings and the failed count seen from the Library side: the same review's library findings, LIBRARY-11 ([PERF13](./PERF13.md)) among them, which is item 2 seen from the other end; merge rather than file twice.
- A per-element AX timeout in `probeAppReachable`: `App.swift`'s process-wide 2 s already bounds each call.
- [PERF13](./PERF13.md)'s rails, Guide, Diagnostics and logger, and [PERF11](./PERF11.md)'s stall detection.

## Acceptance

- `StatusBarController` tests with a counting fake coordinator and a fake `LaunchAtLoginService` that records its calling thread: ten `setQueueActivity` and `setModelDownload` calls with the menu closed call `failedMeetingCount()` zero times and populate nothing; one `menuNeedsUpdate` populates once and makes no `failedMeetingCount()` or `status()` call on the main thread.
- A job completion recomputes the cached count off main and the next open shows it; a `LaunchAtLoginModel` write updates the controller's value with no `launchctl` read; an off-main read that reports a change updates the quit rows of an open menu.
- The existing UX79 `setStopping` test passes unchanged.
- `DoctorRunnerTests` with an injected probe that blocks on a semaphore: `run()` returns before the probe finishes, the probe runs off main, and `output` keeps probe order with the `== mp doctor ==` header after the last probe line.
- `cd daemon && swift build` and `swift test` green, N new tests in the commit body; `bash scripts/ci-local.sh` green.
- Evidence (confirms, does not gate): `sample` the daemon while opening the menu 20 times during `./scripts/rebuild.sh`; no `contentsOfDirectory` or `ProcessLaunchctl.run` frames on the main thread.
