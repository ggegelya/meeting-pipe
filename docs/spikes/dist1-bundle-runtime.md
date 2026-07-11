# DIST1: bundle a runtime for a drag-n-drop installer

Design + runbook, 2026-07-12. Build tool: [`scripts/bundle-runtime.sh`](../../scripts/bundle-runtime.sh) (owner-run on a dev Mac). This is a distribution task, not a yes/no spike: the daemon-side plumbing is shipped and tested, the build tool is written, and the notarized-bundle build + clean-Mac install test are owner-owed (they need Developer ID credentials and a second, clean Mac, neither available in this harness).

## Problem

There is no drag-n-drop installer. `scripts/install.sh` requires Homebrew + `uv` + `ffmpeg` on the machine and builds a Python venv at `~/.local/share/meeting-pipe/venv`. A genuinely clean Mac has none of these, and no usable Python 3.11+ (Apple removed system Python; the Command Line Tools shim is 3.9, below the pipeline's floor). This also blocks locked-down / regulated Macs that often cannot install Homebrew at all, which is the exact environment the zero-egress story is meant for.

The goal: a `.app` a clean Mac installs by dragging, that runs entirely from itself, with the pipeline (`mp`) and `ffmpeg` embedded.

## Approach

Embed a **relocatable Python** ([python-build-standalone](https://github.com/astral-sh/python-build-standalone), the `install_only` variant, which bakes in no absolute rpaths), the **pipeline installed into it** (so `mp` and its deps ride along), and a **static `ffmpeg`**, all under `MeetingPipe.app/Contents/Resources/pipeline-runtime/`. Then notarize the whole bundle.

The daemon already prefers the bundle (shipped in this task, see below), so no runtime code depends on brew/uv/venv once the bundle exists.

## What shipped in this task (tested)

Daemon-side resolution now prefers an embedded runtime, so a bundled app is actually used:

- `PipelineLauncher.findMP` gained a first tier: if `Contents/Resources/pipeline-runtime/bin/python3` exists, run `python3 -m mp`. It wins over the dev-machine venv, the uv-walk, and PATH. Extracted into a pure, injected `resolveDirectMP` and unit-tested (`PipelineLauncherFindMPTests`) so the priority is pinned without a real bundle.
- `MeetingRecorder.findFFmpeg` gained the embedded `pipeline-runtime/bin/ffmpeg` as a fallback (after `MEETINGPIPE_FFMPEG` and PATH, so a machine with its own ffmpeg still uses that; the bundled one is the clean-Mac safety net). This covers both the recorder merge and `MuteRedactor`, which share `findFFmpeg`.
- `scripts/bundle-runtime.sh`: the build tool. Fetches the relocatable Python, `pip install`s the pipeline into it, verifies `python3 -m mp --version`, optionally installs a static ffmpeg, signs every embedded mach-O inside-out, and prints the owner-owed notarize/DMG/verify steps.

## The gotchas (each is handled, or flagged)

1. **Console-script shebang vs relocation (the crux).** `pip install` bakes an absolute path to the build-time interpreter into a console script's shebang (`bin/mp`). The moment the `.app` is relocated to the user's `/Applications`, that path is wrong and `bin/mp` fails. Fix: the daemon invokes the embedded runtime as `python3 -m mp`, resolving the package relative to the (relocated) interpreter. `findMP` and the bundle script both do this deliberately; `bin/mp` is never used from the bundle.
2. **Sign every mach-O, inside-out.** Notarization rejects any unsigned mach-O anywhere in the bundle (the Python dylibs, C-extension `.so` files, the interpreter, ffmpeg). `codesign --deep` is unreliable; the script signs the leaves first, then the app last.
3. **ffmpeg licensing.** A redistributed ffmpeg must be an LGPL- or GPL-compliant static build. The script leaves `FFMPEG_URL` unset by default and refuses to guess; the owner pins a build they can legally ship. (DEP1 offers the alternative, below.)
4. **Bundle size.** With MLX + numpy + soundfile the runtime is large (hundreds of MB). Acceptable for a drag-install; noted so it is not a surprise.

## Reconciliation with DEP1 and I7

- **DEP1 (native AVFoundation vs ffmpeg): GO, but ffmpeg does not vanish.** DEP1 verified that the recorder merge + the STOR1 transcode can be native, which would shrink the bundle. But `MuteRedactor` is a third ffmpeg spawn site outside DEP1's scope, so a merge+transcode port alone does not remove the binary. DIST1 therefore still bundles a static ffmpeg today; if DEP1's port lands AND MuteRedactor is ported too, the ffmpeg embed can be dropped later. The `findFFmpeg` fallback is written so removing the embed is a no-op for machines that have their own ffmpeg.
- **I7 (drop Python entirely): the strategic fork.** DIST2's spike recommended bundle-the-runtime (DIST1) near-term and defer the Swift port until MLX-Swift LM tooling is production-ready. DIST1 is that near-term path. It does not foreclose I7: if the pipeline is later ported to Swift, the embedded Python simply stops being built and `findMP` falls through to nothing (with no pipeline subprocess at all). Bundling now buys a shippable clean-Mac install without betting on the port.

## Owner-owed remainder (needs Developer ID + a clean Mac)

The build tool + daemon plumbing are done; the release build cannot be produced or validated here:

1. Run `scripts/bundle-runtime.sh` on a dev Mac (set `FFMPEG_URL` to a shippable static build; optionally pin a newer `PBS_TAG`/`PYTHON_VERSION`). Confirm it prints a working `mp --version` from the embedded runtime.
2. Re-sign with a real `Developer ID Application` identity (`CODESIGN_IDENTITY`), then notarize (`xcrun notarytool submit ... --wait`) and staple (`xcrun stapler staple`).
3. Package a `.dmg` and **test a drag-install on a genuinely clean Mac** (no Homebrew, no uv, no system ffmpeg): record a meeting and confirm from `events.jsonl` that the pipeline ran entirely from the bundle (no `uv`/venv fallback), and that the merge found the embedded ffmpeg.
4. D8 (Developer ID + notarization in CI) is the durable home for steps 2-3 once a second user exists; until then this is a manual owner build.

This keeps DIST1 honest: the parts that can be built and tested without release credentials are shipped and pinned by tests; the notarized artifact is a documented, scripted, owner-run build.
