# STOR8: `mp backup` writes the whole corpus, voiceprints included, to a world-readable archive under its final name, with no check that the destination is encrypted

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) PP-12). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified in `pipeline/src/mp/backup.py` on 2026-10-24. `backup_roots` archives four roots: the library (`recording.output_dir`, audio included unless `--no-audio`), `digests/`, `~/.config/meeting-pipe/` (config, workflows, `voiceprint.json`, `roster.json`, glossary) and the corrections corpus. That is every transcript, summary and recording, plus the owner's and every named participant's voice embeddings. Every library file the app writes is mode 0600 (SEC11, SEC14), and ADR 0016 keeps `originals/` out of the archive precisely because "Writing them into a tarball the owner copies to a NAS would defeat the property that ADR establishes". The archive itself gets none of that care:

- **Mode.** `create_backup` calls `destination.mkdir(parents=True, exist_ok=True)` and then `tarfile.open(archive, "w:gz", compresslevel=1)`. Both take the process umask, so under the default `022` the directory is 0755 and the archive 0644: readable by any local account, and by anyone at all on an exFAT or FAT USB drive, which has no permissions. The members inside keep their 0600 bits, which protects nothing once the container is readable.
- **Atomicity.** The archive is written in place under its final name, `meeting-pipe-backup-<ts>.tar.gz`. A crash, a full disk or an unplugged drive mid-run leaves a truncated file with a valid-looking name, exactly what STOR5's restore file panel asks the user to pick ("Pick a meeting-pipe backup archive (meeting-pipe-backup-*.tar.gz)."). The `.last-backup.json` marker is then written with `marker.write_text(...)`, not `storage.atomic_write_text`, and also at umask mode.
- **Encryption.** None, and nothing checks the destination. STOR4 runs `mp backup <dir>` unattended from a LaunchAgent (`BackupSchedulerService`, label `com.meetingpipe.backup`), so the usual destination is an external drive or a network share that nobody is watching. `check_destination` already inspects the destination (it refuses an unmounted `/Volumes/<name>`), so a second check fits beside it.

Latent on the owner's Mac on 2026-10-24: there is no `.last-backup.json` and no backup LaunchAgent installed, so no archive exists yet.

## Scope

1. **Private by construction.** Create the destination directory 0700 when `create_backup` creates it (leave an existing directory's mode alone and say so in the summary line if it is group- or world-readable), and open the archive with `os.open(..., O_WRONLY | O_CREAT | O_EXCL, 0o600)` handed to `tarfile.open(fileobj=...)`, so the mode never depends on the umask.
2. **Atomic.** Write to `meeting-pipe-backup-<ts>.tar.gz.partial` in the destination, `fsync`, close, then `os.replace` to the final name. Write the marker with `storage.atomic_write_text` (0600). On any exception, delete the `.partial` and leave the marker untouched. A `.partial` left by a killed process never carries the final name, so neither `mp restore <archive>` nor the restore panel can mistake it for a backup.
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
