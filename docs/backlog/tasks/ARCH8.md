# ARCH8: MeetingRecorder is a 2,328-line class that every REC and END fix lands in, and its 265-line stop() is one method

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) A2, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) SA-4 recorder half). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

`daemon/Sources/MeetingPipe/MeetingRecorder.swift` holds one type, `final class MeetingRecorder`, with 45 methods and 67 stored properties. Its size over time, read from git on 2026-10-24: 1,009 lines on 2026-06-01, 1,609 right after ARCH5 moved the static post-processing half into `RecordingPostProcessor` on 2026-07-24, 2,225 on 2026-09-01, and 2,328 now. 36 of its 58 commits are since June, mostly REC8, REC13, REC15, REC16, REC17 and CI8 fixes. ARCH5's extraction worked because every member it moved was already `static`; what is left is instance state, so the next extraction needs a seam, not a cut and paste.

The class is already organised by `// MARK:` region, which is where the seams are. Measured spans:

| Region | Approx. lines | What it is |
|---|---|---|
| The mic capture chain | 120 | engine and tap setup |
| System audio (SCStream) | 270 | `startSystemCapture`, `openSystemFile`, `padSystemChannel`, `retrySystemAudio`, auto-retry |
| Idle-sleep power assertion and wake re-arm (REC8) | 100 | assertion, wake observer, `handleDidWake`, `handleSystemAudioLost` |
| System audio liveness watchdog (REC4) | 35 | timer plus `MicTapLivenessMonitor(stallAfterSeconds: 3.0)` |
| Mic tap | 120 | `installMicTap`, `processMicBuffer` |
| Input device change recovery | 370 | `replaceEngine`, `armConfigurationChangeObserver`, `evaluateConfigurationChange`, the retry schedule, `recoverCapture` (about 200 lines alone), `abandonMicCapture` |
| Mic tap liveness watchdog | 570 by MARK span | only about 70 lines are the watchdog (`startTapLivenessWatchdog`, `checkTapLiveness`, `recoverFromTapStall`); the rest of the region is static buffer helpers (`resample`, `monoCaptureFormat`, `collapseToMono`, `makeSilenceBuffer`), `stop(limitSeconds:)` and `flushIntermediatesForTermination` |

Correction to the audit: it reads the last row as "a tap watchdog of ~570 lines" and proposes extracting `MicTapLivenessWatchdog` second. The watchdog's decision logic is already a separate type (`MicTapLivenessMonitor`, 51 lines), as is the recovery's (`CaptureRecoveryPlanner`, 69 lines) and the system retry's (`SystemCaptureRetryPlanner`). What is left in the class for the tap watchdog is three small timer methods. The size is in recovery, in system audio, and in `stop()`.

`stop(limitSeconds:)` is 265 lines, `@MainActor`, and is a sequence of about 15 commented steps: snapshot counters, compute the REC9 system offset, stop both watchdogs, drop the REC8 retry and wake hook, await the SCStream start, halt capture, stop observing device changes, drain an in-flight recovery, the REC13 bounded engine teardown, the MIC15 coverage snapshot, drain the writer queues, the VPIO disable, drop the `AVAudioFile`s, the duration diagnostic, the merge, the mute timeline, the clean-finish marker. Each step carries ordering constraints that live only in its comment (for example "Stop observing device changes before teardown so it can't trigger").

## Scope

Extract along the MARK seams, behaviour pinned first, one extraction per commit, with `swift test` green between each:

1. **Pin before moving.** Add recorder tests for the paths each extraction touches that are not already covered by `MeetingRecorderTests`, `CaptureRecoveryPlannerTests`, `MicTapLivenessMonitorTests`, `SystemCaptureRetryPlannerTests`, `SystemCaptureStartREC17Tests` and `CaptureHealthREC16Tests`. At minimum: a configuration change while recording schedules a recovery and a second change inside the window does not double-schedule; `stop()` during an in-flight recovery waits for it; `stop()` with no current file releases the idle-sleep assertion (END11 item 3).
2. **`InputDeviceRecovery`** (the largest region). A type owning the configuration-change observer, the retry schedule and the `recoverCapture` procedure, talking to the recorder through a narrow protocol for the engine swap and the writer pad. It keeps REC13's rule exactly: the observer registers through `addMainQueueObserver` (nil queue plus an explicit main hop), never with a non-nil `queue:`, because that spelling is the deadlock. The tap-stall recovery (`recoverFromTapStall`) and its 70 lines of timer move with it, since a stall and a device change both end in `recoverCapture` under the same one-recovery-at-a-time `recoveryTask` guard.
3. **`SystemAudioChannel`.** The SCStream start, retry, padding, liveness watchdog and the REC17 bounded start, owning `systemFile`, `systemWriter` and their counters. `stop()` calls one `systemChannel.stop()` step.
4. **Split `stop()` into named private steps** in the order they run today (`haltCapture`, `drainWriters`, `teardownEngine`, `finalizeFiles`, `mergeAndPersist` or similar), each with its ordering constraint in at most three lines. `stop()` itself reads as the sequence.

Whichever REC task next touches the recorder does step 1 plus the one extraction its fix lands in, rather than a separate sweep (the ARCH5 promote-on-touch rule); a session may also run the steps on their own.

## Explicitly not / out of scope

- No rewrite and no behaviour change: the same events in the same order, the same timeouts, the same files on disk. The existing REC13 bounds and CI8's off-pool GCD hops move with their code unchanged.
- Not moving anything into `MeetingPipeCore`: these types own AVFoundation and ScreenCaptureKit objects.
- A separate `MicTapLivenessWatchdog` type, as the audit proposed. It would be about 70 lines wrapping an existing 51-line monitor; it goes with recovery in step 2.
- The `MeetingRecorder` surface the session sees (`SessionRecording`) stays as it is; narrowing the session side is ARCH7.
- The logger's thread safety (PERF13), Process handling for the merge's ffmpeg (CONC5), and the ffmpeg dependency itself (DEP2).

## Acceptance

- `MeetingRecorder.swift` under 1,500 lines after steps 2 to 4, with the extracted types in their own files and each named in ARCHITECTURE.md's Recording row in the same commit.
- `stop(limitSeconds:)` under 60 lines, its body a sequence of named step calls.
- At least 6 new tests from step 1, written and green against the unextracted class before any move, and still green after.
- `cd daemon && swift build` warning-clean under `-strict-concurrency=targeted`, with no new `@unchecked Sendable` (an extracted type that needs one lists its reason, which HYG10's allowlist fence will check if it has landed), `swift test` green, `bash scripts/ci-local.sh` green, N new tests stated in each commit body.
- The source-text fences that read `MeetingRecorder.swift` by path (for example `SystemCaptureStartREC17Tests`) are updated to read the file the code moved to, and still fail when the property they pin is removed.
