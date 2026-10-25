# CONC9: `ProcessAudioSignal`, `HALSystemMuteProbe` and `HALVoiceActivityProbe` change their state from the main thread and the CoreAudio bus queue with no lock, so a process-list change races the 1 Hz poll

Band origin: filed 2026-10-25 from the performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

`ProcessAudioSignal` (DET8) is the lifecycle's best end evidence and the live-call signal END13, END14 and END17 read. Its doc comment states the threading as "`start`/`stop` on main; probe and `onChange` fire on the HAL bus queue or poll timer queue". Re-read at HEAD 01e904a on 2026-10-25, the poll timer queue is main, so two threads write the same fields:

- **Main.** `ProcessAudioSignal.defaultScheduler` is `Timer.scheduledTimer(withTimeInterval: interval, repeats: true)`, and `NativeLifecycleAdapter.init` builds the signal as `ProcessAudioSignal(halBus: halBus, eventLog: eventLog)` with no scheduler, so `evaluate(reason: "poll")` runs on the main run loop at 1 Hz (5 s while the listener delivers) for the whole prompt and recording. `start` and `stop` run on main through `MeetingLifecycleCoordinator.engage` and `disengage`.
- **The bus queue.** `CoreAudioHALBus.subscribe` registers `queue.async(execute: handler)`, so the per-object `kAudioProcessPropertyIsRunningInput` listener (`self?.cadence.noteListener(); self?.evaluate(reason: "listener")`) and the process-object-list listener in `subscribeProcessObjectList` (`self.resolve(context: context); self.evaluate(reason: "list_changed")`) run on `MeetingPipeCore.CoreAudioHALBus`.
- **The shared, unguarded fields.** `resolve(context:)` runs `for token in halTokens { halBus.unsubscribe(token) }; halTokens = []; resolvedObjects = []`, then `resolvedObjects = objects` and `halTokens.append(token)`. `evaluate(reason:)` reads `probe(context, resolvedObjects)` and, on the first nil of a streak, calls `resolve` itself on whichever thread it is on. `lastValue`, `cadence`, `currentPollInterval`, `context`, `unresolvedLogged` and `reResolvedThisStreak` are written from both. No lock covers any of them, and `MeetingLifecycleCoordinator`'s END13 comment on `liveCallSignalState` already says the signal's `lastValue` "is written from those background queues with no synchronisation of its own".

**How often both run at once.** The list listener fires whenever any process starts or stops being an audio client (browser tabs, notification sounds, the meeting client's own helpers), while the poll reads `resolvedObjects` every second on main. The owner's `events.jsonl` holds six `signal`/`process_audio_object_resolved` rows for `us.zoom.xos` pid 77432 between 2026-10-13 08:09:00.117Z and 08:09:00.150Z, six re-resolves inside 33 ms in the shape of the list listener, each reassigning both arrays. [END13](./END13.md)'s 2026-09-04 incident log shows the same resolver firing mid-call on Teams (`process_audio_object_resolved` at 14:02:25 local, `object_count: 5`).

**What the race costs.**

- Swift array properties are not atomic. A main-thread read that retains `resolvedObjects`' buffer while the bus queue assigns `[]` and releases it can retain a freed buffer (EXC_BAD_ACCESS, mid-recording), and `stop()`'s `for token in halTokens` on main can iterate while `resolve` appends on the bus queue. The per-event window is tiny and the exposure is every engaged session over weeks of uptime. No MeetingPipe crash report was present in `~/Library/Logs/DiagnosticReports` on 2026-10-25, so this is a mechanism, not an observation.
- A lost or doubled `onChange` edge from the `if lastValue == value { return }` check racing itself, which matters because END14's veto and END17's dwell revert act on this signal's edges.
- A leaked listener: `resolve` on the bus queue appending a token after `stop()` on main cleared `halTokens` leaves a subscription nothing unsubscribes. Not seen in the retained log (199 `halbus`/`subscribed` against 199 `unsubscribed` in `events.jsonl`, 2026-10-12 to 2026-10-24), so also a mechanism.

**The same shape, less often.** `HALSystemMuteProbe` (Threading: `start`/`stop` on main; handlers on the bus's serial queue) runs `rebindCurrentDevice` on the bus queue on every default-input change; it unsubscribes and reassigns `muteToken` and `currentDevice` while `stop()` on main does the same, so a device change during a stop can leak the mute listener. `HALVoiceActivityProbe` has `token`, `currentDevice`, `lastValue` and `support` written by `stop()` on main and read by `evaluate` on the bus queue. Both start from `MicGate.start` on main.

**In-repo models.** `AXLeaveButtonSignal` confines its state to a private serial queue; `ShareableContentSignal` guards a `State` struct with an `NSLock` and polls on a `DispatchSourceTimer` on `pollQueue`. Off-main `onChange` is already safe downstream: `MeetingLifecycleCoordinator.ingest` hops to `engineQueue` and drops events whose captured generation no longer matches, and `MicGate` serialises `update` under its lock.

Review provenance: DETECTION-7 (verified high). [PERF10](./PERF10.md) proposed a queue scheduler for this poll; its 2026-10-25 amendment hands that leg here, because a poll moved to a third queue keeps racing the bus queue.

## Scope

The seam is each signal's own threading: [`ProcessAudioSignal.swift`](../../../daemon/Sources/MeetingPipeCore/Lifecycle/Signals/ProcessAudioSignal.swift), [`HALSystemMuteProbe.swift`](../../../daemon/Sources/MeetingPipeCore/MicGate/Probes/HALSystemMuteProbe.swift) and [`HALVoiceActivityProbe.swift`](../../../daemon/Sources/MeetingPipeCore/MicGate/Probes/HALVoiceActivityProbe.swift).

1. **`ProcessAudioSignal`: one private serial queue owns every mutable field.** The production poll becomes a `DispatchSourceTimer` on that queue (the `daemon/CLAUDE.md` rule for a repeat off main). Both bus handlers hop onto it with `async`, never `sync`: the signal queue calls `halBus.subscribe` and `unsubscribe`, which `queue.sync` onto the bus queue, so a bus handler that synced onto the signal queue could deadlock against it. `start` and `stop` from main hop with `async` and a generation token captured at `start`; `evaluate` emits `onChange` only while the token matches. The `start`-time `resolve`, a whole process-object enumeration, moves off main with it. An injected scheduler keeps the inline test path, as `AXLeaveButtonSignal`'s does.
2. **`lastValue`'s public getter** becomes a locked read or is removed; the coordinator caches its own copy (`liveCallSignalState`, END13), so check for remaining readers first.
3. **`HALSystemMuteProbe` and `HALVoiceActivityProbe`** get the same confinement, or a lock over their few fields that is never held across a HAL call or `onChange`, plus the generation check, so a rebind or listener already queued when `stop()` runs subscribes nothing and emits nothing.
4. **The Threading doc lines say what is true,** in all three types and in `MeetingLifecycleCoordinator`'s `liveCallSignalState` comment.

## Explicitly not

- What any signal decides: `PromotionEngine`, the corroboration rail and END14, END15 and END17's use of process audio are unchanged.
- `AXMuteButtonProbe`'s main-thread poll: [PERF10](./PERF10.md). The engage path that calls `ProcessAudioSignal.start` from main beside full AX walks: the engage-path task filed 2026-10-25 (DETECTION-2 ([PERF15](./PERF15.md)), MAINTHREAD-2 ([PERF15](./PERF15.md))). This task makes `start` itself non-blocking and nothing more on that path.
- `CoreAudioHALBus`, which already serialises its own state on its queue, and `ProcessAudioScanProbe` (DET12's start-side read), which runs only on discovery's scan queue.
- `SystemAudioCapture`'s unguarded statics, the sibling race in the executable target: [CONC6](./CONC6.md). Any `@unchecked Sendable` or `uncheckedState:` this adds joins [HYG10](./HYG10.md)'s allowlist with its reason.
- [HYG17](./HYG17.md) item 4 consolidates the main-run-loop `Timer` bodies, `ProcessAudioSignal`'s among them; this task removes that user, and whichever lands second rebases.
- Re-moding main-run-loop timers to `.common`, which the review's UI-7 ([CONC10](./CONC10.md)) finding proposes for timers an app-modal alert suspends: moving these polls off the main run loop takes them off that list as a side effect.

## Acceptance

- `ProcessAudioSignalTests` with the production queue: bus handlers driven from `DispatchQueue.concurrentPerform` against a fake backend and resolver while the poll fires, for at least 1,000 iterations, clean under `swift test --sanitize=thread --filter ProcessAudioSignalTests`; `evaluate` runs off main (an injected probe asserts `dispatchPrecondition(condition: .notOnQueue(.main))`); `stop()` while a resolve is in flight ends with `CoreAudioHALBus.activeSubscriptionCount == 0`; a listener delivery queued before `stop()` produces no `onChange` after it; `start` returns before a semaphore-blocked resolver finishes.
- `HALSystemMuteProbeTests`: a default-input change racing `stop()` leaves no mute subscription and emits nothing after `stop`, TSan clean. `HALVoiceActivityProbeTests`: the same for its listener.
- At least one new test is measured red against `main` before the change (the main-thread poll or the leaked subscription) and named in the commit body.
- `cd daemon && swift build` warning-clean under the existing strict-concurrency flag, `swift test` green with N new tests stated in the commit body, `bash scripts/ci-local.sh` green.
