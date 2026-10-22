# PERF10: the Teams mute-button probe and the process-audio signal still poll on the main thread, so a busy Teams or coreaudiod can freeze the UI for seconds during a call

Band origin: filed 2026-10-23 from the code audit run for the owner's "the app feels slow" report ([PERF9](./PERF9.md) is the measured half). This half is confirmed by reading code and was not caught in a trace, because no call was live while sampling. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What is wrong

Two per-call pollers use their type's default scheduler in production, and both default schedulers are `Timer.scheduledTimer`, which fires on the main run loop:

- `AXMuteButtonProbe` (built by `NativeMuteAdapter` as `AXMuteButtonProbe(app:axBus:catalogue:eventLog:)`, no scheduler passed). `AXMuteButtonProbe.defaultScheduler` arms the health poll. Each `evaluate(reason:)` reads the button through `AXUIElementCopyAttributeValue` (title, help, description). After a run of unknown readings, `noteUnknownAndMaybeRearm` re-resolves the element with a full tree walk, also on main. AX notifications reach it on main too (`RealAXBackend` adds its source to `CFRunLoopGetMain()`).
- `ProcessAudioSignal` (built by `NativeLifecycleAdapter` as `ProcessAudioSignal(halBus:eventLog:)`). `ProcessAudioSignal.defaultScheduler` arms the 1 Hz fallback poll. Each `evaluate(reason:)` reads `AudioObjectGetPropertyData`, and `resolve(context:)` enumerates the process object list. These are synchronous calls into `coreaudiod` with no bound.

The only bound on the AX side is process-wide: `App.swift` sets `AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2.0)` ("bounds each call to 2 s for all elements, so the run loop always recovers"). That keeps the run loop from wedging forever, but it still lets one slow Teams AX read hold the main thread for 2 s, and an evaluate makes three such reads. That is the 1 to 3 s freeze shape the owner described. The sibling signal already avoids it: `AXLeaveButtonSignal` runs on its own queue through `AXLeaveButtonSignal.queueScheduler(on:)`, and its walks moved off main after a Teams AX re-walk on main froze the app (the same freeze class as the CoreAudio calls REC13 bounded).

## Scope

- Give `AXMuteButtonProbe` and `ProcessAudioSignal` queue schedulers, the way `AXLeaveButtonSignal` does, using a `DispatchSourceTimer` (the `daemon/CLAUDE.md` rule: a repeat scheduled off main needs one). Each keeps its own serial queue. Only the resulting state change hops to main or to the bus queue, whichever its consumers already expect.
- Bound each Teams AX element read per element with `AXUIElementSetMessagingTimeout(element, ...)` at a value well under the UI's frame budget (about 0.25 s, measured and documented beside the constant), keeping the 2 s system-wide value as the backstop.
- Move the per-recording-start `MeetingAXHandleBuilder.build` calls in `MeetingSessionController.engageMicGate` and `engageLifecycle` onto the existing `axWalkQueue`, if they are still on main when this is picked up.

## Explicitly not

- Changing what either signal decides. This is a threading change only, and [END15](./END15.md) owns process-audio semantics.
- `MeetingDiscoveryWatcher.sampleMicBusy` (a 3 s or 12 s main-thread `Timer` reading `isInUseByAnotherApplication`). It showed up at 5 to 9 samples per minute in the 2026-10-23 traces, so it is cheap; it is listed under [PERF13](./PERF13.md).

## Acceptance

- `MeetingPipeCoreTests`: each signal's production scheduler is not the main queue (inject a queue and assert `evaluate` runs off main via `dispatchPrecondition(condition: .notOnQueue(.main))`), and the existing signal tests stay green with the fake schedulers they already use.
- A test fails without the change (the default scheduler fires on main).
- `cd daemon && swift build` and `swift test` green, new test count in the commit body. Strict concurrency stays clean, with no new `@unchecked Sendable`.
- Evidence after install (confirms, does not gate): during a Teams call, `sample MeetingPipe 20` shows no `AXUIElementCopyAttributeValue` or `AudioObjectGetPropertyData` under the main thread. If [PERF11](./PERF11.md) has landed, its stall events show no stall over 250 ms attributed to a call.
