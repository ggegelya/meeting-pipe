---
id: DIST8
title: A default uninstall deletes the only copies of held-back recordings, every kept original and the corrections corpus, against what SETUP.md promises
category: Distribution
status: new
priority: P1
comment: Filed 2026-11-13 (audit band 2026-11-13). Broken promise: SETUP.md says a plain `uninstall.sh` leaves recordings and settings alone, yet it rm -rf's Application Support/MeetingPipe with no flag and no prompt, deleting originals/ (the only copy of a held-back or quarantined recording, excluded from mp backup and Time Machine), the summary-grading corrections corpus and auto_consent.json; README's `--reset-tcc` permissions fix runs the same rm (F020, not seen in the field). A hard precondition of MIC18; the owner may re-band. Keep Application Support/MeetingPipe unless --purge, list it with sizes and confirm before a purge, a stubbed scratch-HOME test, and true SETUP.md and README text in the same commit.
---

# DIST8: A default uninstall deletes the only copies of held-back recordings, every kept original and the corrections corpus, against what SETUP.md promises

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: finding F020 in the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) (high, partially confirmed, lens data). The [field evidence](../../audits/2026-11-13-field-evidence.md) lists F020 as "not seen" (no uninstall trace on the work laptop). Re-verified against HEAD `3a2da4fc` on 2026-11-13 by code reading.

**What the script does.** `scripts/uninstall.sh` parses only `--purge`, `--reset-tcc`, `--all` and `--help`, and never prompts. After booting out the LaunchAgent and `pkill`ing the daemon it runs, unconditionally, `rm -rf "$DATA_DIR"`, `rm -rf "$LOG_DIR"`, `rm -rf "$APP_SUPPORT"`, `rm -rf "$FLUID_AUDIO_SUPPORT"` and `rm -rf "$APP_BUNDLE"`, where `APP_SUPPORT="$HOME/Library/Application Support/MeetingPipe"`. Only `~/.config/meeting-pipe` and the Keychain tokens wait for `--purge`. The script's header comment and its closing echo do say "Application Support data"; the user-facing docs do not.

**What lives in that folder.** Every writer was enumerated on 2026-11-13, and each is either irreplaceable or a setting:

- `originals/`: `MuteRedactor.originalsDirectory()` (`"MeetingPipe/originals"` under Application Support). `MuteRedactor.quarantine` *moves* (`FileManager.default.moveItem(at: url, to: dest)`) the recording there; its two callers are `SinkDispatcher`'s held-back path for a failed redaction (`heldBackReason` tells the owner "The full recording is kept in MeetingPipe's originals folder.") and `OrphanRecordingRecovery`'s quarantine of a redaction-opt-in orphan. `RecordingPostProcessor` has already deleted the mic and system intermediates after a verified merge, so the moved file is the only copy. `protectOriginalAtRest` sets `isExcludedFromBackup`, and `backup.py`'s `EXCLUSIONS` lists `originals/` ("ADR 0016 excludes them from backups"), so neither Time Machine nor `mp backup` holds it. The folder also holds every kept pre-redaction original (ADR 0016). `OriginalsReaper.maxAge` (30 days) bounds how long a file sits there.
- `corrections/`: `CorrectionStore.directory()` (`Endpoints.Paths.correctionsRelative`), the summary-grading corpus of ADR 0015: grades and `CorrectionWindow` edits, which `SummaryStaleness` says are written only to `corrections/<stem>.json`, never into `summary.json`, so they exist nowhere else.
- `auto_consent.json`: `ConsentStore`'s "Always for {App}" consent, a setting.

**What the docs promise.** `docs/SETUP.md` "Changing your mind": "That leaves your recordings, your settings, and your macOS permissions alone." A held-back recording is a recording, the corpus and consent are the owner's own data, and none survive. README's Uninstall block annotates the plain run "keeps config + leaves TCC alone", and README's signing paragraph and troubleshooting entry recommend `scripts/uninstall.sh --reset-tcc` as a permissions fix, which runs the same `rm` lines.

**Failure scenario.** A meeting is held back after a failed redaction, so its only audio is in `originals/`. Within the 30-day window the owner runs `./scripts/uninstall.sh` to reinstall cleanly, or `--reset-tcc` to fix a stuck permission, as the docs suggest is safe. The recording, every kept original, the grading corpus and the consent list are deleted with no confirmation.

**Correction at filing:** narrower than the audit's original claim, as its verifier already noted. Per-line transcript corrections are `<stem>.transcript_corrections.json` sidecars in the library (`TranscriptCorrectionStore`), so they survive; what dies is the summary-grading corpus. That corpus is in `backup.py`'s `backup_roots` (`Root("corrections", ...)`), so it is recoverable when an `mp backup` archive exists; the originals are not. SETUP.md's narrower sentence that recordings in `~/Documents/Meetings/` are never touched is literally true.

**Correction at filing (exposure today):** on this Mac on 2026-11-13 `~/Library/Application Support/MeetingPipe` held only an empty `corrections/`, and the work laptop's pack shows no uninstall. The P1 rests on the promise and on [MIC18](./MIC18.md), not on an observed loss.

**Why P1.** MIC18 (P1) makes the kept original the recovery copy for regulated and NDA meetings and says it "lands only after the audit's F001 (the originals reaper deletes sole copies) and F020 (default uninstall deletes them) are fixed". F001 is [SEC26](./SEC26.md); this task is F020.

Related: [SEC26](./SEC26.md) (the reaper deletes the same sole copies; its `originals/held/` folder sits under `originals/`, so this task covers it), [DIST5](./DIST5.md) (item 3 edits the same SETUP paragraph and adds agent bootout to the same script; other audit-band batches may amend DIST5 and [SEC17](./SEC17.md), which also touch uninstall), [STOR7](./STOR7.md) (per-meeting delete footprint), [STOR8](./STOR8.md) (the backup archive that holds the corpus).

## Scope

1. **Keep the folder by default.** In `scripts/uninstall.sh`, move `rm -rf "$APP_SUPPORT"` out of the unconditional block into the `PURGE` branch beside `rm -rf "$CONFIG_DIR"`. The default and `--reset-tcc` runs then keep `originals/` (including SEC26's `held/` once it lands), `corrections/` and `auto_consent.json`, and say so in the closing message with the folder's path, the way the `Kept $CONFIG_DIR` line does. The venv, logs, FluidAudio model cache and app bundle are rebuildable and still go.
2. **List and confirm before a purge.** Under `--purge` or `--all`, before any removal, print each of `originals/` (file count and size), `corrections/` (file count and size), `auto_consent.json` and `~/.config/meeting-pipe` (size), stating that `originals/` is in no backup, then ask `y/N`. A non-interactive run (stdin not a TTY) refuses with exit 2 unless `--yes` is also given; `--yes` is the only new flag. The confirm runs before the LaunchAgent bootout and every `rm`, so declining (or the non-TTY refusal) aborts the whole run with nothing stopped or removed, and the script says so.
3. **True text in the same commit.** `uninstall.sh`'s header comment, `docs/SETUP.md` "Changing your mind" (what the plain run keeps, including held-back recordings, and that `--purge` deletes them after asking), README's Uninstall block annotations and its two `--reset-tcc` recommendations (which now delete nothing of the owner's). If [DIST5](./DIST5.md) item 3 has landed first, extend its "what stays" list rather than rewriting it.

## Explicitly not

- Copying `originals/` elsewhere or into `mp backup` on uninstall: ADR 0016 keeps pre-redaction audio local-only and out of backups; keeping it in place is enough.
- A prompt on the default run: after item 1 it deletes nothing that cannot be rebuilt.
- Removing the digest and backup LaunchAgents and the Hugging Face model on uninstall: [DIST5](./DIST5.md) item 3.
- The signing identity uninstall leaves in the login keychain: the audit band's [SEC17](./SEC17.md) amendment.
- `pkill` of a daemon that is recording a live meeting: the guard [DIST9](./DIST9.md) adds for rebuild and install, reusable here once it exists. Recorded, not scoped.
- A whole-installer CI job: [CI9](./CI9.md).

## Acceptance

- `scripts/test-uninstall.sh` (new) runs the real `uninstall.sh` with `HOME` set to a `mktemp -d` scratch directory and stubs for `launchctl`, `pkill`, `security`, `tccutil` and `killall` first on `PATH`, each recording its arguments to a file and doing nothing, so the test can never stop the live daemon, clear real Keychain tokens or reset real permissions. It fails if any stub is bypassed. Cases:
  - Default run: scratch `Application Support/MeetingPipe/originals/<stem>.wav`, `corrections/<stem>.json` and `auto_consent.json` all still exist; the scratch venv, logs and app bundle are gone; output names the kept folder.
  - `--reset-tcc`: same survivors; the `tccutil` stub was called.
  - `--purge --yes`: the three are gone; output listed each before removal with a count and size.
  - `--purge` with stdin not a TTY and no `--yes`: exit 2, every scratch path (the three, the config dir, the venv, the app bundle) still exists, and no stub was called.
  - `--purge` answered `n` (on a pseudo-TTY, or through the confirm read factored into a sourced `scripts/lib` helper the test drives with canned input): same as the previous case.
- The new test is wired into `scripts/ci-local.sh` (a new CI check goes in that script, per the root `CLAUDE.md`).
- `bash scripts/ci-local.sh fences` green (truth fences, links, no em-dash in changed lines); `docs/SETUP.md` and `README.md` edited in the same commit.

## Owner walkthrough

1. [owner] With no meeting in progress, put a scratch file at `~/Library/Application Support/MeetingPipe/originals/walkthrough.wav`, run `./scripts/uninstall.sh`, and see it report the folder kept and the file still there; reinstall with `./scripts/install.sh`.
2. [owner] Run `./scripts/uninstall.sh --purge`, read the listing (the scratch file counted, `originals/` named as in no backup), answer `n`, and see the file still there and the app still running; then delete the scratch file by hand.
3. [session] Read `docs/SETUP.md` "Changing your mind" and README's Uninstall block against the script's behaviour.
