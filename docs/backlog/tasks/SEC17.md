---
id: SEC17
title: The app holds microphone, Screen Recording and Accessibility grants but is signed without hardened runtime, and its signing key is imported for use by any app
category: Security
status: new
priority: P2
comment: Filed 2026-10-24 (audit band, arch M2, go-live DI-6): codesign shows flags=0x0(none) and no entitlements, so same-user DYLD injection inherits the TCC grants, and dev-cert.sh imports the key with -A. Sign with --options runtime plus an audio-input entitlements file in sign_app_with_resources, import new keys with -T /usr/bin/codesign, fix the existing key's ACL without recreating the cert. Amended 2026-11-12 ([security review](../../audits/2026-11-12-security-review.md)): helpers resolved from user-writable PATH, venv and uv inherit TCC attribution; disclaim responsibility on spawn or run only sealed helpers. [Spec](./SEC17.md) Amended 2026-11-12 (SAST pass): the pipeline also resolves lsof (feeds SEC27's reuse identity), mdfind and claude from PATH; call /usr/sbin/lsof and /usr/bin/mdfind absolutely and prefer claude's fixed install dirs over PATH. Amended 2026-11-13 by the audit band: a codesign-only ACL is still prompt-free, so state that residual in dev-cert.sh, and remove the identity under uninstall --reset-tcc (F130, F101).
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

## Amended 2026-11-12 (SAST pass)

From the static-analysis pass after the [security review](../../audits/2026-11-12-security-review.md) (bandit B607 and ruff S607). The owner approved it with "File all proposed". The helper inventory above is daemon-side; three more resolve from `PATH`, all in the pipeline:

- `local_server.listening_pid` runs `["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"]`. Its answer feeds `served_identity`, the reuse check [SEC27](./SEC27.md) item 7 hardens. A planted `lsof` that prints nothing makes identity "unknown", and reuse proceeds today. SEC27's token check is the real fix; this closes the cheap path to it.
- `doctor._mdfind_app_bundles` runs `["mdfind", "-name", "MeetingPipe.app"]`.
- `provider_claude_cli.find_claude` tries `shutil.which("claude")` before its `_FALLBACK_DIRS` (`~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin`, `/usr/local/bin`). [SEC20](./SEC20.md) defers PATH resolution here.

`/usr/sbin/lsof` and `/usr/bin/mdfind` are root-owned system binaries on macOS (checked 2026-11-12).

Added scope:
- Call `lsof` and `mdfind` by those absolute paths. Keep each call site's existing degrade-on-`OSError` behaviour.
- `claude` has no system path, so an absolute path is not available. Resolve it from the fixed install directories before `PATH`, and log the resolved path once per run, so a PATH-planted binary is at least visible. Whether to drop the `PATH` step entirely is the pickup session's call against how the owner installed Claude Code.
- Once this ships, ruff's S607 has nothing left to flag, and [CI12](./CI12.md) can drop S607 from its ignore list.

Added acceptance:
- Tests pin the argv of `listening_pid` and `_mdfind_app_bundles` to the absolute paths.
- A `find_claude` test shows that a `claude` on a temp `PATH` loses to one in a fallback directory.

## Amendment 2026-11-13 (audit band)

From the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md): F130 and F101, both "partially confirmed" and, by the audit's own note, one root cause to count once. Re-read in code at HEAD on 2026-11-14. The [field evidence](../../audits/2026-11-13-field-evidence.md) shows the permission grants surviving both rebuilds (2026-10-12 and 2026-11-12) and no evidence of misuse; everything below about TCC treating foreign code as the app is inferred from documented macOS behaviour, not executed.

**Item 3 narrows the exposure; it does not close it (F130).** `dev-cert.sh` still imports with `security import "$tmp/id.p12" -P "$p12pass" -A ...`, under the comment "This is a local, untrusted, dev-only signing key (no value off this machine), so the broad ACL is an acceptable trade for a prompt-free rebuild loop." The value is on this machine: the designated requirement is `identifier "com.meetingpipe.daemon" and certificate leaf = H"..."`, so anything that can sign with this key produces code that satisfies the requirement the Microphone, Screen Recording and Accessibility grants are bound to. Item 3's `-T /usr/bin/codesign` replaces "any app" with "codesign, prompt-free", and any same-user process can run `/usr/bin/codesign`, so the same signature is still one command away. The rebuild loop depends on that prompt-free signing, which is why the trade exists. So item 3's acceptance bullet (the ACL lists codesign rather than "any") proves the ACL's shape, not that the exposure is closed. Hardened runtime (item 1) closes the `DYLD_INSERT_LIBRARIES` route; it does nothing about a binary signed with the key.

**Uninstall leaves the key and the grants behind (F101).** `uninstall.sh` never removes the signing identity, and resets TCC (`tccutil reset <service> com.meetingpipe.daemon` per service, then `tccutil reset All`) only under `--reset-tcc` (or `--all`). [DIST5](./DIST5.md)'s 2026-11-13 amendment already owns the default uninstall's half: it prints that the "MeetingPipe Dev" identity stays and the `security delete-identity -c "MeetingPipe Dev"` command, and deliberately does not delete it, because the next install would mint a new leaf and every grant would prompt again. That reason does not apply under `--reset-tcc`, where the grants are being reset anyway.

### Added scope

5. **State the residual where the key is made (F130).** Rewrite the `-A` comment in `dev-cert.sh` (and the header) to say what the key is worth on this Mac: any process that can sign with it can produce code the app's TCC grants accept, that `-T /usr/bin/codesign` narrows this but leaves it prompt-free, and that only an ACL that prompts before codesign can use the key would close it (inferred, not tested), at the cost of the prompt-free rebuild loop. Which ACL form, and whether to take that cost at all, is the pickup session's to measure and the owner's to decide; the default this task ships is item 3 plus the honest comment.
6. **Under `--reset-tcc`, also remove the identity (F101).** In `uninstall.sh`, the `--reset-tcc` branch also runs `security delete-identity -c "MeetingPipe Dev"` (ignoring "not found") and says so, since nothing is left for the identity to preserve. The default uninstall keeps DIST5's print-and-keep behaviour unchanged. If the owner prefers the identity to survive even `--reset-tcc`, the script prints why instead.

### Added acceptance

- `dev-cert.sh`'s comment no longer says the key has "no value off this machine" without the on-machine half, and names the prompt-free residual (a grep in the commit body is enough).
- A dry-run harness or shellcheck-clean test of `uninstall.sh` (the shape `scripts/test-login-agent-guard.sh` uses: canned command output, nothing real mutated) shows `--reset-tcc` invoking `security delete-identity -c "MeetingPipe Dev"` and the default path not invoking it.
- [docs/SETUP.md](../../../docs/SETUP.md)'s uninstall paragraph says what `--reset-tcc` now removes, in the same commit.
