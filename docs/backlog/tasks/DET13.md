# DET13: the reprompt cooldown drops the live candidate, so a back-to-back meeting gets no prompt and a manual Record arms no end detection

Band origin: filed 2026-08-10 from the owner's 2026-08-04 testing notes, describing the 12:27 and 12:33 pair: "I had two meetings in a row... first meeting recording was fine (12.27). then I ended the meeting (recording processing started) and immediately joined another. no prompt happened during the processing, but meeting was in an active phase, and I have no chance to wait. so I click myself a record button. it recorded it disconnected from MS teams. when meeting ended - recording didnt stop (obviously cause it was not connected to teams) I want to mitigate it somehow in a good way. Either have a possibility to run a meeting directly connected to the app that currently uses mic, or something else, I am not sure 100%. I need more reliable UX in this topic." END9's spec already names this cooldown under "Observed but not filed here". Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What happened, from the owner's event log

All times local (UTC+3); `events.jsonl` stores UTC and the stems are local, which is why the two disagree by three hours.

| Time | Event |
|---|---|
| 12:27:36 | `lifecycle starting`, `prompt_shown`, Teams native pid 91771 |
| 12:27:39 | `recording_started` `20260804-122739.wav`, workflow `Personal` |
| 12:32:40 | `ending_provisional` `ax_leave_button_invalid`, confirmed, `ended`. A genuine end: the owner left the call. |
| 12:32:41 | `recording_stopped`, `pipeline_queued`, `pipeline_started` |
| **12:33:03** | `recording_started` `20260804-123303.wav`, **`bundle_id: "manual"`** |
| 12:33:15 | `pipeline_succeeded` for the first meeting |
| 12:48:38 | `state_change recording -> stopping`, hand-stopped after **15 m 35 s** |

Between 12:32:41 and 12:33:03 the owner joined a second Teams call and **no `lifecycle starting` and no `prompt_shown` was emitted at all**. 22 seconds elapsed, well inside the 60 s window below.

The consequence is on disk. `20260804-123303.meta.json` carries `source_bundle_id: null` and `source_kind: null`, while the detected meetings either side of it (`20260804-122739`, `20260806-163013`) both carry `com.microsoft.teams2` / `native`. So the second meeting was recorded with no app identity, and therefore with no AX end anchor, and it ran until the owner noticed and stopped it by hand.

## The chain, re-derived from source on 2026-08-10

`handleDiscovery` ([MeetingSessionController.swift:1117](../../../daemon/Sources/MeetingPipe/MeetingSessionController.swift#L1117)) has two suppression branches and they are not symmetric.

The **skip-latch** branch keeps the sighting ([:1136](../../../daemon/Sources/MeetingPipe/MeetingSessionController.swift#L1136)):

```swift
if coordinator.stateMachine.isSkipLatched(bundleID: source.bundleID) {
    coordinator.stateMachine.refreshSkipLatch(bundleID: source.bundleID)
    coordinator.stateMachine.noteSuppressedCandidate(source)   // DET7
    return
}
```

Its own comment states exactly why, and it is this task's problem stated in advance: keep the candidate so a manual start "can attach to the meeting the user skipped instead of recording `source: nil`, which resolves the default workflow, writes no source into the sidecar, and arms no AX end detection."

The **cooldown** branch, immediately below, does not ([:1140](../../../daemon/Sources/MeetingPipe/MeetingSessionController.swift#L1140)):

```swift
if coordinator.stateMachine.isCoolingDown(
    bundleID: source.bundleID,
    cooldownSec: coordinator.liveRepromptCooldownSec
) {
    return
}
```

A bare `return`. The cooldown is `repromptCooldownSec = 60` ([ConfigDefaults.swift:35](../../../daemon/Sources/MeetingPipe/ConfigDefaults.swift#L35)), anchored on the previous meeting's end, so for a full minute after any recording stops the same bundle produces neither a prompt nor a retained candidate.

`startManual` ([:201](../../../daemon/Sources/MeetingPipe/MeetingSessionController.swift#L201)) is already the right shape and is the reason the fix is cheap:

```swift
func startManual(summaryMode: SummaryMode, trigger: String) {
    if let candidate = coordinator.stateMachine.liveSuppressedCandidate() {
        recordAttached(to: candidate, summaryMode: summaryMode, trigger: trigger)
    } else {
        beginRecording(source: nil, summaryMode: summaryMode)
    }
}
```

So every manual entry point (menu row, hotkey, `meetingpipe://record`) already attaches when a candidate exists. On 2026-08-04 it took the `else`.

**Storing the candidate in the cooldown branch is necessary but not sufficient**, and this is the part a pickup must not miss. `liveSuppressedCandidate()` ([DetectionStateMachine.swift:126](../../../daemon/Sources/MeetingPipe/Coordination/DetectionStateMachine.swift#L126)) reads:

```swift
guard isSkipLatched(bundleID: candidate.source.bundleID, now: now) else {
    suppressedCandidate = nil
    return nil
}
```

Its lifetime *is* the skip latch's, deliberately, as its comment explains. In a cooldown there is no skip latch, so the read would still return nil however the write was added. The candidate's lifetime has to cover both suppression reasons.

## The 60 s window is directly observable, twice

Two independent re-prompts in the corpus land at exactly 65 s after the preceding end, which is the cooldown expiring and not a fresh detection:

- `20260804-133028` ended 13:30:49, next `lifecycle starting` 13:31:54.
- `20260806-163013` ended 16:31:59, next `lifecycle starting` 16:33:04.

END9 records the same clustering from the other direction and warns against a misreading worth repeating here: a re-detect gap is **floored** by this cooldown, so it must never be quoted as an accessibility-blackout duration.

## Scope

Two changes, and they are separable. The second is the owner's "more reliable UX" ask and is the larger design question.

**1. Make a cooldown-suppressed sighting attachable.** Store the candidate in the cooldown branch, and give `suppressedCandidate` a lifetime that covers a cooldown as well as a skip latch, so `liveSuppressedCandidate()` returns it. Then the owner pressing Record during the cooldown gets a recording attached to Teams: the workflow rules see the app, the meta sidecar carries its identity, and `armLifecycleLeaveButton` has something to arm on, which is what makes the recording stop when the call ends. This is the half that turns the reported incident from data-with-no-end-detection into an ordinary recording, and it should ship first and alone if the second half stalls.

Derive the new lifetime from the live `DiscoveryScanCadence` rather than hardcoding a second grace, per DET9's rule. Note the misattribution risk DET9's comment names: a candidate that outlives the meeting lets a later manual start attribute itself to a dead call. Bound it accordingly; the cooldown is only 60 s, so the window is naturally small.

**2. Decide whether a back-to-back meeting should be prompted at all.** The cooldown exists for a real reason (END9's false ends produce a re-detect within seconds, and prompting again immediately is worse than not), so removing it is not the answer. The shape worth evaluating: distinguish "the same call we just stopped recording, seen again" from "a different call in the same app", and let only the second through. Candidate discriminators, in order of how much they are already available:

- The window title. END9's title veto exists for exactly this class and cites two proven genuine back-to-back pairs at +67.6 s and +64.6 s (2026-05-28, 2026-06-12) whose titles differ. CAL3's 3% title coverage is the caveat: a nil title must degrade to prompting, never to blocking.
- A gap in the confident-winner stream. A false end is followed by the full call signature returning within tens of seconds; a genuine new call has the previous one's signature genuinely absent in between.
- Nothing model-shaped. This is a state question, not a classification question.

If neither discriminator is trustworthy on this corpus, change 1 plus a visible affordance is an acceptable end state: the owner would still have to press Record, but the recording would then be a real attached recording rather than a headless one.

## Explicitly not / out of scope

**Not shortening or removing `repromptCooldownSec`.** It is load-bearing against END9's false-end re-prompt storms, and the owner's own 2026-08-06 log shows the cost of prompting into a still-confused state (a prompt at 16:33:04 that they let time out, then a second at 16:34:41 that they accepted). Making the window shorter trades this defect for that one.

**Not auto-resuming a recording without consent.** END9's title-veto reasoning applies unchanged and is not to be re-litigated: two proven genuine back-to-back meetings sit inside any plausible resume grace, and recording one unconsented under the previous meeting's workflow and privacy posture is a worse failure than a missed prompt. Any policy here returns "prompt", never "record".

**Not the skip-latch branch.** DET7 built it, DET9 hardened its grace, and it behaves correctly. This task only makes the branch beside it as capable.

**Not END9's false-end defect.** The 12:32:40 end in the timeline above was genuine (the owner left the call). The two are adjacent and will meet in `handleDiscovery`: END9's spec says to land DET9 first then END9 on top, and this task edits the same `isCoolingDown` branch END9's resume exemption goes into. Whichever lands second rebases onto the first; they must not fight, and the rule from END9 holds, a user who explicitly skipped is never auto-recorded.

**Not "attach to whatever app is using the mic".** The owner floated this ("run a meeting directly connected to the app that currently uses mic"). It is the right instinct and the wrong mechanism here, and DET10 is the evidence: the mic-busy input has never produced a span on this Mac, so `mic_busy_started` / `mic_busy_ended` have fired zero times and there is nothing to attach to. The discovery sighting is the signal that actually exists, which is why this task uses it.

## Acceptance

- A `DetectionStateMachine` test asserts a candidate noted while a bundle is cooling down is returned by `liveSuppressedCandidate()`, and that it lapses when the cooldown does. Both halves; a candidate that never expires is the misattribution DET9 warns about.
- A `MeetingSessionController` test drives the recorded sequence (a recording ends, a confident winner for the same bundle arrives 22 s later, then a manual start) and asserts the recording is attached: the source is carried into the recording rather than nil. It must fail against `main`, where the manual start takes the `beginRecording(source: nil)` branch.
- A test asserts the pre-existing skip-latch path is unchanged, since both branches now write the same slot.
- If change 2 ships, a test using END9's real 2026-05-28 title pair asserts a differing title is treated as a new meeting and a nil title degrades to prompting rather than to suppression.
- The change emits an auditable event when a cooldown-suppressed sighting is retained, so the next occurrence is readable from `events.jsonl` alone. Any new event action is documented in the `CONVENTIONS.md` event table in the same commit and `python3 scripts/truth_fences.py both` stays green.
- `cd daemon && swift build` clean, `swift test` green, with the number of tests this task adds recorded in the ship note. Do not pin an absolute suite total.
- No em-dashes in changed lines; repo dash guard green.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts. The deciding steps need two real calls close together, so this is owner-owed by construction.

1. [session] `./scripts/rebuild.sh` after landing, then tell the owner it is ready.
2. [owner] The reported scenario, which is the whole task: end a Teams call, then join another within a minute. If change 2 shipped, a prompt should appear for the second call. If it did not, press Record by hand.
3. [owner] Either way, confirm the recording is **attached**: the HUD shows the workflow, and after it finishes the Library row shows the Microsoft Teams source chip. A row with no source chip means it took the nil path and the fix missed.
4. [owner] The load-bearing clause: **leave that second call and do nothing.** The recording must stop on its own. Before this change it kept running until hand-stopped, which is the failure that cost 15 m 35 s of room audio on 2026-08-04.
5. [owner] Then the guard in the other direction: after a recording ends normally, confirm you are not immediately re-prompted for the call you just left. That is the behaviour the cooldown exists for and the thing this task could plausibly break.
6. [owner] Say "DET13 good to close" (or what is wrong); [session] moves the row and this spec into `q6-final.md` and deletes this file.

## Progress, 2026-08-18: change 1 shipped, change 2 not built

Swift only, one commit. Change 1 in full, exactly as the Scope section separates it: the `isCoolingDown` branch in `handleDiscovery` now keeps its sighting, and `liveSuppressedCandidate()` reads a lifetime that covers a cooldown as well as a skip latch, so a manual Record inside the 60 s window produces an attached recording rather than the headless one of 2026-08-04. **7 new tests** (4 in `DetectionStateMachineTests`, 3 in `MeetingSessionControllerBranchTests`). Gates: `cd daemon && swift build` clean, `swift test` green, `python3 scripts/truth_fences.py both` clean on all three fences; the Python half was run anyway to prove it untouched (`ruff check src tests` clean, `pyright` 0 errors, `pytest -q` all passed). Zero U+2014 in the diff. Walkthrough step 1 was deliberately **not** run: `./scripts/rebuild.sh` relaunches the owner's live install, and this repo's operating notes leave that to them.

**The shape, and why the lifetime is what it is.** The candidate slot keeps one rule per suppression reason rather than one blended rule. A skip-latched candidate is still gated on `isSkipLatched`, unchanged, because the latch is the stronger liveness oracle: every confident-winner sighting refreshes it and an explicit start drops it. A cooling-down candidate has no latch to ride, which is the half the spec warns a pickup must not miss, so it falls through to the sighting's own age against a new `DetectionStateMachine.suppressedCandidateGraceSec`. That constant is defined as the skip latch's grace rather than as a number, so it is derived from the live `DiscoveryScanCadence` transitively and cannot decay the way DET9's hardcoded 15 did. It is deliberately the same width, and that is a sizing decision rather than laziness: both graces are refreshed by the same sighting and both have to clear the same measured control blackout (48 s on 2026-07-27, 21-33 s in END9), so a tighter one here would drop the candidate mid-call and reproduce DET9's bug in the second latch. The misattribution bound DET9's comment asks for holds from the other side instead: the cooldown branch can only write for the 60 s after an end, and only on a *confident* winner, never on the title-only sighting a post-call chat surface produces (293 of 294 Teams `candidate_dropped` rows are title-only). Retaining a sighting arms no skip latch, so the call still prompts normally once the window lapses, which is the behaviour the cooldown exists for and the thing this task could most plausibly have broken.

**Red first.** Two stages, because the first test named a constant that did not exist yet. Stage one is the compile, verbatim:

```
Tests/MeetingPipeTests/DetectionStateMachineTests.swift:277:74: error: type 'DetectionStateMachine' has no member 'suppressedCandidateGraceSec'
```

The constant was then added inert, read by nothing, so the suite compiled and the assertions themselves could go red. Stage two, verbatim:

```
DetectionStateMachineTests.swift:263: error: test_candidate_noted_during_a_cooldown_is_attachable :
  XCTAssertEqual failed: ("nil") is not equal to ("Optional(MeetingPipe.AppSource(bundleID: "com.microsoft.teams2", displayName: "Teams", kind: MeetingPipe.AppSourceKind.native, meetingTitle: nil))")
  - a cooling-down sighting is the only handle on the call the owner just joined
DetectionStateMachineTests.swift:275: error: test_cooldown_candidate_lapses_once_discovery_stops_seeing_it :
  XCTAssertEqual failed: ("nil") is not equal to ("Optional(MeetingPipe.AppSource(bundleID: "com.microsoft.teams2", displayName: "Teams", kind: MeetingPipe.AppSourceKind.native, meetingTitle: nil))")
MeetingSessionControllerBranchTests.swift:605: error: test_coolingDownSighting_cachesTheCandidate :
  XCTAssertEqual failed: ("nil") is not equal to ("Optional(MeetingPipe.AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams", kind: MeetingPipe.AppSourceKind.native, meetingTitle: nil))")
MeetingSessionControllerBranchTests.swift:642: error: test_backToBackMeeting_manualStartAttachesInsteadOfRecordingHeadless :
  XCTAssertEqual failed: ("nil") is not equal to ("Optional(MeetingPipe.AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams", kind: MeetingPipe.AppSourceKind.native, meetingTitle: nil))")
  - a headless recording has no meeting to watch, so it runs until it is hand-stopped
MeetingSessionControllerBranchTests.swift:645: error: XCTAssertEqual failed: ("nil") is not equal to ("Optional("com.microsoft.teams2")")
MeetingSessionControllerBranchTests.swift:646: error: XCTAssertEqual failed: ("nil") is not equal to ("Optional("Microsoft Teams")")
MeetingSessionControllerBranchTests.swift:668: error: test_coolingDownSighting_emitsOneRetainedEvent_andTheSkipLatchBranchEmitsNone :
  XCTAssertEqual failed: ("0") is not equal to ("1") - one row per retention, not one per discovery poll
MeetingSessionControllerBranchTests.swift:669: error: XCTAssertEqual failed: ("nil") is not equal to ("Optional("coordinator")")
MeetingSessionControllerBranchTests.swift:670: error: XCTAssertEqual failed: ("nil") is not equal to ("Optional("com.microsoft.teams2")")
MeetingSessionControllerBranchTests.swift:682: error: XCTAssertEqual failed: ("0") is not equal to ("1") - a skip-latched sighting must still take the branch above
Executed 7 tests, with 10 failures (0 unexpected)
```

The `nil` on the fourth is the defect itself: `20260804-123303.meta.json`'s `source_bundle_id: null`, reproduced from the recorded sequence (a real `beginRecording` for Teams, the real `stopRecording` flush that arms the cooldown, a confident winner for the same bundle, then `startManual`).

Two of the seven **pass before and after on purpose** and the report should not claim otherwise, since both are fences rather than defect reproductions. `test_suppressedCandidateGrace_is_derived_from_the_live_discovery_poll` pins the new grace against `DiscoveryScanCadence.discoveryDefault.idle` and against the latch's, so it goes red if either is ever hardcoded or if the two drift apart. `test_retaining_a_cooldown_candidate_arms_no_skip_latch` pins the half the fix must not touch: it goes red the day someone "simplifies" the cooldown branch into the skip branch, which would swallow the call for its whole lifetime.

**Change 2 was evaluated and not built, because neither discriminator survives this corpus.**

*The window title is not merely low-coverage here, it is structurally absent at the seam.* All three `AppSource` construction sites in `MeetingSourceScanner.swift` (:162, :195, :249) omit `meetingTitle:` and take the `nil` default, and `MeetingTitleResolver.resolve` has exactly one production call site, `MeetingSessionController.appSource(from:)` (:1290), reached only from the lifecycle `.starting` verdict. The cooldown branch returns before `engageLifecycle`, so on this path the lifecycle never engages, `.starting` never fires, and the resolver never runs. The title is therefore nil on 100% of the sightings a discriminator here would read, and the spec's pre-registered rule that a nil title must degrade to prompting is not a caveat in that case, it is the whole behaviour: the veto is a no-op. `State.swift:9` also excludes `meetingTitle` from `AppSource`'s `Equatable`/`Hashable` on purpose, because it shifts mid-call and "identity comparisons in the state machine must stay stable across those transient flips", which is precisely the comparison this discriminator would introduce.

*And the evidence the Scope bullet cites for it does not say what the bullet says.* The two proven pairs END9 quotes (`END9.md:123`, +67.6 s and +64.6 s) differ in their **summary** titles, which `docs/spikes/ai5-meeting-type-classification.md:45` identifies as "the *summarizer's invented title*, generated by the LLM that wrote the summary", produced minutes to hours after the decision point. CAL3's 3% (`CAL3.md:15`, 6 of 179) is coverage of the **AX window title** in `<stem>.meta.json`, which is the field a discriminator could actually read. The bullet reads the two as one measurement of one field. Worth correcting in the Scope text if change 2 is ever revived; left as this note rather than an edit, since rewriting a filing's Scope is not a pickup's call and HYG7 is already open against END9's citation rot with a citations-only mandate.

*The confident-winner gap has overlapping classes, and this task's own incident is the counterexample.* Measured false-end signature returns run +0.24 s, +0.64 s, +1.07 s, +1.69 s (`END9.md:122`), +32.5 s (`END9.md:19`) and +48.2 s (`DET9.md:26`). The genuine new call in the incident this task was filed over produced its confident winner **22 s** after the previous recording stopped, inside that band: any threshold above 22 s suppresses the prompt on the exact meeting DET13 exists to rescue. The only two genuine points above it are the +67.6 / +64.6 pair, and both sit in the cluster `END9.md:142` warns is floored by `repromptCooldownSec` itself, so they measure the cooldown rather than the gap and cannot set the upper boundary. END9 already ran a timing-only classifier over this population and reported 6 verified false ends from 14 candidates (`END9.md:33`); what separated them was mid-sentence-versus-farewell and speech-onset latency, both transcript properties available only after ASR. The instrument is short of it as well: `discovery_shadow_pick` is gated on `winnerChanged` (`MeetingDiscoveryWatcher.swift:229`), so there is no per-scan winner row on disk, and the bracketing events carry the 3 to 12 s scan cadence as quantization on each edge against a boundary that would have to fit between 22 s and 48.2 s.

*So the spec's own fallback applies:* change 1 plus a visible affordance. **The affordance was deliberately not built.** A new or restyled surface needs a rendered eyeball, this is a menu-bar app that cannot be screenshotted from a session, and `PRODUCT.md`'s register is a judgement call the owner owns. What change 2 still owes is therefore a decision rather than code: whether the back-to-back case gets an affordance beyond the menu row already renaming itself, and if so which surface.

**The audit trail.** `coordinator`/`cooldown_candidate_retained` is emitted once per retention rather than once per 3 to 12 s poll, carrying `bundle_id`, `display_name` and `cooldown_sec`, so the next occurrence is readable from `events.jsonl` alone; the 2026-08-04 one was not, because that branch returned silently and left a 22 s hole in the log with nothing saying why. Documented in `CONVENTIONS.md`'s event-category section beside UX67's precedent for putting one action in an existing category. Docs checked: `CONVENTIONS.md` updated for the event, `ARCHITECTURE.md`'s **Suppressed candidate** glossary entry rewritten (its "lifetime *is* the latch's" claim was made false by this change), `README.md` and `docs/GUIDE.md` both updated because the affordance is user-visible (the menu bar's **Record this \<app\> meeting** now appears for a back-to-back meeting, not only for a skipped one), and `PRODUCT.md`, `docs/SETUP.md` and `design/` left alone since no surface, control or install step changed.
