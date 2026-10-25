# REC24: a failed orphan re-merge is retried after every job forever, and two job completions can merge the same orphan at once over one temp file

Band origin: filed 2026-10-25 from the performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Review findings MAINTHREAD-5, RECORDING-6 and SUBPROCESS-3, all medium and confirmed by the verifier. Re-checked in code at `01e904a` on 2026-10-25.

**Cadence.** `Coordinator.reapStorage` calls `recoverOrphanedRecordings` at launch and from the `onDone` that `PipelineJobDispatcher.route` calls on every `.success` except a `.retranscribe`, so a ten-meeting Library regenerate batch runs the orphan sweep ten times. REC6 chose this cadence on 2026-07-12 so a stop-time merge failure recovers without a relaunch, and that stays.

**No attempt cap.** `OrphanRecordingRecovery.scanOrphanStems` keeps any stem for which `hasRecoveryMarker` is true, and `.recordfail.json` is one of its two markers, so such a stem bypasses `maxOrphanAge` for good. `RecordingPostProcessor.writePostProcessFailure` writes `["schema_version": 1, "reason": reason, "retained": names]` afresh on each failure, and only `cleanupStartMarkers`, after a successful merge, removes it. A stem whose merge fails deterministically therefore re-runs a full ffmpeg merge after every job for the life of the library: REC9's too-short refusal (the likely outcome for intermediates whose writer died mid-write), a corrupt intermediate, or a merge that always reaches the 300 s `mergeCeilingSeconds`. Each attempt re-reads the intermediates, about 2.07 GB per recorded hour (mono Float32 mic at 192,000 B/s plus stereo Float32 system at 384,000 B/s), and until [CONC5](./CONC5.md) lands each timed-out attempt leaves one more ffmpeg and parked GCD thread running, since `runWithTimeout` stops waiting and kills nothing. The verifier priced a fast-failing input at about 2 s of CPU per attempt; the unbounded chain is the hang-prone one.

**No in-flight guard.** Each call starts a fresh `Task { @MainActor [weak self] in let result = await OrphanRecordingRecovery.recover(stems: stems, in: dir) ... }` with nothing marking a stem as in progress. `recoverOrphan`'s "never clobber a recording that already finished" check runs once at entry, and `produceFinal`'s first act is `try? FileManager.default.removeItem(at: tmp)` on the fixed `mergingTempURL(forFinal:)` (`<stem>.merging.wav`). A second job completing during a long orphan merge starts a second merge of the same stem that unlinks the first's temp. The verifier traced it to no data loss (both usually fail REC9's duration check and keep the intermediates; a near-complete promote follows its inode), but to wasted CPU, spurious `postprocess_failed` rows and a delayed recovery.

**The scan runs on main.** `scanOrphanStems` is a `contentsOfDirectory(at:includingPropertiesForKeys: [.contentModificationDateKey], ...)` over the flat `raw/` plus a `fileExists` and `resourceValues` per candidate, called synchronously from `onDone`. The verifier measured 0.6 ms on the owner's 61-entry `raw/` on 2026-10-25; at about ten files per meeting a year is 10k to 15k entries and tens of ms. Hygiene only, but the recover Task already hops off main, so moving it costs nothing.

**Why it matters beyond waste.** A stem stuck in this loop is exactly the earlier orphan that turns the start-window race in the P1 filed beside this task on 2026-10-25 ([REC23](./REC23.md) "The after-job orphan sweep can merge a recording that is still starting, delete its live intermediates, and publish a few-second stub in place of the meeting") from narrow into reliable.

Reachability on the owner's personal Mac on 2026-10-25: `raw/` held no `.recordfail.json` or intermediates and `events.jsonl` no `postprocess_failed` or `merge_timed_out` row, so nothing is stuck there; the work laptop's library was not visible to the review.

## Scope

1. **Single-flight with one coalesced rerun.** A request that arrives while a recovery runs sets a rerun flag instead of starting a second Task, and when the running one finishes at most one rerun starts. Keep the latch as a small pure type beside `OrphanRecordingRecovery` (a request yields start or coalesced; a finish yields rerun or idle), held main-confined by `Coordinator`. Since `recover` is already sequential inside one run, this alone removes the same-stem overlap.
2. **An attempt count in the breadcrumb, with a cap on after-job retries.** `writePostProcessFailure` reads an existing `.recordfail.json` and writes `attempts` (an absent key counts as 1) plus `last_attempt_at` (ISO 8601 UTC). The after-job sweep skips a stem whose `attempts` has reached a cap (proposed 3, a constant beside `maxOrphanAge` with its reason). The launch sweep still tries every marked stem once per launch, because a rebuild can ship the fix that makes a failing merge succeed. Reaching the cap emits `coordinator`/`orphan_recovery_gave_up` once (`stem`, `attempts`, `reason` from the breadcrumb), and the doctor's sidecars-without-wav finding (`OrphanScan.detect`) keeps the stem visible.
3. **The scan moves off main**, into the recover Task's off-main hop. The per-stem owned check from the sibling P1 stays on main.

## Explicitly not

- Per-attempt temp names (`<stem>.merging-<uuid>.wav`). With item 1 no two recoveries overlap, and with CONC5 a timed-out ffmpeg is killed. A uuid temp would be new debris that `OrphanScan`, `detectOrphanStems` (which counts any other `*.wav` as a final, of a phantom stem here) and the doctor would all have to learn.
- Exponential backoff with timestamps. A cap plus once per launch gives the property backoff was for with less state.
- A Library "Retry recovery" control. The capped stem keeps the surfaces it has at `01e904a` (the doctor finding, and a retry on every launch); propose one to the owner if a capped stem ever appears in the field.
- Rewording the stop-path notice "The raw recording was kept and will be recovered automatically" once the cap is reached. It stays true in the sense that every launch retries; any copy change is the owner's call, not filed.
- The retention sweep's overlap, `LocalServerReaper`'s sleep loop, the blocking work in `Task.detached`, killing a timed-out ffmpeg, and `RecordingPostProcessor.runFFmpeg` draining stderr only after `proc.waitUntilExit()` (which the verifier names as the likeliest way a corrupt orphan reaches the 300 s ceiling): CONC5 items 2 and 3, amended 2026-10-25 from the same review.
- The start-window exclusion: the sibling P1. Both edit `recoverOrphanedRecordings` and `recover`; the P1 goes first and this one rebases.

## Acceptance

- `RecordingPostProcessorTests` or `OrphanRecordingRecoveryTests`: two consecutive `writePostProcessFailure` calls leave `attempts: 2` and a `last_attempt_at`; a breadcrumb with no `attempts` reads as 1; an after-job scan excludes a stem at the cap while a launch scan includes it; `orphan_recovery_gave_up` fires once across repeated after-job scans; a successful merge still removes the breadcrumb.
- A latch test: three requests while one recovery runs produce exactly one rerun, and a request after it finishes starts at once.
- A test with an injectable recoverer (default `RecordingPostProcessor.recoverOrphan`) that two overlapping recovery requests never run the recoverer for the same stem concurrently.
- `CONVENTIONS.md`'s `<stem>.recordfail.json` shape gains `attempts` and `last_attempt_at`, its event table gains `orphan_recovery_gave_up`, and `ARCHITECTURE.md`'s `<stem>.recordfail.json` row names the cap, all in the same commit; `python3 scripts/truth_fences.py both` green.
- `cd daemon && swift build` and `swift test` green, new test count in the commit body; `bash scripts/ci-local.sh` green.
