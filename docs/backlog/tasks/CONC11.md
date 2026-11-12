---
id: CONC11
title: MeetingRecorder sends AVAudioFormat across isolation on a Sendable conformance that exists only on macOS 26 and later, while the floor is 14
category: Concurrency
status: new
priority: P2
comment: Filed 2026-11-12 (upgrade review, owner approved): the SDK 27 build warns twice in MeetingRecorder that "conformance of 'AVAudioFormat' to 'Sendable' is only available in macOS 26.0 or newer", where engineCall returns inputNode.outputFormat from the engine queue to the main actor, so on macOS 14 and 15 the capture path relies on a guarantee those OSes do not make. Return the format's plain values instead.
---

# CONC11: MeetingRecorder sends AVAudioFormat across isolation on a Sendable conformance that exists only on macOS 26 and later, while the floor is 14

Band origin: filed 2026-11-12 from the dependency, platform and AI-model upgrade review (owner approved "File all proposed"). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

The project was built on 2026-11-12 with Xcode 27.2 (Swift 6.4.2, SDK 27.2) into a fresh `--scratch-path`. The build reported two warnings, both in `daemon/Sources/MeetingPipe/MeetingRecorder.swift`, each reading: "conformance of 'AVAudioFormat' to 'Sendable' is only available in macOS 26.0 or newer". Both come from the same shape: a bounded `engineCall(site:)` closure returns `engine.inputNode.outputFormat(forBus: 0)` from the engine's queue to a `@MainActor` caller.
- One is in the start path, at site `"start_format_read"` (`guard let micFormat = await engineCall(...)`).
- The other is in `liveInputFormat()`, at site `"input_format_read"`.

The SDK 26 headers declare `AVAudioFormat: Sendable` with macOS 26 availability. On macOS 14 and 15, the floor `Package.swift` declares, the object makes no such promise. Under `-strict-concurrency=targeted` this is a warning, not an error. Neither CI (macos-15, older SDK) nor any build before the 27 SDK showed it.

## Scope

At both `engineCall` sites, return a small `Sendable` value instead of the `AVAudioFormat` object: the sample rate, channel count, common format and interleaving that the main-actor side reads. Rebuild an `AVAudioFormat` on the main-actor side only where one is actually needed. Keep the engine queue as the only place that touches the engine (`daemon/docs/gotchas.md`).

## Explicitly not

- Not raising the floor to 26, which would silence this; that is an owner decision.
- Not the wider `complete`-mode sweep (CONC6).
- Not REC29's API adoption.

## Acceptance

- The fresh `swift build --scratch-path <tmp>` on the 27 SDK prints no `AVAudioFormat` `Sendable` warning.
- `cd daemon && swift test` is green, and the recorder's existing format and tap tests still pass.
- No new `@unchecked Sendable` or `nonisolated(unsafe)` added to silence it.
