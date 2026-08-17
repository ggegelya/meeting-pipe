# STOR5: Restore from backup in Preferences (the recovery half of the backup story)

Band origin: filed 2026-07-29 (owner exploratory sweep, item 16: surface capabilities that exist but are CLI-only; the inventory ranked this the top gap by stakes). Status and priority live in this task's ToC row in [owner-verification.md](../owner-verification.md), the queue of shipped work awaiting owner confirmation.

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

Both suites, ruff, pyright green, 23 new daemon tests and 14 new pipeline tests. Truth fences green. Repo dash guard green.

Owner eyeball: Back up now; move one meeting's files out of the library; Restore from backup, pick the archive: the preview names the missing meeting; confirm; the meeting is back in the Library list.

## Progress (shipped 2026-08-03, owner-owed on the eyeball)

Everything in Scope landed and every engineering line of Acceptance is green. The row stays here as `owner-owed` because the eyeball above is the only check that the preview *actually* names a missing meeting before a `--force` run writes anything, and this is the batch's one destructive-path surface.

**The flag surface, read at pickup as the spec asked, and it changed the shape of everything downstream.** The dry run was prose, and the conflict semantics are not per-file at all: `restore_archive` refuses a destination root that holds *any* file unless `--force`, and with `--force` it merges, overwriting same-named files and leaving everything else alone.

**Why the real run passes `--force`, always.** That refusal was written for a new Mac's empty roots. Every in-app restore writes into *live* roots (that is the whole point of this task: un-deleting a meeting from a library that still holds the other two hundred), so without `--force` the button would refuse on its first use, every time, and the feature would not exist. So the refusal is suppressed and **the preview is what replaces it**: the owner is told how many files are overwritten, by name where there is room, and presses a button reading `Restore N files` under a message ending "There is no undo." That trade is the single most important thing to re-check if this code is ever revisited, which is why it is written down here and not only in the archive: drop the preview and the button becomes an unguarded overwrite of the library.

**The contract.** New `plan_restore` + a `RestorePlan` TypedDict behind `mp restore <archive> --dry-run --json [--out PATH]`: per root the destination, files landing, `added`, `replaced`, and `occupied` (a separate question from `replaced`, since a library full of *other* meetings is occupied with nothing to overwrite), plus `keeps_config_toml`, `audio_included`, `created_at`, and capped `added_sample` / `replaced_sample` path lists so the confirm can name what comes back. `--json` requires `--dry-run` and `--out` requires `--json`, both as `parser.error` before anything is resolved; with `--out` the payload goes to the file and stdout keeps a readable trace, because the daemon's spawn logs to `pipeline.log` and a bare "wrote the plan" would leave the log unable to say what the owner was shown. Plan and real run share `_restorable_members`, the one home of the prefix dispatch and the `config.toml` carve-out, so the preview cannot describe a different restore than the one that runs (pinned by `test_plan_matches_what_the_real_run_then_writes`).

**The daemon.** `daemon/Sources/MeetingPipe/RestoreFlow.swift` carries three things and a gate. `RestorePlan` decodes the payload; `RestorePreview` is the pure copy over it (confirm title, blast-radius message, footer summary), separate from the view because this is the text that has to be honest; `RestoreFlow` is the two-invocation state machine, where `confirm()` only acts from `.confirming`, so the real run is structurally unreachable except through a plan the owner was shown, and its archive comes from the plan rather than the picker so both invocations are provably about one file. `StorageBusyGate` makes backup and restore mutually exclusive, for a stated reason rather than tidiness: a `mp backup` walking the library mid-restore archives a half-restored library. Both argv are built by pure statics (`restorePreviewArgs` / `restoreArgs`) so a test pins them without spawning; the real run is deliberately *not* retained for cancel, since a restore killed halfway leaves a library that is neither the old one nor the backup.

**Two decisions not in the spec.** (1) The button is its own `SettingsRow` directly under "Back up now" rather than a third control inside that row: that row's controls were already truncating (UX43 is the fix landing beside this), and restore earns its own sublabel. It stays in the Backup group so the completion summary lands in the existing footer slot as the spec requires. (2) `LastBackup.parseISO8601` was promoted from `private` and reused instead of copied. Python writes microseconds and `ISO8601DateFormatter`'s fractional mode wants milliseconds, so the naive fractional-then-plain fallback fails on *every* real timestamp; that file had already solved it, and a second copy would have been a copy that drifts.

**Not done, deliberately:** the plan payload is pinned by a fixture *inside* `RestoreFlowTests` (generated by running the real writer and pasted verbatim) rather than by a generated CI4 golden fixture. The CI4 machinery exists for surfaces where a silent drift corrupts data or branches many call sites; here a drift renders an empty preview, the real run's behaviour is pinned independently on the Python side, and the payload is advisory. Worth revisiting if the plan ever grows a field the daemon acts on rather than reads aloud.

**Verified:** `swift build` clean, 2052 daemon tests green (23 new in `RestoreFlowTests`); ruff clean, pyright 0 errors, 1171 pipeline tests green (14 new in `test_backup_restore.py`); truth fences green; dash guard green. Docs in the same commit: `README.md`, `ARCHITECTURE.md`, `CONVENTIONS.md`, root / `daemon/` / `pipeline/` `CLAUDE.md`. Checked and unchanged: `PRODUCT.md`, `docs/SETUP.md`, `design/`.

## Owner walkthrough (for the session that picks this up)

Every task gated on an owner action carries one (2026-07-30 rule). Walk the owner through it step by step; the owner does not read code. Steps are tagged [owner] / [session] by who acts. Nothing here needs the Terminal.

1. [session] `./scripts/rebuild.sh` from the repo root, then tell the owner it is ready.
2. [owner] **Take a fresh backup first, and this is not ceremony.** Preferences ▸ Storage ▸ Backup: if no destination is set, pick one, then click **Back up now** and wait for the footer to read "Last backup today". A restore also replaces workflows, roster, and vocabulary with the backup's copies, so restoring a week-old archive would quietly revert a week of settings. An archive made minutes ago cannot.
3. [owner] Make something to recover. In Preferences ▸ Storage ▸ Library, click **Reveal in Finder**, pick **one** meeting, and drag every file whose name starts with that meeting's timestamp (there are several: the recording, the transcript, the summary, and its sidecars) to the Desktop. To the Desktop, not the Trash, so you can put them back by hand if anything here goes wrong.
4. [owner] Open the Library. That meeting should be gone from the list.
5. [owner] Back to Preferences ▸ Storage ▸ Backup ▸ **Restore from backup…**. The panel opens in your backup folder; pick the archive from step 2. The app reads it first and writes nothing yet, and the footer says "Reading the backup…" while it does. On a large library this takes a moment, because it has to read the whole archive.
6. [owner] **The step this whole task turns on. Read the confirm before pressing anything**, and check three things:
   - **"Comes back:"** should name the files you dragged to the Desktop. That line is the preview claiming it knows what is missing.
   - The sentence should say it **overwrites** some number of files "already there", and that number should look like most of your library. That is correct and it is the honest part: the restore writes the backup's copy over the identical file already on disk, one for one. If it said it was overwriting nothing, the preview would be lying.
   - The button should read **"Restore N files"** where N is everything in the archive, not just the few that are missing.
   If "Comes back" names nothing, or names the wrong meeting, **press Cancel and say so.** That is this check failing, and at that point nothing has been written.
7. [owner] Press **Cancel** once on purpose. The Library should still be missing the meeting and the footer should go back to the backup age. Then open **Restore from backup…** again, pick the same archive, and this time press the restore button.
8. [owner] While it runs, the footer reads "Restoring …" and **Back up now** should be greyed out (they are deliberately never allowed to run together). When it finishes the footer should read "Restored N files from meeting-pipe-backup-….tar.gz."
9. [owner] Open the Library. The meeting you moved out is back, with its summary and transcript intact, and nothing else has changed. Then delete the copies you left on the Desktop.
10. [owner] Say "STOR5 good to close" (or what is wrong); [session] moves the row and this spec into `q6-final.md` and deletes this file. If step 6 was the part that failed, that is engineering work, not dwell time: the preview is the only guard in front of a `--force` overwrite, and the row stays open until it is right.
