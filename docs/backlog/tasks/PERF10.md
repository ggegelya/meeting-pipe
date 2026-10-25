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

## Amended 2026-10-25 (performance review)

The 2026-10-25 performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified) found the mute-probe half of this task twice, as DETECTION-1 (verified critical) and MAINTHREAD-1 (verified high). Re-read at HEAD 01e904a on 2026-10-25, everything stated above still holds. This section adds the magnitude, the legs the original scope lacks, one correction, two hand-offs and a re-band proposal.

**Magnitude against a hung client.** `App.swift` sets `AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2.0)`, and `AXMuteButtonProbe.defaultProbe` makes three reads per evaluate (`copyStringAttribute` for `kAXTitleAttribute`, `kAXHelpAttribute` and `kAXDescriptionAttribute`). Against a Teams whose main thread is hung, one 1 Hz tick holds MeetingPipe's main thread for up to 6 s, and `defaultScheduler`'s `Timer.scheduledTimer(withTimeInterval: interval, repeats: true)` fires again within a second of main freeing (a hung client delivers no notifications, so `AdaptivePollCadence` stays at the fast interval). For as long as the hang lasts, main spends about six seconds in every seven inside these reads. The status menu, the HUD, Stop and the Carbon hotkeys (`HotkeyManager` registers on `GetApplicationEventTarget()`, so they are delivered on main) wait behind them.

**The rearm walk is a multi-window DFS on main, and it repeats.** After `defaultRearmThreshold` (5) consecutive `.unknown` reads, `noteUnknownAndMaybeRearm` calls `resolveElement`, which in production is the `resolveMute` closure `MeetingAXHandleBuilder.build` hands over: `findMeetingWindowMuteButtons(in: axApp, bundleID: bundleID, catalogue: catalogue)`, a mute DFS of every window plus a Leave DFS of each window that has a mute button, every `findButton` entry allocating a fresh `maxNodes = 4000` budget. A window with no mute button (Calendar, chat) is walked to the end of its tree or its budget. The counter resets on every attempt (`consecutiveUnknown = 0` before `guard let fresh = resolve()`), so a reading that stays unknown (a label missing from `MuteLabels.toml`, the Mic is not available label, controls hidden by Teams) re-walks on main about every 5 s for the rest of the recording. `honor_app_mute` defaults to true (`ConfigDefaults.honorAppMute`), so this path runs on every Teams, Zoom, Webex and Slack recording.

**Mute gating lags while main is stalled.** AX notifications reach the probe through `AXObserverBus.subscribe`'s `DispatchQueue.main.async(execute: handler)`, and `MeetingSessionController.startConsumers` applies each verdict inside `await MainActor.run { self.latestVerdict = verdict; self.coordinator.audioRecorder.setMicGateVerdict(verdict); ... }`. While main is stalled a mute made in Teams reaches neither the probe nor the recorder, so under the regulated/NDA zero-fill gate the buffers written in that window keep audio that should have been zeroed.

**Not a MIC16 regression.** MIC16's ship note (2026-07-13, [q6-final.md](../q6-final.md)) says no cross-process AX call runs on main during a recording; that was true of `MeetingAXWindowWatcher`, the only component it moved. The probe's main-run-loop poll dates from TECH-G-MIC step 3 (2026-05-17) and its rearm walk from TECH-MIC6 (2026-06-07), so this is the sibling MIC16 left behind, not a reopen.

**Live evidence is idle-only.** The installed daemon sampled on 2026-10-25 (pid 77137, up 7 days 8 hours, 18 MB footprint, 0.0% CPU, zero wakeups in 10 s) had recorded no meeting in its lifetime and Teams was not running, so it neither confirms nor refutes this. [PERF11](./PERF11.md)'s stall event remains the instrument.

### Legs scope bullet 1 lacks (the probe)

A queue scheduler alone is not enough, and alone it is worse than the state at HEAD: the poll would run on the probe's queue while `evaluate(reason: "notification")` keeps running on main, so the stall becomes a data race on `element`, `lastEvent`, `consecutiveUnknown`, `cadence` and `resolveElement`.

1. **Confine all probe state to one serial queue,** as `AXLeaveButtonSignal` does. The poll is a `DispatchSourceTimer` on that queue (the `daemon/CLAUDE.md` rule); the value and title notification handlers hop onto it with `async` (the `AXLeaveButtonSignal.runAsync` pattern, since `AXObserverBus` always delivers on main); the TECH-MIC6 rearm `resolve()` runs there too.
2. **`start` and `stop` never block main.** No `serialQueue.sync` from main, or the stall moves to Stop (the `AXLeaveButtonSignal.runSync` shape that the engage-path task filed 2026-10-25 from DETECTION-2 ([PERF15](./PERF15.md)) removes). Hop asynchronously with a generation token captured at `start` and checked before `onChange`, so a read in flight when `NativeMuteAdapter.stop()` runs cannot inject a stale reading into the next meeting's `MicGate`. `MicGate.injectAxMuteEvent`'s doc already says Threading: any queue, and `applyMuteReading`'s read-modify-write is under `lock`, so `onChange` from the probe queue needs nothing there. `start` throws on a failed subscription at HEAD; an asynchronous start reports that as an event instead.
3. **Correction to bullet 2.** A messaging timeout set on one element applies to that element only, so the short timeout goes on the cached button and on every element the resolver returns, never on the application element alone, which would not bound the button's reads. Read the three strings with one `AXUIElementCopyMultipleAttributeValues` call, so a hung client costs one timeout per tick rather than three.
4. **Optional, same seam: take the recorder write out of `MainActor.run`.** Capture the recorder once in `startConsumers` and call `setMicGateVerdict` from the consumer task; `MeetingRecorder.setMicGateVerdict` is `gateAccess.withLock { $0.verdict = verdict }`, safe from any thread. `latestVerdict` and `silenceBackstop.ingest` are main-owned and stay inside `MainActor.run`.
5. **Optional: scope the rearm resolver** to the windows that can hold call controls (the `AXSystemDialog` call panel and Leave-bearing windows), so a Calendar window is not walked to its budget on every rearm. The review reported the window watcher's identical 1 Hz walk separately (DETECTION-6 ([PERF18](./PERF18.md))); if both are picked up, share the helper.

An alternative the review raised and the verifier accepted: drop the probe's own poll and rearm, and let `MeetingAXWindowWatcher` (already off main at 1 Hz since MIC16) be the single poller, keeping the probe as the notification fast path. If the pickup takes it, the notification handler still hops off main (leg 1) and the commit says why. Either way the poll leaves the main run loop, which also takes it off the review's UI-7 ([CONC10](./CONC10.md)) list of default-mode `Timer`s that an app-modal alert suspends. [HYG17](./HYG17.md) item 4 consolidates the main-run-loop `Timer` bodies byte for byte, `AXMuteButtonProbe`'s among them; whichever lands second rebases.

### Legs handed to the 2026-10-25 filings

- **The `ProcessAudioSignal` half of bullet 1**, and the acceptance lines that name it (its scheduler test, `AudioObjectGetPropertyData` in the post-install sample), move to the HAL-listener confinement task filed 2026-10-25 from DETECTION-7 ([CONC9](./CONC9.md)). A queue scheduler for its poll alone keeps the race that already exists between that poll and the `CoreAudioHALBus` listeners, so its threading changes in one place. This task keeps `AXMuteButtonProbe`.
- **Bullet 3 (the record-start `MeetingAXHandleBuilder.build` calls)** moves to the engage-path task filed 2026-10-25 from DETECTION-2 and MAINTHREAD-2 ([PERF15](./PERF15.md)), which also owns the discovery-time build, `ShareableContentSignal`'s initial probe and `AXLeaveButtonSignal`'s synchronous `start` and `stop`.

### Re-band proposal (for the owner, not applied)

P1. The broken promise is that Stop and the hotkeys respond during a recording: against a hung Teams this probe holds the main thread about six seconds in every seven for as long as the hang lasts, and under the regulated/NDA gate it also delays the zero-fill of a mute. The review verified it critical. The owner decides.

### Added acceptance

- `AXMuteButtonProbeTests` with the production queue (no injected scheduler): poll-driven and notification-driven evaluates and the rearm resolver all run off main (an injected probe and resolver assert `dispatchPrecondition(condition: .notOnQueue(.main))`).
- A probe or resolver blocked on a semaphore does not block `start`, `stop` or a notification delivery on the calling thread.
- `stop()` during an in-flight read drops it: no `onChange` after `stop`, and none delivered into a following `start`.
- The short timeout is applied to the cached button and to each resolved element (asserted through an injected timeout setter).
- If leg 4 is taken: a controller test that `setMicGateVerdict` is called off the main thread (a fake recorder records `Thread.isMainThread`).
- `swift test --sanitize=thread --filter AXMuteButtonProbeTests` clean.
