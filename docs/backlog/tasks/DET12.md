# DET12: Revive the start-side process-audio corroborator for native apps

Band origin: filed 2026-08-05, split out of [DET8](../q6-final.md) at landing when its own Context turned out to be stale. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

[DET8](../q6-final.md) landed 2026-08-05 (`c773f36`) and revived per-process mic attribution **end-side only**. `ProcessAudioSignal` now enumerates `kAudioHardwarePropertyProcessObjectList`, matches objects by dotted bundle prefix with PID ancestry as fallback, ORs `isRunningInput` across matches, caches the resolution and refreshes it lazily on an unresolved streak or a list-change notification. `usesProcessAudio` is true for Teams and Zoom, and `PromotionEngine` consumes `processAudioIsRunningInput` behind the `requiresCorroboration` rail.

DET8's spec asserted the start side would come back for free: its Context claimed `MeetingSourceScanner.collectSignals` "already calls `ProcessAudioSignal.defaultProbe` and feeds the scorer (weight 3, a `shouldWalkControlAX` precondition, and the required corroborator for bare-brand-token browser titles whose death filed DET6)". That was written against code the DET2 cleanup had already deleted on 2026-07-20. Both the `collectSignals` probe call and `MeetingSourceScorer.hasCorroboratingSignal`'s process-audio disjunct are gone, so there is nothing to revive without writing new start-side code. The DET8 session verified this at landing and deliberately deferred rather than building against a stale premise.

The signal itself is measured and sound. Two owner-run live Teams calls on 2026-08-05, recorded in the DET8 amendment of [`docs/spikes/det2-process-tap-attribution.md`](../../spikes/det2-process-tap-attribution.md), both showed `com.microsoft.teams2.modulehost` reading `isRunningInput=true` at join and false at leave, with all three pre-registered bars passing. The headroom is the point: the process-audio signal preceded the daemon's own recording start by **8.3 s** in run 1 (12:15:16.679 against 12:15:25.003) and **2.1 s** in run 2 (12:24:17.047 against 12:24:19.137). The lead varies but the ordering held in both runs.

A second payoff, and the reason this is not purely a latency task. [DET11](../q6-final.md) established that `MeetingSourceScanner.swift:253` gates **every** native signal behind `if axTrusted`, and `MeetingSourceScorer.swift:85` then drops the zero-signal candidate, so denying Accessibility silently kills start-detection for native apps rather than only end-detection. Process audio needs no Accessibility and no Screen Recording grant: DET8's 2026-07-30 enumeration resolved from a disclaimed harness shell holding no TCC grant at all. A start-side read placed **outside** the `axTrusted` gate would therefore give a native candidate a real signal on an Accessibility-denied machine, where today it has none. That does not close DET11, whose scope is the doc-truth half, but it changes the underlying behaviour DET11 describes.

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

## Progress (2026-08-18, partial)

Shipped: all three seams, the tests, and the doc sync. Owed: the behavioural bar, which is a log read on the owner's next Teams calls rather than anything a session can close.

**Every line citation in the Context and Scope sections above had rotted before this was picked up**, which is the joke the task was already making about itself. DET6 landed hours earlier and rewrote 221 lines of `MeetingSourceScanner.swift`, so `:243`, `:253` and `:146` all pointed somewhere else, and `MeetingSourceScorer.swift:53` / `:85` had moved too. Every symbol was re-resolved by grep and everything below cites by type and function name (HYG6).

**Seam 1, the cache.** `ProcessAudioScanProbe`, in `MeetingPipeCore/Lifecycle/Signals/` beside DET8's `ProcessAudioSignal`. It shares that type's `match`, `readIsRunningInput` and `reduceIsRunningInput` rather than growing a second spelling of any of them, so the two ends of a meeting cannot drift on what the property means; `readIsRunningInput` went from `private static` to `static` for exactly that, and nothing else widened. The difference is caching shape. End-side there is one detected app and a HAL list-change listener to say when a cached object ID went stale, so `ProcessAudioSignal` resolves once and keeps it. Start-side there are N candidates in a synchronous pass with no listener, so `beginScan` (called once at the top of `MeetingSourceScanner.enumerateCandidates`) drops the snapshot, the first `isRunningInput` of the pass takes a new one, and every later candidate matches against it. Two properties fall out and are pinned: the enumeration is lazy, so a scan whose candidates are all outside the read set costs no HAL work at all, and it is once per SCAN rather than once per process, because DET8's probe measured `replayd` present under a different object ID with the same PID nine minutes later.

**Seam 2, the disjunct.** `MeetingSourceCandidate.Signals.processAudioIsRunningInput`, named after the property and after DET8's end-side signal so the two grep together. `MeetingSourceScorer.Weights.processAudioIsRunningInput` is 3, the pre-DET2 value restored rather than re-derived. It is counted by `distinctSignalCount` and OR-ed by `hasCorroboratingSignal`.

The native-only restriction is **one** mechanism rather than two. `MeetingSourceScanner.readsProcessAudio(bundleID:kind:)` is the single gate on who is read at all, and it asks `NativeLifecycleConfig.usesProcessAudio(bundleID:)` rather than keeping a second list beside the end side's, so "turning Slack on is a measurement, not a flag flip" stays one fact for both ends. Browsers and Chromium PWAs answer false because they hold no native config, and Webex and spark answer false for the ultrasound reason that predates DET2. `hasCorroboratingSignal` therefore does not re-ask about kind: the field can only ever be true for a native, and a second copy of that rule is how two copies drift. Pinned by three tests naming what may never carry the signal. `MeetingSourceScanner.decideBrowserAdmission` is untouched: the bare-brand-token gate is exactly as DET6 left it, and a browser on the mic still names only the browser and never which tab.

**Seam 3, the walk gate.** `MeetingSourceScanner.shouldWalkControlAX` takes `processAudioIsRunningInput` again. It is the fourth admission and the only one that is evidence a call is happening rather than a cheap guess that one is plausible, so a Teams window renamed out of the recognizer while backgrounded in a multi-native scan now earns its control walk on the strength of the mic.

**The `isConfidentNativeMeeting` decision, made deliberately: process audio counts toward that bar**, by being counted in `distinctSignalCount` rather than carved out of it. Three reasons. The bar was raised by DET5 to reject signals that LINGER after a call (a post-call Leave button, a hub mic toggle), and process audio is the one signal in the set measured not to: every Teams object read false 0 s and 11.4 s after the leave across DET8's two live calls. The single app known to hold the mic past the call is Webex, and it is excluded from the read entirely rather than discounted here. And a separate confidence count would have to stay in step with the count `pickBest`'s zero-evidence filter already uses, which has to include this signal or the DET11 payoff below does not exist at all. Consequence, stated both ways: title plus audio now clears the bar where title alone never does, and audio alone still does not.

**The DET11 half is real and partial.** The read sits outside `MeetingSourceScanner.collectSignals`' `if axTrusted` block and needs neither Accessibility nor Screen Recording, so a Teams or Zoom candidate actually on the mic under a denied grant now carries one real signal. It stops being a zero-evidence `candidate_unreadable` and becomes a `candidate_dropped` with its evidence attached, which is a better line in `events.jsonl` rather than a lost one, and `MeetingSourceScanner.unreadableNatives` narrows accordingly. It does **not** make an Accessibility-denied machine detect a meeting: one signal never clears `isConfidentNativeMeeting`, so the owner walkthrough's optional check ("a native Teams call is still detected with Accessibility revoked") does not pass and is not claimed. Lowering that bar is a separate decision with its own measurement owed. DET11's own corrected user-facing copy stays true and was not touched; what changed is `ARCHITECTURE.md`'s claim that `collectSignals` "gates every native signal on AX trust", corrected in the same commit.

**Events.** No new action and no new category: `discovery_shadow_pick` and `candidate_dropped` each gained a `process_audio_is_running_input` attribute, because a line that enumerates four of five signals is a misleading picture, and this is the signal an Accessibility-denied native arrives with on its own.

**Tests: 22 added.** 9 in a new `ProcessAudioScanProbeTests` (the cache, and what a reading means), 8 in `MeetingSourceScannerTests` (the read set, the walk-gate admission, the enumeration count, the AX-denied candidate), 5 in `MeetingSourceScorerTests` (the corroboration pair, the confidence-bar decision, the lone-native win, the Webex fence). The enumeration test is the acceptance one: a counting fake enumerator, two candidates in one scan, one enumeration, then a second `beginScan` proving it is per scan and not per process.

**Not done, and deliberately.** Webex and Slack stay outside the read set. `hasAudioLeg` was not renamed even though DET12 makes its doc comment more awkward, since it now differs from the read set in the Slack case; the comment says so and a rename is not this task's change. And the lone-native bar was not lowered to let process audio win alone.

**Remainder, owner-owed.** The behavioural bar in Acceptance: `events.jsonl` showing the scan attributing a process-audio signal to the Teams candidate at or before the scan that produces the confident winner. That is read from the log after the owner's next Teams calls, so it cannot be closed by the session that shipped this. Read it with `mp logs --action discovery_shadow_pick` and `mp logs --action candidate_dropped`, both of which now carry `process_audio_is_running_input`.

## Behavioural bar: PASSED, read from the log 2026-08-19

Four Teams calls across one working day, none staged. The bar is met, and the day also produced a controlled natural experiment better than the bar asked for.

**The passing scan, 15:03:16.348 UTC.** `discovery_shadow_pick` picked Teams as the confident winner **carrying `process_audio_is_running_input: true` on the winning scan itself**, not after it. `coordinator/ax_handles_built` did not run until 15:03:16.895, so the process-audio attribution led the AX control walk by **547 ms** and the prompt by 828 ms. The bar asked for "at or before"; this is at.

**The natural experiment, which is the stronger result.** Every Teams scan on 2026-08-19, 17 rows:

| Rows | Verdict | title | mute | leave | toolbar | process audio | score |
|---|---|---|---|---|---|---|---|
| 13 (00:45 to 14:23) | `candidate_dropped` | true | false | false | false | **false** | 2 to 3 |
| 1 (07:30:33) | winner | true | **true** | false | false | false | 4 |
| 1 (07:46:45) | winner | true | **true** | **true** | false | false | 7 |
| **1 (15:03:16)** | **winner** | true | false | false | false | **true** | **5** |

The last row and the first thirteen have an **identical AX signal set** and differ in exactly one bit. Those thirteen were dropped as `no_confident_winner`; the fourteenth became the winner. This is DET12's own acceptance case observed on real data rather than in a fake: *"a native candidate whose only non-title signal is a positive process-audio read clears `hasCorroboratingSignal`; the same candidate with a negative read does not."* Both halves, same app, same day, one variable.

**What the other two winners say, and why they are not a failure.** The 07:30 and 07:46 winners were picked on mute and leave with process audio still false, so on those calls the AX controls won the race. That is the expected division of labour rather than a miss: the AX signals appear when Teams draws its call UI, and the mic can go hot slightly later. Process audio is not there to beat AX on a healthy machine; it is there for when AX has nothing, which is exactly the 15:03 row.

**A hypothesis formed on the first two calls and refuted by the third, recorded so it is not re-formed.** After 07:30 and 07:46 both missed, the reading offered was that the call UI always precedes the mic going hot, so the bar's "at or before the winner" clause might be unsatisfiable on an AX-trusted machine. **That is wrong.** The 15:03 call has the mic hot while the AX walk still finds nothing, which is the opposite ordering. Two consecutive misses were not enough to characterise the race, and the conclusion drawn from them was premature.

**The DET11 half is now more than the partial the ship note claimed.** That note said the read makes an Accessibility-denied candidate carry one real signal but that "one signal never clears `isConfidentNativeMeeting`". The 15:03 row shows title plus audio clearing the bar with **no** AX control signal present at all, which is the consequence the `isConfidentNativeMeeting` decision predicted in as many words: "title plus audio now clears the bar where title alone never does". Measured, not just designed. This still does not prove detection survives a *revoked* Accessibility grant, since `ax_trusted` was true throughout and the AX walk merely had not found the controls yet; that check remains the walkthrough's optional step.

**No engineering remains.** The bar was the last item.
