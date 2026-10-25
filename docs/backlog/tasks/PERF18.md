# PERF18: the mute backstop re-walks every Teams window once a second for the whole recording, including the Calendar or chat window that never has a mute button

Band origin: filed 2026-10-25 from the performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Review finding DETECTION-6 (confirmed, high), re-verified at HEAD 01e904a on 2026-10-25.

`MeetingAXWindowWatcher` ([`MeetingAXWindowWatcher.swift`](../../../daemon/Sources/MeetingPipe/MeetingAXWindowWatcher.swift)) is the authoritative mute-state backstop for native recordings (TECH-C14, rebuilt 2026-05-29). Its type comment states the design: "Every `pollInterval` it re-resolves the live mute button(s) via `MeetingAXHandleBuilder.findMeetingWindowMuteButtons` (a fresh AX-tree walk ...)". `defaultPollInterval` is `1.0`, and `consume(_:)` re-arms at the end of every poll (`cancelPoll = scheduler(pollInterval) { [weak self] in self?.poll() }`), so the rate is 1 Hz plus the walk time, for the whole recording.

Each poll's resolver is `MeetingAXWindowWatcher.readMuteStates(axApp:bundleID:catalogue:)`, which calls `MeetingAXHandleBuilder.findMeetingWindowMuteButtons(in:bundleID:catalogue:)` ([`MeetingAXHandleBuilder.swift`](../../../daemon/Sources/MeetingPipe/MeetingAXHandleBuilder.swift)):

```swift
for window in listWindows(axApp: axApp) {
    guard let mute = findButton(in: window, depth: 0, predicate: { el in
        matchesMute(app: app, catalogue: catalogue, element: el)
    }) else { continue }
    let hasLeave = findButton(in: window, depth: 0, predicate: { el in
        matchesLeave(bundleID: bundleID, element: el)
    }) != nil
    entries.append((mute, isCallPanel(window), hasLeave))
}
```

So every second: one window list; a Mute DFS per window that stops at the first hit or at the per-walk budget (`maxNodes = 4000`, two cross-process reads per node plus three `textBlob` reads per button or checkbox); a Leave DFS of each window that has a mute button; an `isCallPanel` subrole read per hit window; and three reads per found button (`AXMuteButtonProbe.defaultProbe`). The window with no mute button is the expensive one, because nothing stops its walk early, and the live dumps recorded in `findMeetingWindowMuteButtons`' own doc comment show one in every call, backgrounded and focused alike: `win[1] "Calendar | ..." subrole=AXStandardWindow (no mute button)`. A 2 to 3 h meeting is about 7,200 to 10,800 such polls.

**Where the cost lands.** MIC16 (2026-07-13) moved the walk onto `MeetingSessionController.axWalkQueue`, so MeetingPipe's main thread is safe. The cost is now (a) Teams' main thread, which services every AX request during the call the owner is in, and (b) the shared serial `axWalkQueue`: `rescueProvisionalEnd`'s Leave walk and `armLifecycleLeaveButton`'s `MeetingAXHandleBuilder.build` both queue behind whatever window-watcher walk is running. The per-walk node count of a Teams call has never been measured; `maxNodes`' comment ("happy path is well under 100 nodes") was written about a meeting window, not a Calendar or chat window.

## Scope

The seam is the resolver the watcher already injects (`stateResolver`, defaulting to `readMuteStates`), so the watcher's fusion, blind-clear and VAD-contradiction logic and its existing tests do not change.

1. **A per-recording mute-control cache behind the resolver.** Owned by the default resolver closure built in `MeetingAXWindowWatcher.init` and confined to `axWalkQueue` (the resolver only runs there in production, so it needs no lock). Per window it holds whether that window had a mute button, the button element, whether it had a Leave control, and the window's subrole. Each poll lists the windows (one read) and reads each window's subrole (one read each); when the window set and every subrole are unchanged, it reads only the cached buttons (the three probe reads each) and applies `MeetingAXHandleBuilder.scopeToLiveControl` to the cached entries, so the MIC10 part 1 rule stays the single picking rule.
2. **When to re-walk.** A full `findMeetingWindowMuteButtons` walk on the first poll; whenever the window set or any subrole changes (the compact call panel appears as an `AXSystemDialog` and is destroyed again as Teams is backgrounded and focused, MIC10 part 1); on the poll after a cached button first reads `.unknown` or fails, at most once per backstop interval while it keeps doing so, so a label missing from `MuteLabels.toml` cannot put the walk back at 1 Hz; and on a slow backstop (10 to 15 s, the constant documented beside it) so a window that gains a mute button without a window-set change is still found. Never treat the cache as complete across a window-set change.
3. **One counter for the field check.** `mute_poller_started` already exists; emit `micgate`/`mute_poller_stopped` from `stop()` with `polls` and `full_walks`, so the reduction is readable from `events.jsonl` after the owner's next call. Document it in `CONVENTIONS.md` in the same commit.

## Explicitly not

- Changing the 1 Hz poll interval, the fusion rule, `DisagreementPolicy`, the blind-clear threshold or MIC10 part 2's VAD contradiction. The cache changes how the buttons are found, not what is done with their readings.
- The primary `AXMuteButtonProbe`, its main-thread poll and its 5 s re-resolve walk: [PERF10](./PERF10.md) and review finding DETECTION-1 ([PERF10](./PERF10.md)). If that work makes this watcher the single mute poller, this cache is what makes that affordable; coordinate the order.
- Batching the three probe reads through `AXUIElementCopyMultipleAttributeValues`, or lowering `maxNodes`: measure with item 3 first.
- Subscribing to window-created or destroyed notifications instead of listing windows each poll. The type comment records why per-element subscriptions failed here before (one `AXObserver` per PID in `RealAXBackend`, `kAXErrorNotificationAlreadyRegistered`), and a list is one read per poll.
- Discovery's own walks: the regression of PERF6's walk gate (PERF6 shipped 2026-07-11, see [q6-final.md](../q6-final.md); the review's DETECTION-3 and DETECTION-5, held on 2026-10-25 for the owner's reopen decision) and the discovery-scheduling task filed from the same review (DETECTION-4 ([PERF17](./PERF17.md))).

## Acceptance

- Cache tests (MeetingPipeTests) with a fake window lister, walker and button reader that count calls: ten steady polls run one full walk, ten window lists and ten reads per cached button; a window added or removed triggers a full walk on that poll; a window whose subrole changes to `AXSystemDialog` triggers a full walk and the panel's button becomes the only one read; a cached button reading `.unknown` triggers one full walk on the next poll and no second one before the backstop interval while it keeps reading `.unknown`; the backstop walks after its interval with nothing changed.
- `MeetingAXWindowWatcherTests` green unchanged (they inject `stateResolver`), and the `scopeToLiveControl` tests in `MeetingAXHandleBuilderTests` green.
- `cd daemon && swift build` and `swift test` green, new test count in the commit body; `python3 scripts/truth_fences.py both` green with the new event's `CONVENTIONS.md` row; `bash scripts/ci-local.sh` green.
- Evidence after install (confirms, does not gate): the owner's next Teams call's `mute_poller_stopped` row shows `full_walks` a small fraction of `polls` (the backstop alone gives about one in ten to fifteen), recorded in this file, and a `sample MeetingPipe 20` during a call shows the `com.meetingpipe.session.ax-walk` queue mostly idle.
