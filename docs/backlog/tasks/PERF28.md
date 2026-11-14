---
id: PERF28
title: Creating the mic capture file runs synchronously on the main thread at record start, and on early recordings after a launch it freezes the whole app for 2 to 3 seconds
category: Performance
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). `MeetingRecorder.buildMicChain` creates the mic `AVAudioFile` on main with no suspension point, and the span from `input_device_resolved` to `mic file opened` took 2,274 to 3,078 ms on 4 of 74 starts (median 10 ms), each an early recording after a launch or rebuild, the last `20261112-163040`; REC27 bounded every engine call but not this. Scope: create the file off main under its own generous bound (not the 2 s engine budget) and assign on main, delete what an abandoned create leaves, move the marker and recovery-manifest writes off main in order, log the create's duration, then test one prewarm hypothesis against an owner-run `sample`. [Spec](./PERF28.md)
---

# PERF28: Creating the mic capture file runs synchronously on the main thread at record start, and on early recordings after a launch it freezes the whole app for 2 to 3 seconds

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Sources: P003 and P045 in [2026-11-13-responsiveness-audit.md](../../audits/2026-11-13-responsiveness-audit.md) (ranked fix 3), with the start-time inventory in [2026-11-13-field-evidence.md](../../audits/2026-11-13-field-evidence.md) ("Input device at start": mic file mono 48 kHz on 74 of 74 starts). Every code claim below was re-read at HEAD `3a2da4fc` on 2026-11-13.

**The span runs on main with nothing to yield.** `MeetingRecorder.start` and `buildMicChain` are both `@MainActor`. After the bounded format read (`engineCall(site: "start_format_read", ...)`), `buildMicChain` runs, with no `await` in between: `InputDeviceResolver.resolveDefaultInput()`, `Log.event(category: "recorder", action: "input_device_resolved", ...)`, `MeetingRecorder.monoCaptureFormat(from: micFormat)`, then `micFile = try AVAudioFile(forWriting: micURL, settings: fileFormat.settings)`, then `Log.writeLine("recorder", "mic file opened format=...")`. The logger stamps at call time and writes synchronously, so the gap between the `input_device_resolved` row and the `mic file opened` line is main-thread time, and nothing else in the app (prompt fade, hotkeys, status menu) runs during it.

**Field measurement.** That gap over the 74 starts in the field pack: median 10 ms (7 ms era A, 11 ms era B, 8 ms era C); 200 ms or more on 6 of 74; 2,274 and 2,600 ms (era A), 2,851 ms (era B) and 3,078 ms (era C, stem `20261112-163040`, the first start after the 2026-11-12 rebuild). Each of the four is an early recording after a launch or rebuild: 4 of the 9 first recordings after a launch in the pack. On the other 65 recordings the span is at most 248 ms. The prompt is mid-fade when this runs, so the visible symptom is a prompt frozen partly faded with dead hotkeys, then the HUD.

Correction at filing: the cause is attributed to `AVAudioFile(forWriting:)` by elimination, not profiled. The span also holds one synchronous `events.jsonl` append and a format build, and first use in a new process does not explain it by itself: the first start after the 2026-10-12 rebuild took 6 ms on the same span, and 4 of the 9 first-after-launch starts were fast (107 to 480 ms; the ninth, `20260930-175206`, lost its 3,042 ms before `input_device_resolved`, outside this span). So the scope logs the create's own duration and treats the prewarm as a hypothesis to test, not a fix.

**This is a boundary of REC27, not a regression.** [REC27](./REC27.md) (done) bounded every `AVAudioEngine` call in the start off main (`engineCall`, `boundedEngineStart`, through `runBlockingWithTimeout`). File creation is not an engine call and was never in its scope. Two more synchronous writes sit on the same main-actor path: the `.capturemode` marker in `start` (`try? captureMode.marker.write(to: modeMarkerURL, atomically: true, encoding: .utf8)`) and, after `start` returns, `MeetingSessionController.writeRecoveryManifest` (`RecordingManifest.write(...)`), both into the recordings folder, which on the owner's machines is under an iCloud-synced `~/Documents`.

**A stale comment says it cannot happen.** `MeetingSessionController.beginRecording` says "The recorder bounds the engine bring-up off the main thread, so the await below never blocks the UI". The engine bring-up is bounded; the file creation inside the same await is not, so the await does block the UI.

**The obvious fix has a trap.** `engineCall`'s budget is `engineCallBudgetSeconds`, which is `EngineTeardown.defaultBudgetSeconds`, 2.0 s, below all four measured creates, each of which succeeded. Routing the create through `engineCall` would turn every one of those slow-but-successful starts into a failed start, count it against `abandonedCalls` and retire a healthy engine. And a create that times out keeps running on its GCD thread: it can still write `<stamp>.mic.wav` after `unwindFailedStart` removed it and `stemOwnership` released the stem, leaving a header-only capture file that the orphan sweep would see as an interrupted recording.

Related: [UX106](./UX106.md) adds the Starting state that hides whatever wait remains; [OBS7](./OBS7.md) adds click-to-feedback events; [PERF11](./PERF11.md) is the main-thread stall watchdog that would have logged this; [REC21](./REC21.md) makes the same marker writes report failure; [REC23](./REC23.md), [REC20](./REC20.md) and [HYG10](./HYG10.md) (comments that state what the code does not do) touch the same start path.

## Scope

All in `daemon/Sources/MeetingPipe/MeetingRecorder.swift` except the manifest write and the comment.

1. **Create the mic file off main under its own bound.** In `buildMicChain`, build the `AVAudioFile` inside `runBlockingWithTimeout` directly (not `engineCall`), with a budget of its own well above the measured 3.1 s (the pickup picks it, for example the engine start's 8 s), and assign `self.micFile`, `micFileFormat`, the gate writer and the serial writer on main after the await, as today. A slow create therefore still succeeds. A create that times out is not an engine wedge: it does not call `noteAbandoned`, does not retire the engine, and fails the start with `RecorderError.fileCreateFailed`, taking the same `unwindFailedStart` exit the existing `fileCreateFailed` throw takes.
2. **An abandoned create cleans up after itself.** A create that returns after its bound has expired deletes the file it made, the way `SystemCaptureStartAttempt` discards what an abandoned SCStream start produces (REC17), so no header-only `.mic.wav` outlives a failed start. REC23's claim-before-file order is unchanged: the stem is claimed before the create is issued.
3. **Move the marker and manifest writes off main, still awaited and in order.** The `.capturemode` marker is written off main and awaited before any capture file is created (orphan recovery depends on it existing first); `writeRecoveryManifest` runs off main and is awaited before `setRecording`. Neither becomes fire-and-forget. The manifest await goes before `setRecording`, never between it and the `endObservedDuringStart` check: REC7 relies on there being no suspension point between the two, so no end verdict can interleave. REC21 changes the marker write to report a failure; whichever of the two lands second rebases onto the other.
4. **Log the create's duration.** One `recorder.log` line or a field on an existing event with the create's milliseconds, so the next slow start names its own cost instead of being inferred from two timestamps.
5. **Test one prewarm hypothesis, gated on evidence.** At idle after launch (from `Coordinator.start()`, never in `App.main()` above `SingleInstanceGuard.standDownIfPeerIsRunning()`), on a utility queue, create and delete one scratch `AVAudioFile` outside the recordings folder (so no sweep can mistake it for a recording). Ship it only if the owner-run `sample` below shows the cold cost is inside `AVAudioFile` and the prewarm removes it; otherwise record the finding here and leave it out.
6. **Correct the `beginRecording` comment** to say what is bounded and what is awaited.

## Explicitly not

- The Starting state on Record: [UX106](./UX106.md). This task removes the freeze; that one gives the click a visible answer.
- A main-thread stall watchdog: [PERF11](./PERF11.md).
- REC20's awaited free-space read before the first file (`boundedFreeBytes`): already off main and bounded at 2 s.
- Reusing `engineCall` or its 2.0 s budget for the create, for the reason above.
- A prewarm file inside the recordings folder (the audit's first suggestion): a crash between create and delete would leave an orphan the sweep would process.

## Acceptance

- `MeetingRecorderTests` (or a seam test over an injected file factory): a create that takes longer than the old 2.0 s engine budget but inside the new bound starts the recording normally, with no `engine_start_timed_out`, no abandoned-call count and no engine replacement; a create past its bound fails the start with `fileCreateFailed`, removes the `.capturemode` marker, releases the stem and leaves the engine in place; a create that returns after its bound deletes the file it made, so `raw/` holds no `<stem>.mic.wav` afterwards.
- A test that `buildMicChain` performs the create off the main thread (the injected factory records `Thread.isMainThread == false`).
- An ordering test: the marker exists before the factory is called, and the manifest exists before `setRecording` is observed.
- Every start writes one `recorder.log` line with the create's duration in milliseconds (for example `mic file created in <n> ms`), pinned by a test over an injected slow factory. If the pickup puts it on an event instead, the field goes in `CONVENTIONS.md`'s event table and `python3 scripts/truth_fences.py events` stays green.
- The REC10, REC12, REC15, REC23 and REC27 recorder tests stay green.
- `cd daemon && swift build`, `swift build -c release` and `swift test` green, N new tests named in the commit body; `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [session] Install HEAD with the duration log on the work laptop (`./scripts/rebuild.sh`).
2. [owner] Quit and relaunch MeetingPipe, then in a terminal run `sample MeetingPipe 6 -file ~/Desktop/first-record.sample.txt` and within a second click Record on the next prompt (or the menu's Start recording). Repeat on up to three relaunches, since only about half of first starts are slow. Cost: a few short test recordings, deleted afterwards.
3. [session] Read the samples and the new create-duration line: if the main thread (or, after the fix, the create's GCD thread) sits inside `AVAudioFile` or `ExtAudioFile` on the slow start, try the prewarm (scope item 5) and repeat step 2 once with it; if the time is elsewhere (the event-log append, File Provider), record that here and drop item 5.
