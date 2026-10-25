# STOR10: a scheduled backup or digest that fails, or whose LaunchAgent never loaded, leaves no event and no in-app trace, while `backup_schedule_installed` still fires and Preferences only ever shows the age of the last success

Band origin: filed 2026-10-25 from the 2026-10-25 observability audit band ([observability audit](../../audits/2026-10-25-observability-audit.md) O15: UI-5, SW-11, LG-15). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified in code on 2026-10-25 against `main` at `01e904a`. Automatic backup (STOR4) and the weekly digest (AI4) run `mp backup <dir>` and `mp digest` from per-user LaunchAgents built by `LaunchAgentScheduler`. Both halves of a scheduled run can fail without a trace.

**The install half.** `LaunchAgentScheduler.install` writes the plist, then:

```swift
bootout(label: label)
launchctl(["bootstrap", "gui/\(getuid())", url.path])
return true
```

`launchctl` returns a `Bool` that is discarded, and it sets `p.standardError = FileHandle.nullDevice`, so a refused bootstrap (a label still loaded, a bad plist, `mp` moved by a reinstall) leaves nothing. `BackupSchedulerService.apply` and `DigestSchedulerService.apply` then emit `backup_schedule_installed` / `digest_schedule_installed` on any bootstrap outcome; when `install` does return `false` (`mp` not found, plist write failed) they `guard installed else { return }` with no event, and the reason went only to `Log.main.error` (os.Logger, redacted). `LaunchAgentScheduler.isInstalled` checks only that the plist file exists, so Preferences shows the schedule as on either way. `remove` is `try? FileManager.default.removeItem(...)`.

**The run half.** The plist routes the agent's output to `~/Library/Logs/MeetingPipe/backup.out.log` and `backup.err.log` (`digest.*` likewise); nothing in `daemon/Sources` reads either, and launchd neither timestamps nor rotates them. `mp backup`'s `main` catches `BackupError`, does `print(f"[FAIL] {exc}")` and returns 1, emitting no event; the unplugged-drive refusal from `check_destination` ("<volume> is not mounted, so <destination> would be created on the startup disk...") is printed to stdout, so it lands in `backup.out.log`, not `.err.log` (skeptic correction). Any other exception is an uncaught traceback in `.err.log`. `mp digest` emits `digest_generated` on success only; a failure in `generate` is a traceback with no event.

**What the owner sees.** `LastBackup.read` parses only the success marker `~/.config/meeting-pipe/.last-backup.json` and `ageDescription` renders "Last backup N days ago". `PreferencesView+Storage`'s `@State private var backupError` is set only by the in-app **Back up now** run and is gone when the window closes. `doctor.check_last_backup` is `_info` only, "never a failure", and does not look at whether the schedule is on. `docs/GUIDE.md` promises the Backup section "says so inline if one failed" and that "the last-backup line here is where you read their outcome" for unattended runs; that holds only for **Back up now**. `BackupSchedulerService`'s own doc comment says an agent failing "every night into a log nobody reads ... is worse than no schedule at all".

**Reachability.** Not executed on this Mac: `~/Library/LaunchAgents` holds only `com.meetingpipe.daemon.plist`, `events.jsonl` has no `*_schedule_*` event, and there is no `backup.*.log`. The trigger is ordinary use: GUIDE.md itself says a backup to an unplugged external drive refuses to run. Severity medium (skeptic downgrade from high): a growing "Last backup 23 days ago" is visible to anyone who opens Preferences, and the refusal text is on disk; it is diagnosable with effort, not silent forever.

## Scope

1. **Checked install.** `LaunchAgentScheduler.install` returns `Result<Void, ScheduleInstallError>` with the bootstrap exit status and captured stderr (a `Pipe`, not `nullDevice`), and verifies the agent with `launchctl print gui/<uid>/<label>` after bootstrap. `BackupSchedulerService.apply` / `DigestSchedulerService.apply` emit `*_schedule_installed` only on a loaded agent and `*_schedule_failed` with `reason` otherwise, write a file-log line (OBS1's `Log.failure` if landed), and return the error so the Preferences toggle shows it inline instead of reading `isInstalled`.
2. **A last-attempt marker beside the success marker.** `mp backup` and `mp digest` write `~/.config/meeting-pipe/.last-backup-attempt.json` / `.last-digest-attempt.json` (`at`, `outcome` `ok`/`failed`, `reason` capped at 300 characters, `trigger` `scheduled`/`manual` from an `MP_TRIGGER` env var the plist sets) in a `finally`, through `storage.atomic_write_text`. Add both names to `backup.EXCLUDED_NAMES`, since they describe this Mac like `.last-backup.json` does.
3. **Run events.** `mp backup` emits `pipeline` `backup_completed` (`bytes`, `audio_included`) and `backup_failed` (`reason`); `mp digest` gains `digest_failed` (`reason`) beside `digest_generated`. Both carry `trigger`.
4. **One surface that says so.** `LastBackup` reads the attempt marker too; when the newest attempt failed, or the schedule is on and the last success is older than two intervals, the Storage line reads "Last automatic backup failed <when>: <reason>" or "Automatic backup overdue: last success <when>", and `StatusBarModel` gains one `.scheduledRunFailed(title:)` row (the `.permissionConsequence` precedent) that opens Preferences ▸ Storage. The digest gets the same line under Weekly digest and shares the row.
5. **Doctor warns when it matters.** `doctor.check_last_backup` stays `_info` when no backup schedule is installed (Time Machine users), and `_warn`s when `~/Library/LaunchAgents/com.meetingpipe.backup.plist` exists and the last success is older than two intervals (weekly when the plist's `StartCalendarInterval` carries `Weekday`, else daily) or the newest attempt failed.
6. **Docs in the same commit.** GUIDE.md's backup and digest paragraphs say where a failed unattended run shows up; README's backup runbook names the two attempt markers.

## Explicitly not / out of scope

- Reading `backup.out.log` / `backup.err.log` from the app. The marker and the event carry the reason; the launchd logs stay for a human. Rotating or timestamping them is not done here either: once the reason is in the marker and the event, those files are a fallback, and PERF13's logger work does not reach launchd-owned files.
- Retrying a failed run, or waking the Mac for one. launchd's `StartCalendarInterval` already coalesces a missed run on wake.
- Destination encryption and archive mode: STOR8. Restore: STOR5 (shipped).
- A notification for each failure. One menu row that persists until the next success is the durable surface; UX92 owns notification delivery.

## Acceptance

- `LaunchAgentSchedulerTests`: a bootstrap that exits non-zero (injected runner) yields a failure carrying stderr; `BackupSchedulerServiceTests` / `DigestSchedulerServiceTests`: no `*_schedule_installed` event on a failed bootstrap, one `*_schedule_failed`. Fails on `main`.
- `LastBackupTests`: a failed attempt newer than the success renders the failed line; a success older than two daily intervals with the schedule on renders overdue; schedule off renders the plain age. `StatusBarModelTests`: the row appears for a failed or overdue scheduled run and not for a manual failure already shown inline.
- pytest in `test_backup_restore.py`: an unmounted `/Volumes` destination writes a `failed` attempt marker and a `backup_failed` event and exits 1; a success writes `ok` and `backup_completed`; the attempt markers are excluded from the archive. `test_digest.py`: a raising `generate` writes `digest_failed` and the marker.
- `test_doctor.py`: WARN with the plist present and a stale or failed run, INFO with no plist.
- New actions documented in `CONVENTIONS.md`; `python3 scripts/truth_fences.py` green. `cd daemon && swift test` and `cd pipeline && uv run --extra dev pytest -q` green, ruff and pyright clean, N new tests per tree in the commit body.
- Evidence (confirms, does not gate): owner turns on Automatic backup to an external drive, unplugs it, and after the scheduled hour sees the menu row and the Storage line naming the unmounted volume.
