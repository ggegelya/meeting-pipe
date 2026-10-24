# DIST6: every build is version 0.1.0 build 1 with no commit recorded, and an install deletes the previous bundle, so a bug report cannot be tied to code and a bad build cannot be rolled back

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) fix 4 / PD-4 identity half, DI-7; [AI harness audit](../../audits/2026-10-24-ai-harness-audit.md) section D). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified on 2026-10-24.

**No build identity.** `scripts/install.sh` writes `Info.plist` from a heredoc with `CFBundleShortVersionString` `0.1.0` and `CFBundleVersion` `1`. `pipeline/pyproject.toml` and `mp.__version__` are both `0.1.0`. `git tag` lists nothing. The only per-build marker is `RebuildTagger`'s `app_rebuild` event, which records a cdhash change, not which commit it came from. The go-live assessment found the installed app on this Mac predated END9 by its strings alone, because nothing else could say how old it was.

**Where a version is read, it says 0.1.0.** `FailureDetailsView` passes `CFBundleShortVersionString` to `FailurePresentation.report(appVersion:)`, so every copied failure report reads "App version: 0.1.0". `report` also accepts only `^[0-9]+(\.[0-9]+){0,3}$` and prints "unavailable" for anything else, so a version string carrying a commit would be dropped unless that check changes. There is no About window, and neither Preferences nor `mp doctor` prints a version.

**rebuild.sh keeps the install-time plist.** It copies the binary and resource bundles into the installed app and never rewrites `Info.plist`, so a stamp written only by install.sh would go stale on the first rebuild while looking authoritative. (The harness audit says both scripts hard-code the version; only install.sh does.)

**No rollback.** install.sh runs `rm -rf "$APP"` and then `ditto` of the new bundle; rebuild.sh overwrites the binary in place. The previous build is gone either way. DIST4 made the venv a real install synced in place, so a rollback of the app alone would also leave the two trees out of step, which is what DIST4's ordering in rebuild.sh ("so a sync that fails leaves the installed binary alone and the two trees cannot land out of step") exists to prevent.

**The update path is documented now.** DIST4 added it to SETUP.md ("Updating is `git pull` inside the folder, then `./scripts/install.sh` again") and README. DI-7's "no documented update procedure" is closed; a rollback procedure is not.

## Scope

1. **Stamp both scripts.** A shared `scripts/lib/build-stamp.sh` computes `CFBundleVersion` as `git rev-list --count HEAD` (an integer, which is what `CFBundleVersion` must be and what a later notarized build will need), and writes `MPGitCommit` (short SHA, with a `-dirty` suffix when the tree has uncommitted changes) and `MPBuildDate` into `Info.plist` via `PlistBuddy`, before signing. install.sh and rebuild.sh both call it; rebuild.sh re-signs afterwards as it already does. `CFBundleShortVersionString` stays a human version the owner bumps by hand.
2. **Show it.** `FailurePresentation.report` prints the version as `0.1.0 (1042, abc1234)` and its validator accepts that shape; the daemon logs one `daemon` event at launch with `version`, `build` and `commit`; Preferences ▸ Advanced ▸ Diagnostics gets a read-only "Build" row with the same string and a copy button.
3. **Keep one previous build, both trees.** Before replacing anything, install.sh and rebuild.sh copy the current `~/Applications/MeetingPipe.app` to `MeetingPipe.app.prev` and the current venv to `venv.prev` (one generation, replacing any older `.prev`). Copy as an APFS clone (`cp -Rc`), not a move: the clone is near-free, and moving the venv away would turn rebuild.sh's incremental `uv sync` into a full reinstall on every rebuild. The `.prev` suffix is deliberate: without the `.app` extension Launch Services does not register a second bundle claiming `com.meetingpipe.daemon` and the `meetingpipe://` scheme. Nothing ever runs from a `.prev` path: the venv's console scripts carry absolute shebangs into `.../venv/bin/python` (the check `sync_pipeline_venv` relies on), which are correct again once rollback renames the pair back.
4. **One-command rollback.** `scripts/rollback.sh` swaps app and venv with their `.prev` pair, re-signs nothing (the `.prev` bundle is already signed with the same identity, so TCC grants hold), and relaunches through the DIST5 relaunch helper. It refuses when either `.prev` half is missing. `uninstall.sh` removes both `.prev` copies.
5. **Docs in the same commit**: SETUP.md's update paragraph gains how to check the installed build (the Preferences row) and how to roll back; README's install section the same.

## Explicitly not / out of scope

- Tagging the repo on every install. It writes into the clone as a side effect of installing, and a tag is a release decision; tags belong with DIST1's notarized release.
- Sparkle or any auto-update. Deferred selling machinery (root CLAUDE.md) and gated on a Developer ID (D8).
- The field confirmation of the open P1 rows (PD-4's other half). That is per-row owner verification, tracked in each row and `owner-verification.md`, not code.
- Restarting install.sh's relaunch: DIST5. Rollback calls its helper; land DIST5 first or include the helper here and let DIST5 adopt it.
- Pipeline versioning beyond the shared commit. `mp.__version__` stays `0.1.0`; the commit in the app's plist covers both trees because both are installed from the same checkout.

## Acceptance

- `FailurePresentationTests` gains: the stamped shape renders in the report; a malformed string still renders "unavailable"; no path or user data enters the version line.
- A shell test (the `test-login-agent-guard.sh` shape, temp dirs only) pins `build-stamp.sh` writing an integer `CFBundleVersion` and `MPGitCommit` into a scratch `Info.plist`, and `rollback.sh` swapping a scratch app and venv pair and refusing when one `.prev` is missing.
- `bash scripts/test-app-relocation.sh` stays green (it builds a staging app with the installer's functions).
- `cd daemon && swift build` and `swift test` green, N new tests in the commit body; `bash scripts/ci-local.sh fences` green.
- Owner check: after `./scripts/install.sh`, Preferences ▸ Advanced shows the commit `git rev-parse --short HEAD` prints; after a `./scripts/rebuild.sh` on a new commit it shows the new one; `./scripts/rollback.sh` brings the previous commit back and the menu bar comes up.
