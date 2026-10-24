# AI harness audit, 2026-10-24

Scope: the Claude Code harness for this repo (commands, skills, hooks, settings, CLAUDE.md files, global setup) measured against what actually goes wrong, from three read-only passes: 26 session transcripts, 1,015 commits, and the harness files themselves. Nothing here is filed or implemented yet; every item waits on the owner.

## What goes wrong, ranked by cost

| # | Failure mode | Evidence | Mechanized today? |
|---|---|---|---|
| 1 | **CI is red and nobody notices.** Main has failed every pushed run since 2026-07-31 (verified: `gh run list` shows the last 5 all `failure`, latest 2026-10-23). CI installs a hand-pinned dep set instead of `uv.lock`, so anthropic 2.0.0 broke pyright and pytest stopped running. Pushes are rare and no session ever checks CI. | 3 episodes; owner had to say "pipelines is failing" twice; go-live audit QG-1, SA-1 | No |
| 2 | **The same end-of-call behaviour is re-patched repeatedly.** Each detection or teardown fix replaces the previous rule and breaks a new case that the owner finds in a real meeting. | about 46 `fix(detector\|detection\|micgate\|lifecycle)` commits; END9 > END10 > END12 > END13; DET2 > DET8 | Partly (pure `decide()` tests) |
| 3 | **Green tests for code nothing calls.** The pure logic is tested and the production wiring is not. | END9 had 28 green tests and `Coordinator` never called `start()`; DET13 > END11; REC15 > REC16; UX54 reopened; CI6 fixed 5 tests that could not fail | One fence (CoordinatorWiringFenceTests) |
| 4 | **UI regressions caught only by the owner's eye.** The menu-bar app cannot be screenshotted, so every UI task ends in "owner to eyeball". | about 33 UI fix commits; about 18 rows in owner-verification.md | Token fences only |
| 5 | **Docs drift.** Claims go stale, then a sweep fixes dozens at once. | DOC7, DOC9, DOC12, HYG6 (88 dead links), HYG8, HYG7; GUIDE.md promised END11 one fix early | Links and config yes, claims no |
| 6 | **Task specs are wrong against the code**, found only mid-implementation, costing an owner round-trip. | 6 of 15 /tech-task sessions | No |
| 7 | **Self-review misses what adversarial review catches.** | 9d0384da: 5 DET1 bugs including one introduced by Claude's own fix; /tech-task has no adversarial step | Only in /audit |
| 8 | **Em-dashes.** 6 cleanup commits, CI job then dropped 2026-08-18. Claude ran its own em-dash grep 89 times across 16 sessions. | 69aa95c, 6140118, e675462, b662e7f, 052fb38, fbc5cbe | Local pre-commit only |
| 9 | **Prose rules that already drifted from the code.** "Two `@unchecked Sendable`, don't add a third": there are 8. "No outbound HTTP from the daemon": `NotionDatabaseList.swift` uses URLSession. | grep verified | No |
| 10 | **Tool waste.** 33 Edits failed with "file not read" (read via `cat` first); guessed paths (`src/meeting_pipe/` vs `src/mp`); `grep` is ugrep here. | transcripts | No |

## Harness defects (cheap, factual fixes)

- `.claude/commands/tech-task.md` step 6 verifies only `swift build/test`, ruff and pytest. It omits pyright (`--extra mcp`) and `truth_fences.py`, both CI gates. Step 7 cites a "12 KB budget"; the real caps are 24,000 B per file and 800 B per entry.
- Its docs-sync list omits GUIDE.md and SETUP.md despite the root same-commit contract.
- The em-dash CI job is gone but `CONVENTIONS.md:24`, `CONTRIBUTING.md:38`, `docs/backlog/meetingpipe-q6-backlog.md:23`, `.claude/commands/file-task.md:21`, the `scripts/pre-commit` comment and ADR 0005 still say CI enforces it.
- Root `CLAUDE.md` says CI daemon runs on macos-14; `ci.yml` uses macos-15.
- Step 0 (janitor, 627 B) is byte-identical in all four commands and the landing section is 76 to 92% identical, about 9 KB duplicated. It has already drifted (`prune-worktrees.sh:10` still calls the sweep "step 1").
- `design/SKILL.md` (a meeting-pipe design skill) sits outside `.claude/skills/`, so it is never discovered.
- `scripts/test-prune-worktrees.sh` and `scripts/test-login-agent-guard.sh` are "mandatory" but CI never runs them.
- The CLAUDE.md entry fence only measures lines starting `- ` or `| `, so long paragraphs escape it (root `CLAUDE.md:29` is 1,341 B).
- Allowlist: missing what the commands need (`git commit`, `git rebase`, `git -C * merge --ff-only`, pyright, `truth_fences.py`, the two test scripts); too broad in places (`Bash(find . *)` allows `-delete`/`-exec`, local `Bash(node *)`).

## Conflicts between global and project instructions

The owner had to type "commit on main, we are not using branching" into both worktree sessions on 2026-10-24. Causes:

- Global: "NEVER start coding on a protected branch, create a feature branch with `--no-track`". Project: "Work directly on `main`".
- Global: "MANDATORY: Plan Mode First". /tech-task fan-out subagents cannot reach the owner, and the project never says its command gates replace Plan Mode.
- Global bans AI attribution trailers; the harness injects one. Practice follows the global rule (0 trailers in the last 200 commits) but nothing in the project says so.
- Global `writing` skill and `writer-agent` target `<docs-root>/ADRs/` in MADR; the repo keeps ADRs in `docs/decisions/NNNN-*.md` with a property-table header. `<docs-root>` is still a placeholder.
- Global `development` skill is .NET/Angular only but its description triggers on any implementation; `refactoring` and `engineering-principles` point to it.
- Global CLAUDE.md names `/adr`, `/refactor-plan`, `/investigate`, `/pr-review`; none exist.

## Proposals

### A. Make the gates mechanical (highest value)

1. **Get CI green and pin it to `uv.lock`** so local green predicts CI green. Already QG-1 in the go-live assessment; this audit only raises its priority.
2. **`scripts/verify.sh [changed|all]`**: one runner for the whole verify table (ruff, pyright `--extra mcp`, pytest, swift build/test, truth fences, em-dash diff), choosing gates by changed paths. The commands, the pre-commit hook and a Stop hook all call it instead of each restating the table. Replaces about 500 hand-typed gate commands.
3. **SessionStart CI status line**: extend the existing hook to print the latest `main` CI conclusion (`gh run list -L1`, skipped silently offline). One line would have surfaced the 82-day red.
4. **PostToolUse em-dash hook** on Edit/Write: catches U+2014 at the edit, not at commit time.
5. **Source fences for the drifted rules**: an `@unchecked Sendable` allowlist and a URLSession allowlist in the daemon. Needs an owner call first on whether the rule or the code is right (8 vs 2; Notion HTTP).
6. **Run the two "mandatory" shell test scripts in CI.**

### B. Skills (project-scoped, tracked in `.claude/skills/`)

1. **`land-worktree`**: step 0 plus the rebase and ff-only landing, referenced by all four commands. Removes about 9 KB of duplicated, already drifting text.
2. **`contract-change`**: every cross-tree surface in one checklist (sidecar, publish.json, restore plan, config keys, event categories): Swift writer, Python reader, `gen_contract_fixtures.py`, `test_workflow_overlay.py`, CONVENTIONS row, truth fence. Today this is spread across three CLAUDE.md files.
3. **`daemon-ui`**: move `design/SKILL.md` in and merge it with the token contract (`Tokens.swift` vs `colors_and_type.css`), the JSX mockup-first flow, the CI token fences, and a structured owner-eyeball handoff. `impeccable` stays local; it is web-oriented.
4. **`adr`**: the repo's own ADR format and numbering, so the global `writing` skill stops pulling toward MADR and the docs root.
5. **`verify-live`**: `rebuild.sh`, `tail-events.sh`, `valid1_check.py`, what to read in the event log, and how to write an owner-verification row.

Not skills: the UI cluster (about 5.1 KB) and the audio-capture cluster (about 2.6 KB) of `daemon/CLAUDE.md` (21.7 KB of a 24 KB cap) should move into nested `CLAUDE.md` files beside the code they govern. Nested files load automatically for their directory; a skill loads only if its description matches, which is too weak for guardrails.

### C. Command changes

1. **/tech-task, spec check before planning**: confirm every premise in the spec against the code and report mismatches before touching anything (6 of 15 sessions hit a wrong spec).
2. **/tech-task, wiring rule**: any new component must have a test that fails if the production path never calls it (the END9 class, about 8 incidents).
3. **/tech-task, adversarial review** for changes under detection, lifecycle and capture, reusing /audit's skeptic pass (about 46 detector fixes; 9d0384da).
4. **/tech-task step 6 and docs-sync**: call `verify.sh`, add GUIDE.md and SETUP.md.
5. **`/backlog-query`**: the owner has asked by hand for "independent tasks that need no decision from me" and "tasks needing a big recording base". A read-only filter over the active backlog.

### D. Branching, release, rollback

- **Branching: keep trunk-on-main.** Single owner, linear history and per-session worktrees already give isolation; a PR flow adds ceremony without a reviewer. The fix is to make it explicit: one "Precedence" paragraph in the project CLAUDE.md saying it overrides the global branching, Plan Mode and attribution rules here, and naming which command gates stand in for Plan Mode.
- **Release: stamp and keep one previous build.** `install.sh` and `rebuild.sh` hard-code version 0.1.0 build 1 and `rm -rf` the old bundle. Stamp the git SHA into `CFBundleVersion`, keep `MeetingPipe.app.prev` for a one-command rollback, and optionally tag each install. This also makes "the installed build is 6 weeks stale" visible from the About box.

### E. Global and memory hygiene (outside the repo)

- Narrow the `development` skill description to .NET/Angular, set `<docs-root>`, and drop the four nonexistent commands from the global CLAUDE.md.
- `gitkraken-hooks` registers on about 22 hook events with no matcher; keep only if used.
- Run a memory consolidation: several entries are stale (448 tests vs 1,396 now; UX16 listed as pending though it shipped 07-11).

## Suggested order

A1 (CI green) first, since every other gate is moot while CI is red. Then the cheap factual fixes and the precedence paragraph (one small commit each), then A2 to A4 and B1 together (verify.sh and land-worktree are what the commands will call), then B2, C1 to C3, D, and the rest.
