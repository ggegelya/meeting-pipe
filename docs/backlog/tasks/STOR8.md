---
id: STOR8
title: Mp backup writes the whole corpus, voiceprints included, to a world-readable archive under its final name, with no check that the destination is encrypted
category: Storage
status: partial
priority: P2
comment: Shipped 2026-11-17 (pending owner confirmation): the archive is written 0600 through os.open whatever the umask, a destination folder mp backup creates is 0700 and an existing open one is named in the summary, a diskutil probe warns on an unencrypted or unknown destination and the marker records destination_encrypted, shown by doctor and the Preferences last-backup line. Owner chose option (a) for item 4 on 2026-11-17, no follow-up for (b) or (c). Remainder: the owner closes it.
---

# STOR8: `mp backup` writes the whole corpus, voiceprints included, to a world-readable archive under its final name, with no check that the destination is encrypted

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) PP-12). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Verified in `pipeline/src/mp/backup.py` on 2026-10-24. `backup_roots` archives four roots: the library (`recording.output_dir`, audio included unless `--no-audio`), `digests/`, `~/.config/meeting-pipe/` (config, workflows, `voiceprint.json`, `roster.json`, glossary) and the corrections corpus. That is every transcript, summary and recording, plus the owner's and every named participant's voice embeddings. Every library file the app writes is mode 0600 (SEC11, SEC14), and ADR 0016 keeps `originals/` out of the archive precisely because "Writing them into a tarball the owner copies to a NAS would defeat the property that ADR establishes". The archive itself gets none of that care:

- **Mode.** `create_backup` calls `destination.mkdir(parents=True, exist_ok=True)` and then `tarfile.open(archive, "w:gz", compresslevel=1)`. Both take the process umask, so under the default `022` the directory is 0755 and the archive 0644: readable by any local account, and by anyone at all on an exFAT or FAT USB drive, which has no permissions. The members inside keep their 0600 bits, which protects nothing once the container is readable.
- **Atomicity.** The archive is written in place under its final name, `meeting-pipe-backup-<ts>.tar.gz`. A crash, a full disk or an unplugged drive mid-run leaves a truncated file with a valid-looking name, exactly what STOR5's restore file panel asks the user to pick ("Pick a meeting-pipe backup archive (meeting-pipe-backup-*.tar.gz)."). The `.last-backup.json` marker is then written with `marker.write_text(...)`, not `storage.atomic_write_text`, and also at umask mode.
- **Encryption.** None, and nothing checks the destination. STOR4 runs `mp backup <dir>` unattended from a LaunchAgent (`BackupSchedulerService`, label `com.meetingpipe.backup`), so the usual destination is an external drive or a network share that nobody is watching. `check_destination` already inspects the destination (it refuses an unmounted `/Volumes/<name>`), so a second check fits beside it.

Latent on the owner's Mac on 2026-10-24: there is no `.last-backup.json` and no backup LaunchAgent installed, so no archive exists yet.

## Scope

1. **Private by construction.** Create the destination directory 0700 when `create_backup` creates it (leave an existing directory's mode alone and say so in the summary line if it is group- or world-readable), and open the archive with `os.open(..., O_WRONLY | O_CREAT | O_EXCL, 0o600)` handed to `tarfile.open(fileobj=...)`, so the mode never depends on the umask.
2. **Atomic.** Write to `meeting-pipe-backup-<ts>.tar.gz.partial` in the destination, `fsync`, close, then `os.replace` to the final name. Write the marker with `storage.atomic_write_text` (0600). On any exception, delete the `.partial` and leave the marker untouched. A `.partial` left by a killed process never carries the final name, so neither `mp restore <archive>` nor the restore panel can mistake it for a backup.
   **Landed with [STOR12](./STOR12.md) on 2026-11-12**, which depended on it, with its acceptance tests (mid-archive raise leaves no `.partial` and the old marker; a completed run leaves no `.partial` and a 0600 marker). STOR8 drops this item; items 1, 3 and 4 remain.
3. **Say where it is going.** Before writing, read whether the destination volume is encrypted (`diskutil info -plist <mount point>`, whose `Encryption` and `FileVault` keys are present on APFS; treat a failed read as unknown). An unencrypted or unknown destination does not refuse: it prints one `[WARN]` line naming the volume, and the backup marker records `destination_encrypted: true|false|null` so `mp doctor` and the Preferences "last backup" line can show it.
4. **Owner decision, recorded before code.** Whether an encrypted archive is wanted at all, beyond an encrypted destination. The options the pickup puts to the owner: (a) encrypted destination only, which is items 1 to 3 and the recommendation, since FileVault and encrypted APFS volumes are already the Mac's answer; (b) an `hdiutil` encrypted disk image as the archive container with its password in the Keychain, no new Python dependency but a restore that needs the Keychain item, which a lost Mac does not have; (c) a crypto library, which needs the owner's approval as a new dependency (root `CLAUDE.md`). Only (a) is in scope unless the owner picks otherwise.

## Explicitly not

- Changing what is archived. Excluding voiceprints is a policy question for SEC22 and SEC24; `originals/` stays excluded by ADR 0016.
- Archive retention or rotation on the destination (scheduled backups accumulate). Not filed; note it if the pickup sees it bite.
- The synced-root question for a backup destination inside iCloud or Dropbox. SEC18 owns zero-egress for backups; STOR6 item 4 owns dataless files met during a backup.
- STOR5's restore UI (it is in [owner-verification.md](../owner-verification.md) and stays there).

## Acceptance

- New cases in `pipeline/tests/test_backup_restore.py`: under `os.umask(0o022)` the archive is 0600 and a created destination directory 0700; an exception raised mid-archive (monkeypatch `_add_root` to raise after one root) leaves no final-name archive, no `.partial`, and the previous marker unchanged; a completed run leaves no `.partial` and a 0600 marker; the encryption probe parses a canned `diskutil` plist for encrypted, unencrypted and unreadable cases and the marker records each as `true`, `false`, `null`.
- `cd pipeline && uv run --extra dev pytest -q` green, ruff and pyright clean, new test count in the commit body. If the marker gains a field the daemon reads (`LastBackup`), a Swift test for the new field and `swift test` green; CONVENTIONS' backup section updated in the same commit if the marker gains a field.
- README's backup section and `docs/GUIDE.md`'s backup recipe say the archive is private to the user and that an unencrypted destination is flagged, in the same commit.

**Progress (2026-11-17): items 1 and 3 shipped on option (a), left `partial` for the owner.** Item 2 had already landed with STOR12. The archive's `.partial` is opened with `os.open(O_WRONLY | O_CREAT | O_EXCL, 0o600)`, so its mode never depends on the umask; a destination `run_backup` creates is chmodded 0700 (`mkdir`'s own mode is masked), and one that already exists keeps its mode and is named in a `[WARN]` when group or world bits are set. `destination_encrypted` resolves the mount point with `df -P` (`diskutil info` refuses a path that is not one, checked on this Mac) and parses `diskutil info -plist`: `FileVault` decides on APFS, FAT, exFAT and HFS+ are unencrypted, `Encryption` is read only when `FileVault` is absent, and anything else (an error plist, which a network share gets, an unrunnable probe, Linux CI) is `null`. Both child processes get `egress_guard.child_env()`. A `false` or `null` prints one `[WARN]` and does not refuse; the marker records it, `mp doctor` warns on both, and Swift's `LastBackup` reads it so the Preferences last-backup line ends "to a drive that is not encrypted" (or "may not be encrypted" for `null`), which is where an unattended scheduled run's outcome is read.

Independent review (opus, fresh context) found, and this commit fixes: a FAT or exFAT stick and a network share read as "could not tell" and then showed nothing in Preferences or doctor (FAT, exFAT and HFS+ now read as unencrypted, and a recorded `null` is shown and warned too); `Encryption` alone read an Apple Silicon Mac with FileVault off as encrypted (the probe now keys on `FileVault`); the copy promised the 0600 archive was private on external drives, which macOS mounts with ownership ignored (softened everywhere); a `df` line with a space in the device name, a non-zero `df` exit, a folder created by a parallel run, a share refusing `chmod`, and a traverse-only mode flagged as readable. The probe stub moved to `conftest.py` so `test_zero_egress_files.py` stops shelling out too.

**Item 4, owner's decision (2026-11-17): option (a), an encrypted destination only.** The archive itself is not encrypted; no follow-up is filed for (b) an `hdiutil` encrypted image or (c) a crypto library. Decision beyond the spec: the Preferences line, since a scheduled backup's `[WARN]` lands only in `backup.out.log`, which nothing in the app reads. `conftest.py` stubs the probe (`_known_encryption`) so no test shells out to `diskutil`; the probe's own tests call the real function with an injected runner.
