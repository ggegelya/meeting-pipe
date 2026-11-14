---
id: STOR17
title: Restore overwrites live files in place with no free-space check, no per-file atomicity and no check against the manifest
category: Storage
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). restore_archive extracts each member straight over the live file (tarfile makefile opens it "wb"), catches only FilterError and never checks free space, and the app always passes --force, so ENOSPC mid-restore truncates a previously intact file and leaves a half-restored library behind a traceback; the manifest's schema_version is never read and a truncated archive escapes as EOFError (F094, F120, F205). Preflight space from the validation walk, temp-and-os.replace per file, OSError, EOFError and a bad manifest as RestoreError, assert on-disk content after a forced restore.
---

# STOR17: Restore overwrites live files in place with no free-space check, no per-file atomicity and no check against the manifest

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) finding F094 (data lens, confirmed, medium), with F120 (test gap on the same path) and the manifest half of F205 folded in. Re-verified in code at HEAD `3a2da4fc` on 2026-11-14.

**Extraction writes over the live file.** `restore.restore_archive` walks `_restorable_members` and, per member, strips the prefix (`member.name = relative`) and calls `tar.extract(member, path=destination, filter="data")`. The pipeline runs CPython 3.11 (`requires-python = ">=3.11,<3.13"`, local venv 3.11.15), whose `TarFile.makefile` does `with bltn_open(targetpath, "wb") as target:` and then `copyfileobj`, so an existing transcript, summary, WAV or workflow file is truncated to zero the moment its member is reached and refilled from the stream. Nothing is written to a temporary name first.

**Only one exception is handled.** The `try` around the extract catches `tarfile.FilterError` and re-raises it as `RestoreError`; `restore.main` catches only `RestoreError`. An `OSError` (ENOSPC, EIO on an unplugged drive, EACCES) escapes as a traceback with exit 1, and whatever member was mid-write is left truncated.

**No free-space check.** Nothing in `restore.py` calls `shutil.disk_usage`. The backup side has had one since [STOR12](./STOR12.md) (`backup.check_free_space`, which keeps `RECORDING_RESERVE_BYTES` free on the library's volume and `BACKUP_HEADROOM_BYTES` elsewhere), but restore never got the mirror. Restoring an older archive into a live library adds every meeting recorded since (counted as `added` in the plan) on top of what is already there.

**The app always forces.** `PipelineLauncher.restoreArgs` is `["restore", archive.path, "--force"]` and its doc comment says why (every in-app restore writes into a live library). So the occupancy refusal, the only guard `restore_archive` has, never applies to the path the owner uses.

**Scenario (F094):** an in-app restore of an older archive onto a nearly full disk. The added recordings consume the space, the next replaced WAV or transcript is opened `wb`, the write fails with ENOSPC, and restore exits with a traceback, leaving a previously intact file truncated and the library half restored. STOR12 (done) scaled the watchdog cap so a slow restore is not killed half way; it did not make a failing one safe.

**What the owner sees.** `RestoreFlow` sets `.failed("Restore failed: \(PipelineLauncher.diagnostics(for: error))")`, and for a non-zero exit `diagnostics` returns the spawn's stderr tail (`LaunchError.nonZeroExit(_, stderrTail)`, 4 KB). So today an ENOSPC shows the tail of a Python traceback. `restore.main` prints its `[FAIL]` line with a plain `print`, to stdout, which reaches `pipeline.log` but not that line; routing the `[FAIL]` text to the app is the backup and restore stdout class filed separately in this band, and this task does not depend on it.

**F120, the test gap.** In `pipeline/tests/test_backup_restore.py` the only forced restores are `test_restore_force_writes_into_a_non_empty_destination` (asserts `written["library"] == 3`) and `test_plan_matches_what_the_real_run_then_writes` (asserts plan counts equal `written`). Neither reads a restored file back, so a forced restore that wrote the wrong bytes, or clobbered a newer library file not in the archive, would pass both. The round-trip test (`test_restore_into_a_scratch_home_yields_a_working_install`) does check content, but only into an empty home without `--force`.

**F205, the manifest half.** `backup.build_manifest` stamps `"schema_version": MANIFEST_SCHEMA_VERSION` (1) and `"tool_version": __version__`, and has since STOR2 (`1511225d`), so every archive `mp backup` ever wrote carries it. `read_manifest`, `plan_restore` and `restore.main` read neither. `plan_restore` returns `manifest["created_at"]` and `main` prints `manifest['created_at']` and reads `manifest["keychain"]` unguarded, so a manifest missing a key is a `KeyError` traceback rather than a `RestoreError`, and an archive from a future schema restores blindly.

Correction at filing: F094's direction includes verifying written counts against the manifest, on the premise that a short archive restores partially and reports success. It does not: the manifest is the archive's last member and `read_manifest` walks to it before anything is written, so a truncated archive never reaches extraction. Measured on 2026-11-14 with a three-member `.tar.gz` cut in half, `read_manifest` raises `EOFError: Compressed file ended before the end-of-stream marker was reached`, which is neither `RestoreError` nor `tarfile.TarError`, so it is refused up front but as a traceback. The count check is dropped from scope and the `EOFError` mapping added instead.

Correction at filing: F205 also names voiceprint, roster and run sidecars whose versions nobody checks. That part is not restore-specific and is left out of this task; only the backup manifest half is in scope here.

## Scope

All in `pipeline/src/mp/restore.py`. No Swift change and no `RestorePlan` contract change.

1. **Validate the manifest.** A small `_validate_manifest`, called by `read_manifest` and by `plan_restore` once its walk has the manifest, raises `RestoreError` when `schema_version` is missing or greater than `backup.MANIFEST_SCHEMA_VERSION`, and when `created_at`, `roots` or `keychain` is missing. The message names the archive and the version found. Refusing a missing `schema_version` is safe because every archive since STOR2 carries one.
2. **Map read failures.** `read_manifest` and `plan_restore` turn `EOFError`, `zlib.error`, `tarfile.TarError` and `OSError` from reading the archive into `RestoreError` ("<archive> is truncated or unreadable").
3. **Preflight free space before the first write.** The validation walk `read_manifest` already makes passes every member header, so it also sums `member.size` per destination prefix (applying the same `config.toml` carve-out `_restorable_members` does) and keeps the largest single member, at no extra decompression. Return those beside the manifest (a small result type, or a second function sharing the walk; `main` and `restore_archive` are its only callers). Check `shutil.disk_usage` per distinct volume (reuse `backup._existing_ancestor` and `backup._same_volume`): the bar is the incoming bytes plus the largest member (the temp copy coexists with the file it replaces), plus `RECORDING_RESERVE_BYTES` on the library's volume and `BACKUP_HEADROOM_BYTES` elsewhere, mirroring `check_free_space`. Refuse with a `RestoreError` naming free and needed sizes. Not crediting replaced files' current sizes is deliberate: it over-estimates, and a refusal costs less than a truncation.
4. **Per-file atomicity.** Extract each member to a temporary sibling whose name `MeetingStore.stem(of:)` and the directory watcher cannot mistake for a meeting file (dot-prefixed, for example `.<name>.restoring`), still through `filter="data"`, then `os.replace` it over the target. On any failure, unlink the temp and leave the target as it was.
5. **Map extraction failures.** Catch `OSError`, `EOFError`, `zlib.error` and `tarfile.TarError` around the per-member step (alongside the existing `FilterError` branch) and raise `RestoreError` naming the member, the errno name where there is one, and how many files were already replaced, so `pipeline.log` says exactly how far the restore got. Already-replaced files stay replaced (each one is whole); the message says the library holds a mix and that re-running the restore completes it.

## Explicitly not

- Verifying written counts against the manifest's `roots[].files`: see the correction above; a truncated archive is refused before the first write, so the check would catch nothing the validation walk does not.
- Putting the free-space verdict into the dry-run plan so the confirm can warn before the owner presses Restore. It is a `RestorePlan` contract change on both sides (`RestoreFlow.swift` and `restore.py`), and the refusal after confirm writes nothing, so the cost is one wasted confirm. Worth a follow-up if the refusal is ever seen in the field.
- An all-or-nothing transactional restore (stage everything, then swap whole roots). Per-file atomicity removes the truncated-file loss, which is the defect; a staged swap doubles the space need on the volume that is already short.
- Version checks on voiceprint, roster and run sidecars (the rest of F205). Each has its own reader; this task covers the backup manifest only.
- Stale app-lifetime stores after an in-app restore (F135) and retention deleting restored audio (F202): separate findings in the same audit, not this seam.
- Backup-side atomicity and encryption: [STOR8](./STOR8.md). Held-back originals: [SEC26](./SEC26.md). [STOR5](./STOR5.md)'s restore UI and its owner verification stay as they are.
- A pre-restore snapshot of the files about to be replaced. Worth asking the owner about once this lands; not filed.

## Acceptance

- `pipeline/tests/test_backup_restore.py` gains:
  - a forced restore where `os.replace` (or the temp write) is patched to raise `OSError(errno.ENOSPC, ...)` on the second replaced member: `restore_archive` raises `RestoreError`, the live file for that member is byte-identical to before, no `.restoring` temp is left in any destination, and the member replaced before it holds the archived bytes;
  - `restore.main` on the same injected failure returns 1 and prints `[FAIL]` with no traceback;
  - a free-space refusal: with `shutil.disk_usage` patched to report less than the incoming bytes plus the reserve, the restore raises `RestoreError` before writing anything (every destination file unchanged, mtimes included);
  - F120: a forced restore over a populated home where one library file was modified after the backup and one newer library file is not in the archive: the modified file gets the archived bytes back, and the newer file is untouched;
  - F205: a manifest with `schema_version` 2, one with no `schema_version`, and one missing `created_at`, each refuse with `RestoreError` from `read_manifest` and from `plan_restore`, with no traceback through `main`;
  - a real backup truncated to half its bytes refuses with `RestoreError` from `read_manifest` and from `plan_restore` (today `EOFError`).
- The existing STOR12 pass-count pins (`test_plan_restore_walks_the_archive_once`, `test_a_real_restore_walks_the_archive_twice`) stay green: the sizes come from the validation walk the real run already makes, so the preflight adds no pass.
- `cd pipeline && uv run --extra dev pytest -q`, `uv run --extra dev ruff check src tests` and `uv run --extra dev --extra mcp pyright` green, with the number of new tests in the commit body; `bash scripts/ci-local.sh` green.
- `CONVENTIONS.md#backup-and-restore-stor2` and README.md's new-Mac restore runbook (the `mp restore ... --dry-run` steps) say, in the same commit, that a restore refuses a destination without room and that a failure leaves each file either old or restored, never truncated.
