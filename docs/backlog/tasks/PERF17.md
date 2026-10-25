# PERF17: discovery keeps scanning and AX-walking through every prompt and recording although nothing reads the result, and scans queue behind a slow one with no in-flight guard

Band origin: filed 2026-10-25 from the performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Two scheduling gaps in `MeetingDiscoveryWatcher` ([`MeetingDiscoveryWatcher.swift`](../../../daemon/Sources/MeetingPipe/MeetingDiscoveryWatcher.swift)), re-verified at HEAD 01e904a on 2026-10-25. Review findings DETECTION-4 (confirmed, medium) and DETECTION-8 (plausible, verified low).

**Scans outside `.idle` are thrown away (DETECTION-4).** The backstop poll re-arms itself and always scans:

```swift
pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
    guard let self = self else { return }
    self.sampleMicBusy() // DET3: poll-driven backstop for a missed mic KVO edge
    self.scheduleScan(triggerBundle: nil)
    self.armPollTimer()
}
```

`runScan` always calls `self.scanner.scan()`, which enumerates every running app and runs `MeetingSourceScanner.collectSignals`' control-button AX walks for every admitted candidate. The only consumer of the winner is `Coordinator`'s `discoveryWatcher.onDiscovered = { [weak self] source in self?.session.handleDiscovery(source) }`, and `MeetingSessionController.handleDiscovery` opens with `guard coordinator.stateMachine.isAcceptingPrompts else { return }`; `AppState.isAcceptingPrompts` is true only for `.idle`. The mic-in-use tier path ends in `handleMeetingStarted`'s same guard. So in `.prompting`, `.suppressed`, `.recording` and `.stopping` a scan's only output is its `candidate_dropped`, `candidate_unreadable`, `browser_tab_rejected` and `discovery_shadow_pick` log lines. For a 1 to 3 h meeting that is 300 to 3,600 full scans (12 s to 3 s cadence), each walking the very Teams tree that the 1 Hz `MeetingAXWindowWatcher` backstop, the primary mute probe and the lifecycle signal polls are reading during the call. `.stopping` lasts the whole ffmpeg merge, which grows with meeting length.

What the poll must keep doing outside `.idle`: `sampleMicBusy()`. It feeds `onMicBusyBundle`, which is DET1's level-check auto-stop (`MeetingSessionController.handleMicBusyBundle` stops a DET1 recording once its bundle no longer holds the mic) and DET3's span log. It reads `AVCaptureDevice.isInUseByAnotherApplication` and does not depend on the scan.

**No in-flight guard (DETECTION-8).** `scheduleScan` debounces 80 ms on main (`coalesceWork?.cancel()`, then `DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceWindow, execute: work)`), but once a work item fires, `runScan` does `scanQueue.async { ... let result = self.scanner.scan() ... }` with nothing recording that a scan is already running. Every poll, every launch, activation, deactivation or termination of a browser or meeting app, and every mic KVO edge adds one. The serial queue keeps them from overlapping, so this is a backlog, not a race: when scans take longer than triggers arrive (a large Teams or Chrome tree, or a hung client where each AX read waits out the 2 s system-wide messaging timeout `App.swift` sets), scans pile up while activity continues and each delivers its winner to `handleDiscovery` late. The verifier bounded it: against a hung Teams a scan costs about four 2 s timeouts (titles, then one `listWindows` per walk pass), around 8 s, under the 12 s idle poll, so the queue drains once activity stops, and "unbounded" in the finding is overstated. A stale winner delivered late can still start an engage on main.

## Scope

1. **A pure single-flight gate.** Lift the scheduling decision into a small pure type beside `DiscoveryScanCadence` (the watcher itself has no harness: it needs `NSWorkspace` and AVFoundation), holding main-confined `scanInFlight` and `scanPending`. A request while a scan runs marks pending and returns; when that scan's main hop completes, at most one follow-up runs. `runScan` consults it before dispatching to `scanQueue`, and the existing completion hop in `runScan` (the `DispatchQueue.main.async` that calls `onDiscovered`) clears it.
2. **No scans outside `.idle`.** Give the watcher one main-queue input saying whether the session accepts prompts, a closure `Coordinator` sets to `stateMachine.isAcceptingPrompts` beside `onDiscovered` (the watcher still learns nothing else about the state machine, per the ARCH6 note in `MeetingSourceScanner`). While it reads false, the poll keeps `sampleMicBusy()` and its own re-arm and skips `scheduleScan`; the workspace observers and the mic KVO keep `noteActivity()` and `sampleMicBusy()` and skip their scan the same way. On the idle transition, `Coordinator`'s existing `stateMachine.onIdleTransition` hook also calls `discoveryWatcher.refreshNow()`, so the first post-recording scan runs at once instead of up to 12 s later: DET13's cooldown candidate, DET14's cooldown grace and END17's resume window (`resumeCandidate.applies(to:at:)` in `handleDiscovery`) all read the first idle sightings.
3. **The mic-in-use tier while not idle.** `evaluateMicInUseTier` runs after each scan's main hop. With scans skipped it stops running, and a mic-busy span that opened during a recording could then raise a DET1 prompt as soon as the recording ends. While not idle, latch any open span as already handled (set `micTierFiredForSpanSince` to the span's `since`, the tier's own once-per-span latch), so a span seen during a recording never prompts afterwards; a span that opens after the return to idle still can. State it as behaviour in the tier's doc comment.

## Explicitly not

- Scanning at a slow cadence (60 s) during recordings instead of not at all. Nothing reads the result outside `.idle`; a slow scan still costs walks for log lines.
- Changing `DiscoveryScanCadence`'s 3 s and 12 s intervals or the 80 ms coalesce window.
- The cost of a scan when it does run (the walk gate, three passes per window, the browser Leave walk): the reopened [PERF6](./PERF6.md). The in-call mute backstop's own 1 Hz walk: its own task from the same review (DETECTION-6 ([PERF18](./PERF18.md))).
- Moving `sampleMicBusy` off main: item 6 of [PERF13](./PERF13.md), measured cheap.
- Backing off a candidate whose last scan returned `kAXErrorCannotComplete` (the finding's optional extra). The single-flight gate already bounds the hung-client case to one scan in flight and one pending; a per-candidate backoff is a detection change with its own evidence owed.
- [DET10](./DET10.md)'s mic-busy input itself, which has never produced a span; item 3 only keeps the tier's latch honest.

## Acceptance

- Pure gate tests (MeetingPipeTests, beside `DiscoveryScanCadenceTests`): a request with nothing in flight starts a scan; a request while one is in flight starts nothing and marks pending; completion with pending starts exactly one follow-up; five requests during one scan still produce one follow-up; completion with nothing pending starts nothing; a request, or a pending follow-up, while the session is not accepting prompts starts nothing; the idle transition requests a scan.
- Item 3: with the session not idle and a span open, the tier latches that span; after the transition to idle that span raises no `mic_in_use_prompt`, and a new span still can.
- `CoordinatorWiringFenceTests`: `Coordinator` sets the watcher's session input and calls `refreshNow()` from `onIdleTransition`, so neither line can go missing silently.
- `cd daemon && swift build` and `swift test` green, new test count in the commit body; `bash scripts/ci-local.sh` green.
- Evidence after install (confirms, does not gate): for a recorded Teams call, `events.jsonl` carries no `candidate_dropped` or `discovery_shadow_pick` rows between its `recording_started` and its `state_change` back to `idle`, and the next Teams call still prompts.
