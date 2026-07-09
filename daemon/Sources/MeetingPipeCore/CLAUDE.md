# MeetingPipeCore — the island

Loaded when you touch files in this subtree. This is a separate SPM target from the `MeetingPipe` executable, deliberately: it holds the verdict-fusion logic (meeting lifecycle, mute gating) where the cross-thread risk actually lives, so it can be unit-tested without dragging in the app.

Full subsystem map in [`../../../ARCHITECTURE.md`](../../../ARCHITECTURE.md); patterns in [`../../../CONVENTIONS.md`](../../../CONVENTIONS.md). The `daemon/CLAUDE.md` rules apply here too. These are the extra ones that make this target an island rather than a folder.

## The island rules

- **Strict concurrency stays on.** `Package.swift` compiles this target with `-strict-concurrency=targeted` (TECH-CONC2) and the executable without it. A new `Sendable` warning here is a real cross-thread finding, not noise: fix it, don't silence it, and don't take the flag off. (CONC4 is the task that extends the same checking to the executable.)
- **TOMLKit is the only third-party dependency.** It parses `MicGate/Resources/MuteLabels.toml` and nothing else. Adding a dependency here means adding it to every test that links this target; ask first.
- **No UI, and AppKit only where Foundation cannot reach.** There is no SwiftUI, no `NSView`, no window code. There is exactly one `import AppKit`, in `Lifecycle/Signals/WorkspaceSignal.swift`, because `NSWorkspace`'s app-termination notification and `NSRunningApplication` KVO have no Foundation equivalent. Don't add a second one without a reason of that shape. `ApplicationServices` (AX), `CoreAudio` (HAL), and `ScreenCaptureKit` are expected; they are the probes' subject matter.
- **Decisions are pure, hosts are not.** The pattern is a `decide(...) -> Verdict` static or method on its own type, taking every input explicitly (see `MicGate.decide(state:)`, `PromotionEngine`). The host that owns the AVFoundation / AX / CoreAudio handle collects the inputs and forwards them in. That is what lets `MeetingPipeCoreTests` drive the whole fusion stack off synthetic inputs with no hardware and no meeting app.
- **Probes and signals are protocol-backed.** `Infra/` holds the real backends (`RealAXBackend`, `RealCoreAudioBackend`, the AX and HAL buses); tests inject fakes. A probe that reaches a system API directly rather than through its backend cannot be tested.

## Layout

| Directory | What lives there |
|---|---|
| `Lifecycle/` | "Am I in a meeting?" `MeetingLifecycleCoordinator` fuses the `Signals/` into a verdict via `PromotionEngine`; `Adapters/` specialize per meeting client. |
| `MicGate/` | "Should my mic be audible?" `MicGate.decide` fuses the `Probes/`; `MicGateWriter` applies the verdict per buffer; `IdleStopBackstop` auto-stops a dead meeting. |
| `Infra/` | The real system-API backends behind the probes, plus `EventLog`. |

Tests live in `daemon/Tests/MeetingPipeCoreTests/`, mirroring this layout.
