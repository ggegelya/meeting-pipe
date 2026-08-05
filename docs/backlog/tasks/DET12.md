# DET12: Revive the start-side process-audio corroborator for native apps

Band origin: filed 2026-08-05, split out of [DET8](../q6-final.md) at landing when its own Context turned out to be stale. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

[DET8](../q6-final.md) landed 2026-08-05 (`c773f36`) and revived per-process mic attribution **end-side only**. `ProcessAudioSignal` now enumerates `kAudioHardwarePropertyProcessObjectList`, matches objects by dotted bundle prefix with PID ancestry as fallback, ORs `isRunningInput` across matches, caches the resolution and refreshes it lazily on an unresolved streak or a list-change notification. `usesProcessAudio` is true for Teams and Zoom, and `PromotionEngine` consumes `processAudioIsRunningInput` behind the `requiresCorroboration` rail.

DET8's spec asserted the start side would come back for free: its Context claimed `MeetingSourceScanner.collectSignals` "already calls `ProcessAudioSignal.defaultProbe` and feeds the scorer (weight 3, a `shouldWalkControlAX` precondition, and the required corroborator for bare-brand-token browser titles whose death filed DET6)". That was written against code the DET2 cleanup had already deleted on 2026-07-20. Both the `collectSignals` probe call and `MeetingSourceScorer.hasCorroboratingSignal`'s process-audio disjunct are gone, so there is nothing to revive without writing new start-side code. The DET8 session verified this at landing and deliberately deferred rather than building against a stale premise.

The signal itself is measured and sound. Two owner-run live Teams calls on 2026-08-05, recorded in the DET8 amendment of [`docs/spikes/det2-process-tap-attribution.md`](../../spikes/det2-process-tap-attribution.md), both showed `com.microsoft.teams2.modulehost` reading `isRunningInput=true` at join and false at leave, with all three pre-registered bars passing. The headroom is the point: the process-audio signal preceded the daemon's own recording start by **8.3 s** in run 1 (12:15:16.679 against 12:15:25.003) and **2.1 s** in run 2 (12:24:17.047 against 12:24:19.137). The lead varies but the ordering held in both runs.

A second payoff, and the reason this is not purely a latency task. [DET11](DET11.md) established that `MeetingSourceScanner.swift:253` gates **every** native signal behind `if axTrusted`, and `MeetingSourceScorer.swift:85` then drops the zero-signal candidate, so denying Accessibility silently kills start-detection for native apps rather than only end-detection. Process audio needs no Accessibility and no Screen Recording grant: DET8's 2026-07-30 enumeration resolved from a disclaimed harness shell holding no TCC grant at all. A start-side read placed **outside** the `axTrusted` gate would therefore give a native candidate a real signal on an Accessibility-denied machine, where today it has none. That does not close DET11, whose scope is the doc-truth half, but it changes the underlying behaviour DET11 describes.

## Scope

Three seams, all in the start-side scan.

**1. A caching strategy before anything is wired into the scan.** This is the precondition, not an optimisation. The old probe cost one CoreAudio HAL round-trip per candidate process per scan and DET2's cleanup removed it partly on that cost. Resolution is now a **whole-list enumeration** plus per-object property reads, which is heavier still, and the scanner runs it per candidate per scan. DET8 already built the caching primitives end-side (resolution cached, refreshed on an unresolved streak or a `kAudioHardwarePropertyProcessObjectList` change notification); this task extends that cache so one enumeration per scan serves every candidate, rather than re-enumerating per candidate. `MeetingSourceScanner.collectSignals` (`daemon/Sources/MeetingPipe/MeetingSourceScanner.swift:243`) is the seam.

**2. The native corroboration disjunct.** `MeetingSourceScorer.hasCorroboratingSignal` (`daemon/Sources/MeetingPipe/MeetingSourceScorer.swift:53`) currently ORs `callingControlsToolbar`, `leaveButton`, `muteButton` and the never-set `shareableContentActive`. Add process audio back as a disjunct for **native** candidates. The bar exists because `titleMatch` alone is unreliable for natives (Teams and Slack title recognizers match chat threads and calendar windows), and a per-process mic read is a strictly better answer to "is this app in a call" than a title. Note `isConfidentNativeMeeting` is a separate, higher bar used for the lone-native prompt gate and DET5's stale-control defence; decide deliberately whether process audio counts toward `distinctSignalCount` there, and record the decision either way.

**3. The `shouldWalkControlAX` precondition.** The probe was one of the PERF6 gate preconditions before the DET2 cleanup removed it. Restoring it lets a positive audio read admit a candidate to the control walk that today is gated on cheaper and weaker evidence.

Place the read outside the `if axTrusted` gate, so the DET11 mitigation above is real rather than incidental.

## Explicitly not in scope

**The browser bare-brand-token admission.** `MeetingSourceScanner.swift:146` rejects a title that merely contains "webex" / "microsoft teams" / "huddle" because it cannot be told from a doc page about those products. END5 originally admitted such a title when live process audio corroborated it. Re-admitting it is [DET6](DET6.md)'s call, gated on DET6's own measurement, and DET6.md already records it that way. The risk profiles differ and that is why the split exists: a native app's helper process on the mic is high-precision evidence that this app is in a call, while a browser holding the mic names only the browser and not which tab, so the same read that is trustworthy for Teams is ambiguous for Chrome. DET12 must not widen the browser gate as a side effect, and DET6 may consume DET12's cache once it lands.

**Webex and Slack.** `usesProcessAudio` stays false for both, as DET8 shipped it. Cisco holds the mic open post-call for ultrasound (a carve-out predating DET2), neither was probed, and `Coordinator` builds both adapters without a `halBus`, which the initializer's precondition requires for a true flag. Turning either on is a measurement, not a flag flip.

**Re-litigating DET8's end-side design.** The `requiresCorroboration` rail on `processAudioIsRunningInput` stays. Two confirmed in-call mutes across the two 2026-08-05 calls produced zero `isRunningInput` transitions, so the mute half of the rail's rationale is measured as a non-risk, but the churn half stands: `replayd` was absent from run 1's initial enumeration, appeared as `obj 162`, and was already resident as `obj 160` in run 2 under the same pid, so an audio client that re-registers gets a new object ID.

## Acceptance

`swift build` and `swift test` green, with new unit tests covering: a native candidate whose only non-title signal is a positive process-audio read clears `hasCorroboratingSignal`; the same candidate with a negative read does not; the enumeration runs once per scan rather than once per candidate (assert against a counting fake resolver, with two or more candidates in the scan); and a candidate on an `axTrusted == false` scan still carries a process-audio signal rather than the zero-signal set that `pickBest` drops today.

`python3 scripts/truth_fences.py both` green. No new event category is expected, since `process_audio_*` actions already live under `signal`; if a new action is added, the fence is the check.

Do not pin an absolute suite total in a later edit of this file: state the bar as green plus the count of tests the task adds.

Behavioural bar, checkable on the owner's next Teams calls after it ships: `events.jsonl` shows the scan attributing a process-audio signal to the Teams candidate at or before the scan that produces the confident winner, rather than only after recording has started. The DET8 probe measured 8.3 s and 2.1 s of headroom, so a start-side read that never precedes the winner means the wiring is wrong even if the tests pass.

## Owner walkthrough

None needed beyond normal use. This is an internal detection change with no new surface, and the behavioural bar above is read from `events.jsonl` by the session that ships it rather than judged by the owner. If the DET11 mitigation is claimed, the one owner-visible check is that a native Teams call is still detected with Accessibility denied, which the owner can test by revoking the grant in System Settings, Privacy and Security, Accessibility.
