---
id: STOR16
title: The library move checks for in-flight work only at plan time and only from file heuristics, then executes unguarded after its confirm
category: Storage
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). LibraryMover.plan runs inFlightReason, but StorageStatsStore.executeMove calls LibraryMover.execute after an open-ended confirm with no re-check and the Move library button ignores StorageBusyGate, so a recording, backup, restore or pipeline job that starts while the dialog is open has raw/ renamed or copied out from under it; the check itself tests only the first .mic.wav listed, counts the processing window from recording start, and cannot see re-runs (F057, F074, F141; the row is live on the owner's Mac, whose library is iCloud-synced). Ask the recorder and the dispatcher, re-check on main immediately before execute, honour the busy gate, hold recording starts for the move's duration.
---

# STOR16: The library move checks for in-flight work only at plan time and only from file heuristics, then executes unguarded after its confirm

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: findings F057, F074 and F141 (data lens, all confirmed, the audit marks F074 and F141 as the same defect) in the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md). Re-verified in code at HEAD `3a2da4fc` on 2026-11-14.

**The promise.** `LibraryMover`'s header names two refusals as "non-negotiable, since a library moved out from under a live recording is a lost meeting": a recording in progress, and a pipeline job still processing a meeting.

**The check runs once, at plan time.** `LibraryMover.plan` calls `inFlightReason(in: source, now: now)` and throws `MoveError.busy`. The Storage pane's `chooseNewLibraryRoot` then sets `pendingMove = await stats.planMove(to: destination)`, which shows the `"Move the library?"` confirmation dialog with no time limit. Its button calls `Task { await stats.executeMove(plan) }`, and `StorageStatsStore.executeMove` runs `try LibraryMover.execute(plan)` on a detached task with no second check. `execute` does `fm.moveItem(at: plan.source, to: plan.destination)`, a rename within a volume and a copy-then-delete across volumes, then `configStore.outputDirPath = plan.destination.path`, which `ConfigStore.scheduleSave` writes 0.5 s later.

**The button ignores the busy gate.** `StorageBusyGate` (in `RestoreFlow.swift`) gates Back up now and Restore against each other (`backupRunning`, `restoreRunning`). The `Move library…` button is disabled only by `stats.isPlanningMove`. A pane-local gate also cannot see a scheduled backup run by the launchd agent.

**The check is inferred from files, three ways wrong.**

- `MeetingStore.freshCaptureIntermediate(in:)` takes `files.first(where: { $0.lastPathComponent.hasSuffix(".mic.wav") })` and tests only that one file's mtime against `liveCaptureFreshnessSec`. `contentsOfDirectory` order is unspecified, so a stale orphaned `.mic.wav` listed first masks a live capture (ordering inferred, not reproduced).
- The processing test compares `now.timeIntervalSince(startedAt) < Meeting.staleProcessingThresholdSec` (2 h), where `startedAt` is `MeetingStore.parseStem(stem)`, the recording's start. A 2.5-hour meeting that has just stopped and is mid-pipeline is already outside the window.
- A stem counts as processing only when it has a final recording and no terminal sidecar (`.summary.json`, the failure sidecar, `.READY_FOR_MANUAL.md`, the empty marker). A re-summarize or re-transcribe of a meeting that already has a summary is invisible.

**The cost.** If a detected meeting starts recording while the dialog is open and the owner then confirms a move to another volume, `moveItem` copies a partial `.mic.wav` and removes the source; the recorder keeps writing to an unlinked file, and the stop-time merge and sidecar writes target paths that no longer exist. A running `mp` child writing into `raw/` loses its output the same way.

**Reachable on the owner's Mac.** The Move library row is shown only when `CloudSyncDetector` finds a provider. On 2026-11-14 `~/Documents` carries `com.apple.icloud.desktop` and the library is `~/Documents/Meetings/raw`, so the row is live today. [UX89](./UX89.md) plans to offer the move whether or not sync is detected, which widens it further.

## Scope

1. **Ask the owners, not the files.** A busy probe injected into `StorageStatsStore` (the closure pattern `Coordinator` already uses for `preferencesWindow?.onLibraryRestored`, threaded through `PreferencesWindow`, `PreferencesView` and `StorageSectionView`), answering from `MeetingRecorder.ownedStems` (non-empty means a recording is in progress) and `SinkDispatcher.queueDepth` (non-zero means a job is active or queued), plus any in-app `mp` re-run that does not go through the dispatcher lane (the pickup checks `PipelineRunSlots` and the Library re-summarize and re-transcribe paths and covers what it finds). This is REC23's rule: ownership comes from the component that owns the work. `inFlightReason`'s file checks stay as a fallback for work no probe can see, with `freshCaptureIntermediate` testing every `.mic.wav` per stem rather than the first one listed, and the processing window counted from the newest mtime of the stem's files rather than from the stem's start.
2. **Re-check at execute, on main, atomically with the hold.** `executeMove` runs on the main actor; it calls the probe and, in the same main-actor turn, sets a `libraryMoveInProgress` flag that item 4 reads, before it hops to the detached `LibraryMover.execute`. A busy answer cancels the move with `MoveError.busy` and the reason shown in `moveError`. The flag clears when the move finishes, success or failure.
3. **Honour the busy gate.** The `Move library…` button is disabled while `StorageBusyGate.isBusy` or the probe is busy, and Back up now and Restore are disabled while a move is in progress (the gate gains a `moveRunning` field).
4. **Hold recording starts for the move's duration.** While `libraryMoveInProgress` is set, the recorder's start path does not open capture files under the old or new root; what it does instead is the owner's decision below. Emit `coordinator` `recording_start_held` with `reason` `library_move` when it fires.

## Explicitly not

- Re-rooting the Library store and the watcher after a move: [UX89](./UX89.md) and its amendment.
- Replacing `inFlightReason`'s suffix chain with `MeetingStatus.decide`: [ARCH20](./ARCH20.md) item 4. Whichever lands second keeps both. An unreadable library folder reading as not busy: [OBS3](./OBS3.md) and [STOR11](./STOR11.md).
- Moving the plan off main: done in PERF13.
- Trashing a meeting while it records: [STOR18](./STOR18.md), the same ownership question on another surface.
- Making the cross-volume copy resumable or transactional.

## Acceptance

- `StorageStatsStoreTests` with an injected probe and an injected executor (a new seam beside the existing `planner`): plan while idle, then the probe reports a recording, then `executeMove` refuses with `MoveError.busy`, the executor is never called and `outputDirPath` is unchanged. The same with the probe reporting a queued job. A behavioural test, not a token-presence fence (the audit's F112 names that weakness in REC23's fence).
- A test that `libraryMoveInProgress` is set before the executor runs and cleared after it returns and after it throws, and that a recording start attempted while it is set takes the held path and emits `recording_start_held`.
- `LibraryMoverTests`: a directory with a stale `.mic.wav` that sorts first and a fresh one for another stem reports a recording in progress; a stem started 2.5 h ago whose newest file was written a minute ago with no terminal sidecar reports processing.
- `StorageBusyGate` tests for the new `moveRunning` field.
- `recording_start_held` in `CONVENTIONS.md`'s event table; `python3 scripts/truth_fences.py events` green.
- `docs/GUIDE.md`'s Cloud sync paragraph that describes **Move library…** says the move refuses while a meeting is recording or processing, and what happens to a meeting that starts during a move, in the same commit.
- `cd daemon && swift build` and `swift test` green, the number of new tests in the commit body; `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [owner] Decide what a recording start does while a move is running, before code: (a) refuse with a notice, losing that meeting unless it is restarted by hand; (b) defer the start until the move finishes, losing the opening of the meeting for the length of the move (milliseconds for a same-volume rename, the full copy time across volumes); or (c) record into a staging folder outside the library and move the result in after. (b) is the proposal, since the move is owner-initiated from Preferences and a same-volume rename makes the window negligible.
2. [session] Implement the chosen path in item 4 and pin it in the hold test.
