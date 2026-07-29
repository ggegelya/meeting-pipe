# STOR5: Restore from backup in Preferences (the recovery half of the backup story)

Band origin: filed 2026-07-29 (owner exploratory sweep, item 16: surface capabilities that exist but are CLI-only; the inventory ranked this the top gap by stakes). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Backup is a first-class Preferences surface: remembered destination, "Back up now", and a scheduled agent with frequency/day/time (`PreferencesView+Storage.swift:177-227`, STOR3/STOR4). Restore is not: `mp restore <archive>` shipped with STOR2 (tar.gz with a manifest, `--dry-run` supported per its q6-final record) and the Storage pane deliberately excludes it, with the comment at `PreferencesView+Storage.swift:173-176` giving the reason ("a new-Mac restore runs before the app is configured, so it is not surfaced here") and the footer at :227 sending the user to the README runbook.

That rationale is sound for the case it names and silent about the others. On THIS Mac, with the app running, restore is how you: un-delete meetings that were trashed or retention-swept by mistake, recover from a bad batch operation, or pull the library back after moving it. For those, "open Terminal and run a command from a README" fails the de-CLI standing rule (restore is a user-facing capability, not an owner-dev diagnostic; it is not on the exempt list) and fails the owner's non-technical bar outright: the product currently helps you produce archives you cannot open.

## Scope

- A "Restore from backup..." button in the Backup group beside "Back up now": archive file picker (default directory = the remembered backup destination), then a mandatory dry-run pass rendered as a preview (what the archive contains, what would be written, what conflicts with files already on disk), then an explicit confirm, then the real run with the in-flight state and a completion summary in the existing footer slot.
- Plumb through `PipelineLauncher` like backup does, two invocations: `mp restore <archive> --dry-run` parsed for the preview, then the real run on confirm. At pickup, read `restore.py` for the actual flag surface and conflict semantics (STOR2's record names `--dry-run`; whether skip-existing/overwrite is a flag or the default decides how the preview words conflicts); if the dry-run output is prose today, add a `--json` mode to `mp restore` in the same change so the preview parses a contract instead of scraping text.
- The confirm copy names the blast radius honestly (how many files land, how conflicts are handled) and the busy state blocks a concurrent backup (shared `backupInFlight`-style gate).
- The clean-Mac first-restore path stays a documented terminal step: update the footer and README wording so the split is explicit (in-app for this-Mac recovery, runbook for a fresh machine), rather than the current blanket "Restore is a terminal step".

## Explicitly not in scope

Merging two libraries beyond what `mp restore` already defines. Selective per-meeting restore (the archive is the unit; per-meeting recovery is what the Trash confirm already guards upstream). Automatic or scheduled restores. Changing the archive format or manifest (STOR2's).

## Acceptance

Pipeline: if `--json` is added, tests pin the dry-run JSON shape (counts, conflict list) and that `--dry-run` writes nothing (existing STOR2 tests likely cover the second; extend, do not duplicate).

Daemon: launcher tests pin the two-invocation sequence (dry-run first, real run only after confirm, correct argv both times) against a fake launcher; preview presentation derives from a fixture dry-run payload (counts and conflict rendering table-tested); the restore and backup busy states are mutually exclusive.

Both suites, ruff, pyright green (baselines at filing: 1770 Swift, 1050 Python). Truth fences green. Repo dash guard green.

Owner eyeball: Back up now; move one meeting's files out of the library; Restore from backup, pick the archive: the preview names the missing meeting; confirm; the meeting is back in the Library list.
