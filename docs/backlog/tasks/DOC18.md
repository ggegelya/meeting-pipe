# DOC18: the owner's global instructions and this repo's instructions contradict each other on branching, Plan Mode, commit attribution and ADR location, and nothing says which wins here

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) H3, [AI harness audit](../../audits/2026-10-24-ai-harness-audit.md) "Conflicts between global and project instructions" and proposal D). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Every session here loads two instruction sets: the owner's global `~/.claude/CLAUDE.md` and this repo's root `CLAUDE.md`. Re-read side by side on 2026-10-24:

| Topic | Global | This repo | Effect |
|---|---|---|---|
| Branching | "NEVER start coding directly on a protected branch ... Create a feature branch first", with `--no-track` | "Work directly on `main`", worktrees for parallel sessions | The owner typed "commit on main, we are not using branching" into both worktree sessions on 2026-10-24. |
| Plan Mode | "MANDATORY: Plan Mode First. Every engineering action MUST start with Plan Mode" | Never mentions Plan Mode; `/tech-task`'s fan-out subagents "cannot reach the owner" by its own text | A subagent cannot satisfy the global rule, and nothing says the command's owner gates replace it. |
| Commit attribution | "NEVER include AI attribution (`Co-Authored-By: Claude`, ...)" | Silent | The harness audit found 0 trailers in the last 200 commits that morning. **Since then all 8 commits of 2026-10-24 (`76974b5` to `45b8c6a`) end in `Co-Authored-By: Claude Opus 5.5`**, because the harness injects one and the repo says nothing. The conflict is live, not hypothetical. |
| ADRs | `writing` skill and `writer-agent` write MADR 4.0.0 to `<docs-root>/ADRs/`; `<docs-root>` is still the placeholder | `docs/decisions/NNNN-slug.md` with a property-table header | A session following the global route writes to a path that does not exist, in the wrong format. |

Outside the repo, also verified: the global file names `/adr`, `/refactor-plan`, `/investigate` and `/pr-review`, and `~/.claude/commands/` does not exist; the global `development` skill's description reads "Code standards for .NET, Angular, and TypeScript. Use when writing code, implementing features, or fixing bugs", so it triggers on Swift and Python work it has nothing to say about.

## Scope

1. **One "Precedence" paragraph in the root `CLAUDE.md`**, in the Git workflow section, at most 800 B so it passes the per-paragraph fence the [DOC15](./DOC15.md) amend adds. It states, for this repo only:
   - commit on `main`; per-session worktrees are the isolation, and the global feature-branch rule does not apply;
   - the command gates replace Plan Mode: `/tech-task` step 5's argue-back, [HYG14](./HYG14.md)'s premise check, and the multi-task question round are where the owner approves; outside a command, plan as the global rule says;
   - the attribution rule the owner picks (below);
   - ADRs live in `docs/decisions/` in the repo's own format ([HYG13](./HYG13.md)'s `adr` skill), never under a global docs root.
2. **Owner decision on attribution trailers**, asked before the paragraph is written: follow the global ban (no trailer; the default, since it is the owner's own standing rule) or allow the harness trailer here. Whatever the answer, the paragraph says it in one clause so the next session stops guessing.
3. **A list for the owner, not edits**: the global-side fixes the audit proposes (set `<docs-root>` or drop the Output Locations table, remove the four nonexistent commands, narrow the `development` skill's description to .NET and Angular). They live in `~/.claude/`, outside this repo, and no session edits them.

## Explicitly not / out of scope

- Editing anything under `~/.claude/` (owner's own files; scope item 3 is a list).
- Rewriting the 8 commits that already carry a trailer. `main` is pushed; a history rewrite costs more than the trailers do.
- Switching this repo to a PR flow. The harness audit's recommendation is to keep trunk-on-`main` for one owner with worktrees, and this task only makes that explicit.
- The harness defects list ([HYG11](./HYG11.md)) and the `/tech-task` process steps ([HYG14](./HYG14.md)).

## Acceptance

- The paragraph exists, names all four topics, and is at most 800 B (`awk` the line length in the commit body); `python3 scripts/truth_fences.py claude` green.
- The owner's attribution answer is recorded in the paragraph and in this row's ship note.
- The first commit after this lands follows the recorded attribution rule (checked with `git log -1 --format=%B`).
- The owner-side list is in the ship note, so it is not lost when the spec is archived.
- `bash scripts/ci-local.sh fences` green.
