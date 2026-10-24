# DOC17: the process documents outweigh the source, because every shipped spec is copied whole into one 1.43 MB archive, ARCHITECTURE.md is 188 KB, and filing has no brake while P1s wait on the owner

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) D6, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) SA-5 and SA-6). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Measured 2026-10-24 on `45b8c6a`:

| Thing | Size |
|---|---|
| All tracked Markdown | 4,346,504 B |
| All Swift under `daemon/Sources` plus Python under `pipeline/src` | 4,271,156 B |
| `docs/backlog/q6-final.md` (one file, 135 `[DONE]` spec bodies) | 1,428,696 B |
| `docs/backlog/meetingpipe-q6-backlog.md` | 208,409 B |
| `daemon/docs/gotchas.md` | 191,511 B |
| `ARCHITECTURE.md` (24 `###` sections, the daemon file index among them) | 188,135 B |

Three mechanisms produce this, each written into the process:

1. **`/tech-task` step 8 copies the full spec into the archive.** "The spec text from `docs/backlog/tasks/<ID>.md` moves there prefixed `[DONE]`", and then a sub-bullet explains how to rewrite every relative link one level shallower because HYG6 swept 88 dead links out of `q6-final.md` that the move had broken. Git already keeps every spec at the commit that deleted it; the archive copy duplicates history and creates the link-rot class it then has to police.
2. **`ARCHITECTURE.md` is the mandated orientation read** (root `CLAUDE.md`: "Read before non-trivial work"; `/tech-task` step 2) and is too large to read as orientation. [ARCH13](./ARCH13.md) shrinks its daemon file index by moving files into feature folders.
3. **Filing has no brake.** On 2026-10-24 ten P1 rows in the active ToC are `partial` (END9 to END14, UX74, DET13, HYG7, REC17) and four complex P1s sit in `owner-verification.md` (DET9, REC12, REC13, DIAR5): fourteen P1s whose code shipped and whose confirmation waits on the owner's calendar. The go-live assessment measured throughput falling to 9 commits in September and 4 in October 2026 and read it as the verification queue, not the code, becoming the bottleneck. The owner approved this band's filing on 2026-10-24 with those fourteen open, which is the case the brake below would have put to them first.

## Scope

1. **Ship notes, not spec copies.** Change `/tech-task` step 8's done-done path: the ToC row moves to `q<N>-final.md` with a one-line ship note that names the shipping commit's sha, and `tasks/<ID>.md` is deleted, not copied (the spec is recoverable at `<sha>^`). Delete the link-rewrite sub-bullet, since nothing moves any more. Update `/file-task` step 2's dedupe to search `git log --grep <ID>` alongside the archives, since new archive rows carry no spec text. Existing `q6-final.md` content is left as is.
2. **Split `ARCHITECTURE.md` per subsystem**, after ARCH13 lands so the split does not move a file index that is about to shrink: an index file keeping the subsystem map, data flow, key invariants, on-disk table and glossary, plus one file per subsystem under `docs/architecture/` (daemon detection, recording, transcription, UI, storage; pipeline). `/tech-task` step 2 and the root `CLAUDE.md` orientation row then say to read the index plus the part the task touches.
3. **A WIP brake in `/file-task` and `/audit`**: before filing, count P1 rows that are `partial` in the active ToC plus P1 rows in `owner-verification.md`. Above a threshold the owner sets (the go-live assessment's "a handful"; propose 5), stop and put the count and the list to the owner before writing anything. The owner can approve the filing anyway; the step only makes the trade visible.

## Explicitly not / out of scope

- Rewriting or deleting `q6-final.md`'s existing bodies, the earlier quarter archives, or any shipped spec. History stays where it is.
- Splitting `daemon/docs/gotchas.md` (191 KB). It is read by anchor from `CLAUDE.md` rules, not as orientation; named here so it is not lost.
- The always-loaded `CLAUDE.md` budgets: the [DOC15](./DOC15.md) amend.
- Comment volume in source: [HYG9](./HYG9.md).
- Removing `truth_fences.py` or `ci-local.sh`. Both earn their keep (architecture review, "What is fine").
- A permanent anchor-checking fence. The link fence resolves files, not `#anchors` (`resolve_link` strips the fragment); the split checks its anchors once (see Acceptance), and a standing anchor fence is not filed.

## Acceptance

- `tech-task.md` step 8 no longer copies a spec or rewrites links; `file-task.md` step 2 includes `git log --grep`; the first task shipped after this lands leaves a one-row archive entry with a sha and no `[DONE]` body (checked on that commit).
- `ARCHITECTURE.md` is at most 40 KB after the split, each subsystem file stands alone, and a one-off script run in the commit body resolves every inbound `ARCHITECTURE.md#anchor` link in tracked files (7 on 2026-10-24) to a heading that exists, at its new path where it moved.
- `file-task.md` and `audit.md` carry the brake with the owner's threshold; a dry run on the landing tree prints the count and the list, and stops when the count is over the threshold.
- `python3 scripts/truth_fences.py both` and `bash scripts/ci-local.sh fences` green.
