---
id: STOR13
title: A backup of a missing or unreadable library succeeds, stamps the last-backup marker, and lets retention prune the archives that held recordings
category: Storage
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). run_backup archives a missing library root as zero files and rglob silently skips unreadable directories (reproduced on the venv's Python 3.11.15), yet the run stamps .last-backup.json and STOR12's retention prunes, so a daily schedule with the library away removes every archive that held recordings in about five weeks (F092; latent, no backup agent or marker on 2026-11-14). Refuse a missing library root or an unreadable library directory, record the library file count in the marker and refuse a collapse to zero, skip pruning on a large shrink.
---

# STOR13: A backup of a missing or unreadable library succeeds, stamps the last-backup marker, and lets retention prune the archives that held recordings

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: finding F092 (data lens, confirmed) in the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md). Re-verified in code at HEAD `3a2da4fc` on 2026-11-14.

**A missing root is archived as zero files.** `backup_roots` returns the library (`cfg.recording.output_dir`, `holds_audio=True`), `digests`, `config` and `corrections`. `_root_files` opens with `if not root.source.is_dir(): return`, and `_add_root`'s docstring makes that deliberate: a missing root "contributes an entry with zero files rather than being silently dropped". That is right for `digests` (pinned by `test_a_missing_root_is_recorded_as_zero_files_not_dropped`, where the library exists and `digests` does not) and wrong for the library, the one root that holds the recordings.

**An unreadable directory is skipped silently.** `_root_files` walks `sorted(root.source.rglob("*"))`. Reproduced on 2026-11-14 with the pipeline venv's own interpreter (CPython 3.11.15, `requires-python = ">=3.11,<3.13"`): a library holding `ok/a.wav` and a mode-000 `locked/b.wav` lists `['locked', 'ok', 'ok/a.wav']`, with no exception and no warning, so `b.wav` is simply not in the archive.

**Nothing downstream notices.** `run_backup` then does `os.replace(partial, archive)`, writes the marker through `storage.atomic_write_text` (`"at"`, `"archive"`, `"bytes"`, `"audio_included"`, no file count), and calls `prune_old_backups`. Doctor's last-backup line and the Storage pane's `LastBackup` age line read that marker, so both say a backup happened today. No step compares this run with the previous one.

**Retention turns it destructive.** STOR12 (done 2026-11-12) added `retained`: the newest `KEEP_RECENT` (7) archives plus the newest archive in each of `KEEP_WEEKS` (4) ISO weeks strictly before the week of the oldest of those 7. With a daily schedule and the library gone, the 7 recent slots hold empty archives after a week, and each of the 4 weekly slots is taken by an empty archive as its week passes, so about five weeks after the library disappeared no archive holding recordings is left. STOR4 (done, [q6-final.md](../q6-final.md)) refuses only an unmounted destination in `check_destination`; nothing guards the source.

**Triggers.** An external volume holding the library that is unplugged while the scheduled agent runs; `output_dir` re-pointed at an empty or wrong folder, which [UX89](./UX89.md) (a live free-text path) and [UX94](./UX94.md) (its 2026-11-13 amendment: a parse error reverts `output_dir` to the default) each describe; a library subfolder that loses read permission.

**Latent on the owner's Mac.** On 2026-11-14 `~/Library/LaunchAgents` holds only `com.meetingpipe.daemon.plist` (no `com.meetingpipe.backup.plist`), `~/.config/meeting-pipe/.last-backup.json` does not exist, and `output_dir` is `~/Documents/Meetings/raw` on the internal disk. It bites from the first scheduled run after Automatic backup is turned on with a library that can go away.

Correction at filing: the audit's direction says to compare against "the last manifest". The manifest is the archive's last member, so reading it back means decompressing the whole previous archive, the pass STOR12 removed. The count belongs in the marker this task extends, which is already read cheaply.

## Scope

All in `pipeline/src/mp/backup.py`, `run_backup` and its helpers.

1. **Refuse a missing library root.** Before `check_free_space` and before the `.partial` is opened, raise `BackupError` when the library root (`cfg.recording.output_dir`) is not a directory, naming the path and the likely causes (an unplugged drive, a re-pointed recordings folder). The other three roots keep today's zero-files behaviour.
2. **Report unreadable directories instead of skipping them.** Replace the `rglob` walk in `_root_files` with a walk that surfaces errors (`os.walk(..., onerror=...)` or an explicit `os.scandir` recursion), keeping today's ordering, symlink skip and `_should_include` filter. Any directory under the library root that cannot be listed raises `BackupError` naming up to the first five paths and the total count. The estimate in `estimate_backup_bytes` walks the same iterator, so the refusal lands before anything is written.
3. **Record and compare the library's size.** The marker gains `library_files` (the library root's archived file count) and keeps every existing key, so `LastBackup` and doctor are unaffected. A run whose library file count is 0 while the previous marker's `library_files` was above 0, with `audio_included` equal on both, raises `BackupError` naming both counts, before the archive is renamed into place, so the marker and the existing archives are untouched.
4. **Never prune on a large shrink.** When the library file count is below half the previous marker's (same `audio_included`), the archive is written and the marker stamped, since it is a true copy of what exists, but `prune_old_backups` is not called; the summary prints `retention skipped: library has N files, last backup had M` and `pipeline` `backup_prune_skipped` is emitted with `library_files` and `previous_library_files`. The pickup states the threshold beside its constant with the reason.

## Explicitly not

- An override flag for a deliberate wipe of every meeting. Deleting the marker is the escape hatch; a flag would need an in-app path under the de-CLI rule, which a case this rare does not earn.
- Reading the previous archive's manifest (see the correction above).
- Refusing a missing `digests`, `config` or `corrections` root: absence there is legitimate and pinned.
- Run-outcome visibility for scheduled runs (attempt marker, `backup_failed` event, menu row, doctor WARN): [STOR10](./STOR10.md). A refusal from this task is one more failure STOR10 surfaces; if STOR10 lands first, the skip in item 4 can ride its `backup_completed` event instead of a separate action.
- The failure text reaching the app at all: today `backup.main` prints `[FAIL]` to stdout, which the app never shows ([STOR14](./STOR14.md)).
- An unreadable library seen by the daemon (Library, watcher, sweeps): [STOR11](./STOR11.md). The free-text path that re-points the library: [UX89](./UX89.md). A parse error reverting it: [UX94](./UX94.md).

## Acceptance

- New cases in `pipeline/tests/test_backup_restore.py`: a config whose library root does not exist raises `BackupError`, writes no `.partial` or archive, leaves an existing marker byte-identical and prunes nothing from a destination holding 15 dated archives; a library with a mode-000 subdirectory raises `BackupError` naming it (skipped when run as root); a marker with `library_files: 40` and a library that now exists but is empty raises, with both counts in the message; a library that shrank from 40 to 10 files writes and stamps but prunes nothing from the 15-archive destination and emits `backup_prune_skipped`; a normal second run with the same count prunes exactly as STOR12's policy says and the marker carries `library_files`.
- `test_a_missing_root_is_recorded_as_zero_files_not_dropped` and the STOR12 retention and pass-count tests pass unchanged.
- `pipeline` `backup_prune_skipped` and the marker's `library_files` key documented in `CONVENTIONS.md`'s "Backup and restore" section; `python3 scripts/truth_fences.py` green.
- `docs/GUIDE.md`'s backing-up recipe and README's backup runbook say that a backup refuses a missing or unreadable library and keeps older archives when the library shrinks sharply, in the same commit.
- `cd pipeline && uv run --extra dev ruff check src tests`, `uv run --extra dev --extra mcp pyright` and `uv run --extra dev pytest -q` green, with the number of new tests in the commit body; `bash scripts/ci-local.sh` green.
