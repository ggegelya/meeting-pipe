---
id: REC29
title: macOS 27 deprecates the AVAudio tap, connect and play calls the capture and playback paths use, and its throwing tap API could replace the Objective-C barrier on 27 and later
category: Recording
status: partial
priority: P2
comment: Shipped 2026-11-18: SDK 27 error variants for the mic tap (inside the barrier still), connect and play behind compiler(>=6.4) + #available(macOS 27), Outcome.failed takes the raise's fresh-engine path, 27-floor scratch build has 0 deprecations, ci-local green. Owed: the owner's live check, one recording with level metering and one Library playback on an installed build.
---

# REC29: macOS 27 deprecates the AVAudio tap, connect and play calls the capture and playback paths use, and its throwing tap API could replace the Objective-C barrier on 27 and later

Band origin: filed 2026-11-12 from the dependency, platform and AI-model upgrade review (owner approved "File all proposed"). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

The owner builds with Xcode 27.2 (Swift 6.4.2, SDK 27.2) on macOS 27.2. Because the deployment floor is macOS 14, the compiler stays silent about anything deprecated after 14.

On 2026-11-12 a scratch copy of `daemon/` was built with `platforms: [.macOS("27.0")]`. It emitted exactly five deprecations:
- `installTap(onBus:bufferSize:format:block:)` "was deprecated in macOS 27.0", in `MicLevelMonitor` (`Design/MicLevelMonitor.swift`) and in `MeetingRecorder`'s mic tap install;
- `AVAudioEngine.connect(_:to:format:)`, twice in `PlaybackEngine`;
- `AVAudioPlayerNode.play()`, in `PlaybackEngine`.

At a macOS 26 floor the same build showed none of these.

The SDK 27 header `AVFAudio.framework/Headers/AVAudioNode.h` marks the old call `API_DEPRECATED_WITH_REPLACEMENT("installTapOnBus:bufferSize:format:error:block", ..., macos(10.10, 27.0))`. The replacement is declared `- (BOOL)installTapOnBus:... error:(NSError **)outError block:... NS_REFINED_FOR_SWIFT API_AVAILABLE(macos(27.0))`. `AVAudioEngine.h` and `AVAudioPlayerNode.h` carry `...error:` replacements for connect and play in the same way.

That matters here because REC12 added the `MeetingPipeObjC` target only because `installTap` reports failure by raising an NSException. Swift cannot catch it, so the process aborted. On macOS 27 and later the new call reports the same failure as an error.

## Scope

- In `MeetingRecorder`'s tap install (the `GuardedTapInstall` path) and in `MicLevelMonitor`, use the throwing tap install inside `if #available(macOS 27, *)`. Map its error onto the same failure handling the barrier's caught exception feeds today (REC15's mic-loss path).
- Keep the `MeetingPipeObjC` barrier for macOS 14 to 26.
- In `PlaybackEngine`, use the `connect(...error:)` and `play(...error:)` forms on 27+, feeding the existing playback-failure handling.
- No floor change.

## Explicitly not

- Not raising the deployment floor (an owner decision; DOC16's parity fence and CI9's runner choice move with it).
- Not deleting the Objective-C barrier.
- Not the `AVAudioFormat` `Sendable` warnings (CONC11).

## Acceptance

- `swift build` against a scratch copy with `platforms: [.macOS("27.0")]` emits no `deprecated in macOS 27.0` warning.
- The normal floor-14 build stays free of new warnings.
- New tests use an injected tap installer that throws: the error path reaches the same mic-loss handling the barrier path reaches, and the barrier path is still taken when the availability branch is forced off.
- `cd daemon && swift test` is green; `bash scripts/ci-local.sh daemon` is green.
- A live check on the owner's Mac: one recording with mic level metering and one Library playback, logged in this file's progress line.

**Progress (2026-11-18):** Measured on macOS 27.2 before building: `__installTap` returned -10863 for a second tap on a bus and `connectNode` -10868 for a 0 Hz format (the cases that used to raise), but `playAudio()` on a node with no engine still raised, so the 27 tap call runs inside the `@try` barrier too rather than replacing it; the spec's "could replace the barrier" did not survive the measurement. `GuardedTapInstall.Installer` (`.throwing` / `.raising`) is chosen by `inputTapInstaller` under a pure `#available`; a thrown error is the new `Outcome.failed` (condemns, `requiresFreshEngine`, `mic_tap_install_failed`, recovery reason `tap_install_failed`). The SDK gate is `#if compiler(>=6.4)` because CI's macos-15 runner lacks the SDK 27 symbols; the 27 branch is therefore compiled and tested only locally until CI moves (CI9). `PlaybackEngine.connect`/`play` now throw and fail the play; a refused play arms the idle stop. MicLevelMonitor was deleted by REC18 and is not touched. Tests: 5 new in `GuardedTapInstallTests` plus one real-node macOS 27 check, 2 in `InputDeviceRecoveryTests`, 2 in `AudioPlaybackControllerTests`. A scratch copy at `platforms: [.macOS("27.0")]` built with no `deprecated in macOS 27.0` warning; the floor-14 build shows no new warning in the touched files. Owner live check (one recording with metering, one Library playback) is not yet logged here.
