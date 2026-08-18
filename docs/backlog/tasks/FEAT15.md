# FEAT15: an interactive tutorial, which reverses a standing scope decision

Band origin: filed 2026-08-04 at the owner's explicit request during DOC11's eyeball: "better to make some tutor overflow with fancy animations etc. you can file a ticket for this." Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## The scope reversal, stated first because it is the reason this file exists

**The root `CLAUDE.md` currently defers exactly this.** Its DOC11 carve-out reads: "The guide is a document plus one menu item, not onboarding machinery: interactive tours, first-run wizards, coach marks, videos, and a hosted docs site all stay deferred." The paragraph above it defers "in-app onboarding wizards, first-run tours, and anything that exists to convert a stranger rather than unblock a user".

The owner asked for this on 2026-08-04 with that deferral in force, and is the only person who can move it. This section exists so that a session picking this up does not have to guess whether the standing rule or the ticket wins, and so that the reversal is a recorded decision rather than a task quietly outranking a documented one.

**What was not decided at filing, and had to be before code:** whether the deferral is lifted in general, or only for this one surface. The distinction is load-bearing, because the deferred list is what has kept first-run wizards and coach marks out of a single-user product for two quarters, and "we built a tutorial" is the precedent that gets cited next time. The pickup session's first job was to put that question to the owner and record the answer here, then amend the root `CLAUDE.md` in the same commit as the first code, so the rule and the repo agree at all times.

### Answered, 2026-08-18

**The task is promoted out of P3 for this batch**, so the P3 rule is not a reason for a session to stop on it.

**The reversal is `this surface only`.** The deferral lifts for a tutorial the user opens on purpose and for nothing else. First-run wizards, coach marks, videos, and a hosted docs site all stay deferred exactly as they were, and having built this one is explicitly not a precedent for any of them: each would have to be put to the owner on its own terms. A second tour surface is a new decision too, not an extension of this one.

That answer is written into the root `CLAUDE.md` beside the DOC10 and DOC11 carve-outs, in the same commit as the first code. Two things keep it from being quietly widened later. The amendment names the boundary and the still-deferred list in the same breath, so a future reader cannot cite the tutorial as cover for the rest. And the boundary's operative clause, that the tour runs only when someone picks the menu row, is a fence rather than a promise: `TutorialFenceTests.test_nothing_on_a_launch_path_starts_the_tour` asserts that `TutorialSession.shared.start(` appears in exactly one file, the menu-action extension, and that `App.swift`, `Coordinator.swift` and `OnboardingWindow.swift` do not mention the session at all. A first-run tour is therefore a red build, not a code-review catch.

**The shape is `drive the real UI`**, chosen over the rehearsal surface and over the narrow two-or-three-flows option, with the trade stated to the owner: it is the most work and the most fragile against layout, and it is the only one of the three that cannot go stale about what exists.

## Context

DOC11 shipped a task-oriented Guide (a document plus a menu item) on 2026-08-04. The owner's verdict on the eyeball leg was that the content is a reasonable start and the presentation is not: it "looks ugly like it come from 90s", and a static document is the wrong shape for teaching the app.

Two things separate this from the deferred class it resembles, and they are the argument for taking it seriously rather than reflexively refusing:

The deferral's stated reason is that onboarding exists "to convert a stranger rather than unblock a user". This owner is the only user and is already converted, so the anti-goal does not apply on its own terms. What the deferral is really protecting against is machinery that costs more to maintain than it teaches, in a product with one user and a fast-moving surface.

That protection is real and this task inherits the risk rather than escaping it. Every animated step that names a control is a claim that goes stale exactly the way DOC7 and DOC9's doc sweeps did, except a stale animation cannot be caught by grep the way a stale sentence can. **The maintenance story is the design problem here, not the animation.** A tour that drives the real UI stays true by construction and is expensive; a tour that reproduces the UI in its own views is cheap and is a second copy of every surface, which is the failure mode DOC11's single-copy rule was written to avoid.

## Scope

Not fixed at filing, deliberately. This task was a decision before it was a build, and the decision was the shape:

- **Drive the real UI** (highlight and narrate actual controls), which cannot go stale about what exists but is the most work and is fragile against layout.
- **A rehearsal surface** (a self-contained animated walkthrough that never touches the live app), which is cheap and is a second copy of the surfaces it teaches, with the staleness that implies.
- **Something narrower than either**, for example animating only the two or three flows that are genuinely hard to discover from the Guide's prose, rather than a tour of everything.

Whichever is chosen, the same-commit maintenance contract that governs `docs/GUIDE.md` and `docs/SETUP.md` has to extend to it before the first step is written, or this becomes the stalest surface in the repo within a quarter.

## What shipped, and how it is kept true

The menu bar gains **Tutorial…**, beside **Guide…**. It walks seven controls across three surfaces: the Library's rail, its Record button, its search field and its Preferences gear, then Vocabulary and Speaker labels on the Pipeline pane, then Regulated mode on the Permissions pane. Each stop dims the window it is in, cuts a hole over the real control, rings it, and puts a card beside it naming the control and saying what it is for.

### The maintenance mechanism, which is the answer the acceptance asked for

A step makes three claims: the control exists, it is called what the narration calls it, and it lives somewhere the app can open. None of them is a string looked up at runtime, and none of them relies on a human noticing.

`TutorialAnchor` is a `CaseIterable` enum with one case per control the tour names. Each case declares its surface, `attachedIn` (the file that must carry `.tutorialAnchor(.<case>)`), `namedIn` (the file that must spell the label as a literal), and `control` (the label itself, spelled exactly once in the repo outside the app's own render site). `TutorialFenceTests` then holds four claims, and each was checked against a deliberate break before this landed:

| Goes stale | Caught by | Verified red |
| --- | --- | --- |
| The control is deleted | the modifier goes with it, so the anchor is attached nowhere | yes, by deleting `.tutorialAnchor(.preferencesGear)` |
| The control is renamed | the literal in `namedIn` no longer matches `control` | yes, by renaming the Record button's label to "Start" |
| Narration re-spells a name | a step whose own prose contains its control as a whole word | fence present; the card renders `anchor.control` |
| The anchor is deleted | the compiler, at every step that named it | Swift exhaustiveness |

Two more fences cover the surfaces rather than the controls: every `TutorialWindow` must carry exactly one `.tutorialStage(_:)`, and the presenter must answer every `TutorialSurface` by name with no `default:` branch (the compiler already forces exhaustiveness; the fence is what stops a `default:` swallowing the next surface).

The runtime residue is a card that says so out loud. `TutorialSpotlight.focus` answers `.missing` for an anchor that reported nothing, reported a zero-size frame, or reported one wholly off the viewport, and the card then prints the control's name above a line saying it is not on screen. That is deliberately the weaker guard, since the fences are what fail a build.

### Two findings the shape produced

**A tour anchor may only point at an unconditionally rendered control.** The filter bar's "Save as smart folder" was the first candidate for a step and had to be dropped: it is drawn only once a filter is active, so a tour opened on a clean Library would have rung nothing every time, and the `.missing` card would have been the normal case rather than the alarm. Making the tour set up its own preconditions would be the tour driving app *state*, which is a much larger promise than narrating and would need undoing at every step.

**The fences cover what exists and what it is called; they cannot cover where it is sitting.** A control scrolled out of its pane resolves as `.missing` even though it exists, because the tour does not drive scroll position. Both Preferences anchors sit on groups that are in view at the window's own minimum height, and a future pane reshuffle can break that without any fence noticing. That is the fragility the owner accepted when picking this shape, stated here rather than left implicit. What keeps it survivable is that the runtime is honest about it rather than silent: the card prints the control's name above "Not on screen right now, so there is nothing to point at", and `TutorialSession.leaveStep` logs one line naming the anchor for every step that ended that way, so `log stream`/`Console` over the daemon subsystem answers "which step could not find its control" directly. A session that hits this should reach for the anchor's placement or for the pane's scroll position, not for the fences: a green suite plus a `.missing` card is exactly the combination this hole produces, and it is not a contradiction.

Full reasoning, including why the overlay lives inside the window rather than in a floating panel above it, is in [`daemon/docs/gotchas.md`](../../../daemon/docs/gotchas.md#a-tour-is-a-set-of-claims-about-controls).

## Explicitly not / out of scope

**Not DOC13.** The Guide's own visual pass and its content sweep (including the repo-file references the owner found in the same sitting) are filed there and do not depend on this. DOC13 should land first regardless: a tutorial over a document that still points at `../README.md` inherits the problem.

**Not a first-run wizard.** Even under a lifted deferral, something that runs automatically at first launch is a different decision from something the user opens on purpose, and nothing in the owner's request asks for the former.

**Not marketing.** Everything tied to selling stays deferred and this does not change that.

## Acceptance

Unwritable at filing, deliberately: the backlog's own rule is that a task which cannot fail verification is not ready, and every bar depended on which of the three shapes was picked. Written now that it is, with what each bar actually returned.

- The scope-reversal question is answered by the owner and recorded above, and the root `CLAUDE.md` is amended in the same commit as the first code. **Met.** The amendment sits beside the DOC10 and DOC11 carve-outs; `TutorialFenceTests.test_the_root_claude_md_carves_the_tutorial_out_and_keeps_the_rest_deferred` fails if it stops naming the carve-out or stops naming the four still-deferred items, and that test was observed red before the amendment was written.
- The chosen shape is recorded here with its maintenance story, and a step naming a renamed or removed control is not caught by "a human notices". **Met**, per the table above. Both the deletion and the rename legs were run against a deliberate break and observed red with a message naming the file and the fix.
- The same-commit contract extends to this surface before the first step was written. **Met**, in the root `CLAUDE.md` amendment, phrased as SETUP.md's and GUIDE.md's contract plus the mechanical half a document does not need.
- `swift build` clean, `swift test` green with new tests. **Met**: 2,633 tests, 0 failures, 35 of them new (24 `TutorialTests`, 11 `TutorialFenceTests`).
- `python3 scripts/truth_fences.py both` green. **Met** (config keys, event categories, `CLAUDE.md` budget).
- No em-dashes. **Met**, checked over every file in the diff.
- DSN3's constraints on the new surface. **Met**: no `.system(size:` anywhere under `Tutorial/` (its own fence), and the card's colours are `fg` / `fgMuted` / `.mpSignal` / `.mpWarning`, all of which clear 4.5:1. `fgFaint` is not used.

Not met, and owed to the owner: step 5 of the walkthrough below, running the tour as though new to the app.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts.

1. [session] Put the scope-reversal question to the owner before anything else: is the deferral lifted for tours in general, or only for this surface? Record the answer in this file. **Done 2026-08-18: this surface only, recorded above.**
2. [session] Propose the shape (drive the real UI, a rehearsal surface, or something narrower) with its maintenance story, and get the owner's pick before building. **Done 2026-08-18: drive the real UI.**
3. [owner] Confirm DOC13 has landed, since a tutorial over an unfixed Guide inherits its problems. **Done: DOC13 is `3f7448f`, and this branched from it.**
4. [session] Build, then `./scripts/rebuild.sh`. **Built; `rebuild.sh` is the owner's to run, since it relaunches the installed app.**
5. [owner] Run the tutorial as though new to the app, from the menu bar's **Tutorial…**. Pass: seven steps, each ringing a control that exists and is where the card says; Back and Next move between them; the Preferences leg opens the right pane; Esc closes. What a fail looks like: a card reading "Not on screen right now" on any step, which means the control exists but was not laid out where the tour could reach it (most likely scrolled out of a Preferences pane).
6. [owner] Say "FEAT15 good to close" (or what is wrong); [session] moves the row and the spec into `q6-final.md` and deletes this file.

**Cost to the owner, and why a harness cannot do it instead:** a few minutes, no live call, no recording, no special hardware. Open the menu bar, pick **Tutorial…**, press Next seven times. The suite already proves every control exists and is named correctly, which is the half a checkout can see; what it cannot see is layout at a real window size on a real screen, because the `.missing` verdict depends on where a control actually lands, and SwiftUI offers no headless way to lay out an `NSHostingView` and read a probe out of it. That is `simple` by the 2026-07-30 weighting.
