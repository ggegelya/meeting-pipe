# ADR 0010: InputDeviceSignal disposition (delete)

| Property            | Value                  |
| ------------------- | ---------------------- |
| **Status**          | Accepted               |
| **Date**            | 2026-05-28             |
| **Decision Makers** | Project owner          |
| **Technical Area**  | Detection / lifecycle  |
| **Related Tasks**   | TECH-C16, TECH-C13     |

## Context

`InputDeviceSignal` was built in the TECH-C13 step-3 signal set as a corroborating lifecycle signal. It subscribes to `kAudioHardwarePropertyDefaultInputDevice` through `CoreAudioHALBus` and emits the new `AudioDeviceID` whenever the system default input device changes, on the theory that a device switch mid-meeting (a Bluetooth headset disconnect, a USB mic unplug) is weak evidence the meeting may be ending and is a useful correlation event for dogfood analysis.

It was never wired. Since step 4, `MeetingLifecycleCoordinator` fuses signals exclusively through the per-app `LifecycleAdapter` plus `PromotionEngine` path; standalone signal types are not part of that contract. A repo-wide search finds no reference to `InputDeviceSignal` outside its own source file and its unit test. It ships in the binary and consumes zero state-machine paths in production. Per the TECH-C16 framing, a built-but-unwired signal is itself the failure mode: it must be wired or deleted, with no middle state.

## Decision Drivers

- **The single responsibility it would serve is already covered elsewhere.** Mid-recording input-device changes are handled where they actually matter: the recorder's device-change auto-resume (Step 3, commit `fe3bf0e`) re-arms capture on a device swap and surfaces `recorder.onConfigurationChange` to the user. That path keeps one continuous WAV across the swap. A lifecycle-side corroborator adds nothing the recorder does not already own.
- **By its own design it never promotes a verdict.** The signal's documented contract is telemetry only ("the coordinator does not promote to `.ended` on this signal alone"). Wiring it would add `signal.default_input_device_changed` rows to `events.jsonl` and per-change work to the HAL bus for a correlation that has had no consumer and no analysis demand.
- **Simplicity over speculative observability.** This is a single-user personal tool. Carrying a dead corroborating signal against a hypothetical future dogfood-correlation use is the kind of speculative flexibility the project's principles say to drop.

## Options Considered

### Option A: Wire it into MeetingLifecycleCoordinator as a corroborating signal

Subscribe the coordinator to the signal and emit its events during meetings. Pros: closes the unwired state by wiring. Cons: it cannot influence verdicts (telemetry only by design), so it adds HAL-bus work and event volume to every native meeting for no verdict value; it duplicates the recorder's already-shipped device-change handling; it perpetuates a corroborating-signal layer that has no consumer.

### Option B: Delete the signal and its test

Remove `InputDeviceSignal.swift` and `InputDeviceSignalTests.swift`. Pros: removes dead code and its maintenance surface; the only behaviour anyone relied on (continuous capture across a device swap) already lives in the recorder. Cons: if a future task genuinely needs default-input-device telemetry in the lifecycle stream, the signal has to be rebuilt; the implementation is recoverable from git history and is roughly forty lines, so the cost is negligible.

## Decision

**Option B.** Delete `InputDeviceSignal` and its test. The mid-recording device-change need it nominally served is fully covered by the recorder's device-change auto-resume; as a lifecycle corroborator it was telemetry-only with zero consumers since step 4.

## Consequences

- `daemon/Sources/MeetingPipeCore/Lifecycle/Signals/InputDeviceSignal.swift` and `daemon/Tests/MeetingPipeCoreTests/InputDeviceSignalTests.swift` are removed. `swift build` and `swift test` stay green; no production path referenced the type.
- `CoreAudioHALBus` keeps its subscribe/unsubscribe API unchanged; it is still used by `MicGate` and the wired lifecycle signals, so deleting this consumer orphans nothing.
- No `signal.default_input_device_changed` events will appear in `events.jsonl`. Nothing read them.
- If default-input-device correlation is wanted later, rebuild from git history (`docs/decisions/0010` and the deleted file) and wire it through whatever fusion contract exists at that time, rather than re-introducing a standalone unwired signal.
