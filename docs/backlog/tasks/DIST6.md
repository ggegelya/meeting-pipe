---
id: DIST6
title: Every build is version 0.1.0 build 1 with no commit recorded, and an install deletes the previous bundle, so a bug report cannot be tied to code and a bad build cannot be rolled back
category: Distribution
status: new
priority: P2
comment: Filed 2026-10-24 (audit band, go-live PD-4 identity half, DI-7, harness D): install.sh hard-codes 0.1.0 build 1, no tags, the failure report says 0.1.0 and rejects non-numeric versions, rebuild.sh never rewrites the plist, install rm -rf's the old app. Stamp an integer build plus commit in both scripts, show it in reports, a log event and Preferences, keep an APFS-cloned app.prev and venv.prev, rollback.sh. [Spec](./DIST6.md) Amended 2026-10-25 (observability band): findMP picks embedded, venv, uv run from the clone, or PATH mp silently on every spawn and run_started records none of it, so the plist commit can name code that did not run. Item 2 adds a tier on MPInvocation, a pipeline_invocation_resolved event on change, executable, version, build commit and tier on run_started, and a doctor WARN for a clone or PATH tier. Amended 2026-11-13 by the audit band: the home Mac still runs a 2026-09-11 binary over an editable venv of the main checkout and nothing detects it; add a doctor FAIL on an editable or mismatched venv and a spawn-time stamp comparison (F021).
---

# DIST6: every build is version 0.1.0 build 1 with no commit recorded, and an install deletes the previous bundle, so a bug report cannot be tied to code and a bad build cannot be rolled back

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) fix 4 / PD-4 identity half, DI-7; [AI harness audit](../../audits/2026-10-24-ai-harness-audit.md) section D). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

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

## Amended 2026-10-25 (observability audit band)

The [observability audit](../../audits/2026-10-25-observability-audit.md) (finder FB-12) adds the pipeline half of build identity. Verified in code on 2026-10-25.

**Which pipeline code ran is chosen silently and recorded nowhere.** `PipelineLauncher.findMP()` walks a four-tier ladder: the embedded runtime (`Contents/Resources/pipeline-runtime/bin/python3 -m mp`, DIST1), the prebuilt venv (`~/.local/share/meeting-pipe/venv/bin/python3 -m mp`, through `resolveDirectMP`), `uv run --project <repo>/pipeline mp` found by walking up from the executable to a `pipeline/pyproject.toml`, and a bare `mp` on `PATH`. It returns the first hit with no log on any branch, and `runMP` calls it through `invocation()` on every spawn. On the Python side `orchestrate.run_all` emits `run_started` with `wav` and `force_byo` only. The third and fourth tiers can run different code from the installed app: `uv run --project` runs the clone's working tree as it is now, and a stale `PATH` `mp` runs whatever was installed last. Item 1's `MPGitCommit` in the app's plist would then name a commit the pipeline did not run, so the stamp is only true if the tier is recorded beside it.

Item 2 additionally covers:

- **Name the tier.** `MPInvocation` gains `tier` (`embedded`, `venv`, `uv_clone`, `path`). The daemon logs `daemon` / `pipeline_invocation_resolved` (`tier`, the executable path) once at launch and again whenever a spawn resolves a different tier than the last, as an event plus a `daemon.log` line, so a fall-through mid-session is visible. OBS4's `pipeline.log` spawn header carries the same tier name.
- **Stamp the run.** `runMP` exports `MP_BUILD_COMMIT` (the plist's `MPGitCommit`) and `MP_INVOCATION_TIER`; `run_started` adds `executable` (`sys.executable`), `version` (`mp.__version__`), `build_commit` and `tier` from those. Under the `uv_clone` tier the commit is the clone's, so `run_started` also adds `source_commit` from `git -C <pipeline dir> rev-parse --short HEAD` when that tier ran, bounded by a short timeout and omitted on failure.
- **Say it in the places the owner looks.** The Preferences "Build" row and `mp doctor` print the resolved tier, and a `uv_clone` or `path` tier on an installed app is a doctor WARN, because the installed app should always resolve `embedded` or `venv`.

Added acceptance:

- `resolveDirectMP` and a seam over the uv and `PATH` tiers return the right `tier` for each layout (temp dirs, no real `uv`); `pipeline_invocation_resolved` fires once for two spawns on the same tier and again on a change.
- A pytest that `run_started` carries `executable`, `version`, `build_commit` and `tier` from the environment, and omits `build_commit` when it is unset.
- The doctor WARN for a `path` tier against an app bundle path, and none for `venv`.

## Amendment 2026-11-13 (audit band)

From the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) F021 and the [field evidence](../../audits/2026-11-13-field-evidence.md) cross-check finding "F021 class on the laptop: each build ran for a month or more".

**The skew is live on the owner's home Mac.** Re-verified on 2026-11-14 on that Mac: `~/Applications/MeetingPipe.app/Contents/MacOS/MeetingPipe` has an mtime of 2026-09-11, the running daemon (started 2026-11-13 09:11 local) is that binary, and `~/.local/share/meeting-pipe/venv` still carries `_editable_impl_meeting_pipe.pth` pointing at the main checkout's `pipeline/src`. 96 commits have landed since 2026-09-11 (F021 counted 94 at audit time, 48 touching `daemon/Sources` and 19 touching `pipeline/src`). [DIST4](../q6-final.md) (done) made the venv a non-editable install in `scripts/lib/pipeline-venv.sh` (`--no-editable`), but this Mac was never reinstalled, so that fix has not run here.

What it costs: every committed or uncommitted edit under the main checkout's `pipeline/src` processes real meetings under a daemon that predates the cross-tree contracts. The audit found no concrete contract break in the drift it examined (no removed CLI flag, SEC25's sidecar change only fails closed, the new `publish_state` "local" falls into benign default branches), so the harm is a work-in-progress Python edit running against a real meeting, and no signal that two months of daemon fixes are not running.

**Nothing detects it.** `PipelineLauncher.resolveDirectMP` accepts the venv on `isExecutable(venvPython)` and `bin/mp` alone, and neither `mp doctor` nor `MeetingPipe doctor` checks for an editable install (a grep for "editable" in `daemon/Sources` and `pipeline/src` finds only UI copy). Item 1's `MPGitCommit` names the app's commit only.

**Field, the work laptop.** Era A predates 2026-09-04 and ran until 2026-10-12 (at least 38 days), era B ran 31 days; whether the Python tree moved ahead of the binary in between cannot be told from the pack. The field note asks for the git revision of both trees in a launch event and the About panel.

Correction at filing: F021 proposes stamping "the app and the wheel". An editable venv has no wheel and the `uv_clone` tier runs the clone directly, so the pipeline half is stamped at sync time instead; and there is no About panel, so the Preferences "Build" row of item 2 is where it shows.

Added scope:

- **Stamp the venv.** `scripts/lib/pipeline-venv.sh` writes the commit it synced from (the same string as `MPGitCommit`) into a stamp file inside the venv.
- **Doctor FAIL on an editable or mismatched venv.** Both doctors FAIL when the venv's site-packages holds an `_editable_impl_*.pth` or a `direct_url.json` with `"editable": true`, or when the venv stamp differs from the app's `MPGitCommit`. The message names `./scripts/install.sh` as the fix.
- **Compare at spawn.** Beside the `pipeline_invocation_resolved` event the 2026-10-25 amendment adds, the daemon reads both stamps and logs `daemon`/`pipeline_build_mismatch` (`app_commit`, `pipeline_commit`, `editable`) once per launch on a mismatch or an editable venv, and the Preferences "Build" row shows it. It warns and does not refuse: refusing would fail every meeting on a Mac that is merely stale.
- Item 2's launch event carries both commits.

Related: [OBS5](./OBS5.md) (the launch row), [HYG19](./HYG19.md).

Added acceptance:

- A pytest for the doctor probe over scratch venvs: an editable `.pth` FAILs, a matching stamp passes, a differing stamp FAILs.
- A Swift test that the spawn-time check reports an editable venv and differing stamps from injected file reads and stays quiet when they match; `pipeline_invocation_resolved` behaviour unchanged.
- `pipeline_build_mismatch` documented in `CONVENTIONS.md`'s event schema; `python3 scripts/truth_fences.py both` green.

## Owner walkthrough (amendment)

1. [owner] Run `./scripts/install.sh` once on the home Mac. Afterwards `ls ~/.local/share/meeting-pipe/venv/lib/python3*/site-packages | grep editable` prints nothing and the doctor reports no mismatch. This is the one-time cure F021 describes; the probe is what stops it recurring unseen. It confirms the probe after landing and does not gate building it.
