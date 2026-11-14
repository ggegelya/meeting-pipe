---
id: DIST9
title: rebuild.sh overwrites the running daemon's executable in place long before it stops the daemon, and never checks for a live recording
category: Distribution
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). rebuild.sh cp's the new binary over the installed one (same inode, measured by the audit) before re-signing and long before bootout, so a KeepAlive respawn or a manual open in that window is killed at exec (audit measured exit 137), and neither rebuild.sh nor install.sh checks for a recording in progress, so a relaunch silently ends a live meeting (F105, not seen in the field; the 2026-11-13 reliability audit tells the owner to rebuild only between meetings). Refuse or ask when a recording is live, stop the daemon before touching the bundle, replace the binary by temp file and rename, in DIST5's shared relaunch helper if it has landed.
---

# DIST9: rebuild.sh overwrites the running daemon's executable in place long before it stops the daemon, and never checks for a live recording

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: finding F105 in the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) (partially confirmed, lens data). The [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) and its [evidence](../../audits/2026-11-13-recording-reliability-evidence.md) repeat it as the reason to rebuild the work laptop only between meetings. The [field evidence](../../audits/2026-11-13-field-evidence.md) cannot tell either way for F105, and found no launch that interrupted a recording between 2026-09-29 and 2026-11-13. Re-verified against HEAD `3a2da4fc` on 2026-11-13 by code reading.

**The order in `scripts/rebuild.sh`.** `swift build -c release`, then `sync_pipeline_venv`, then `say "Refreshing $APP"` and `cp "$NEW_BIN" "$APP/Contents/MacOS/MeetingPipe"`, then `install_resource_bundles`, the `GUIDE.md` copy, `ensure_dev_cert` and `sign_app_with_resources "$APP"`, then `mdimport`, and only then the relaunch: `launchctl bootout "gui/$UID/$LAUNCHD_LABEL"` and the five-try `launchctl bootstrap` loop (or, when launch at login is off, `pkill -f "$APP/Contents/MacOS/MeetingPipe"` and `open "$APP"`). The daemon runs throughout the bundle rewrite. BSD `cp` onto an existing file truncates and rewrites it, so the running process's executable inode is modified in place; the audit measured the same inode before and after.

**Consequence 1, the exec window.** Between the `cp` and the re-sign, the file at the installed path is a new binary under the old signature. `scripts/launchd.plist.template` sets `KeepAlive` with `SuccessfulExit` false, so a daemon that exits non-zero in that window is respawned from that path; the audit measured such a fresh exec killed at once (exit 137). A manual open of the app in the window meets the same.

**Consequence 2, the live meeting.** Neither `rebuild.sh` nor `scripts/install.sh` looks for a recording in progress before relaunching. The bootout sends SIGTERM, whose path flushes what was captured (and, since [REC26](./REC26.md), the flags), and orphan recovery picks up the stem at the next launch; but the rest of the meeting is not recorded and nothing warned the owner. `install.sh` has the same gap with a different order: `rm -rf "$APP"` then `ditto "$APP_BUILD" "$APP"` while the daemon runs (unlinking does not disturb the running image), then `launchctl unload`, `bootstrap` and `kickstart -k`; with `--reset-tcc` it sends `pkill -KILL` first, which skips the SIGTERM flush entirely.

**Correction at filing:** the batch summary and the audit's original scenario say macOS can kill the already-running daemon whose mapped code pages changed, with no SIGTERM flush. The audit's own verifier did not reproduce that in three scratch trials (every page was resident at overwrite time) and did not disprove it. This task treats it as unreproduced: the fix removes the possibility either way, but the P2 rests on consequences 1 and 2.

**Where a live recording is visible on disk.** No daemon surface answers "are you recording" to a script: the `meetingpipe://` verbs in `AutomationCommand` are `record`, `stop`, `toggle` and opens, with no query. The nearest on-disk signal is `RecordingManifest`: `MeetingSessionController` writes `<stem>.recovery.json` beside the recording at start and removes it on a clean finish ("Clean finish: the meta sidecar is now on disk and the job is enqueued, so drop the start-time recovery manifest"). It is also left behind by a failed merge or sidecar write, for orphan recovery, so it is a superset of "live".

Related: [DIST5](./DIST5.md) item 1 (one shared relaunch helper in `scripts/lib/relaunch.sh`, not landed: `scripts/lib/` holds `dev-cert.sh`, `login-agent.sh`, `pipeline-venv.sh`, `resource-bundles.sh` and `sign-app.sh` on 2026-11-13; other audit-band batches may amend DIST5), [DIST6](./DIST6.md) (no rollback, notes the in-place overwrite only as that), [REC26](./REC26.md) (done, flags survive a rebuild relaunch).

## Scope

1. **Refuse or ask on a live recording.** Before touching the app or the venv, `rebuild.sh` and `install.sh` check for a recording in progress and, when one may be live, print what they found and ask `y/N`; with no TTY they refuse with exit 2 unless `--force` is given. The check fails toward asking: a `<stem>.recovery.json` in the recordings directory (resolved from config the way the venv's `mp` resolves `recording.output_dir`, falling back to the default) while the daemon process is running counts as live, so a stale manifest from an unrecovered orphan costs one extra question, never a lost meeting. If the pickup session finds that check too noisy in practice, the alternative is a pid-stamped live marker the daemon writes at `recording_started` and removes at stop; the manifest scan is preferred because it needs no daemon change.
2. **Stop before writing.** `rebuild.sh` stops the daemon (bootout, or `pkill` when launch at login is off) before the binary, resource bundle and `GUIDE.md` writes, and starts it after signing, so no process runs or respawns from a half-written bundle. The venv sync keeps its place before any app write, so DIST4's "a sync that fails leaves the installed binary alone" still holds.
3. **Replace, do not overwrite.** The binary lands as a temp file in `Contents/MacOS/` and is renamed over `MeetingPipe` (`mv`, same volume), so the installed path is never a partially written or old-inode-new-bytes file.
4. **One home for it.** If [DIST5](./DIST5.md)'s `scripts/lib/relaunch.sh` has landed, the live check and the stop live there and both scripts call it; if not, put the live check in a new sourced `scripts/lib/` helper both scripts call, and DIST5 folds it into the relaunch helper later.

## Explicitly not

- Rollback of a bad build or keeping the previous bundle: [DIST6](./DIST6.md).
- install.sh's unchecked relaunch success: [DIST5](./DIST5.md) item 1.
- `uninstall.sh`'s `pkill` of a recording daemon: [DIST8](./DIST8.md) records it; it can call the same guard once this lands. Not scoped here.
- A daemon-side query endpoint for recording state: the manifest scan needs no new surface.
- Observed, not examined: `sync_pipeline_venv` rewrites the venv while the daemon may have an `mp` run in flight under it. Recorded so it is not lost; not filed.

## Acceptance

- `scripts/test-rebuild-guard.sh` (new, the stubbed-`PATH` shape DIST5 specifies for `test-relaunch.sh`: `launchctl`, `pgrep`, `pkill`, `open`, `codesign`, `swift` and `mdimport` stubbed to log their calls, `HOME` a `mktemp -d` scratch with a fake installed app and recordings directory; never the real `launchctl` or app). Cases:
  - A scratch `<stem>.recovery.json` present and the `pgrep` stub reporting a process: with no TTY and no `--force` the script exits 2, the fake app's binary is byte-identical and no `launchctl` or `pkill` call was logged.
  - Same with `--force`: proceeds.
  - No manifest: proceeds without asking.
  - Call order in the log: the stop (`bootout`, or `pkill` on the launch-at-login-off branch) precedes the first write to the fake app, and `bootstrap` (or `open`) follows the signing call.
  - The fake binary's inode differs after the run (rename, not overwrite).
- The new test is wired into `scripts/ci-local.sh` (a new CI check goes in that script, per the root `CLAUDE.md`).
- `bash scripts/test-login-agent-guard.sh` and `bash scripts/test-app-relocation.sh` stay green (the launch-at-login branch and the resource-bundle and venv libraries are touched); `bash scripts/ci-local.sh fences` green.
- README's "Rebuild loop for local edits" paragraph says the rebuild now stops the daemon before writing into the app and asks before ending a live recording, in the same commit.

## Owner walkthrough

1. [owner] Start a manual recording, run `./scripts/rebuild.sh`, and see it stop to ask before building into the app; answer `n` and see the recording still running in the HUD; stop the recording.
2. [owner] With nothing recording, run `./scripts/rebuild.sh` and see it complete and relaunch without asking.
