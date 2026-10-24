# CI9: CI builds only the debug configuration on macOS 15, so the release build that ships, the declared macOS 14 floor, and new compiler warnings are never checked

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) QG-6, QG-7 remainder, QG-10). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

After CI8 (2026-10-24) every `ci.yml` job calls `scripts/ci-local.sh <job>`. The `daemon` job runs on `macos-15` and its step list is `swift build` (debug), `swift test`, the engine suites under `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, and DIST4's `test-app-relocation.sh .build/debug`. Three gaps remain:

1. **The shipped configuration is never built in CI.** `install.sh` and `rebuild.sh` both run `swift build -c release`, and `test-app-relocation.sh` defaults to `daemon/.build/release`, but CI passes it `.build/debug`. No CI step uses `-c release`, so an optimizer-only failure, or a divergence behind the two `#if DEBUG` blocks in `MeetingPipeCore/MicGate/MicGate.swift`, reaches the installed app first.
2. **The declared floor is never exercised.** `daemon/Package.swift` declares `platforms: [.macOS(.v14)]`, and README, SETUP and CONTRIBUTING promise macOS 14. No job runs on macOS 14. The code does guard its newest API (`AppleIntelligenceSummarizer` wraps Foundation Models in `#if canImport(FoundationModels)` plus `@available(macOS 26.0, *)`), so the claim is plausible, but nothing has ever built or run it there. Two docs also name the wrong runner: `CONVENTIONS.md` ("CI runs on `macos-14` with full Xcode") and `CONTRIBUTING.md` ("CI runs on `macos-14`"); the root `CLAUDE.md` already says `macos-15`.
3. **Warnings regress silently.** A clean debug build on 2026-10-24 (fresh `--scratch-path`, Swift 6.3.3) emits two Swift-6-mode diagnostics in production code, both phrased "this is an error in the Swift 6 language mode": `Preferences/MCPStatusStore.swift` ("main actor-isolated static property 'ceilingSeconds' cannot be accessed from outside of the actor") and `RecordingPostProcessor.swift` ("reference to captured var 'lengths' in concurrently-executing code"). CONC4 shipped warning-clean under `-strict-concurrency=targeted`. Nothing fails on a new warning, and an incremental local build does not reprint old ones, so they are invisible on the owner's Mac as well.

## Scope

1. **Release build.** `ci-local.sh daemon` adds `swift build -c release` and runs `test-app-relocation.sh` against `.build/release`. Keep or drop the debug relocation run, and state the job's added wall time in the commit (the go-live run measured 88 s for a local release build).
2. **Warning gate.** The step parses the build output and fails on any `warning:` whose path is under `daemon/Sources` (dependencies under `.build/checkouts` excluded) and is not on an allowlist in the script, one entry per line with a reason. Fix the two diagnostics above in the same task so the allowlist starts empty. CI always builds clean, so the gate bites there; say in the script that a local incremental run only checks what it recompiled.
3. **Floor job.** A `daemon-floor` job on `macos-14` that runs `swift build` and `swift test --filter MeetingPipeCoreTests`, through a new `ci-local.sh` job name so the step list stays in the script. If that image cannot build the package (FluidAudio declares swift-tools-version 6.0, and the code is developed on Swift 6.3), quote the failure in the spec's progress note and stop: whether to raise the declared floor to what CI can test, or keep macOS 14 as a stated-untested claim in README, is the owner's call.
4. **Runner names.** Correct `CONVENTIONS.md` and `CONTRIBUTING.md` to `macos-15` in the same commit.

## Explicitly not / out of scope

- Automated coverage for `uninstall.sh` and `bundle-runtime.sh` (go-live QG-7). DIST5 fixes what the uninstaller leaves behind and the DIST1 amendment fixes the bundler's defects; a test written against either script today would pin the defects those tasks remove, so each lands with its fix. This narrows the band map's description of CI9.
- Running `test-prune-worktrees.sh` and `test-login-agent-guard.sh` from `ci-local.sh`: HYG11.
- `-warnings-as-errors` in `Package.swift`'s `swiftSettings`. It would also break the owner's local build the day an Xcode update adds a deprecation warning; the CI-side gate catches the same regression without that cost.
- Complete concurrency checking on Core: CONC6. An Xcode version matrix beyond the floor job. Signing and notarization, deferred by the root `CLAUDE.md`.

## Acceptance

- `bash scripts/ci-local.sh daemon` builds release and runs the relocation smoke on it, green.
- A scratch unused variable in `daemon/Sources` fails the warning gate on a clean build (tried and reverted, said in the commit body); the two current diagnostics are gone; every allowlist entry has a reason.
- The floor job is green on `macos-14`, or its failure is quoted and the owner's decision recorded beside it.
- `bash scripts/ci-local.sh all` and `python3 scripts/truth_fences.py` green after the doc edits. The first CI run with these jobs needs the owner's push (the CI8 precedent); report its result when it happens.
