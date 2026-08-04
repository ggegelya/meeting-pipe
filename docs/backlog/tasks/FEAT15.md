# FEAT15: an interactive tutorial, which reverses a standing scope decision

Band origin: filed 2026-08-04 at the owner's explicit request during DOC11's eyeball: "better to make some tutor overflow with fancy animations etc. you can file a ticket for this." Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## The scope reversal, stated first because it is the reason this file exists

**The root `CLAUDE.md` currently defers exactly this.** Its DOC11 carve-out reads: "The guide is a document plus one menu item, not onboarding machinery: interactive tours, first-run wizards, coach marks, videos, and a hosted docs site all stay deferred." The paragraph above it defers "in-app onboarding wizards, first-run tours, and anything that exists to convert a stranger rather than unblock a user".

The owner asked for this on 2026-08-04 with that deferral in force, and is the only person who can move it. This section exists so that a session picking this up does not have to guess whether the standing rule or the ticket wins, and so that the reversal is a recorded decision rather than a task quietly outranking a documented one.

**What is not yet decided, and must be before code:** whether the deferral is lifted in general, or only for this one surface. The distinction is load-bearing, because the deferred list is what has kept first-run wizards and coach marks out of a single-user product for two quarters, and "we built a tutorial" is the precedent that gets cited next time. The pickup session's first job is to put that question to the owner and record the answer here, then amend the root `CLAUDE.md` in the same commit as the first code, so the rule and the repo agree at all times.

## Context

DOC11 shipped a task-oriented Guide (a document plus a menu item) on 2026-08-04. The owner's verdict on the eyeball leg was that the content is a reasonable start and the presentation is not: it "looks ugly like it come from 90s", and a static document is the wrong shape for teaching the app.

Two things separate this from the deferred class it resembles, and they are the argument for taking it seriously rather than reflexively refusing:

The deferral's stated reason is that onboarding exists "to convert a stranger rather than unblock a user". This owner is the only user and is already converted, so the anti-goal does not apply on its own terms. What the deferral is really protecting against is machinery that costs more to maintain than it teaches, in a product with one user and a fast-moving surface.

That protection is real and this task inherits the risk rather than escaping it. Every animated step that names a control is a claim that goes stale exactly the way DOC7 and DOC9's doc sweeps did, except a stale animation cannot be caught by grep the way a stale sentence can. **The maintenance story is the design problem here, not the animation.** A tour that drives the real UI stays true by construction and is expensive; a tour that reproduces the UI in its own views is cheap and is a second copy of every surface, which is the failure mode DOC11's single-copy rule was written to avoid.

## Scope

Not fixed at filing, deliberately. This task is a decision before it is a build, and the decision is the shape:

- **Drive the real UI** (highlight and narrate actual controls), which cannot go stale about what exists but is the most work and is fragile against layout.
- **A rehearsal surface** (a self-contained animated walkthrough that never touches the live app), which is cheap and is a second copy of the surfaces it teaches, with the staleness that implies.
- **Something narrower than either**, for example animating only the two or three flows that are genuinely hard to discover from the Guide's prose, rather than a tour of everything.

Whichever is chosen, the same-commit maintenance contract that governs `docs/GUIDE.md` and `docs/SETUP.md` has to extend to it before the first step is written, or this becomes the stalest surface in the repo within a quarter.

## Explicitly not / out of scope

**Not DOC13.** The Guide's own visual pass and its content sweep (including the repo-file references the owner found in the same sitting) are filed there and do not depend on this. DOC13 should land first regardless: a tutorial over a document that still points at `../README.md` inherits the problem.

**Not a first-run wizard.** Even under a lifted deferral, something that runs automatically at first launch is a different decision from something the user opens on purpose, and nothing in the owner's request asks for the former.

**Not marketing.** Everything tied to selling stays deferred and this does not change that.

## Acceptance

Cannot be written until the shape is chosen, and saying so is deliberate rather than a gap: the backlog's own rule is that a task which cannot fail verification is not ready, and every acceptance bar here depends on which of the three shapes is picked.

What is fixed at filing, and what the pickup session must satisfy before writing code:

The scope-reversal question above is answered by the owner and recorded here, and the root `CLAUDE.md` is amended in the same commit as the first code so the rule and the repo never disagree.

The chosen shape is recorded here with its maintenance story, specifically how a step naming a control that has been renamed or removed is caught. If the answer is "a human notices", the shape is wrong.

The usual gates apply once there is code: `swift build` and `swift test` green with new tests, `truth_fences.py both` green, no em-dashes, DSN3's constraints on any new surface.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts.

1. [session] Put the scope-reversal question to the owner before anything else: is the deferral lifted for tours in general, or only for this surface? Record the answer in this file.
2. [session] Propose the shape (drive the real UI, a rehearsal surface, or something narrower) with its maintenance story, and get the owner's pick before building.
3. [owner] Confirm DOC13 has landed, since a tutorial over an unfixed Guide inherits its problems.
4. [session] Build, then `./scripts/rebuild.sh`.
5. [owner] Run the tutorial as though new to the app. Pass: every control it names exists and is where it says.
6. [owner] Say "FEAT15 good to close" (or what is wrong); [session] moves the row and the spec into `q6-final.md` and deletes this file.
