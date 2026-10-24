# DIST4: the installed app only works while the git clone stays put, through its resource bundles and through its venv

Band origin: filed 2026-10-24 from the 2026-10-21 go-live assessment (`docs/audits/2026-10-21-go-live-assessment.md`, findings DI-1 critical and adversarially confirmed, PP-5, DI-2, UX-2; none of them was filed before). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

`~/Applications/MeetingPipe.app` and `~/.local/share/meeting-pipe/venv` look like an install, but both are bound to the clone they were built from, in two independent ways. Both were re-verified on the owner's live install on 2026-10-24.

### 1. Resource bundles resolve from `<repo>/daemon/.build` (DI-1)

SwiftPM's generated `Bundle.module` accessor tries exactly two places, `Bundle.main.bundleURL.appendingPathComponent("<Package>_<Target>.bundle")` (for an app that is the `.app` root) and an absolute path into the build tree it was compiled in, and calls `fatalError("could not load resource bundle: ...")` when neither exists. `scripts/install.sh` section 2b and `scripts/rebuild.sh` copy `MeetingPipe_MeetingPipe.bundle` and `MeetingPipe_MeetingPipeCore.bundle` into `Contents/MacOS` ("Side-by-side resource bundle"), which is neither path. The live app on 2026-10-24: `Contents/MacOS` holds `MeetingPipe`, `MeetingPipe_MeetingPipe.bundle`, `MeetingPipe_MeetingPipeCore.bundle`; `Contents/Resources` holds only `AppIcon.icns` and `GUIDE.md`.

So every resource lookup in the installed app is served by the absolute `.build` path. Move, rename, or `swift package clean` the repo and `Coordinator` init dies in `MuteLabelsLoader.loadDefault()` (`try loadDefault(bundle: .module)`); launchd's KeepAlive then restarts it into the same crash every 10 s. The four production `Bundle.module` uses: `MuteLabelsLoader.loadDefault` (Core), `MeetingAppRegistry.bundledTOMLString`, and `AppGlyphView.loadGlyph` (twice).

### 2. The installed venv is a launcher back into the clone (PP-5, DI-2, UX-2)

`install.sh` section 3 runs `uv sync --frozen --extra mcp 2>/dev/null || uv sync --extra mcp` in `pipeline/`, then `cp -R "$REPO_ROOT/pipeline/.venv" "$DATA_DIR/venv"`. uv installs the project editable by default, so the copy carries `site-packages/_editable_impl_meeting_pipe.pth` containing `<repo>/pipeline/src`, and `bin/mp` (uv's `/bin/sh` polyglot launcher, because the repo path has spaces) does `exec '<repo>/pipeline/.venv/bin/python3' "$0" "$@"`. Both confirmed on the live venv 2026-10-24.

Consequences: production Python is the working tree. A `git pull`, a branch switch, or an uncommitted edit changes what the app runs on its next pipeline job while the Swift binary stays at whatever was last built, and moving or deleting the clone breaks every pipeline run. The `2>/dev/null ||` fallback also hides a frozen-sync failure and silently re-resolves (rewriting `uv.lock`) instead. `--no-editable` alone would not fix it: the copied `bin/mp` would still exec the clone's own `.venv` interpreter.

`PipelineLauncher.findMP`'s venv tier then accepts `venv/bin/mp` on `isExecutableFile` alone, which is true for a launcher whose interpreter is gone, so a broken venv shadows the uv and PATH tiers instead of falling through.

### Probe (2026-10-24, scratch copy of `pipeline/`)

`UV_PROJECT_ENVIRONMENT=<venv> uv sync --project <copy>/pipeline --frozen --no-editable --reinstall-package meeting-pipe --extra mcp` built a fresh venv in about 7 s from uv's cache. Its `bin/mp` execs `<venv>/bin/python`, `site-packages` has no editable `.pth` (only `_virtualenv.pth`), and after `mv` of the source copy both `bin/mp --version` and `python3 -m mp --version` still print `mp 0.1.0`, with `mp.__file__` inside the venv. An incremental re-sync after editing a source file took 0.3 s and carried the edit.

## Scope

1. **Resources.** Put the bundles in `Contents/Resources` and stop calling `Bundle.module` from sources. A Core-side `ResourceBundleLocator` (Foundation only, so the island rules hold) returns `<Bundle.main.resourceURL>/<name>.bundle` when it exists; inside an `.app` that lacks it, `Bundle.main` itself, so lookups miss and each caller's existing not-found path runs (`Coordinator` already catches the MuteLabels throw) instead of a crash loop; outside an `.app` (`swift run`, `swift test`) nil, so the caller falls back to its own `Bundle.module`. Each module gets one accessor (`Bundle.coreResources`, `Bundle.appResources`). One shared shell function places the bundles, used by `install.sh`, `rebuild.sh` and the smoke, and migrates an existing install's stale `Contents/MacOS` copies. `scripts/lib/sign-app.sh` stops two-pass signing them if the outer signature seals them as resources (verify with `codesign --verify --deep --strict`). `MeetingPipe doctor` gains an `app.resources` probe.
2. **Venv.** One shared shell function creates the venv in place at the data dir with the probed command, recreates a venv left in the old `cp -R` layout, and fails loudly unless `mp` imports from inside the venv. No `2>/dev/null ||` fallback. `install.sh` and `rebuild.sh` both call it (owner's decision 2026-10-24: one rebuild makes both trees match the checkout). `findMP`'s venv tier runs `<venv>/bin/python3 -m mp`, the DIST1 tier's shape, gated on that interpreter being executable and `bin/mp` existing.
3. **Fence.** `scripts/test-app-relocation.sh` assembles a staging `.app` from a build dir with the shared functions, moves `daemon/.build` aside, and runs `Contents/MacOS/MeetingPipe doctor`; `--with-pipeline` also syncs a staged venv from a copy of `pipeline/`, moves the copy, and requires the pipeline probes to pass. CI runs the Swift half against the debug build it already makes (owner's decision 2026-10-24: CI never runs a full `uv sync`).

## Explicitly not

- A spawn probe inside `findMP`. It is called from many places, some on main; `pipeline.roundtrip` in doctor is the spawn check.
- Making `install.sh` work from a staging prefix. It loads a LaunchAgent with the live label and kills the live daemon; the smoke reuses its functions instead.
- The embedded relocatable runtime, notarization, or a drag-install. DIST1.
- Adjacencies in the same audit, not filed here: the bundle tool installs dependencies without the lock (QG-3, DI-4), ffmpeg is still a hard runtime dependency (DI-12), uninstall leaves scheduled jobs behind (DI-10).

## Acceptance

- With `daemon/.build` moved aside and the pipeline source moved, a staged app's `MeetingPipe doctor` exits without a crash, `app.resources` is OK and names `Contents/Resources`, and `pipeline.binary` plus `pipeline.roundtrip` are OK against the staged venv: `scripts/test-app-relocation.sh --with-pipeline` green on a release build. CI runs the script without `--with-pipeline` and it is green there.
- Tests pin: `ResourceBundleLocator` finds a bundle in a fake `.app`'s Resources, returns main (never nil) for a fake `.app` without it, returns nil outside an `.app`, and the hardcoded bundle names match SwiftPM's; `findMP`'s venv tier runs `python3 -m mp` and falls through on a dangling interpreter; the `app.resources` probe's ok and fail cases. A test fails without the fix (the venv-tier args).
- `cd daemon && swift build` and `swift test` green, with the new test count in the commit body; ruff, pyright and pytest green; `python3 scripts/truth_fences.py` clean.
- README, `docs/SETUP.md` and `ARCHITECTURE.md` say the app and venv no longer read the clone at runtime and that updating is a pull plus `rebuild.sh` or `install.sh`, in the same commit.
- Owner, after landing (not a precondition): one `./scripts/install.sh` migrates the live install; then `Contents/MacOS` has no `.bundle`, `head -2 ~/.local/share/meeting-pipe/venv/bin/mp` names the venv's own python, and `site-packages` has no `_editable_impl_meeting_pipe.pth`.
