# HYG11: the harness still carries defects CI8 did not touch: a wrong byte budget, a docs-sync list missing two contract docs, six claims that CI blocks em-dashes, two mandatory scripts CI never runs, and 9 KB of duplicated landing text

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) H2, [AI harness audit](../../audits/2026-10-24-ai-harness-audit.md) defects list, proposals A4, A6 and B1, and the allowlist defect). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

The harness audit listed nine defects on the morning of 2026-10-24; CI8 landed later that day. Re-checked against the tree after CI8 (`45b8c6a`):

**Already fixed, not in scope:** `/tech-task` step 6 now runs `bash scripts/ci-local.sh`, which covers pyright `--extra mcp` and `truth_fences.py` (CI8, `af4a909`); the root `CLAUDE.md` now says CI runs on macos-15, matching `ci.yml`. The CLAUDE.md paragraph-fence gap is the [DOC15](./DOC15.md) amend, and `design/SKILL.md` is [HYG13](./HYG13.md).

**Still open, each verified:**

1. `.claude/commands/tech-task.md` step 7: "`python3 scripts/truth_fences.py claude` enforces the 12 KB budget". The constants are `CLAUDE_MAX_ENTRY_BYTES = 800` and `CLAUDE_MAX_BYTES = 24_000`.
2. The same step's docs-sync list names README, ARCHITECTURE, CONVENTIONS, the two `gotchas.md`, the `CLAUDE.md` files and `design/`, but not `docs/GUIDE.md` or `docs/SETUP.md`, which the root `CLAUDE.md` puts under a same-commit contract.
3. **Six places say CI fails on an em-dash, and none does.** The owner dropped the job on 2026-08-18 (`fbc5cbe`, "Owner's call: the rule existed to catch machine-written prose, and the whole project is AI-built, so it no longer discriminates anything"). Still claiming CI enforcement: `CONVENTIONS.md` "No em-dashes" (the `conventions` job bullet), `CONTRIBUTING.md` ("CI fails on a U+2014 added under `daemon/Sources`"), the Conventions line of `docs/backlog/meetingpipe-q6-backlog.md`, `.claude/commands/file-task.md` step 8, the header of `scripts/pre-commit` ("mirrors the CI em-dash rule", "mirrors ci.yml's diff step exactly"), and ADR 0005 (Status Accepted, describes the CI job). The only enforcement is the local hook, installed on the owner's Mac as a symlink. `pipeline/src` has 57 lines containing U+2014; `daemon/Sources` and `daemon/Resources` have none.
4. `scripts/test-prune-worktrees.sh` and `scripts/test-login-agent-guard.sh` are "mandatory" in the root `CLAUDE.md` verify table, but `ci-local.sh` never calls them (it does call `test-app-relocation.sh`).
5. `scripts/prune-worktrees.sh`'s header says it runs from "step 1 of the backlog commands"; it is step 0 in all four.
6. Step 0 is byte-identical in `tech-task.md`, `file-task.md`, `spike.md` and `audit.md` (same md5 on 2026-10-24), and the harness audit measured the landing step at 76 to 92% identical across them, about 9 KB in all. Item 5 is the drift that duplication already produced.
7. `.claude/settings.json` allowlist: lacks what the commands run (`bash scripts/ci-local.sh`, `python3 scripts/truth_fences.py`, `git commit`, `git rebase main`, `git -C <main> merge --ff-only`, the two test scripts), and `Bash(find . *)`, `Bash(find pipeline *)`, `Bash(find daemon *)`, `Bash(find scripts *)` also allow `-delete` and `-exec`.

## Scope

One commit, all harness text and config:

1. Step 7 names the two constants instead of a figure ("within `CLAUDE_MAX_ENTRY_BYTES` and `CLAUDE_MAX_BYTES` in `truth_fences.py`"), so the number cannot drift again; add `docs/GUIDE.md` and `docs/SETUP.md` bullets with the same-commit wording from the root `CLAUDE.md`.
2. Correct the six em-dash claims to the truth: the rule stands as a writing rule, enforced only by the optional local `scripts/pre-commit`, CI job dropped 2026-08-18 (`fbc5cbe`). ADR 0005 gets a dated amendment section rather than an edited history. The 57 legacy lines in `pipeline/src` are not swept.
3. `ci-local.sh daemon` calls both test scripts (macOS, the OS they were written and pinned on). Running them in the Linux `truth-fences` job is the alternative if the pickup confirms both are portable (no BSD-only `stat`/`date` flags); either way, one place.
4. Fix the "step 1" in `prune-worktrees.sh`'s header (comment only; `sh scripts/test-prune-worktrees.sh` still runs, per the root rule for any edit to that script).
5. **Shared landing text**: move step 0 and the common landing procedure into one file, `.claude/shared/landing.md`, and have each command reference it by path in one line plus its own one-line delta (`audit.md` lands "the band", `file-task.md` "the filing"). A plain file rather than the harness audit's `land-worktree` skill: the procedure only ever runs from inside a command, which can name a path, so skill discovery buys nothing, and `.claude/skills/` is gitignored today.
6. Allowlist: add the commands' own calls; replace the four `find` allows with `deny` rules for `-delete` and `-exec` (or drop them, since the Glob tool covers listing). Check the wildcard syntax against current Claude Code docs before relying on a mid-string `*`.

**Owner decision, asked before scope item 2 is final:** a `PostToolUse` hook on Edit and Write that rejects U+2014 in the written text (harness proposal A4). For: the owner's global instructions still ban em-dashes in all output, and transcripts show sessions running their own em-dash grep 89 times across 16 sessions. Against: it re-adds mechanical enforcement the owner removed on purpose. Default if unanswered: no hook, docs corrected only.

## Explicitly not / out of scope

- Re-adding the CI em-dash job. The owner removed it; the hook question above is the only enforcement on the table.
- `scripts/verify.sh` (harness A2): CI8's `ci-local.sh` is already the one step list; a changed-paths selector is not filed.
- The local, untracked `.claude/settings.local.json` (`Bash(node *)`). It is the owner's file; named here, not edited.
- The CI status line ([HYG12](./HYG12.md)), project skills ([HYG13](./HYG13.md)), `/tech-task` process steps ([HYG14](./HYG14.md)), the instruction-precedence paragraph ([DOC18](./DOC18.md)).

## Acceptance

- `grep -rn "12 KB" .claude/commands` returns nothing; step 7 lists GUIDE.md and SETUP.md.
- No tracked doc outside `docs/audits/` and the archives claims CI fails on an em-dash; ADR 0005 has a dated amendment naming `fbc5cbe`.
- `bash scripts/ci-local.sh daemon` (or `truth-fences`, per scope item 3) runs both test scripts and their output appears in the log; `sh scripts/test-prune-worktrees.sh` green after the header edit.
- The four commands each reference `.claude/shared/landing.md`, and no step-0 paragraph remains duplicated (md5 check as above returns one file's worth, not four).
- If the owner says yes to the hook: a script under `scripts/` plus a canned-JSON test (a write containing U+2014 exits non-zero with a message; one without passes), registered in `.claude/settings.json`.
- `bash scripts/ci-local.sh fences` green; a `/file-task` dry read of the edited commands finds every step it references.
