---
id: REC31
title: On ExFAT, FAT32 and nobrowse volumes the free-space reader reads zero, so the low-space watch force-stops every recording at its first tick
category: Recording
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). Audit G002: effectiveFreeBytes takes min of the two capacity keys and volumeAvailableCapacityForImportantUsage reads 0 with space free on ExFAT, FAT32 and nobrowse volumes, so a library there opens every recording on "Disk: 0m left", LowSpaceWatch's first 60 s tick force-stops it with a false disk-full notice, and a real write failure is blamed on the disk; the default boot-volume library is unaffected. Read a zero important-usage value as unreadable, and route the Storage pane's free space through the same reader (G043).
---

# REC31: On ExFAT, FAT32 and nobrowse volumes the free-space reader reads zero, so the low-space watch force-stops every recording at its first tick

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source findings: G002 and G043 in [2026-11-12-independent-audit.md](../../audits/2026-11-12-independent-audit.md); the recording reliability audit's verdict section repeats G002 as "HEAD only, not observable in the pack" ([2026-11-13-recording-reliability-audit.md](../../audits/2026-11-13-recording-reliability-audit.md)). No field evidence: the code is newer than any installed build, and the field pack has one recordings directory on the boot volume.

**The reader** (re-verified at HEAD `3a2da4fc` on 2026-11-13). `RecordingWriteFailure.freeSpace(at:)` reads `volumeAvailableCapacityForImportantUsageKey` and `volumeAvailableCapacityKey` and hands both to `RecordingWriteFailure.effectiveFreeBytes`, whose two-present case is `case let (a?, b?): return min(a, b)`. That was the owner's choice on 2026-11-12 under [REC19](./REC19.md), so a disk whose writes are failing cannot read high on purgeable space. It treats nil as unreadable but takes a present 0 at face value.

**The measurement** (the audit's, with scratch disk images on this Mac; not re-measured at filing). A normally mounted APFS or HFS+ volume reads important-usage equal to available and non-zero, so an ordinary Mac-formatted external or secondary disk is unaffected. The important-usage key reads 0 with space free on ExFAT and FAT32 volumes (writable, browsable) and on any volume mounted `nobrowse` regardless of filesystem. Network volumes were not measured. **Correction at filing:** G002's title says "any volume except the boot Data volume"; its own body narrows that to the three cases above, and this task takes the narrow form.

**What a zero does, all three readers re-verified:**

- **Start.** `MeetingRecorder.boundedFreeBytes` reads `RecordingWriteFailure.freeSpace(at: directory).freeBytes` before the recording arms, so the start notice covers 0 s and the HUD opens on `RecordingLowSpace.hudText(coveredSeconds: 0)`, "Disk: 0m left", with a low-space notification.
- **The watch.** `LowSpaceWatch` re-reads every `RecordingLowSpace.checkIntervalSeconds` (60 s) through the same reader. `RecordingLowSpace.Policy.evaluate` computes covered seconds from 0 bytes, `if covered <= 0 { stopped = true; return Assessment(action: .stop, ...) }`, and `LowSpaceWatch.deliver` emits `recording_stopped_low_space` and hands `.stop(message: RecordingLowSpace.stopMessage(freeBytes: 0))` to the session, which stops through REC20's merging `forceStop`. Every meeting on such a volume is cut to its first minute (kept and merged) with a false "disk was almost full" notice.
- **Write failures.** `RecordingWriteFailure.decide` reads `if let free = freeBytes, free < diskFullThresholdBytes` as `.diskFull`, so any real write-failure stop on those volumes names the disk as full ("Zero KB free"), which is the exact misdirection REC19 removed.

**G043, same reader family.** `StorageStats.freeBytes(on:)` reads only the important-usage key, `Int(values?.volumeAvailableCapacityForImportantUsage ?? 0)`, so unreadable is 0 and an ExFAT library shows 0 free in Preferences and drops the growth projection (`LibraryGrowth.Projection` returns nil when `freeBytes > 0` fails). `mp doctor` reads `shutil.disk_usage(...).free` (`_free_disk_gb` in `pipeline/src/mp/doctor.py`, `free_bytes` in `pipeline/src/mp/storage.py`). The audit's probe read 15.10 GB against 14.07 GB on the Data volume. **Correction at filing:** REC20's spec says the growth definition is shared between the pane and `mp doctor` (`mp.storage.library_growth`), which holds; the free-space figure each divides by is what differs, so the two runways disagree by that margin.

## Scope

1. `RecordingWriteFailure.effectiveFreeBytes`: an important-usage value of 0 (or below 0) is unreadable, so `(0, b?)` returns `b`. Keep `min` for every other pair, which is REC19's owner decision and is not reopened. Update the doc comment to say why a zero is not a measurement here.
2. `StorageStats.freeBytes(on:)` reads through `RecordingWriteFailure.freeSpace(at:)` (unreadable stays the pane's existing fallback), so the pane, the start check, the watch and the write-failure notice all read one figure. Leave `mp doctor` on `shutil.disk_usage`; with item 2 the daemon's figure becomes `min(important, available)`, which should sit close to what `shutil.disk_usage` reports, and the pickup records the residual difference on this Mac in the commit body rather than chasing it.

## Explicitly not

- Reversing REC19's `min` choice, or reading only `volumeAvailableCapacity`: owner decision 2026-11-12.
- Network and file-provider volumes: not measured, and [REC25](./REC25.md)'s writer-stall path owns a volume that hangs rather than reads wrong.
- Making `mp doctor` read the important-usage key: Python has no portable equivalent, and the owner reads the daemon's figure in the pane.
- The low-space policy thresholds and HUD copy: [REC20](./REC20.md), owner-accepted 2026-11-12.

## Acceptance

- `RecordingWriteFailureTests`: `effectiveFreeBytes(importantUsage: 0, available: n) == n`; `effectiveFreeBytes(importantUsage: 0, available: nil)` is nil; `(0, 0)` returns 0 (a genuinely full volume still reads full); the existing `min` cases stay green.
- A `RecordingLowSpaceREC20Tests` case driving `LowSpaceWatch.pollNow()` with a scripted reader that returns the ExFAT shape (important 0, available 50 GB) through the real `effectiveFreeBytes`: no `.stop`, no `recording_stopped_low_space`, and no "Disk: 0m left" label at start.
- `decide(channel:freeBytes:volumeName:)` fed the ExFAT shape through the reader returns `.unknown`, not `.diskFull`.
- A test or source fence that `StorageStats.freeBytes(on:)` goes through `RecordingWriteFailure.freeSpace(at:)`.
- Optional, by the pickup session: a scratch ExFAT disk image attached with `hdiutil`, read once through the pre-fix and the fixed reader, then detached and deleted, recorded in the commit body. Touches no library and no live recording.
- `cd daemon && swift build` and `swift test` green, with the number of new tests in the commit body; `bash scripts/ci-local.sh` green.
