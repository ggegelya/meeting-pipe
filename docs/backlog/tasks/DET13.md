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
