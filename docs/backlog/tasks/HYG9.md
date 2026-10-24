# HYG9: production comments carry about 3,000 ticket-ID tokens as a changelog, against the comments policy, and nothing stops the count from growing

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) D1, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) SA-6 docs half). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

`CONVENTIONS.md`'s "Comments policy" says: "Don't reference the current task (`// E5 fix`), the bug ticket, or "added by …". Those rot." The code does the opposite at scale. Measured 2026-10-24 over tracked files with a regex for band-style IDs (`TECH-` optional, 1 to 6 capitals, 1 to 3 digits, optional `-SUFFIX`):

| Tree | Comment lines | Comment lines naming an ID | ID tokens |
|---|---|---|---|
| `daemon/Sources` (295 files, 70,160 lines) | 18,645 | 2,747 | 2,958 |
| `pipeline/src` (69 files, comments and docstrings) | n/a | 636 | 672 |

The architecture review counted 2,612 Swift lines with a narrower pattern; the order of magnitude is the finding, not the exact figure, and the regex also catches non-IDs such as `UTF8`, which is why the fence below builds its pattern from the backlog's own vocabulary. `MeetingRecorder` alone carries 894 comment lines. The narration is where the false claims [HYG10](./HYG10.md) fixes live: a comment that tells the story of a ticket stops being checked against the code the moment the ticket closes. A sample of the shape, from `CallTeardownWatcher`: "the target's two documented `@unchecked Sendable` conformances stay two (the island rule in `MeetingPipeCore/CLAUDE.md`)", which was a count at one commit and is now false (there are seven).

The review's advice, which this task adopts: do not mass-rewrite (a sweep of 3,600 lines is a review nobody can do, and it would bury every other diff for weeks). Stop the growth with a ratchet, and shrink by touch.

## Scope

1. **A ratchet fence in `scripts/truth_fences.py`**, a new `comments` check run by `both` (so `ci-local.sh truth-fences` and `fences` pick it up with no YAML change):
   - The ID pattern is built from the band prefixes that actually appear as row IDs in `docs/backlog/*.md` ToC tables (`PIPE`, `END`, `REC`, `HYG`, `TECH-` forms, ...), so `UTF8`, `H264` or `A11Y` never count.
   - It counts ID tokens inside comments only: Swift `//`, `///` and `/* */` lines under `daemon/Sources`, Python `#` comments and docstrings under `pipeline/src`. Code and string literals do not count (an event attribute or a test name that carries an ID is data, not narration).
   - Two ceilings, `COMMENT_ID_CEILING = {"daemon/Sources": N, "pipeline/src": M}`, set to the measured counts on the tree the task lands on. Above a ceiling fails with the offending files' deltas. Below a ceiling also fails, telling the session to lower the constant to the new count: the same stale-entry contract `CLAUDE_ALLOWLIST` uses, so a ratchet that has been released cannot quietly re-absorb growth.
2. **One rule line in `.claude/commands/tech-task.md` step 4**: when you edit a function, replace its ticket narration with the invariant in at most three lines; the history goes to the commit message and, when it is a sharp edge, to `daemon/docs/gotchas.md` or `pipeline/docs/gotchas.md`. Then lower the ceiling in the same commit.
3. **`CONVENTIONS.md` "Comments policy"**: one sentence naming the fence, so the rule and its enforcement are found together.

## Explicitly not / out of scope

- A mass rewrite of existing comments, for the reason above. Shrinking happens on touch.
- A diff-based check ("no added line in a comment may contain an ID"), the shape the design-token font check uses. Rejected: a moved or reindented comment shows as added, so [ARCH13](./ARCH13.md)'s move-only commit and [ARCH8](./ARCH8.md)'s extractions would fail it for no new narration. A count is invariant under moves.
- A per-file allowlist. 295 Swift files would make a table nobody reads; two tree-level ceilings carry the same ratchet.
- Tests (`daemon/Tests`, `pipeline/tests`). A test pinning an incident by ID is traceability with a reader, and the fences in `daemon/Tests` cite IDs on purpose. Scripts and docs are out too; [DOC17](./DOC17.md) owns docs volume.
- Fixing false comments. That is [HYG10](./HYG10.md); a comment HYG10 corrects lowers the count, and whichever lands second rebases its ceiling.

## Acceptance

- `python3 scripts/truth_fences.py comments` passes on the landing tree with the ceilings at the measured counts, and `both` includes it.
- A test beside [`test_link_fence.py`](../../../pipeline/tests/test_link_fence.py) (the precedent for testing a truth fence from pytest): adding one `// PIPE19: ...` comment line to a scratch copy fails the fence; removing one ID-bearing comment fails it with the "lower the ceiling" message; an ID inside a Swift string literal or a test file does not count; `UTF8` in a comment does not count.
- The ID-prefix set is derived from the backlog at run time, and a test asserts it contains at least `PIPE`, `END` and `HYG` so a broken parser cannot yield an empty pattern that passes everything.
- `.claude/commands/tech-task.md` step 4 carries the one-line rule, and `CONVENTIONS.md` names the fence.
- `bash scripts/ci-local.sh fences` green. No source file changes in this task.
