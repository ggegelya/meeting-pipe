---
id: SEC35
title: Doctor's cloud-sync check never looks at the folder NDA and regulated meetings publish to, or at the backup destination, so it reports an all-clear while both sit in iCloud
category: Security
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). F018, F137, F086: `doctor._synced_roots` adds the published folder only when the global `output.sinks` lists filesystem, but `apply_overrides` forces every NDA, regulated or unreadable-sidecar meeting onto that sink, and no check looks at the backup destination or the Obsidian vault; SEC12's every-synced-root claim does not hold. The zero-egress legs are latent on this Mac (regulated off, no NDA workflow); the vault leg is live (110 notes and 110 WAVs in a vault under the iCloud-synced Desktop folder, never named by doctor). Add the published folder, the backup destination (from the backup marker and the backup agent) and the vault and LAN targets as doctor roots, and warn in the Storage pane's backup picker. Promote before enabling regulated or NDA. [Spec](./SEC35.md)
---

# SEC35: Doctor's cloud-sync check never looks at the folder NDA and regulated meetings publish to, or at the backup destination, so it reports an all-clear while both sit in iCloud

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Sources: [independent audit](../../audits/2026-11-12-independent-audit.md) findings F018 (high, confirmed, re-read in source by the audit author), F137 (confirmed) and F086 (medium, partially confirmed, folded in as a residual). Re-read at HEAD `3a2da4fc`.

**This regresses SEC12.** SEC12 (done, 81dc71fa, [q6-final.md](../q6-final.md)) claimed doctor checks every synced root meeting-pipe writes to and FAILs under regulated mode or any NDA workflow. That fix does not hold for the one folder those modes force meetings into.

**The gate (F018).** `doctor._synced_roots` builds `[("library", library), ("digests", storage.digests_dir(library))]` and adds the published folder only under `if "filesystem" in cfg.output.sinks:`. The global default is `["notion"]`. But `workflow.apply_overrides` rewrites sinks for every zero-egress meeting (`if overlay.output.sinks != ["filesystem"]: overlay.output.sinks = ["filesystem"]`, logged `zero_egress→sinks=filesystem`), and SEC25's `_fail_closed` does the same for an unreadable sidecar. Swift's `Workflow.effectiveSinks` is `flags.ndaMode ? [.filesystem] : sinks`. `FilesystemPublisher` then writes `<stem>.summary.md`, `.actions.json` and `.transcript.md` into `filesystem.output_dir`, default `~/Documents/Meetings/published`, inside iCloud Desktop and Documents on this Mac. Workflow-level sinks (`[[sinks]]` tables with a `type` key, written by `WorkflowStore`) are not read either: `workflows.py` has readers for NDA and local-backend workflows only. `check_library_sync` then prints `[ OK ] no meeting data is inside a cloud-sync folder` and returns before it looks at NDA workflows. The audit reproduced this in a sandbox (local library, published folder under a synced root, default sinks, one NDA workflow: `[ OK ]`; control with filesystem in global sinks: `[FAIL]`). The case bites after the documented fix: `LibraryMover` moves only the recordings and digests, so a library moved out of iCloud leaves `published/` behind, and README and CONVENTIONS promise doctor keeps reporting it.

**The backup destination (F137).** `backup.check_destination` refuses only an unmounted `/Volumes` drive. Neither `mp backup`, doctor, nor the Storage pane's `chooseBackupDestination` (its panel message only advises "Prefer one outside a cloud-synced folder if the library is sensitive") runs sync detection on it. An archive holds all audio, transcripts, voiceprints and the roster, NDA and regulated meetings included.

**Correction at filing:** the backup destination is not in `config.toml`, so doctor cannot read it from `cfg`. It lives in the daemon's `UISettings.backupDestinationPath` (UserDefaults) and, when the schedule is on, in `~/Library/LaunchAgents/com.meetingpipe.backup.plist` (`BackupSchedulerService.apply` installs `arguments: ["backup", destination]`). Doctor can reach it two ways it already half has: `storage.backup_marker(home)` (read by `check_last_backup`) records the last archive path, whose parent is the destination of the last run, manual or scheduled; and the agent plist's `ProgramArguments` names the next one.

**The vault (F086, residual).** `ObsidianPublisher` copies `<stem>.wav` (`_copy_audio_attachment`) and embeds the whole transcript (`"## Transcript\n\n" + transcript_md.read_text(...)`) into `obsidian.vault_path`; `lan.mount_path` takes files too. Neither is a doctor root, and Swift's `CloudSyncDetector.detect` runs only on the library (`StorageStatsStore`) and the move destination (`LibraryMover`). **Correction at filing:** sidecar-bearing NDA and regulated meetings never reach the vault (forced to filesystem above). Only a sidecar-less run under global `regulated_mode` (manual CLI, legacy recordings) does, because `config.effective_sinks` under `zero_egress` drops only Notion; that publish-time leg is [SEC18](./SEC18.md) item 1, not this task. What remains here is doctor's blind spot.

**Field evidence.** None for the zero-egress legs: regulated mode is off and no workflow is NDA on this Mac (`workflow_nda_mode` false on 113 of 113 metas in the [field pack](../../audits/2026-11-13-field-evidence.md)). The vault is the sink in use and it is synced: the pack puts 110 of 110 notes in one vault under the user's Desktop folder, each with a `.wav` attachment copied in, and on 2026-11-14 `cloudsync.detect_sync_provider(~/Desktop)` returned iCloud Drive with root `~/Desktop` (`com.apple.icloud.desktop` on both `~/Desktop` and `~/Documents`). Because that root differs from the library's (`~/Documents`), the dedupe in `_synced_roots` would not fold it into the library line: doctor today WARNs about the library and says nothing about the vault, which holds every meeting's audio. Outside zero egress that is a WARN-level gap, which is why the priority stays P2.

## Scope

All in `pipeline/src/mp/doctor.py` unless named.

1. **Published folder.** `_synced_roots` adds `filesystem.output_dir` when any of these holds: the global sinks list `filesystem`; `cfg.modes.regulated_mode`; any NDA workflow exists; any workflow's `sinks` lists a `filesystem` entry; or the folder exists and holds at least one file (which covers the SEC25 fail-closed path and every earlier run). A new reader in `workflows.py` (`sink_types_in_use(directory)` or similar, read-only like its neighbours) answers the workflow half.
2. **Backup destination.** `_synced_roots` adds the parent of the archive named in `storage.backup_marker(home)` (`run_backup` writes `"archive": str(archive)`, built from `destination.expanduser()`, so it is absolute for every daemon-run backup; a relative path from a hand-typed CLI run is skipped, not guessed) and the destination in the backup agent plist's `ProgramArguments` when it is installed (read with `plistlib`, home-relative so tests can point it at a scratch tree), labelled "backups". Deduped by sync root like the rest.
3. **Vault and LAN targets.** When `obsidian` or `lan` is in the global sinks or any workflow's sinks, add `obsidian.vault_path` / `lan.mount_path` as roots. They are WARN-level ("this data leaves your Mac") always, and FAIL only when `regulated_mode` is on and the global sinks list them (the sidecar-less path); once SEC18 item 1 has landed, they are WARN-only. If [FEAT22](./FEAT22.md) step 1 deletes the LAN sink first, the LAN half is moot and only the vault is added.
4. **The picker.** `PreferencesView+Storage.chooseBackupDestination` runs `CloudSyncDetector.detect` on the chosen folder and shows an inline warning naming the provider (stronger wording when regulated mode is on or an NDA workflow exists), without refusing the choice. The decision is a pure function so it is testable without a panel.

## Explicitly not

- Refusing a synced backup destination in `mp backup`: [SEC18](./SEC18.md) item 5. The publish-time synced-target gate for the filesystem sink: SEC18 item 2. The sidecar-less sink rule: SEC18 item 1. Archive mode 0600 and encryption: [STOR8](./STOR8.md).
- Moving the library or changing the default location: [STOR6](./STOR6.md). Doctor's exit code stays 0 (owner's call for SEC12).
- Detecting the backup destination from `UISettings` when neither a marker nor an agent exists: there has been no backup, so nothing is there yet; the picker check in item 4 covers the moment it is chosen.

## Acceptance

- `test_doctor.py`: with default sinks, a local library and the published folder under a fake synced root, one NDA workflow makes `check_library_sync` print `[FAIL] published summaries is synced`, and regulated mode does the same; a workflow listing a `filesystem` sink makes it at least `[WARN]` with no NDA; an empty, absent published folder with none of the conditions adds nothing; a non-empty published folder with none of the conditions adds the root.
- `test_doctor.py`: a backup marker whose archive sits under a fake synced root gives a `backups` line (FAIL with an NDA workflow, WARN without); a backup agent plist in the scratch home whose destination is synced does the same; both absent adds nothing.
- `test_doctor.py`: a synced `obsidian.vault_path` with obsidian in global sinks is a WARN; with `regulated_mode` on it is a FAIL until SEC18 item 1 lands (the test pins whichever rule is current).
- `test_workflows.py`: the new sink reader returns the sink types across workflow TOMLs, skipping malformed files like its neighbours.
- Swift: the picker's pure decision returns a warning for a synced path, the stronger wording under regulated mode or an NDA workflow, and nothing for a local path.
- `cd pipeline && uv run --extra dev pytest -q` and `swift test` green with the new test counts in the commit body; ruff and pyright green; `bash scripts/ci-local.sh` green. The `_synced_roots` docstring, README's doctor section and CONVENTIONS say what is checked, in the same commit.
