# CONC4: Strict concurrency on the executable target

Band origin: architecture review 2026-07-10 (engineering-health band). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

**CONC4 (P2, partial): extend compiler-checked concurrency to the executable.** `-strict-concurrency=targeted` covers only MeetingPipeCore ("an island", per Package.swift); the 104-file executable mixes four idioms (47 `Task {`, 15 `Task.detached`, 67 DispatchQueue sites, 36 `@MainActor`, plus Combine) with comments as the only enforcement, and this exact bug class has shipped three incidents (the 2026-05-13 VPIO degradation, the 2026-06-05 stopCapture hang, the 2026-06-12 stacked starts). Scope: flip targeted mode on the MeetingPipe target, triage the warning list, fix file-by-file, tests green after each file. `complete` mode is explicitly out of scope, a separate later decision. Acceptance: the executable builds warning-clean under targeted strict concurrency; no behavior change; the full suite stays green.

**Progress 2026-07-10 (measured, then stopped deliberately).** Flipping the flag produces **20 unique warnings** (the raw build prints ~400; they are the same 20 repeated per compilation unit). By file: `MeetingRecorder` 7, `CorrectionsTab` 5, `MeetingSessionController` 2, `SinkDispatcher` 2, `DoctorRunner` 2, plus 2 surfaced in Core.

The 2 Core ones **are shipped**: `MeetingLifecycleVerdict`, `MeetingLifecycleContext`, its nested `Kind`, and `EndingReason` are now `Sendable`. They are immutable value types crossing an `AsyncStream` boundary, exactly like `MicGateVerdict`, which already declared it; annotating them is correct on its own terms and is a prerequisite for the rest. The flag itself was reverted so `main` stays warning-clean.

The remaining 18 are **not** the "mechanical Sendable annotations, not logic changes" the spec anticipated, which is why this stopped rather than guessing:

- `MeetingSessionController` (2) and `SinkDispatcher` (2) capture `self` into `@Sendable` closures. Both are documented main-queue-only, so the correct fix is `@MainActor` on the type, not `@unchecked Sendable`. That is a real isolation decision: it cascades into `Coordinator` (which calls them from non-isolated context), into `SessionHost`'s protocol requirements, and into ARCH4's new tests.
- `MeetingRecorder` (7) captures `AVAudioEngine`, `SystemAudioCapture?`, and two optional callback closures into `@Sendable` closures, plus wants `@preconcurrency import AVFoundation`. Its cross-thread state is lock-guarded, so `@unchecked Sendable` is arguable, but it is a promise about synchronisation, and the audio-render-thread rules mean a wrong one silences a warning while leaving a real race.
- `CorrectionsTab` (5) sends a `Task<[String: Any]?, Never>` across an actor boundary; `[String: Any]` is not Sendable, so this needs a typed payload, not an annotation.
- `DoctorRunner` (2) captures a `(Data) -> ()` appender; the closure needs to be `@Sendable`-typed at its declaration.

Next session: take `MeetingRecorder` first as the spec says, then decide `@MainActor` for `MeetingSessionController` + `SinkDispatcher` as one change, then `CorrectionsTab`'s payload type. Re-flip the Package.swift line last, once the count is zero.
