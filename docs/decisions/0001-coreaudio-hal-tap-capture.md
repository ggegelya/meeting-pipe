# ADR 0001: CoreAudio HAL tap for system-audio capture

| Property            | Value              |
| ------------------- | ------------------ |
| **Status**          | Superseded by ScreenCaptureKit (SCStream) |
| **Date**            | 2026-05-18         |
| **Decision Makers** | Project owner      |
| **Technical Area**  | Capture            |
| **Related Tasks**   | TECH-C1            |

> **Superseding note (TECH-DOC5).** The HAL ProcessTap capture path described here was replaced by ScreenCaptureKit (`SCStream` with `capturesAudio = true`) for system-audio capture: the Apple-recommended path since macOS 13, no aggregate device, and it excludes the daemon's own process audio. This ADR is retained for the rationale trail; the live capture path is ScreenCaptureKit.

## Context

The daemon needs to capture the meeting app's audio output (the other
participants' voices) without piping it through a virtual driver or a
licensed third-party kext. The capture path also has to coexist with the
microphone tap that AVAudioEngine already owns on the user's default
input device, and it has to land on the right channel of a single stereo
WAV so the writer can keep mic and system audio aligned for diarization
and the silent-system-audio backstop.

## Decision Drivers

- **No virtual drivers.** BlackHole / Loopback require a kext install,
  user-visible system prompts, and a separate uninstall story. The
  primary user runs MeetingPipe on their daily-driver Mac; adding a
  system-extension dependency is not an acceptable cost.
- **Per-process scoping.** The capture must isolate the meeting app's
  output from system-wide audio so the recording does not include music
  or browser tabs.
- **Sample-aligned with the mic tap.** The writer expects frame-count
  equality between left (mic) and right (system) channels.
- **API stability on macOS 14 and 15.** ScreenCaptureKit's audio path
  ships with constraints (system permission, frame timing tied to the
  display update cycle) that do not match the recording use case.

## Options Considered

### Option A: ScreenCaptureKit audio (SCStream with `capturesAudio = true`)

Pros: official API, per-app filtering via `SCContentFilter`.

Cons: built for the screen-capture use case; the audio cadence is
coupled to the video frame loop, which adds jitter; requires Screen
Recording TCC even when the user does not want screen capture; the
sample format and channel count are not directly controllable.

### Option B: CoreAudio HAL Process Tap (`AudioHardwareCreateProcessTap`)

Pros: a per-process tap on the audio output; sample-accurate; the daemon
controls the format. Available since macOS 14. Does not require Screen
Recording TCC for audio-only capture (still requires the user to grant
the tap permission).

Cons: a private-looking API surface that is officially documented but
sparsely. The macOS 15 behaviour around tap re-creation across sample
rate changes had to be discovered by testing.

### Option C: Virtual audio driver (BlackHole or similar)

Pros: works on every macOS version; simple from a code perspective.

Cons: kext install + System Settings dance; the user has to route the
meeting app's output to the driver; the routing breaks when the user
changes output devices. Not viable for a daily-use app.

## Decision

**Option B.** CoreAudio HAL process tap. `SystemAudioCapture.swift` owns
the tap lifecycle; the tap output lands as the right channel of the
stereo WAV the recorder produces.

## Consequences

- The daemon requires macOS 14.0 or later (already the floor for
  ScreenCaptureKit primary-display exclusion features used elsewhere).
- The capture path is per-PID, not per-bundle. The recorder resolves the
  PID at meeting-start time via the meeting-app detection layer.
- No system extensions or kexts ship with the app.
- Sample-rate-change handling lives in `SystemAudioCapture.swift`. A
  format mismatch tears the tap down and re-creates it.
- A future macOS that removes or restricts `AudioHardwareCreateProcessTap`
  becomes a porting problem; the fallback would be Option A with the
  jitter cost accepted.
