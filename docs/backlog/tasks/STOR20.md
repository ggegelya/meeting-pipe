---
id: STOR20
title: A backup retention hold is invisible in the app and can be ended only by deleting a hidden marker file, so after a deliberate large delete the backup folder grows one archive per run until backups fail for lack of space
category: Storage
status: new
priority: P2
comment: Filed 2026-11-26 (owner approved 2026-11-25/26, left over from STOR13 70b5b276): run_backup carries retention_hold in .last-backup.json while the library stays under half its pre-shrink count, but LastBackup.read ignores the key, Back up now discards the CLI's "retention skipped" line, and nothing reads backup_prune_skipped. Scope: show the hold on the Storage pane and let the owner end it there through mp.
---

# STOR20: A backup retention hold is invisible in the app and can be ended only by deleting a hidden marker file, so after a deliberate large delete the backup folder grows one archive per run until backups fail for lack of space

Band origin: filed 2026-11-26 from the STOR13 amendment session (commit `70b5b276`). Owner approved filing on 2026-11-25/26. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

**The hold, read at HEAD `0f141418` on 2026-11-26.** `backup.run_backup` counts the library root's files (`library_files`, every file `_root_files` archives for the root that holds audio). When that count is under `PRUNE_SHRINK_RATIO` (0.5) of the previous comparable count, it writes the archive and stamps the marker but skips `prune_old_backups`, emits `pipeline` / `backup_prune_skipped`, and since the STOR13 amendment stamps `retention_hold: {library_files, audio_included}` with the pre-shrink count. Later runs compare against the held count and keep holding until a run counts at least half of it again; a run with the other `audio_included` keeps holding too. The only other release is deleting `~/.config/meeting-pipe/.last-backup.json`, which `docs/GUIDE.md`'s backing-up recipe and `mp backup`'s summary line both tell the owner to do.

**Nothing in the app shows it.**

- `LastBackup.read(at:)` parses `at`, `audio_included` and `destination_encrypted` only; `retention_hold` and `library_files` are never read. The Storage pane's age line and the menu read through it.
- Preferences ▸ Storage ▸ **Back up now** (`PreferencesView+Storage.runBackup`) treats `.success` as `refreshLastBackup()` and nothing else; the CLI's `retention skipped: library has N files, down from M ...` line goes nowhere. The scheduled LaunchAgent run has no terminal at all.
- No daemon code reads `backup_prune_skipped` or `retention_hold` (grep of `daemon/Sources`, 2026-11-26). `doctor.check_last_backup` reports the age only.

**What it costs.** With retention off, every run adds one archive (`meeting-pipe-backup-<timestamp>.tar.gz`, the whole library each time) and none is removed. `check_free_space` refuses a run once the destination cannot fit the next archive plus REC20's headroom; the scheduled job's refusal then reaches the app as "Automatic backup failed" (`LastBackup.scheduledLine`), with the free-space reason but nothing tying it to the hold. Meanwhile the owner sees "Last backup today".

**What starts a hold.** Anything that drops the library to under half its files between two backups: deleting a batch of meetings in the Library on purpose, or re-pointing the recordings folder to a smaller one (UX89). The app's own audio retention sweep contributes but rarely starts one alone: a `.drop` removes one file per meeting (the recording; the voice vectors are nulled in place, SEC22 item 5) out of the roughly seven entries a meeting holds (the PERF24 figure quoted in `Coordinator+AutoRetry.runLaunchAutoRetry`), and `.compress` removes none, so it halves the count only if audio were most of the files. Deleting the marker to end the hold also blanks the Storage pane's age line ("No backup has run on this Mac yet") and the recorded `destination_encrypted` until the next run, which GUIDE.md warns about.

## Scope

1. **Read it.** `LastBackup.Info` gains the hold (held count, `audio_included`) and the marker's `library_files`, parsed in `LastBackup.read`; an absent or malformed `retention_hold` is no hold. The marker shape is in `CONVENTIONS.md`'s backup section and the Swift side stays read-only.
2. **Show it.** While a hold is recorded, the Storage pane's Backup section shows one line under the age line, in GUIDE.md's register, saying older backups are being kept because the library went from M to N files and will be thinned again once it is back to half, plus the end control below. No menu row and no notification: the age line is still true, and the scheduled failure row already covers the free-space end state.
3. **End it from the app.** A button beside that line (for example **Thin old backups again**) with a confirm that says the older archives will be pruned on the next backup per the normal schedule. It runs a new `mp backup` subcommand or flag (the pickup names it; `mp backup --end-retention-hold` is one shape) that rewrites the marker atomically without `retention_hold` and changes nothing else, so the next run compares against the current count and prunes. Python stays the marker's only writer.
4. **Docs, same commit.** GUIDE.md's backing-up recipe replaces the delete-the-dot-file instruction with the Storage pane control, README's backup runbook names the new subcommand, `CONVENTIONS.md`'s backup section documents it, and `mp backup`'s summary line points at the control instead of the marker path.

## Explicitly not

- Changing the 0.5 ratio, the retention policy (`KEEP_RECENT`, `KEEP_WEEKS`) or the STOR13 refusals.
- Pruning from the app directly: the button only clears the hold, and the next backup prunes on the normal schedule, so one code path deletes archives.
- Telling the audio retention sweep to adjust the baseline: it is one cause among several, and an explicit owner action is the release the STOR13 amendment asked for ("until the owner acknowledges the shrink").

## Acceptance

- Swift: `LastBackup` tests over marker fixtures (with a hold, without one, with a malformed `retention_hold`) read the held count, `library_files` and `audio_included`, or no hold; a view-model or pure-formatter test for the Storage line's text in both directions (hold shown, no hold no line).
- Python, `pipeline/tests/test_backup_restore.py`: the new subcommand on a marker with `retention_hold` leaves every other key byte-identical and drops the hold; a following `run_backup` over the same shrunk library prunes per STOR12's policy; on a marker without a hold it changes nothing and says so; on no marker it exits non-zero with a message.
- The Storage pane control's confirm and run (Owner walkthrough below confirms; does not gate building).
- `cd daemon && swift build` and `swift test` green; pipeline ruff, pyright and pytest green; the number of new tests in the commit body; `python3 scripts/truth_fences.py` and `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [session] Install the build (`./scripts/rebuild.sh`) and, in a scratch home or with the owner's consent on the real marker, write a marker carrying `retention_hold`.
2. [owner] Open Preferences ▸ Storage. Pass: the Backup section shows the hold line with both counts and the end control; ending it asks first, and afterwards the line is gone and the age line is unchanged.
