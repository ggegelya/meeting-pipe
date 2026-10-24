# DOC15: daemon/CLAUDE.md is back at its CI5 cap one day after DOC14 split it, and the next rule cannot land

Band origin: filed 2026-08-18 from the ten-task batch that landed the same day (`20e66c7` through `b122e00`). Two agents in that batch independently declined to add a rule to `daemon/CLAUDE.md` because there was no room for one. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## The measurement

`daemon/CLAUDE.md` is **23,943 bytes** at `b122e00`, against `CLAUDE_MAX_BYTES = 24_000` in `scripts/truth_fences.py`. That is **57 bytes of headroom**, and `python3 scripts/truth_fences.py claude` passes only because nothing else landed.

The shape of the growth is what makes this a task rather than a trim:

| Point | Bytes | Rules (lines starting `- `) |
|---|---|---|
| Before DOC14 (`8257b22^`) | 73,706 | 44 |
| After DOC14's split (`8257b22`, 2026-08-17) | 18,513 | 44 |
| Now (`b122e00`, 2026-08-18) | 23,943 | 58 |

DOC14 split the narrative onto `daemon/docs/gotchas.md` and left 5,487 bytes of headroom. **One day of parallel batches spent 5,430 of it**, adding 14 rules. No individual entry is the problem: the largest is 435 bytes against `CLAUDE_MAX_ENTRY_BYTES = 800`, and the fence's own comment says a rule runs 200 to 400 while a narrative bullet runs 1,100 to 3,300. This file is at its cap purely by accretion of legitimate one-line rules, which is exactly the condition `CLAUDE_MAX_BYTES` was written to surface. Its failure message says so: "consider whether this subtree wants splitting. Raising CLAUDE_MAX_BYTES is not the fix."

## It is already costing, twice, and both are recorded

**FEAT15 could not state its rule where the rule belongs.** Its tour contract ("a change to a control the tour points at updates the tour in the same commit") is a Swift rule about Swift files, and it lives in the **root** `CLAUDE.md` instead, with the reason written into the text: "That rule is stated here rather than in `daemon/CLAUDE.md` because that file is 185 bytes from its CI5 cap and cannot take another line." FEAT15 drafted a minimal 177-byte line and measured it against 185 free, then declined on the grounds that a sibling landing first would break CI5 on rebase.

**That fear was correct, and it is now measurable.** The 185 came from `3f7448f`, where the file really was 23,815 bytes. DOC12 (`df878d6`) then took it to 23,845 and ARCH6 (`bd32468`) to 23,943. So the root `CLAUDE.md`'s own sentence is stale by 128 bytes, and FEAT15's 177-byte rule now overflows the cap by 120 bytes rather than fitting in 185. A Swift rule is being read out of the root file by every session in the repo, including ones that never touch Swift, because the Swift file is full.

**CI6 had to leave its lesson as a code comment.** Its deny-list-rot finding lives inside `MeetingStore`'s meeting-loading path as a comment beside `let transcriptJSON = files.first { $0.lastPathComponent == "\(stem).json" }`, saying the selector "is deliberately not a deny-list of sidecar suffixes (CI6): this was one ... and the list had fallen thirteen sidecars behind the inventory in ARCHITECTURE.md's on-disk table". It got no `daemon/docs/gotchas.md` section either, and that was the right call under the file's own rule: `daemon/CLAUDE.md`'s header states "A new rule is a line here plus a section there", so a gotchas section with no rule line pointing at it is an orphan nobody reaches, which is worse than none.

So the cap is not merely blocking new rules. It is displacing them into two places (the root file and a source comment) that no Swift session is guaranteed to read.

## Scope

Make room the right way, then land both displaced rules to prove there is room.

**1. Decide what the file is for, and record the answer.** This is the question the cap exists to force and the pickup must answer it explicitly rather than trimming to fit. 58 rules is more than a session reads on every turn regardless of byte count, and the fence's comment is honest that the answer at this end is structural.

**2. The candidate moves, in the order they should be considered.** None is pre-selected here.

- **Re-derive the rule set.** Several of the 58 are per-incident and have outlived their incident; a few pairs collapse into one line. This is the cheapest move and the one most likely to be sufficient on its own, but it is also the one that quietly re-accretes, so it is not sufficient alone as an outcome.
- **Push more narrative down.** `daemon/docs/gotchas.md` already carries 59 `###` sections at 112 KB and is the sanctioned home. Some rule lines still carry their evidence inline rather than linking to it.
- **A further subtree split.** `daemon/Sources/MeetingPipeCore/CLAUDE.md` is the precedent and is 3,218 bytes. The UI rules (the SwiftUI, window, layout and pasteboard cluster, roughly the second half of the Don't section) are candidates for a subtree file of their own, which would only load for sessions in those directories.

**3. Land the two displaced rules in the same commit**, since they are the proof the headroom is real: FEAT15's tour-anchor line moves out of the root `CLAUDE.md` into `daemon/CLAUDE.md` where it belongs, and CI6's deny-list rule gets a line plus its `daemon/docs/gotchas.md` section together.

**4. Correct the stale byte figure.** The root `CLAUDE.md` says "185 bytes from its CI5 cap"; whatever survives of that sentence after step 3 must be true against the tree it ships on, or must not name a byte count at all.

## Explicitly not in scope

**Raising `CLAUDE_MAX_BYTES`.** The root `CLAUDE.md` treats the fence as authoritative, the fence's own failure text says raising it is not the fix, and the owner reaffirmed that on 2026-08-18. If the pickup concludes the constant is genuinely wrong, that is a conversation with the owner before any edit, not a line in this task's diff.

**`CLAUDE_MAX_ENTRY_BYTES` and the allowlist.** Every entry passes at 800, the largest being 435, and `CLAUDE_ALLOWLIST` is empty and documented as intentionally so. Nothing here needs either.

**The other three `CLAUDE.md` files.** All three pass with headroom measured in thousands of bytes rather than in tens, and none is touched, except for the one root sentence step 4 covers. Their sizes are deliberately not pinned here: a sibling session edited the root `CLAUDE.md` and `pipeline/CLAUDE.md` within the hour after this filing and moved both, which is the same rot that made FEAT15's "185 bytes" wrong. Measure them with `wc -c` at pickup rather than trusting a number in a document.

**Deleting a rule to make room.** A rule that still holds stays, whatever it costs in bytes. The moves above are re-homing and de-duplication, never dropping a live constraint to pass a fence.

**Observed but not filed:** `truth_fences.py`'s comment on `CLAUDE_MAX_BYTES` says the backstop lands at "~85 rules at daemon's current average". That average was measured before DOC14 and the file now hits the cap at 58 rules, so the parenthetical is itself drifted. Fix it in passing if this task touches the constant's comment; it is not worth its own row.

## Acceptance

- `wc -c daemon/CLAUDE.md` reports **at most 18,513 bytes**, the size DOC14's split left. The bar is that precedent rather than an invented target, and the ship note records the measured size and the free bytes.
- The rule count is recorded in the ship note alongside the byte count, since the structural question is about rules read per turn and a byte number alone does not answer it.
- FEAT15's tour-anchor rule is present in `daemon/CLAUDE.md` and gone from the root `CLAUDE.md`, and CI6's deny-list rule is present as a line in `daemon/CLAUDE.md` plus a section in `daemon/docs/gotchas.md`, each linking the other.
- Every rule line that survives still resolves: its `docs/gotchas.md` anchor exists, and any file or symbol it names exists. If a subtree split happens, the moved rules resolve from their new depth.
- `python3 scripts/truth_fences.py both` green.
- `cd daemon && swift build` clean. No Swift source change is expected; if one is needed, say why in the ship note.
- The answer to "what is this file for" is written down in the file itself or in `daemon/docs/gotchas.md`, so the next session at the cap inherits a decision instead of re-deriving one.
- No em-dashes in changed lines.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts.

This task is closable without the owner, and the spec says so rather than inventing an observation. The one thing that is genuinely the owner's is the structural call, and only if the pickup lands on the split.

1. [session] Do steps 1 and 2, then state which move was taken and why the other two were not.
2. [owner] Only if the answer is a further subtree split: confirm that a fourth always-loaded file is wanted, since each one is a file every session in its directory pays for. A no here means the answer is the first two moves and a smaller file.
3. [owner] Say "DOC15 good to close" (or what is wrong); [session] moves the row and this spec into `q6-final.md` and deletes this file.

## Amended 2026-10-24 (audit band)

Reopened from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) H1, [AI harness audit](../../audits/2026-10-24-ai-harness-audit.md) defects list and the "Not skills" note under proposal B). The 2026-08-19 ship stands as recorded in the ToC row; what follows is new scope, and the "only the close word is outstanding" state no longer holds.

### The file re-accreted

| Point | Bytes | Rules (lines starting `- `) |
|---|---|---|
| DOC15 ship, 2026-08-19 | 18,400 | 55 |
| `45b8c6a`, 2026-10-24 | 22,440 | 63 |

That is 4,040 bytes and 8 rules in two months, from 10 commits: END9 to END14, REC16, REC17, CI8 and DIST4. The growth is lifecycle and capture rules, which is the scenario the "re-derive the rule set" move was warned about: it was the cheapest move and the one that quietly re-accretes. The file now has 1,560 bytes of headroom under `CLAUDE_MAX_BYTES`.

### The entry fence has a gap

`check_claude`'s `offenders` measures only lines that start with `- ` or `| ` ("if not (line.startswith("- ") or line.startswith("| ")): continue"). A plain paragraph is never measured, so the 800-byte rule-versus-story line does not apply to it. On 2026-10-24 four prose paragraphs exceed 800 bytes and pass:

- root `CLAUDE.md`, the backlog paragraph under "Orientation" ("The active backlog lives in ..."): 1,341 B;
- root `CLAUDE.md`, "Learning to use it is the same carve-out" (DOC11): 1,012 B;
- root `CLAUDE.md`, "Exactly one interactive tour is carved out" (FEAT15): 959 B;
- `pipeline/CLAUDE.md`, "A second Swift-to-Python surface: `mp.speaker_overlay` ...": 803 B.

### Added scope

1. **Close the fence gap.** `offenders` measures every prose line: anything not blank, not a heading, and not inside a fenced code block, at the same `CLAUDE_MAX_ENTRY_BYTES`. Then bring the four paragraphs under it: the two FEAT15 carve-out paragraphs move to `PRODUCT.md` (or `daemon/docs/gotchas.md`, beside the tour section they already link) leaving one rule line in the root file; the DOC11 paragraph and the backlog paragraph split into rule lines with the narrative moved out; the `speaker_overlay` paragraph loses its last few bytes of narration.
2. **Move rules to where their types live.** The rules that name `MeetingPipeCore` types (`CallTeardownOracle`'s cap, `PromotionEngine`'s live veto, the SlimCore mute-log rule) move to `daemon/Sources/MeetingPipeCore/CLAUDE.md` (3,218 B), which loads only for sessions in that target. The pickup checks each rule's subject before moving it; a rule about `MeetingSessionController` stays.
3. **The UI cluster wants a nested file, and that now hits this spec's owner gate.** The window, view, scroll, layout, pasteboard and tutorial rules (from "Don't let a window that holds user-authored text" through "Don't rename or remove a control the tutorial rings", about 6.5 KB on 2026-10-24) are the harness audit's and the architecture review's candidate for a nested `CLAUDE.md`. Two constraints: it is the fourth always-loaded file walkthrough step 2 reserves for the owner, so the owner answers that first; and the views are flat, with 25 `*View`/`*Window` files directly in `daemon/Sources/MeetingPipe/`, so a nested file has no directory to sit in until [ARCH13](./ARCH13.md)'s move-only commit creates feature folders. If the owner says yes, this item lands after ARCH13; items 1 and 2 do not wait for it.

### Added acceptance

- A test beside [`test_link_fence.py`](../../../pipeline/tests/test_link_fence.py): a 900-byte prose paragraph in a scratch `CLAUDE.md` fails the fence; a 900-byte line inside a fenced code block does not; a heading does not.
- `python3 scripts/truth_fences.py claude` green with every prose line in all `CLAUDE.md` files at most 800 B.
- `wc -c daemon/CLAUDE.md` back at or under 18,513 bytes, the original bar, with the byte and rule counts in the ship note.
- Every moved rule still resolves its `gotchas.md` anchor from its new depth.
- Interacts with [DOC18](./DOC18.md), whose precedence paragraph must fit the same 800-byte prose limit, and with [HYG10](./HYG10.md), which rewrites the `@unchecked Sendable` rule in both `daemon/CLAUDE.md` and `MeetingPipeCore/CLAUDE.md`.
