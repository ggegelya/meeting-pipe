---
description: Implement a TECH-* task from the active backlog, one task per session, one commit
---

You're picking up a single backlog task: $ARGUMENTS

1. Read the task definition from the active backlog: the highest-numbered `docs/backlog/meetingpipe-q<N>-backlog.md` (currently `docs/backlog/meetingpipe-q4-backlog.md`; earlier quarters are archived beside it). The task ID format is `TECH-<letter><number>` (e.g. `TECH-E5`). Search for the line starting with `**TECH-...` matching the ID. If you can't find it, stop and tell me.
2. Read the orientation docs the task touches:
   - [`CLAUDE.md`](CLAUDE.md) at the repo root for git workflow, verification, and conventions worth knowing.
   - [`ARCHITECTURE.md`](ARCHITECTURE.md) for the subsystem map.
   - [`CONVENTIONS.md`](CONVENTIONS.md) for code patterns, the event log, and sidecar schemas.
   - [`GLOSSARY.md`](GLOSSARY.md) for any term in the task description you don't recognise.
   - `daemon/CLAUDE.md` if the task touches Swift, `pipeline/CLAUDE.md` if it touches Python. Both load automatically when you read files in those subtrees.
3. Read the existing files the task points at (file paths in the backlog entry are authoritative; check they still exist before editing).
4. Implement the task. Stop and ask before introducing any new dependency, before extending a global stylesheet, or before extending an existing pattern flagged in CLAUDE.md as needing approval.
5. Argue back if the task has a better path. The backlog isn't gospel; if you have a concrete reason to deviate, name it before implementing.
6. Verify before declaring done:
   - **Swift edits:** `cd daemon && swift build` and (with full Xcode) `swift test`.
   - **Python edits:** `cd pipeline && uv run --extra dev ruff check src tests` and `uv run --extra dev pytest -q`.
   - Update README.md or SPEC.md if user-visible behaviour or contracts changed.
7. Mark the task `[DONE]` in the active backlog file (prefix the `**TECH-...` line; keep the trail, don't delete).
8. Commit on `main` (no branch) using the repository's configured git identity:
   ```bash
   git commit -m "TECH-<ID>: <short summary>"
   ```
   One logical commit. Don't push.
9. Summarise: changed files, decisions that weren't in the spec, anything I'd want to know that the diff doesn't show.

If the task is a P3 deferred item, or its prerequisites aren't done, stop and tell me; don't ship a half-implementation.
