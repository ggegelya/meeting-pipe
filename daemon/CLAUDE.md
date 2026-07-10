# daemon/ — Swift menu-bar app

Loaded when you touch files in this subtree. The full subsystem map is in [`../ARCHITECTURE.md`](../ARCHITECTURE.md); patterns in [`../CONVENTIONS.md`](../CONVENTIONS.md); terms in [`../ARCHITECTURE.md#glossary`](../ARCHITECTURE.md#glossary). This file is the short list of things that bite if you forget them.

## Build + test

```bash
swift build               # from daemon/
swift test                # full Xcode required locally (CI on macos-14 has it)
```

`swift test` fails with `import XCTest` if only Command Line Tools are installed. Write tests anyway — CI runs them. To run locally, `sudo xcode-select -s /Applications/Xcode.app` first.

## Patterns to match

- **Pure logic on its own type with explicit inputs.** When a subsystem grows non-trivial branching, lift the decision into a `decide(at: Date, …) → Action` style entry point on its own struct (see `MicGate.decide`, `AudioRetention.decide`, `MeetingSourceScorer.score`, `WorkflowMatcher.match`). The host that owns AVFoundation / NSWorkspace / TCC just forwards inputs in.
- **`MeetingSessionController` talks to `SessionHost`, not `Coordinator`.** Adding a subsystem the session logic needs means adding it to `SessionHost` (and to `FakeSessionHost` in the tests), not reaching for `Coordinator`. Protocol-type it only if a test cannot construct the real thing; a global read (the way `beginRecording` used to call `AVCaptureDevice.authorizationStatus`) has to come through the host or it takes the branch back out of reach.
- **Fully-qualified type name in stored-property initializers.** `Self.foo` errors with "covariant 'Self' type cannot be referenced from a stored property initializer" on Swift 5.9+. Write `StatusBarController.foo` instead. `lazy var` sidesteps this but only use lazy when deferred init is what you want.
- **Combine subscriptions filter to value changes.** `removeDuplicates()` + `dropFirst()` before triggering rebuilds. The permissions poll runs at 2 s; subscribing to `objectWillChange` rebuilt the status-bar menu twice a second until the snapshot dedupe landed (`StatusBarController.PermissionsSnapshot`).
- **`ObservableObject` + `@Published` debounce writes.** `ConfigStore.scheduleSave` is the template: 500 ms `Timer.scheduledTimer`, gated on an `isInitialized` flag so the init's `didSet` storm doesn't trigger a spurious save.
- **TOML round-trip preserves unknown keys.** Read into `TOMLTable`, mutate only what the UI models, write back. New top-level tables need `ensureTable("foo")` to fetch the *live* pointer back after insertion (TOMLKit's `subscript SET` copies the source node — first-assignment-per-fresh-table is silently dropped without this).

## Don't

- Don't call Anthropic / Notion APIs from the daemon. Outbound HTTP belongs in the pipeline.
- Don't add a key to `MeetingMetaSidecar.build` without also updating `mp.workflow.apply_overrides` on the Python side. They're a single contract; the sidecar is the only Swift to Python surface.
- Don't read a per-sink sidecar (`<stem>.notion.json`) to learn whether a run published. A failed publisher never writes one, so an earlier run's file survives. Read `<stem>.publish.json` via `PublishResult.load` (PIPE1).
- Don't log or write files from inside an audio render callback (`MeetingRecorder` taps, `SystemAudioCapture`). Those run on real-time threads; blocking work there glitches the recording.
- Don't `print(...)` for event-stream data. Use `Log.event(category:action:attributes:)` so `mp logs` / `mp analyze-detection` see it.
- Don't pile inline styles into a SwiftUI view. The shared primitives (`SettingsGroup`, `SettingsRow`, `SettingsSegmented`, `SettingsSlider`, `SettingsStatusPill`, `SettingsSecretField`, `SettingsHotkeyField` in `Preferences/PreferencesControls.swift`) are the design system. Add new primitives there rather than parallel one-offs.

## Where things live (quick index)

| Subsystem | Entry file |
|---|---|
| State machine + dispatch | `Coordinator.swift` (+ its `Coordinator+*.swift` extensions), `MeetingSessionController.swift` (one meeting's lifetime), `SessionHost.swift` (the seam it sees instead of Coordinator), `Coordination/` (`DetectionStateMachine`, `SinkDispatcher`, `PipelineJobDispatcher`, `ConfigRefreshCoordinator`) |
| Meeting detection (start + end) | `MeetingPipeCore/Lifecycle/` (`MeetingLifecycleCoordinator` + signals + per-app adapters), `MeetingDiscoveryWatcher.swift`, `MeetingSourceScanner.swift`, `MeetingSourceScorer.swift`, `Resources/meeting_apps.toml` |
| Mute gating | `MeetingPipeCore/MicGate/` (`MicGate` + probes + per-app adapters), `MicGateWriter` |
| Recording | `MeetingRecorder.swift`, `SystemAudioCapture.swift`, `MuteRedactor.swift` (offline redaction), `AudioRetention.swift` |
| Transcription (ASR + diarization) | `Transcription/` (`FluidAudioRunner`, `TranscriptionRunner`, `SegmentBuilder`, `TranscriptionService`) |
| Workflows | `Workflow.swift`, `WorkflowStore.swift`, `WorkflowMatcher.swift`, `WorkflowsView.swift` |
| Library UI | `LibraryWindow.swift`, `LibraryListView.swift`, `MeetingDetailView.swift`, `MeetingStore.swift` |
| Preferences | `PreferencesWindow.swift`, `Preferences/PreferencesView.swift`, `Preferences/PreferencesControls.swift`, `Preferences/UISettings.swift` |
| Permissions | `PermissionsCenter.swift` |
| Pipeline subprocess | `PipelineLauncher.swift`, `LocalServerReaper.swift` (kills an `mlx_lm.server` orphaned by a watchdog SIGKILL) |
| Event log | `Logger.swift` (`Log.event` / `Log.writeLine` / `Log.main`) |
