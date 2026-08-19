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
