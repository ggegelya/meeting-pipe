# MeetingPipe owner-verification backlog

Shipped work whose engineering is green and which is waiting on the owner to confirm it behaves. Nothing here is a task a session picks up and implements; the code already landed. This file exists so the active backlog holds only what a session can actually start, and so the queue of things waiting on the owner is legible as its own list rather than scattered through 57 rows.

Since 2026-10-26 this file holds the gate and the queue lives in the tasks themselves: a task waiting here has `status: owner-verify` and `verification: simple` or `complex` in the header of its `tasks/<ID>.md`, and the **Owner verification** section of [`INDEX.md`](./INDEX.md) is the generated list. [`meetingpipe-q6-backlog.md`](./meetingpipe-q6-backlog.md) holds the process rules for work to be done. This is the gap between building and closing: done building, not yet confirmed.

## How a row gets here (the gate)

A session may not decide on its own that its task is owner-owed. Added 2026-08-18 at the owner's request, after REC12 and REC13 both landed with walkthroughs the owner could not run when asked ("for the rest it is hard to test now").

Before a task moves here, the session must do two things and then stop:

1. **Clarify the verification.** Say exactly what the owner has to do, what a pass looks like, what it costs them in time and setup, and why it cannot be checked in a harness instead. "Owner eyeball" is not a verification step; neither is a walkthrough that assumes a live meeting without saying so.
2. **Get the owner's approval to move it.** The owner decides whether that verification is worth their time and whether the categorization below is right. A task whose verification is vague, impractical, or not worth doing gets fixed, automated, or closed on tests instead. It does not get parked here.

Until both happen the task stays `partial`. A task that reaches its ship commit without an approved verification plan is not finished being scoped, and moving it here anyway is how a queue of unrunnable checks accumulates.

## The two weights

**simple**: a few clicks in the app, a Preferences pane, a Finder window. No live call, no real meeting, no waiting. Doable in one sitting whenever the owner has ten minutes.

**complex**: needs a live meeting, real call audio, specific hardware to plug and unplug, or dwell time across several meetings before a verdict is possible. Cannot be scheduled at will, because it depends on the owner's actual calendar.

The weight is about what the check *costs the owner*, not how hard the task was to build or how severe the bug was. REC12 is a P1 crash fix and is `complex` only because confirming it means using the app for a working day.

## How a row leaves

The owner runs the walkthrough in `tasks/<ID>.md` and says "<ID> good to close" or what is wrong. On a pass the session sets `status: done`, drops `verification:`, adds `closed: <date>` and a one-line close note in `comment:`, exactly as a done-done task closes. On a fail the remainder is engineering work and the task goes back to `partial`, not back into this queue.

Specs stay in [`tasks/`](./tasks/) throughout, so their walkthroughs stay reachable at the path every other document already links to.

## The queue

Generated: the **Owner verification** section of [`INDEX.md`](./INDEX.md), split into Simple and Complex. `python3 scripts/backlog.py list --status owner-verify` prints it too.

## Known gap at extraction (2026-08-18)

These eight predate the gate above and were moved as-is at the owner's direction, so none of them went through the clarify-and-approve step. Two are worth naming rather than discovering later.

**UX45 has no `## Owner walkthrough` section at all.** Its owner-owed remainder is one line at the end of its Acceptance ("Owner eyeball: set a Filesystem output directory in Integrations; an NDA workflow's editor no longer shows an unconfigured caption; toggle Include the full transcript off and a republished Notion page carries the summary without the transcript body"). That violates the 2026-07-30 rule that every owner-gated task carries a walkthrough, and it is exactly the shape the gate now exists to stop.

**DIAR3 is seven-eighths done.** Steps 1 to 7 were completed on 2026-07-31 and only step 8 is open: turn on "Clean up speaker labels after transcription" and live with it for a few meetings. It is `complex` because of the dwell time, not because anything is difficult.

**Resolved 2026-08-18:** that step 8 is now merged into DIAR5's walkthrough rather than run on its own. DIAR5 changed what the toggle does, so the step as written asks for a verdict on behaviour that no longer ships, and two dwell-time rows for one activity is the queue bloat this file exists to prevent. Worth carrying as the general case: when a later task changes the surface an open walkthrough grades, the walkthrough is stale in the same way a doc is, and re-pointing it is the fix rather than running it as written.
