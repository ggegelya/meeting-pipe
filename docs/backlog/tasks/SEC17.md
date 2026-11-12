---
id: SEC17
title: The app holds microphone, Screen Recording and Accessibility grants but is signed without hardened runtime, and its signing key is imported for use by any app
category: Security
status: new
priority: P2
comment: Filed 2026-10-24 (audit band, arch M2, go-live DI-6): codesign shows flags=0x0(none) and no entitlements, so same-user DYLD injection inherits the TCC grants, and dev-cert.sh imports the key with -A. Sign with --options runtime plus an audio-input entitlements file in sign_app_with_resources, import new keys with -T /usr/bin/codesign, fix the existing key's ACL without recreating the cert. Amended 2026-11-12 ([security review](../../audits/2026-11-12-security-review.md)): helpers resolved from user-writable PATH, venv and uv inherit TCC attribution; disclaim responsibility on spawn or run only sealed helpers. [Spec](./SEC17.md)
---

# SEC17: the app holds microphone, Screen Recording and Accessibility grants but is signed without hardened runtime, and its signing key is imported for use by any app

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) M2, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) DI-6). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Measured on the owner's install on 2026-10-24:

```
$ codesign -dvv ~/Applications/MeetingPipe.app
Identifier=com.meetingpipe.daemon
CodeDirectory v=20400 size=43567 flags=0x0(none) hashes=1355+3 location=embedded
Authority=MeetingPipe Dev
TeamIdentifier=not set
$ codesign -d -r- ~/Applications/MeetingPipe.app
designated => identifier "com.meetingpipe.daemon" and certificate leaf = H"ba4b7fd9..."
```

`flags=0x0(none)` means no hardened runtime, and `codesign -d --entitlements -` prints none. Without hardened runtime dyld honours `DYLD_INSERT_LIBRARIES` and loads unsigned libraries, so any process running as the same user can start the binary with an injected library, and that code runs under the identity TCC has granted microphone, Screen Recording and Accessibility to. The designated requirement pins the certificate leaf, not the cdhash, so a re-signed binary with the same dev key also passes.

The signing seam is one function: `sign_app_with_resources` in [scripts/lib/sign-app.sh](../../../scripts/lib/sign-app.sh) runs `codesign --force --sign "$sign_id" --identifier com.meetingpipe.daemon "$app"`, and both `install.sh` and `rebuild.sh` call it. `scripts/bundle-runtime.sh` (the DIST1 path) already passes `--options runtime`; the installed path does not.

The key: [scripts/lib/dev-cert.sh](../../../scripts/lib/dev-cert.sh) imports the self-signed identity with `security import "$tmp/id.p12" -P "$p12pass" -A ...`. Its own comment says why ("let any tool use the key without a per-build keychain prompt"). `-A` means any application can use that private key with no prompt, so any same-user process can sign a binary as `MeetingPipe Dev`, and because the designated requirement trusts that leaf, such a binary would satisfy TCC's check for `com.meetingpipe.daemon`.

Premise corrections against the audits, checked 2026-10-24:

- The LaunchAgent plist's `EnvironmentVariables` block (from `scripts/launchd.plist.template`) holds only `PATH`. It is user-writable like every user LaunchAgent, so it is one route to inject `DYLD_*`, but it is not a separate defect: hardened runtime makes dyld ignore those variables whatever sets them. No plist change is needed.
- "Check that the embedded Python and MLX still load": the pipeline runs from its own venv at `$DATA_DIR/venv` (DIST4's `sync_pipeline_venv`), a separate executable outside the bundle, so the app's runtime flags do not apply to it. `otool -L` on the installed binary lists only `/System/` and `/usr/lib/` libraries, so library validation has nothing third-party to reject.

## Scope

1. `sign_app_with_resources` signs with `--options runtime --entitlements <file>`, where a new checked-in entitlements plist (for example `scripts/MeetingPipe.entitlements`) carries `com.apple.security.device.audio-input` and nothing else. Hardened runtime blocks microphone access without that entitlement. Screen Recording (ScreenCaptureKit) and Accessibility need no entitlement. Add `com.apple.security.cs.disable-library-validation` only if a measured launch failure requires it, and record which load failed.
2. The function's post-sign sanity check also asserts the runtime flag (`flags=0x10000(runtime)` in `codesign -dvv`) and prints the same yellow warning style when it is missing.
3. `dev-cert.sh` imports new keys with `-T /usr/bin/codesign` instead of `-A`. For the key already in the owner's login keychain, recreating the certificate is not an option: the designated requirement pins its leaf, so a new cert resets every TCC grant. The pickup session finds an ACL change that keeps the same key (for example `security set-key-partition-list` limited to Apple tools, which asks for the login password once), and documents it in [docs/SETUP.md](../../../docs/SETUP.md) as a one-time step if it cannot be made silent.
4. SETUP.md and README say what changed, and that one re-grant may be needed if macOS asks.

## Explicitly not

- Developer ID, notarization, Gatekeeper acceptance: D8 and DIST1, deferred by the root `CLAUDE.md` selling rule. This task hardens the self-signed path only.
- The Keychain ACL that trusts `/usr/bin/security` for the API tokens (SEC23 names it as a residual).
- Helpers the app runs from user-writable `PATH` directories (`/opt/homebrew/bin/ffmpeg`, `claude`): observed, not filed here; CONC5 owns the spawn sites and DEP2 removes ffmpeg.
- App Intents invocation (AUTO1), which needs a real Team ID, not a runtime flag.

## Acceptance

- After `./scripts/rebuild.sh`, `codesign -dvv` on the installed app shows the runtime flag, and `codesign -d --entitlements -` shows exactly the audio-input entitlement.
- A launch with `DYLD_INSERT_LIBRARIES` pointing at a test dylib that writes a marker file does not load it (marker absent); the same experiment on the pre-change build loads it. Recorded in the commit body.
- Owner walkthrough on the rebuilt app: a recording captures both mic and system audio, the Accessibility-based detection still fires on a Teams call, and no TCC prompt reappears (or exactly one, documented).
- A newly generated dev key's ACL (`security dump-keychain -a` for that item) lists codesign as the trusted application rather than "any".
- `bash scripts/test-app-relocation.sh` green (mandatory after a `sign-app.sh` edit), `bash scripts/ci-local.sh` green.

## Amended 2026-11-12 (security review)

From the [security review](../../audits/2026-11-12-security-review.md) (verified, Low while this task is open, a Medium residual once it ships). This task's "Explicitly not" names user-writable PATH helpers as observed and points at CONC5 and DEP2, but neither closes the class: CONC5 is about draining and timeouts, and DEP2 removes only ffmpeg.

- `ExecutableResolver.resolve` checks the env override, then every `$PATH` entry, then the fallbacks, so `findFFmpeg` resolves `MEETINGPIPE_FFMPEG`, then PATH, then the bundled copy. The installed app has no `Contents/Resources/pipeline-runtime/` and the LaunchAgent puts `/opt/homebrew/bin` first, so `/opt/homebrew/bin/ffmpeg` (user-owned, `drwxrwxr-x`) runs on every recording stop.
- `PipelineLauncher.findMP` resolves the embedded runtime, then `~/.local/share/meeting-pipe/venv/bin/python3`, then `~/.local/bin/uv`, then `mp` on PATH, all user-writable. `summarize_local` finds `mlx_lm.server` via `shutil.which` on the same PATH.
- Foundation `Process` does not disclaim responsibility, so TCC attributes these children to MeetingPipe (the repo already relies on this: DET8 measured from a disclaimed harness shell). None of the legitimate children need a grant, so the attribution is pure attack surface.

Added scope: spawn every helper with responsibility disclaimed (`responsibility_spawnattrs_setdisclaim` through a small spawn wrapper, shared with CONC5's helper if it lands first), and drop `MEETINGPIPE_FFMPEG` and the PATH walk in release builds. Reordering lookups alone does not close it, since the venv is user-writable by design.

Added acceptance: a test with an injected spawner that every helper spawn sets the disclaim attribute; owner check that a recording stop and a summary still work after `./scripts/rebuild.sh`.
