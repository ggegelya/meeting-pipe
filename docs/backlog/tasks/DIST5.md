# DIST5: install.sh reports "running" without checking the daemon came up and never checks for Swift 6, uninstall.sh leaves the digest and backup agents and the local model behind, and the Gatekeeper guidance describes a dialog a local build never shows

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) DI-8, DI-9 toolchain half, DI-10, DI-16, PP-14). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified on 2026-10-24 against `scripts/install.sh`, `scripts/rebuild.sh` and `scripts/uninstall.sh` as they stand after DIST4 and CI8.

**1. install.sh's relaunch is unchecked (DI-8).** Step 6 runs `launchctl unload "$PLIST" || true`, then `launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || true` and `launchctl kickstart -k ... 2>/dev/null || true`, and prints "✓ Install complete. MeetingPipe is running in your menu bar". Nothing checks a process exists. `rebuild.sh` documents why that is not enough: after a cdhash change `kickstart -k` "reuses that stale constraint, so the respawn fails with EX_CONFIG (78) ... and kickstart still returns 0", and `bootstrap` "can lose a race with the teardown". rebuild.sh fixed both with `bootout`, a five-try `bootstrap` loop that dies on failure, and a `pgrep` loop that dies with a pointer to `launchd.err.log`. install.sh never got the fix.

**2. Swift 6 is required and not checked (DI-9, toolchain half).** `daemon/Package.swift` says `swift-tools-version:5.9`, but the pinned FluidAudio 0.14.8 declares `// swift-tools-version: 6.0` (`daemon/.build/checkouts/FluidAudio/Package.swift`), so a Swift 5.x toolchain fails at package resolution with a SwiftPM error that does not name the fix. install.sh checks only `command -v swift`; SETUP.md Step 1 says "You should see a version number" without naming which.

**3. Uninstall leaves running jobs and gigabytes (DI-10).** `uninstall.sh` boots out and removes only `com.meetingpipe.daemon.plist`. The daemon also installs `com.meetingpipe.digest` (`DigestSchedulerService.label`) and `com.meetingpipe.backup` (`BackupSchedulerService.label`) through `LaunchAgentScheduler` under `~/Library/LaunchAgents/`; after an uninstall they stay loaded and fire into a deleted venv on schedule. It also leaves the local summarizer model under `~/.cache/huggingface/hub` (`prefetch_model.py`'s cache path; the default `mlx-community/Qwen2.5-7B-Instruct-4bit` is the 4.3 GB download SETUP.md Step 7 names), and keeps `~/.cache/meeting-pipe` with a message. SETUP.md's "Changing your mind" says the uninstaller leaves recordings, settings and permissions alone, which is true, and says nothing about the rest.

**4. The Gatekeeper guidance is wrong for both paths (DI-16).** SETUP.md Step 4 and "When something goes wrong", and README's "First launch & Gatekeeper", tell the user to right-click Open past an "unverified developer" dialog and README calls the app "unsigned". A locally built bundle carries no `com.apple.quarantine` attribute (`xattr -l ~/Applications/MeetingPipe.app` on this Mac shows only `com.apple.provenance`), so Gatekeeper never shows that dialog for the from-source install, and the app is signed, with the self-signed "MeetingPipe Dev" identity (`scripts/lib/dev-cert.sh`). For a downloaded, non-notarized build the right-click Open bypass is not the path on current macOS either (System Settings ▸ Privacy & Security ▸ Open Anyway is), and a notarized DMG (DIST1) shows no such dialog at all.

**5. PP-14 is mostly fixed; recorded here so it is not refiled.** "The install hides frozen-sync failures" no longer holds: DIST4's `sync_pipeline_venv` runs `uv sync --frozen --no-editable` and install.sh dies on failure ("There is no unlocked fallback any more"). CI8 capped `anthropic`, `httpx` and `mlx-lm`. The remaining floor-only ranges (`pydantic`, `numpy`, `soundfile`, `tenacity`, `mlx-embeddings`) move only on a deliberate `uv lock`, since both install paths now consume the lock (`bundle-runtime.sh` via `uv export --frozen --require-hashes`). Nothing to do.

## Scope

1. **One relaunch helper.** Move rebuild.sh's bootout, bootstrap-retry and `pgrep` verification into `scripts/lib/relaunch.sh` (the `login-agent.sh` pattern), and call it from both scripts. install.sh's closing line is printed only after verification passes; on failure it dies with the same `launchd.err.log` pointer rebuild.sh uses. The UX42 disabled-agent branch is unchanged in both.
2. **Check the toolchain.** install.sh parses `swift --version` and dies below 6.0 with a message naming the fix (install or update the Xcode Command Line Tools, or select a full Xcode with `xcode-select -s`). SETUP.md Step 1 says "6.0 or later" and what to do otherwise.
3. **Uninstall what the app installs.** `uninstall.sh` boots out and removes `com.meetingpipe.digest` and `com.meetingpipe.backup` alongside the daemon agent (labels read from one list, so a third scheduled job is one line). The Hugging Face model directories the app downloaded (`models--mlx-community--*` for the configured local model and the embedder) are removed only with `--purge`, listed by name and size before removal; a default uninstall prints their size and the flag. SETUP.md "Changing your mind" lists what stays.
4. **Correct the Gatekeeper text.** SETUP.md Step 4, its troubleshooting line and README's "First launch & Gatekeeper" say what is true for a from-source install: the app is self-signed, no Gatekeeper dialog appears, and if the menu-bar icon is missing, open `~/Applications/MeetingPipe.app` once. The downloaded-build case is left to DIST1's SETUP.md section, which this task does not write.

## Explicitly not / out of scope

- `LSMinimumSystemVersion 13.0` and the Screen Recording usage string: DOC16.
- Version stamping and a rollback copy: DIST6. If both land, DIST6's stamp goes into the same heredoc; sequence them.
- Hardened runtime and the `-A` key import in `dev-cert.sh`: SEC17.
- Automated CI coverage of the installer and uninstaller as a whole: CI9. This task adds only the canned-output test for the new helper.
- Removing the library or Keychain items by default. `--purge` keeps owning the destructive cases.

## Acceptance

- `scripts/test-relaunch.sh` (new, the `test-login-agent-guard.sh` shape: no real `launchctl`, stubbed commands on `PATH`) pins: bootstrap succeeding on the third try passes; bootstrap failing five times exits non-zero; a bootstrap that succeeds with no process appearing exits non-zero with the log pointer; the disabled-agent branch never calls bootstrap.
- `bash scripts/test-login-agent-guard.sh` stays green; `bash -n` on all three scripts clean.
- A toolchain-version check case: a stubbed `swift --version` printing 5.10 makes install.sh's check die before `swift build`; 6.0 and 6.3.3 pass.
- `bash scripts/ci-local.sh fences` green after the SETUP.md and README edits.
- Owner check on this Mac: run `./scripts/install.sh` and see it confirm the daemon is up; turn on the weekly digest in Preferences, run `./scripts/uninstall.sh`, and `launchctl print gui/$(id -u)/com.meetingpipe.digest` reports no such service.
