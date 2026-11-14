---
id: HYG11
title: The harness still carries defects CI8 did not touch: a wrong byte budget, a docs-sync list missing two contract docs, six claims that CI blocks em-dashes, two mandatory scripts CI never runs, and duplicated landing text
category: Hygiene
status: new
priority: P2
comment: Filed 2026-10-24 (audit band, architecture review H2, harness defects list, A4, A6, B1): after CI8, still open: tech-task cites a 12 KB budget (caps are 800 B and 24,000 B), docs-sync omits GUIDE and SETUP, six docs say CI blocks em-dashes though the owner dropped that job 2026-08-18, two mandatory test scripts skip ci-local.sh, step 0 is copied 4 times, allowlist gaps. One commit; em-dash hook is an owner call. Amended 2026-11-12 ([security review](../../audits/2026-11-12-security-review.md)): the allowlist also auto-approves rg --pre and git diff/log --output, which run a command or write any file. [Spec](./HYG11.md) Amended 2026-11-13 by the audit band: the janitor's transcript veto never matches a path with a space (F182), and the interpreter pin and CONTRIBUTING's macos-14 drift from CI (F183).
---

# HYG11: the harness still carries defects CI8 did not touch: a wrong byte budget, a docs-sync list missing two contract docs, six claims that CI blocks em-dashes, two mandatory scripts CI never runs, and 9 KB of duplicated landing text

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) H2, [AI harness audit](../../audits/2026-10-24-ai-harness-audit.md) defects list, proposals A4, A6 and B1, and the allowlist defect). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

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

## Amended 2026-11-12 (security review)

From the [security review](../../audits/2026-11-12-security-review.md) (verified, Low). Beyond the `find -exec` / `-delete` this task names, `.claude/settings.json`'s `Bash(rg:*)` allows `rg --pre <cmd>` (runs a command per file) and `Bash(git diff:*)` / `Bash(git log:*)` allow `--output=<path>` (writes a file anywhere). `pytest -p`, `swift build` and `git show` textconv run only code already in the repo. Whether Claude Code's own dangerous-flag lists override an explicit allow rule was not determinable from the minified binary.

Added to scope item 6: deny rules (or narrowed allow patterns) for `rg --pre`, `rg --pre-glob`, `git diff --output`, `git log --output`. The SessionStart hook running `scripts/prune-worktrees.sh` is expected behaviour once the folder is trusted and stays.

## Amendment 2026-11-13 (audit band)

Two more harness defects from the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) ("Low findings, not verified" table, F182 and F183), both re-checked at HEAD (`3a2da4fc`) before filing.

**F182: the janitor's live-session veto never fires for this checkout.** `scripts/prune-worktrees.sh`'s `session_alive` builds the transcript directory with `_slug=$(printf '%s' "$1" | tr './' '--')`, so only `/` and `.` become hyphens. The real directories under `~/.claude/projects/` turn the space into a hyphen too: this checkout's is `-Users-<user>-My-Documents-Projects-GIT-meeting-pipe` and its worktrees' are `...-meeting-pipe--claude-worktrees-<name>`, while the computed slug keeps `My Documents`. `[ -d "$_dir" ] || return 1` then answers not-alive for every worktree of this repo, so the veto the script's header calls best-effort is no veto here at all. The git gates (merged, committed, clean, idle, never the caller's own) still hold, which keeps this a hygiene defect rather than a data-loss one, but a live session whose worktree clears those gates is exactly the 2026-07-24 case the transcript veto exists for. `scripts/test-prune-worktrees.sh` pins no transcript case: every `check_alive` scenario is decided by a git gate or the age floor, which is why this went unnoticed.

**F183: `ci-local.sh` is not quite the same run as CI, and `CONTRIBUTING.md` describes a runner that is not there.** Correction at filing: the audit says the Python 3.12 pin exists only in `ci.yml`. At HEAD the `pipeline` job pins `UV_PYTHON: "3.11"` (matching pyright's `pythonVersion = "3.11"` and `requires-python = ">=3.11,<3.13"` in `pipeline/pyproject.toml`), and the 3.12 is the `truth-fences` job's `actions/setup-python`, which runs only the stdlib fence script. The substance holds: the interpreter pin lives only in the YAML, there is no `.python-version` at the repo root or in `pipeline/`, so `bash scripts/ci-local.sh pipeline` and the installer's venv sync use whichever interpreter uv resolves inside `>=3.11,<3.13` (uv picked a managed 3.11.15 on the owner's Mac while filing; a Mac with 3.12 would run the suite on a version CI never uses). The audit's second half also holds: CI builds the daemon in debug only (`ci-local.sh`'s `daemon` runs `swift build`), while `scripts/install.sh` ships `swift build -c release`, so a release-only compile failure reaches the owner first. And `CONTRIBUTING.md` says "CI runs on `macos-14`" while the `daemon` job is `runs-on: macos-15`; its em-dash sentence is already the sixth place in item 3 above.

Added scope:

7. (F182) Build the slug the way the observed directories are named, every character outside `[A-Za-z0-9-]` to a hyphen (`sed 's/[^A-Za-z0-9-]/-/g'` or equivalent), and keep it a veto only. Confirm the rule against `ls ~/.claude/projects` for a path holding another punctuation character before trusting it, since the layout stays undocumented. Add two gates to `scripts/test-prune-worktrees.sh`, with `HOME` pointed at a scratch dir and the scratch repo under a path containing a space: a merged, clean, idle worktree whose slug directory holds a fresh `*.jsonl` survives, and the same worktree with only a transcript older than the age floor is removed.
8. (F183) Pin the interpreter once, where both runs read it: a `pipeline/.python-version` holding `3.11`, which uv honours for `uv run` and `uv sync` alike, and the `pipeline` job's `UV_PYTHON` either dropped or kept with a comment naming that file. `CONTRIBUTING.md`'s runner line says `macos-15`. On the debug-only build, the default is to say so in `CONTRIBUTING.md` and the root `CLAUDE.md` verify table rather than add a release build to the CI job (one more full compile per run); adding `swift build -c release` to `ci-local.sh daemon` is the alternative, and an owner call.

Added acceptance:

- `sh scripts/test-prune-worktrees.sh` green with the two new transcript gates, and the live-transcript gate fails when the `tr './' '--'` slug is put back (tried and reverted, said in the commit body).
- From `pipeline/`, `uv run python -c 'import sys; print(sys.version_info[:2])'` prints `(3, 11)` with no `UV_PYTHON` set; `bash scripts/ci-local.sh pipeline` green. If `scripts/lib/pipeline-venv.sh` changes, `bash scripts/test-app-relocation.sh --with-pipeline` per the root rule.
- `grep -n "macos-14" CONTRIBUTING.md` returns nothing; `bash scripts/ci-local.sh fences` green.
