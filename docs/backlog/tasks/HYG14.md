# HYG14: /tech-task never checks a spec's premises against the code, never requires proof that production calls a new component, and never asks anyone to refute a detection or capture change

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([AI harness audit](../../audits/2026-10-24-ai-harness-audit.md) failure modes 2, 3, 6 and 7, proposals C1 to C3). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Three failure modes recur, and `/tech-task` has no step for any of them (re-read 2026-10-24):

1. **Specs are wrong against the code and it is found mid-implementation.** The harness audit counted 6 of 15 `/tech-task` sessions hitting a spec premise that was false, each costing an owner round trip. Today's command comes closest in step 3 ("check they still exist before editing", paths only) and step 5 ("Argue back if the task has a better path"), neither of which asks the session to test the spec's claims. Filing this very band showed how fast premises go stale: two defects the harness audit recorded on the morning of 2026-10-24 (the `/tech-task` step 6 gate list, the macos-14 claim) were already fixed by CI8 that afternoon, and so was the go-live assessment's red-CI item from 2026-10-21. HYG7 exists because END9's spec cited a file ARCH6 had deleted.
2. **Green tests for code production never calls.** END9 shipped with 28 green tests while `Coordinator.start()` never started the watcher; `CoordinatorWiringFenceTests` was written afterwards and says so in its header ("END9's oracle was correct, well tested, and never ran"). The audit lists DET13 then END11, REC15 then REC16, and UX54's reopen as the same class, about 8 incidents.
3. **Self-review misses what adversarial review catches.** `git log` shows 46 commits whose subject starts `fix(detector|detection|micgate|lifecycle)`, and END9 to END14 each added a rule to the end-of-call logic ([T8](./T8.md) carries the replay half). The audit cites a DET1 review that found five bugs, one introduced by the session's own fix; its reference `9d0384da` is not a commit in this repository (likely a session id), so that example rests on the audit. `/audit` step 4 already has the mechanism: a skeptic agent told to refute, not confirm.

## Scope

Edit `.claude/commands/tech-task.md` only:

1. **New step between 3 and 4, "Check the spec's premises"**: list every factual claim the spec makes that the implementation depends on (a named symbol and what it does, a cited behaviour, a measured number, a "nothing calls X"), confirm each in the code, and report the list with a verdict per item before writing code. A false premise that changes scope stops the task and goes to the owner (in fan-out mode it is returned as a question, under the existing step 2 deltas). A false premise that does not change scope is fixed in the spec in the same commit.
2. **Wiring rule, added to step 4**: a new component that production must construct or start (a watcher, signal, service, scheduler, sink) ships a test that fails if the production path never calls it. Until [T7](../q6-final.md#done-t7-the-end10-wiring-fence-skips-instead-of-failing-when-coordinatorstart-moves-skips-pass-ci-silently-and-the-watchers-have-no-headless-seam)'s headless wiring seam exists, a source fence in the `CoordinatorWiringFenceTests` style meets the rule if the test says why no behavioural seam exists, and it must fail rather than skip when its anchor moves (T7 converts the existing `XCTSkip`).
3. **Adversarial review, a new step after verification (step 6) and before the docs sync**, mandatory when the diff touches `daemon/Sources/MeetingPipeCore/Lifecycle/`, `daemon/Sources/MeetingPipeCore/MicGate/`, `MeetingDiscoveryWatcher`, `MeetingSessionController`, `MeetingRecorder`, `SystemAudioCapture`, `EngineTeardown` or `GuardedTapInstall` (the list lives in the step; [ARCH8](./ARCH8.md)'s extracted types join it when they land). One read-only subagent gets the spec and the diff, not the author's summary, and is told to refute the change in code: a sequence that ends a live call, a path that drops audio, a signal the change makes self-corroborating. Each finding is fixed or answered in the step 11 summary. Reuse `/audit` step 4's wording so the two do not drift.

## Explicitly not / out of scope

- Building the replay harness or the headless wiring seam. Those are [T8](./T8.md) and [T7](../q6-final.md#done-t7-the-end10-wiring-fence-skips-instead-of-failing-when-coordinatorstart-moves-skips-pass-ci-silently-and-the-watchers-have-no-headless-seam); this task only makes the command require what they make cheap.
- Adversarial review for every task. It costs one more agent run per task; the trigger list keeps it to the subsystems with the patch-on-patch history.
- A changed-paths CI gate enforcing any of this. These are session steps; a fence cannot judge whether a premise was checked.
- The comment rule ([HYG9](./HYG9.md)), the docs-sync list and budget figure ([HYG11](./HYG11.md)), and the Plan Mode precedence question ([DOC18](./DOC18.md)), which all edit the same file. Whichever lands later rebases; the steps are independent.

## Acceptance

- `tech-task.md` carries the three additions, numbered so every cross-reference in the file (and in `file-task.md`, `spike.md`, `audit.md`, and the multi-task section's "steps 1 through 9") still points at the right step. A grep for `step [0-9]` across `.claude/commands/` is reviewed by hand in the commit.
- The adversarial step's trigger paths all exist (`ls` each in the commit body).
- The next `/tech-task` run on a detection or capture task (owner-observed, not a precondition for closing) shows a premise list before code and a skeptic report before the commit.
- `bash scripts/ci-local.sh fences` green. No source code changes.
