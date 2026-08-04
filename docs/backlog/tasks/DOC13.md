# DOC13: the Guide is a repo document rendered in a window, and it reads like one

Band origin: filed 2026-08-04 at the owner's request, on the eyeball leg of DOC11 the day it shipped. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

DOC11 shipped `docs/GUIDE.md` and an in-app reader (`GuideDocument` / `GuideWindow` / `GuideView`) on 2026-08-04. Walking its acceptance the same day, the owner's verdict was that the content is a good start and the surface is not shippable: "it is a good start, but we will need a HARD WORK on UX and UI. it looks ugly like it come from 90s", and separately that it "has references to some development related files, which is definitely not okay from the product perspective that will be shipped eventually".

**The second half is verifiable and is the sharper defect.** The shipped document links to repository paths that do not exist on a user's machine, and the in-app reader renders them as links:

- `docs/GUIDE.md:3` links `[`SETUP.md`](./SETUP.md)`.
- `:5` links `[`README.md`](../README.md)` and tells the reader it is "the reference for every surface and every setting".
- `:305` links `[Moving to a new Mac](../README.md#moving-to-a-new-mac)`.
- `:440` links `[`README.md`](../README.md#troubleshooting)`.

Read from the app, `../README.md` resolves to nothing. The reader is told the real reference lives in a file it cannot open, on a path that only means something inside a git checkout.

**DOC11 already solved the same class one case narrower and stopped there.** Its parser flattens same-document `#anchor` links to their label, and the recorded reason is exactly this one: "one in a window resolves to nothing". A link to `../README.md` has the identical property and a worse failure, because it looks like a working cross-reference to a document the user is being told is authoritative. So this is not a new insight to be argued for, it is an existing rule applied to one more shape.

**The single-copy design is what makes the content problem structural rather than sloppy.** `docs/GUIDE.md` is deliberately one file serving two readers: a contributor reading it in the repo, where `../README.md` is correct and useful, and a user reading it in the app, where it is broken. DOC11 chose the single copy for a good reason (no guide prose in Swift, so editing the document is the whole edit, which is what makes its same-commit maintenance contract enforceable), and that reason still holds. The task is to keep one copy and stop it reading as a repo artifact in the window, not to fork it.

## Scope

Two halves, both owner-visible, and the content half is the one that decides whether the surface is shippable.

**Content.** Sweep the document for anything that only means something inside a checkout: repo-relative links, filenames as filenames, and any instruction whose subject is a file rather than a control. Decide per case between three treatments, and record the rule so the next edit does not reintroduce it: fold the content in (the user needs the fact, not the pointer), drop the pointer (the fact is elsewhere in the Guide), or keep it as a contributor-only aside the renderer strips. Extend `GuideDocument.parse` so a link the app cannot resolve is flattened to its label, the same treatment and for the same stated reason as the anchor case, rather than left to editorial discipline.

**Design.** A visual pass over `GuideWindow` / `GuideView` against `design/README.md` and `PRODUCT.md` rather than against taste. The register is already written down (local-first, quiet, deliberate), the tokens exist in `design/colors_and_type.css`, and the app's own surfaces are the comparison: the Guide should not be identifiably the odd one out beside the Library and Preferences. Typography, spacing, the heading rail, and the reading measure are the likely surface; DSN3's constraints apply (no `.system(size:`, contrast floor 4.5:1, `fgSubtle` clears it and `fgFaint` does not).

## Explicitly not / out of scope

**Not the interactive tutorial.** Filed separately as FEAT15 at the owner's request in the same conversation, because it reverses a standing scope decision and this task does not depend on it. DOC13 makes the document good; FEAT15 is a different surface with a different argument.

**Not forking the single copy.** Two copies is the failure DOC11's contract exists to prevent, and a second copy in Swift would make a stale recipe possible again. If the renderer needs to strip contributor-only content, that is a parser rule over one file, not a second file.

**Not README or SETUP.md's own content.** Their register is correct for their readers. Only the Guide's references to them are in scope.

**Not a hosted docs site**, still deferred.

## Acceptance

`cd daemon && swift build` clean and `swift test` green, with new tests (leave the count to the session that writes them; do not pin an absolute suite total).

**No repo-shaped reference survives in the rendered document.** Pinned as a test over `docs/GUIDE.md` itself rather than as a review promise: no link target contains `../`, no link target ends in `.md`, and the four instances named in Context are gone. This is the DOC11 idiom (its `GuideDocumentTests` already fences the document's own content) and it is what stops the next edit reintroducing them.

A link the renderer cannot resolve is flattened to its label, pinned the way the same-document anchor case already is.

The owner's eyeball on the visual pass, which is the half a test cannot reach: the Guide window opened beside the Library and Preferences does not read as a different application.

`python3 scripts/truth_fences.py both` green. No em-dashes in changed lines. `docs/GUIDE.md` and the in-app reader stay in the same commit, per the maintenance contract in the root `CLAUDE.md`.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts.

1. [session] `./scripts/rebuild.sh`, then tell the owner it is ready.
2. [owner] Open the Guide from the menu bar and read it as a user rather than as its author. Pass: nothing on screen refers to a file you do not have, and nothing tells you the real answer is in a document you cannot open.
3. [owner] Put the Guide window beside the Library and Preferences. Pass: it reads as the same application.
4. [owner] Follow one recipe end to end without leaving the window. Pass: you never needed the thing it used to link to.
5. [owner] Say "DOC13 good to close" (or what is still wrong); [session] moves the row and the spec into `q6-final.md` and deletes this file.
