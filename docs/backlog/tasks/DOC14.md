# DOC14: the always-loaded docs outgrew their job

Band origin: owner-requested review of the `CLAUDE.md` practice, 2026-08-16. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## The finding

Every `CLAUDE.md` is prepended to every prompt in its subtree. That makes them the only docs in this repo whose cost is paid per turn rather than per read, and nothing was measuring them. Measured 2026-08-16, a session touching Swift loaded ~26k tokens of instructions before reading a line of code: `daemon/CLAUDE.md` 16.7k, the repo root 3.2k, the user's global 3.3k, `MEMORY.md` 1.6k, the workspace root 0.6k, the Core island 0.8k.

`daemon/CLAUDE.md` alone was **64%** of that, and its growth is the whole story:

| Date | Size |
|---|---|
| 2026-05-14 | 3.8 KB |
| 2026-07-01 | 4.6 KB |
| 2026-07-15 | 6.6 KB |
| 2026-08-01 | 31.9 KB |
| 2026-08-16 | 71.7 KB |

94 commits, monotonic, nothing ever removed. It grew another 4.7 KB during the ~20 minutes of the review itself, as UX62, UX63, UX64 and UX65 landed.

**It was not stale.** All 30 Swift symbols and 15 test files it named still resolved, which is why no doc-truth sweep had caught it. DOC12 and HYG6 look for prose that stopped being true; this is prose that is true, relevant, and in the wrong file.

## Why it happened

Two rules that are individually right and compound badly.

1. **`/tech-task` step 7 made appending mandatory and removal invisible.** It required updating `CLAUDE.md` when a gotcha list changed and called a skipped doc update a failed verification, with no matching pressure to delete, compress, or budget.
2. **The house style writes the incident, not the rule.** In the `Don't` section: 35 bullets, 7,124 words, median 147 words per bullet, longest 560, and 18 over 150. The actionable rule is the first sentence, 6 to 10 words. `Don't bootout the resident agent` carried 243 more words; `Don't add startup work to App.main() above...` carried 374.

A third made it hard to see: the no-hard-wrap rule means one bullet is one line, averaging 712 characters and peaking at 3,337, so line-based diffs understate the growth and every edit rewrites a whole paragraph.

The narrative is good writing and it is worth keeping. Each of those paragraphs encodes a real defect that cost real time, and several record measurements nobody should have to repeat. The defect is placement: 35 imperative rules each buried in a paragraph of forensics compete for attention with the task, so the failure mode is not cost, it is an agent skimming a 560-word bullet and missing the one clause that binds it.

## The shape of the fix

Split rule from evidence, and fence the split.

- **`CLAUDE.md` carries the rule**: one imperative line, plus any constraint that must be obeyed without reading further, plus a link.
- **The sibling `docs/gotchas.md` carries the evidence**: one section per rule, at whatever length the measurement needs, read on demand.
- **`scripts/truth_fences.py claude`** enforces a 12 KB per-file budget with the same ratchet-allowlist contract as the config and event fences. Raising the budget is explicitly not the fix.
- **`/tech-task` step 7** now names `gotchas.md` as the default home for that writing and reserves `CLAUDE.md` for rule changes.

## Scope

1. Fence + `/tech-task` step 7 + CONVENTIONS.md + trim the repo-root `CLAUDE.md` under budget. **Shipped 2026-08-16.**
2. Split `daemon/CLAUDE.md`. The 44 narrative bullets move verbatim to `daemon/docs/gotchas.md`; the quick index loses its per-row essays and keeps the file names, since [`ARCHITECTURE.md`](../../../ARCHITECTURE.md)'s Daemon section already carries what each one does.
3. Split `pipeline/CLAUDE.md` the same way.
4. `AGENTS.md`: it is an untracked hand-fork of the repo-root `CLAUDE.md`, so it drifts invisibly and escapes review. It points at `daemon/AGENTS.md`, `pipeline/AGENTS.md` and `MeetingPipeCore/AGENTS.md`, none of which exist, so a Codex session gets no subtree guidance at all; and its find-and-replace produced `.Codex/worktrees/` where the real path, and what `scripts/prune-worktrees.sh` prunes, is `.claude/worktrees/`.

## Not in scope

The user-global `~/.claude/CLAUDE.md` (3.3k tokens) is outside this repo and serves two lanes; it is the owner's to trim. `MEMORY.md` is auto-memory with its own consolidation path. `ARCHITECTURE.md` (144 KB), `README.md` (147 KB) and `CONVENTIONS.md` (84 KB) are large but read on demand, which is the point of moving prose into that class rather than out of it.
