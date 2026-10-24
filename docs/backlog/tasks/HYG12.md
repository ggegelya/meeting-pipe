# HYG12: no session ever sees the state of CI, so a red main stays invisible until the owner reports it

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([AI harness audit](../../audits/2026-10-24-ai-harness-audit.md) failure mode 1 and proposal A3). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

CI on `main` failed every pushed run from 2026-07-31 until CI8 (82 days). The cause was a local/CI command mismatch, which CI8 fixed by making `scripts/ci-local.sh` the one step list. The detection gap is a separate defect and CI8 only half closed it: it added a weekly scheduled run whose failure GitHub mails "to whoever last edited this cron line" (`ci.yml`). That reaches the owner's inbox. It does not reach a session: across the 26 transcripts the harness audit read, no session ever checked CI, and the owner had to say "pipelines is failing" twice.

State on 2026-10-24: `gh run list --branch main` returns the latest two completed runs as `failure` (2026-10-23 and 2026-10-24) with a third in progress. `gh` is installed at `/opt/homebrew/bin/gh` and authenticated for `ggegelya/meeting-pipe`. Pushes are rare by policy (the root `CLAUDE.md`: "Do not push unless asked"), so local `main` is routinely ahead of `origin/main` and those commits have no CI result at all, which a status line must say rather than reporting the last remote green as if it covered them.

The only `SessionStart` hook today is the worktree janitor in `.claude/settings.json`.

## Scope

1. **`scripts/ci-status.sh`**: prints one line to stdout and exits 0, always. Content:
   - the conclusion of the latest completed `CI` workflow run on `main` (`gh run list --workflow CI --branch main --status completed -L1 --json conclusion,headSha,createdAt,event`), with its short sha, date and event (`push`, `schedule`);
   - a run in progress, if there is one;
   - how many commits local `main` is ahead of `origin/main` (`git rev-list --count origin/main..main`), phrased as "not yet seen by CI".
   Example shape: `CI main: failure at 45b8c6a (2026-10-24, push); 3 local commits not yet seen by CI.`
2. **Silent on every failure path**: no `gh`, `gh` not authenticated, offline, no `origin/main`, or slower than a bound. Silence means no output, not an error line. macOS ships no `timeout(1)`, so the script bounds `gh` itself (background the call and kill it after about 3 s), and the hook entry also sets Claude Code's per-hook `timeout` as a backstop.
3. **Register it** as a second `SessionStart` command in `.claude/settings.json`, after the janitor, with `|| true` like the janitor. A `SessionStart` hook's stdout is added to the session's context, which is the point.

## Explicitly not / out of scope

- Fixing whatever makes the current runs red. That is the CI owner's job of the day ([CI9](./CI9.md) covers the coverage gaps), not this line's.
- Blocking a session, a commit or a landing on red CI. Pushes are rare, so the remote state is often stale by design; a gate on it would block correct local work. The line informs.
- A pre-push hook or a Stop hook. Neither is filed.
- Polling or re-checking mid-session. Once per session start is the measured need (the 82 days, not the minutes).
- Allowlist entries for the commands themselves ([HYG11](./HYG11.md) owns the allowlist).

## Acceptance

- `scripts/test-ci-status.sh`, in the style of `scripts/test-login-agent-guard.sh` (canned input, touches nothing real, no network): a fake `gh` first on `PATH` returning canned JSON pins
  - a `failure` run prints the conclusion, short sha and date;
  - a `success` run with local `main` two commits ahead prints both facts;
  - an in-progress run alongside a completed one mentions both;
  - `gh` absent from `PATH`: no output, exit 0;
  - `gh` exiting non-zero (offline, unauthenticated): no output, exit 0;
  - `gh` sleeping past the bound: no output, exit 0, and the script returns within the bound plus one second.
- The test script is called from `ci-local.sh` in the same place [HYG11](./HYG11.md) puts the other two shell test scripts.
- `.claude/settings.json` carries the hook with a `timeout`; a fresh session on the owner's Mac shows the line in its opening context (owner confirms by eye, one session, no setup).
- `bash -n scripts/ci-status.sh` clean; `bash scripts/ci-local.sh fences` green.
