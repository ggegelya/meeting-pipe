# REC11: recorder teardown concurrency, an unbounded drain on the quit path and an off-main `stop()`

Filed 2026-08-03 by the audit band. Two defects in one teardown path, medium, spot-checked.

## (a) The quit path uses the unbounded `finish()` REC7 replaced everywhere else

`flushIntermediatesForTermination` is `@MainActor` and calls `SerialBufferWriter.finish()` with no timeout, while `stop()` calls the REC7 bounded `finish(timeout:)` for the same drain on the same writers. The wedge REC7 exists to bound is therefore still unbounded on the one path that runs during `applicationWillTerminate` and the SIGTERM handler.

- `daemon/Sources/MeetingPipe/MeetingRecorder.swift:1485-1486` calls `micWriter?.finish()` and `systemWriter?.finish()` inside the `@MainActor` flush declared at `:1445`.
- `daemon/Sources/MeetingPipe/SerialBufferWriter.swift:27-28` is `func finish() {` over `queue.sync {}`, an unbounded block on the writer's serial queue.
- `daemon/Sources/MeetingPipe/MeetingRecorder.swift:1311` is the graceful path's bounded variant.
- `daemon/Sources/MeetingPipe/MeetingRecorder.swift:45-47` is the project's own risk model naming this exact drain as a thing that can wedge.
- `daemon/Sources/MeetingPipe/MeetingRecorder.swift:1440-1441` claims the flush is "Deadlock-free: the only blocking calls are the writers' own serial queues, never the main queue." That is true about deadlock and quietly does not cover an indefinite block.
- `daemon/Sources/MeetingPipe/Coordinator.swift:603-605` calls it synchronously from `applicationWillTerminate` and the SIGTERM source.

Failure shape: the disk fills, or an external volume holding `~/Documents/Meetings/raw` stalls, while a recording is live. The owner quits, or `rebuild.sh` sends SIGTERM, and the app blocks forever on the main thread. The launch agent cannot relaunch it and the owner has to force-quit, which is exactly the situation where the intermediates the flush was protecting are least likely to be intact.

## (b) `stop()` is nonisolated async, so the teardown races the main-thread owners of its own fields

Per SE-0338 a nonisolated async function does not inherit the caller's actor, so `await recorder.stop()` from the `Task { @MainActor }` in `stopRecording` runs the whole teardown off the main thread.

- `daemon/Sources/MeetingPipe/MeetingRecorder.swift:1214` is `func stop() async -> Bool {` with no `@MainActor`, unlike `start` (`:320`), `unwindFailedEngineStart` (`:496`), `recoverCapture` (`:961`) and `flushIntermediatesForTermination` (`:1445`).
- `daemon/Sources/MeetingPipe/MeetingRecorder.swift:1279-1280` states in a comment that `stop()` is off-main, so this is the intended reading rather than a misread.
- `daemon/Sources/MeetingPipe/MeetingRecorder.swift:1236-1246` writes the four timer handles, the wake observer and the idle-sleep assertion off-main.
- `daemon/Sources/MeetingPipe/MeetingRecorder.swift:1440` claims the flush is "Main-thread only (it mutates the recorder state the render path also touches)", i.e. exclusive main-thread ownership of the very fields `stop()` writes off-main.
- `daemon/Sources/MeetingPipe/MeetingRecorder.swift:664-668` guards `IOPMAssertionRelease(idleSleepAssertionID)` with a non-atomic `guard holdsIdleSleepAssertion`, reachable from both the off-main `stop()` and the `@MainActor` flush, so a double release is possible.
- `daemon/Sources/MeetingPipe/MeetingRecorder.swift:729-731` schedules a 1 Hz `checkSystemLiveness` on the main queue whose only interlock with the off-main teardown is timing.

## Scope

For (a): use `finish(timeout:)` in `flushIntermediatesForTermination`, with a termination-specific budget since `applicationWillTerminate` has its own OS deadline, log a `writer_drain_timed_out` event on the abandoned path exactly as `stop()` does, and correct the "Deadlock-free" comment to say what it actually guarantees.

For (b): mark `stop()` `@MainActor` and keep only the genuinely long waits off-main, since the SCStream stop, the writer drains and `RecordingPostProcessor.produceFinal` are already `async` and bounded and can be awaited from the main actor without blocking it. If that cascades further than is comfortable, the smaller fix is to hop the teardown block through `MainActor.run` the way the recovery-task box at `:1275-1281` already does. Delete the contradictory `:1440` claim either way.

## Acceptance

Suite green with new tests. Both suites still pass with strict concurrency. A test pins that the termination flush abandons a wedged writer within its budget and emits the event. No owner walkthrough: neither defect is observable without a wedged disk or a race, and pre-registering an observation the owner cannot make is the failure mode this band was filed against.
