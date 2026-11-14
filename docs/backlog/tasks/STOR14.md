---
id: STOR14
title: mp backup and mp restore print their failure reason to stdout, so the app's Back up now and in-app restore show a failure with no cause
category: Storage
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). backup.main and restore.main print BackupError and RestoreError with a bare print to stdout and exit 1, while runMP keeps only the stderr tail, so an unplugged backup drive shows "Couldn't finish the file operation" with no cause and the restore pane "Could not read that backup: " with nothing after it; STOR3's shipped promise that a Back up now failure surfaces inline does not hold (F109). [FAIL] lines to sys.stderr in both mains, the CLI test that pins stdout flipped.
---

# STOR14: mp backup and mp restore print their failure reason to stdout, so the app's Back up now and in-app restore show a failure with no cause

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: finding F109 (quality lens, confirmed) in the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md). Re-verified in code at HEAD `3a2da4fc` on 2026-11-14.

**A done task's fix does not hold.** STOR3 (done 2026-07-11, [q6-final.md](../q6-final.md)) shipped Back up now with "any failure shown inline in `.mpDanger`", and its own record says a failure "surfaces as `runMP`'s `LaunchError.nonZeroExit(code, stderrTail)`". The stderr tail is empty for every refusal `mp backup` makes, so the inline failure carries no cause. STOR5's in-app restore (`owner-verify`) inherited the same gap.

**The Python side prints to stdout.** `backup.main` catches `BackupError` with `print(f"[FAIL] {exc}")` and `return 1`. `restore.main` does the same with `RestoreError` twice: in the `--json` preview branch and in the real run. Neither writes failure metadata. Every refusal with an actionable message goes this way: `check_destination`'s "is not mounted ... Plug the drive in, or pick another destination", `check_free_space`'s room refusal, and the restore's missing archive, missing manifest and occupied destination.

**The daemon reads only stderr.** `PipelineLauncher.runMP` copies both pipes to `pipeline.log`, but only `errPipe`'s handler appends to `stderrTail` (capped at `stderrLimit = 4096`), and the termination handler builds the result from it through `PipelineLauncher.outcome`, which returns `LaunchError.nonZeroExit(status, stderr)`. `PipelineLauncher.diagnostics(for:)` returns that text. So:

- Back up now (`StorageSectionView.runBackup`) sets `backupError = PipelineLauncher.diagnostics(for: error)`, an empty string, and the footer renders `FailurePresentation(diagnostics: error, operation: .storage, title: "Couldn't finish the file operation")` with no cause. With the backup drive unplugged, the owner sees that title and nothing else; the text that names the fix is only in `pipeline.log`.
- `RestoreFlow.preview` sets `.failed("Could not read that backup: \(PipelineLauncher.diagnostics(for: error))")` and `RestoreFlow.confirm` sets `.failed("Restore failed: ...")`, both ending in an empty string.

**A test pins the bug.** `test_cli_reports_a_bad_archive_without_a_traceback` asserts `"[FAIL]" in capsys.readouterr().out`.

Correction at filing: the audit offers `emit_failure(..., operation="storage")` as an alternative fix. It is not one on its own. `emit_failure` writes the `MP_FAILURE_PATH` metadata (a cause and remedy class, not the message), `outcome` turns it into `LaunchError.reportedFailure(status, metadata, stderr)`, and `diagnostics(for:)` still returns the stderr text for that case, so the notice would gain a cause class and still lack the sentence that names the drive. stderr is the required change; metadata is optional on top.

## Scope

1. In `pipeline/src/mp/backup.py` `main` and `pipeline/src/mp/restore.py` `main`, print each `[FAIL]` line to `sys.stderr` (`print(..., file=sys.stderr)`). Success output stays on stdout: the `--json` preview without `--out` still writes the plan, and only the plan, to stdout, and the summary lines are unchanged.
2. Optional, only if it costs nothing extra: call `emit_failure(exc, operation="storage")` in the same `except` blocks so the notice also gets a cause class. `storage` is in both `FailureMetadata.Operation` on the Swift side and `failure_details.OPERATIONS` on the Python side (checked 2026-11-14).

## Explicitly not

- The daemon's stderr drain dropping the last chunk when the child exits right after writing it, and the unlocked `stderrTail`: [CONC7](./CONC7.md). A one-line-then-exit `[FAIL]` is exactly that race's shape, so this fix is fully reliable only once CONC7 lands; the two do not conflict.
- Scheduled-run visibility (attempt marker, `backup_failed` event, menu row, doctor WARN): [STOR10](./STOR10.md). Its Context records that the `[FAIL]` line lands in the agent's `backup.out.log`; after this task it lands in `backup.err.log`, which STOR10's pickup should note. Nothing in the app reads either file.
- Failure events for pipeline commands generally: [OBS3](./OBS3.md).
- Uncaught exceptions: they already reach stderr as a traceback.

## Acceptance

- `test_cli_reports_a_bad_archive_without_a_traceback` asserts `[FAIL]` in `capsys.readouterr().err` and an empty `.out`.
- New pytest cases: `backup.main` against a destination under a monkeypatched `VOLUMES_ROOT` whose volume does not exist returns 1 with the "is not mounted" sentence on stderr and nothing on stdout; `restore.main` real run (no `--dry-run`) on an archive with no manifest returns 1 with `[FAIL]` on stderr; `test_cli_json_to_stdout_is_the_whole_of_stdout` stays green.
- A `PipelineLauncherTests` or `FailureProcessTests` case that spawns a child writing one `[FAIL] ...` line to stderr and exiting 1 yields `diagnostics(for:)` containing that line (skips without the pipeline venv where the existing process tests do).
- `cd pipeline && uv run --extra dev ruff check src tests`, `uv run --extra dev --extra mcp pyright`, `uv run --extra dev pytest -q` and `cd daemon && swift test` green, the number of new tests per tree in the commit body; `bash scripts/ci-local.sh` green.
- [owner] With the backup destination on an unplugged drive, Back up now shows the "is not mounted" sentence under the failure title (a simple owner-verify item).
