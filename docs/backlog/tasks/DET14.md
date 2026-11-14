---
id: DET14
title: The menu offers "Record this <app> meeting" for up to two minutes after the call ended
category: Detection
status: partial
priority: P2
comment: Filed 2026-08-19 from the field, by the owner: after a Teams call finished the menu's top row still offered to record it. Not a refresh bug, the menu repopulates on open and the read self-expires; the lifetime behind it was wrong. **Two graces compose and only the second was costed**: DET13's cooldown branch rewrites the candidate on every confident sighting for the whole 60 s re-prompt cooldown, so the last write can land 60 s after the end, and the candidate then lives `suppressedCandidateGraceSec` (DET7's 5 polls, 60 s) from that write. Ceiling about 120 s, which is where the owner's estimate starts; the observed run was ~80 s. **DET9's width is not the error and is not touched.** A skip-latched call is *known live* (the owner dismissed a prompt for a meeting that was running, and every sighting refreshes the latch), so its grace is bridging a measured control blackout in a call there is positive evidence for. A cooling-down call has no such evidence, and the cooldown is anchored on the previous meeting's **end**, so the branch fires exactly when a call may have just finished. DET13 gave it the latch's width by derivation and its own comment flags the asymmetry without drawing the consequence. **Shipped 2026-08-19, two changes.** The candidate records which branch wrote it, and a cooldown-origin one gets 2 polls rather than 5 (still more than one quiet poll, so a single scan with no confident winner cannot drop it, which is the DET9 bug; derived from the live cadence so it cannot decay). And a confirmed lifecycle end drops it at once, because the grace is an upper bound on ignorance and an end is the positive signal it stands in for. **The end clear is safe because it is not sticky**, demonstrated rather than argued: on 2026-08-19 a false end fired at 07:40:21Z, the recording stopped at 07:40:22Z, discovery had re-populated the candidate by 07:40:24Z, and the owner restarted by hand at 07:40:26Z. Explicitly not clearing on recording-stop (that is DET13's rescue, and the owner used it that day) or on `candidate_dropped` (DET9's finding is that discovery going quiet is not an end). 9 tests, measured red by restoring the old derivation and neutering the end clear. `ARCHITECTURE.md`, `docs/GUIDE.md` and `README.md` all stated the old lifetime as user-facing fact and are corrected in the same commit. Spec in [`tasks/DET14.md`](./DET14.md). **Owner-owed:** walkthrough steps 2 and 3, proposed weight `simple` (leave a call and open the menu; then a back-to-back rejoin to confirm DET13's rescue survived). Needs the owner's approval before the row moves to `owner-verification.md`. Amended 2026-11-13 by the audit band: the stop-time retention (END13 item 5) re-adds the candidate the end clear just dropped, so the clear holds only for ends that arrive while not recording (D049); scope narrowed to skip the retention after a definitive end only, keeping the 20261022-150025 re-attach.
---

# DET14: the menu offers "Record this <app> meeting" for up to two minutes after the call ended

Filed 2026-08-19 from the field, by the owner: after a Teams call finished the menu bar's top row still read **Record this Microsoft Teams meeting**, and it stayed that way for what they estimated as two to four minutes. Shipped the same day.

Not a refresh bug. `StatusBarController.refreshMenuBeforeDisplay` repopulates on every open and `liveSuppressedCandidate()` self-expires on read, so the row is accurate at the moment it is drawn. The lifetime behind it is what was wrong.

## Where two minutes comes from

Two graces compose, and only the second was ever costed:

- DET13's cooldown branch writes the candidate on **every** confident sighting for as long as the bundle is inside its 60 s re-prompt cooldown, so the last write can land 60 s after the previous meeting ended.
- The candidate then lives `suppressedCandidateGraceSec` from that write, which DET7 derived from the skip latch's 5 polls x 12 s = 60 s.

So the ceiling is about 120 s past a real end. The owner's estimate starts exactly there. The observed run on 2026-08-19 was shorter, about 80 s: the recording stopped at 07:43:37Z, the last confident sighting was before 07:43:58Z (the scans at 07:43:58 and 07:44:02 both report `leave_button: false, mute_button: false, calling_controls_toolbar: false`), and the screenshot the owner sent is timestamped 10:44 local, inside that window.

**Why the grace was that wide is sound and stays sound for the branch it was written for.** DET9 measured a live Teams call running 48 s between confident winners while plainly still up, because the compact / backgrounded call UI hides Leave, Mute and the toolbar; END9 measured a 21-33 s blackout the same way. A narrower grace drops a live call mid-meeting, which is the more expensive failure.

**What was wrong is applying that to both branches.** DET7's grace protects a call the skip latch has *proven live*: the owner dismissed a prompt for a meeting that was running, and every sighting refreshes the latch. A cooling-down call carries no such evidence, and the cooldown is anchored on the previous meeting's **end**, so the branch fires exactly when a call may have just finished. DET13 gave it the latch's width by derivation, and the doc comment even flags the asymmetry ("a cooling-down meeting has no latch at all") without drawing the consequence.

## What shipped

1. **The cooldown-origin candidate gets its own, shorter grace.** `DetectionStateMachine` now records which suppression branch wrote the candidate (`SuppressedCandidateOrigin.skipLatch` / `.cooldown`) and reads the matching grace. The cooldown's is 2 polls rather than 5, derived from the live `DiscoveryScanCadence` per DET9's rule so it cannot decay the way DET9's hardcoded 15 did. Two, because it still has to bridge one ordinary quiet poll so a single scan finding no confident winner cannot drop it (the DET9 bug), but it does not have to bridge END9's control blackout, which is a fact about calls the latch has already proven live. The skip-latch branch is untouched.

2. **A confirmed lifecycle end drops the candidate at once.** `noteMeetingEnded(bundleID:)`, called from `handleMeetingEnded` before its state switch, because it is not about what this session is doing. The grace is an upper bound on *ignorance*, a guess at how long to keep believing in a call discovery has stopped confirming; a lifecycle end is the positive signal that guess stands in for, so it should not have to be waited out.

**The end clear is safe precisely because it is not sticky**, and 2026-08-19 demonstrates it rather than arguing it. A provisional end fired at 07:40:19Z, was rescued, ended for real at 07:40:21Z, the recording stopped at 07:40:22Z, and discovery had re-populated the candidate by 07:40:24Z, which the owner then used to restart by hand at 07:40:26Z. So on a false end the very next poll writes the candidate straight back, and DET13's false-end rescue is intact.

## Explicitly not in scope

**Not clearing on recording-stop.** That is precisely what DET13's cooldown retention exists to prevent: the 2026-08-04 incident was a back-to-back meeting joined 22 s after a stop, which fell to `beginRecording(source: nil)` and ran 15 m 35 s past its end with no AX anchor. The owner used the same affordance at 07:40:26Z on the day this was filed. A stop is not an end.

**Not clearing on `candidate_dropped`.** DET9's whole finding is that "discovery stopped seeing it" is not "it ended". Keying on that would reintroduce the bug DET9 fixed, in the branch DET13 added.

**Not the skip-latch grace.** It stays 5 polls. The split here is a statement about the weaker evidence the cooldown branch carries, not a general tightening, and a test pins the latched candidate keeping its full width so this cannot be read as one.

**Not the row's copy.** Wording was offered as an alternative and not taken: the row is accurate while the candidate is live, so the defect is the lifetime rather than the sentence.

**Not the 60 s cooldown itself.** It is load-bearing against END9's false-end re-prompt storms and is unchanged; only the candidate's survival past its last sighting moved.

## Acceptance

- A test asserts a cooldown candidate is gone well before the old grace, which is the read that kept the stale row on the menu. Red against the unfixed derivation.
- A test asserts a cooldown candidate is still attachable inside its own grace, so DET13 is not regressed.
- A test asserts a latched candidate keeps the full grace, so the split is not a general tightening.
- A test asserts the new grace is derived from the live discovery poll, not written as a number, and that it still exceeds one quiet poll.
- A test asserts a confirmed end drops the candidate for that bundle only, and a test asserts the next sighting undoes a false end.
- `swift build` clean, `swift test` green with the number of tests recorded in the ship note. Do not pin an absolute suite total.
- `python3 scripts/truth_fences.py both` green, and the `ARCHITECTURE.md` glossary entry, `docs/GUIDE.md` and `README.md` corrected in the same commit, since all three state the old lifetime in user-facing prose.
- No em-dashes in changed lines.

> **Verified 2026-08-19.** Every bar above is met. **+9 tests** in `DetectionStateMachineTests`. **Measured red, not asserted:** setting `cooldownCandidateGracePolls` back to 5 and neutering `noteMeetingEnded` to a no-op turned 6 of them red on their own assertions; both were restored and the suite re-run green. `swift build` clean, `swift test` 2840 tests 0 failures, truth fences green, no pipeline change.
>
> Three docs corrected in the same commit, all of which asserted the old lifetime as user-facing fact: `ARCHITECTURE.md`'s Suppressed candidate glossary entry, `docs/GUIDE.md`'s two recipes, and `README.md`'s `default_prompt_action` note.

## Owner walkthrough (for the session that picks this up)

Steps are tagged [owner] / [session] by who acts.

1. [session] `./scripts/rebuild.sh` after landing, then tell the owner it is ready. Landing on `main` is not installing.
2. [owner] Leave a Teams call, wait about half a minute, and open the menu bar menu. Pass: the top row reads **Start Recording**, not **Record this Microsoft Teams meeting**. Before this it read the latter for up to two minutes.
3. [owner] The half that must not have broken, and it is worth checking deliberately because it is the more expensive failure. Leave a call and rejoin (or join a second one) within a few seconds, then start it from the menu row or `⌃⌥M`. Pass: the Library row for that recording carries the app chip, and the recording stops on its own when you leave rather than running on. That is DET13's rescue, which this task narrows the window on and must not remove.
4. [owner] Say "DET14 good to close" (or what is wrong); [session] moves the row and this spec into `q6-final.md` and deletes this file.

## Amendment 2026-11-13 (audit band)

Source: D049 in the [2026-11-13 recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md), long form in its [evidence file](../../audits/2026-11-13-recording-reliability-evidence.md). Re-verified in code at HEAD on 2026-11-14.

**DET14's end clear does not hold on the recording path (D049).** `MeetingSessionController.handleMeetingEnded` calls `coordinator.stateMachine.noteMeetingEnded(bundleID:)`, DET14's clear, and then, in its `.recording` branch, `stopRecording(file:source:summaryMode:)`, whose first act for a sourced recording is `noteSuppressedCandidate(source, origin: .cooldown)` plus a `coordinator`/`stopped_candidate_retained` row. That write is END13 item 5, which landed on 2026-09-04, two weeks after DET14, and its comment calls the order deliberate ("It sits after `handleMeetingEnded`'s DET14 clear on the lifecycle-end path, which is the right order"). So on the recording path the clear is undone in the same run-loop turn, and the candidate lives `cooldownCandidateGraceSec` (2 idle polls of `DiscoveryScanCadence.discoveryDefault`, 24 s) from that write, longer if discovery re-sights the app inside the 60 s cooldown. `StatusBarController` reads `liveSuppressedCandidate()` for the menu's top row, so for up to 24 s after every lifecycle-ended recording the menu offers "Record this <app> meeting". DET14's promise holds only for ends that arrive while not recording.

Field, work-laptop pack (2026-09-29 to 2026-11-13): `stopped_candidate_retained` with `grace_sec` 24 lands within 1 s after `lifecycle`/`ended` on 40 of 41 lifecycle-ended sourced stops in builds B and C (47 rows in all, first seen 2026-10-12T14:47Z). The harm itself leaves no row, since nothing logs what the menu showed.

**Correction at filing: this is a documented trade, and the audit's direction would remove the one benefit the field shows.** `ARCHITECTURE.md`'s Suppressed candidate entry already states the cost END13 accepted ("a genuinely finished call can show the menu row for up to 24 s where DET14 left 0"), and `docs/GUIDE.md` says the row goes back to Start Recording "within about half a minute", so no user-facing doc is wrong today. The audit's direction is to skip the stop-time retention whenever the stop came from a confirmed lifecycle end. The audit's own field cross-check (item 7 of the stop-edge section's list of where the code-only trace was wrong) says that retention is what made a rescue work: on 2026-10-22 stem 20261022-150025 was ended by a false end (`ax_leave_button_invalid`, then `process_audio_is_running_input_false` 5.7 s later, `lifecycle`/`ended` at 12:14:59.006Z), the owner pressed Record at 12:15:21.948Z (`record_attached`, trigger manual, +22.9 s), and the restart 20261022-151521 attached to the retained candidate; discovery re-sighted the call only about 24 s after the end. Without the retention that restart records with `bundle_id: "manual"` and no end anchor, the END11 failure. That end was a weak-signal end, not a definitive one. Also note DET14's owner walkthrough step 2 waits "about half a minute", which is past the 24 s grace, so it passes whether or not the clear holds.

### Scope additions

1. Skip the stop-time retention only after a **definitive** end, and keep it for every weak-signal end, user stop and backstop stop. Definitive here means what END17 calls definitive: `confirmedBy` carries `PromotionEngine.teardownEvidence` (`call_teardown_observed`), or the end was led by `PrimarySignalKind.workspaceAppTerminated` (the app quit, `isDefinitive`). Every false end the field has shown (20261022-150025, and DET13's 2026-08-04 incident) was weak-signal, and a quit app has no call to re-attach to. Seam: `handleMeetingEnded`'s `.recording` branch passes the `EndingReason` (or a `retainCandidate` flag derived from it) into `stopRecording`; the user-stop and backstop callers keep today's retention.
2. When it lands, update the `ARCHITECTURE.md` sentence quoted above to say the 24 s row survives weak-signal ends only, and re-time DET14's walkthrough step 2 so it can see the difference.
3. If the owner prefers the audit's wider direction (drop on every lifecycle end), that is a deliberate trade of the 20261022-150025 rescue against a 24 s stale row, recorded as the owner's decision in this file before it is built.

### Acceptance additions

- Controller tests: a recording ended with `confirmedBy` containing `call_teardown_observed`, and one led by `workspace_app_terminated`, leave no live candidate after the stop and write no `stopped_candidate_retained` row (red at HEAD); a recording ended on the pair dwell or the lone dwell still retains the candidate for its 24 s grace (pins the 20261022-150025 rescue); a user stop and an idle-backstop stop still retain it.
- `cd daemon && swift build` and `swift test` green, with the number of tests added in the commit body; `python3 scripts/truth_fences.py both` green; `ARCHITECTURE.md` corrected in the same commit.
- Walkthrough step 2 re-timed: [owner] leave a Teams call (a normal Leave, not quitting Teams) and open the menu within 10 s; the row still reads **Record this Microsoft Teams meeting**, by design. Then quit Teams during a recorded call and open the menu within 10 s; the row reads **Start Recording**.
