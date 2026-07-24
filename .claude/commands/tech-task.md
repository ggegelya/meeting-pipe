---
description: Implement a backlog task from the active backlog, one task per session, one commit
---

You're picking up a single backlog task: $ARGUMENTS

0. Sweep stale worktrees first: `sh scripts/prune-worktrees.sh`. It removes worktrees under `.claude/worktrees/` whose branch is already fully merged into `main` and whose tree is clean, plus their branches, and never touches the one you are standing in. It is a silent no-op when there is nothing stale. A `SessionStart` hook runs it too; this line is the backstop for when the hook isn't installed.
1. Read the task definition from the active backlog: the highest-numbered `docs/backlog/meetingpipe-q<N>-backlog.md` (currently `docs/backlog/meetingpipe-q6-backlog.md`; earlier quarters are archived beside it, and the current quarter's shipped items live in `docs/backlog/q<N>-final.md`). The task ID format is `<letter><number>` (e.g. `E5`); ids no longer carry the `TECH-` prefix, so strip a legacy `TECH-` if the argument includes one. Find the task's `| <ID> |` row in the Table of contents for its Status and one-line Comment, then read its full spec: `docs/backlog/tasks/<ID>.md` (one file per task; its Band-origin line points at the shared context in the backlog's Task specs section), or, for an item carried from Q4 unchanged (no `tasks/` file), the `**<ID>` spec in `docs/backlog/q4-final.md` (search the id). If you can't find it, stop and tell me.
2. Read the orientation docs the task touches:
   - [`CLAUDE.md`](CLAUDE.md) at the repo root for git workflow, verification, and conventions worth knowing.
   - [`ARCHITECTURE.md`](ARCHITECTURE.md) for the subsystem map.
   - [`CONVENTIONS.md`](CONVENTIONS.md) for code patterns, the event log, and sidecar schemas.
   - [`ARCHITECTURE.md#glossary`](ARCHITECTURE.md#glossary) for any term in the task description you don't recognise.
   - `daemon/CLAUDE.md` if the task touches Swift, `pipeline/CLAUDE.md` if it touches Python. Both load automatically when you read files in those subtrees.
3. Read the existing files the task points at (file paths in the backlog entry are authoritative; check they still exist before editing).
4. Implement the task. Stop and ask before introducing any new dependency, before extending a global stylesheet, or before extending an existing pattern flagged in CLAUDE.md as needing approval. De-CLI standing rule (see the backlog delegation section): if the task ships a user-facing capability, its UI affordance ships in the same task; a CLI-only ship is `partial`, not done. Owner-dev diagnostics (dogfood, analyze-detection, corrections-stats, train-adapter, spike harnesses) are exempt.
5. Argue back if the task has a better path. The backlog isn't gospel; if you have a concrete reason to deviate, name it before implementing.
6. Verify before declaring done:
   - **Swift edits:** `cd daemon && swift build` and (with full Xcode) `swift test`.
   - **Python edits:** `cd pipeline && uv run --extra dev ruff check src tests` and `uv run --extra dev pytest -q`.
7. Docs sync check (mandatory, after verification): diff what you changed against the orientation docs and update any that drifted, in the same commit:
   - `README.md` when user-visible behaviour, flows, CLI usage, or troubleshooting changed.
   - `ARCHITECTURE.md` when you added, renamed, moved, or retired a module, subcommand, sidecar, or subsystem responsibility (the pipeline subcommand table and the daemon file map are the usual suspects).
   - `CONVENTIONS.md` when a pattern, schema, or event category changed (the sidecar and marker schemas live there).
   - Root / `daemon/` / `pipeline/` `CLAUDE.md` when anything their quick indexes or gotcha lists name changed.
   - `design/` docs when a UI surface changed.
   "No docs affected" is a legitimate outcome, but only after actually checking; name the docs you checked in the summary either way. Stale docs mislead every later session, so treat a needed-but-skipped doc update as a failed verification.
8. Mark the outcome in the backlog:
   - **Done-done:** move the task to the running quarter archive `docs/backlog/q<N>-final.md` in the same commit: its ToC row (Status `done`, a one-line ship note in the Comment) moves there from the active ToC, and the spec text from `docs/backlog/tasks/<ID>.md` moves there prefixed `[DONE]`; delete `docs/backlog/tasks/<ID>.md` (the `tasks/` dir is active-only). Create the archive file with its running-archive header if this quarter's doesn't exist yet.
   - **Partial or owner-owed:** keep the row in the active backlog with that Status and the remainder named in the Comment; do not move it.
9. Commit on `main` (no branch) using the repository's configured git identity:
   ```bash
   git commit -m "<ID>: <short summary>"
   ```
   One logical commit covering the implementation, the doc updates, and the backlog move together. Don't push.
10. **Land the work if this session is running in a worktree.** Detect it first: inside a linked worktree `git rev-parse --path-format=absolute --git-dir` and `git rev-parse --path-format=absolute --git-common-dir` return different paths (`<repo>/.git/worktrees/<name>` against `<repo>/.git`); in the main checkout they return the same path. If they match, step 9 already committed on `main` and there is nothing to land, so skip to step 11. If they differ:
    - Resolve what you need, the main checkout and your task branch: `MAIN=$(git worktree list --porcelain | head -1 | cut -d' ' -f2-)` (the first entry is always the main checkout) and `BRANCH=$(git rev-parse --abbrev-ref HEAD)`.
    - Preflight one thing only: the main checkout must be on `main` (`git -C "$MAIN" rev-parse --abbrev-ref HEAD`), or the merge below lands on whatever branch it happens to have checked out. A dirty main checkout does not block you; a fast-forward leaves unrelated uncommitted work alone, and git refuses on its own when the incoming commit touches a file I have modified there. Never stash, reset, checkout, or commit work you did not make in order to clear the path.
    - Rebase so the landing stays linear: `git rebase main`. A parallel session may have landed while you worked, so expect this to do real work sometimes. On a conflict, stop and report; don't invent a resolution.
    - If the rebase moved your commit, re-run the step 6 verification. Your suite passed against the old base, and a task that landed in between can break it. A red suite after the rebase means you don't land it; report that instead.
    - Land it: `git -C "$MAIN" merge --ff-only "$BRANCH"`. `--ff-only` is deliberate: it keeps one linear commit per task, and it refuses rather than papering over a base you forgot to rebase onto. If it fails because my uncommitted work is in the way, stop and name the files it listed. If it fails on `index.lock`, another session is mid-merge, so wait a few seconds and retry once, then stop and report.
    - Clean up: if this session created the worktree itself, exit it with the remove action. If the worktree came from the new-conversation checkbox instead, that tool is a documented no-op (it only touches worktrees it created), and you must not delete the directory you're standing in either: doing so works, but every later tool call in this session then dies on a missing cwd, so a follow-up question would find a broken session. Leave it, and say it is already merged and that `scripts/prune-worktrees.sh` takes it at the next session start. To land it sooner, print both halves, since the worktree and the branch are separate: `git -C "$MAIN" worktree remove <path>` and `git -C "$MAIN" branch -d "$BRANCH"`.
    - Don't push, in either mode.
11. Summarise: changed files, decisions that weren't in the spec, which docs you checked in step 7 (and which you updated), anything I'd want to know that the diff doesn't show. If you landed from a worktree, say so and name the commit `main` now points at.

If the task is a P3 deferred item, or its prerequisites aren't done, stop and tell me; don't ship a half-implementation.
