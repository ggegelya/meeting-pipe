# daemon/ — Swift menu-bar app

Loaded when you touch files in this subtree. The full subsystem map is in [`../ARCHITECTURE.md`](../ARCHITECTURE.md); patterns in [`../CONVENTIONS.md`](../CONVENTIONS.md); terms in [`../GLOSSARY.md`](../GLOSSARY.md). This file is the short list of things that bite if you forget them.

## Build + test

```bash
swift build               # from daemon/
swift test                # full Xcode required locally (CI on macos-14 has it)
```

`swift test` fails with `import XCTest` if only Command Line Tools are installed. Write tests anyway — CI runs them. To run locally, `sudo xcode-select -s /Applications/Xcode.app` first.

## Patterns to match

- **Pure logic on its own type with explicit inputs.** When a subsystem grows non-trivial branching, lift the decision into a `decide(at: Date, …) → Action` style entry point on its own struct (see `SilenceDetector.SilenceDecision`, `MeetingWindowProbe.ProbeResult`, `WorkflowMatcher.match`). The host that owns AVFoundation / NSWorkspace / TCC just forwards inputs in.
- **Fully-qualified type name in stored-property initializers.** `Self.foo` errors with "covariant 'Self' type cannot be referenced from a stored property initializer" on Swift 5.9+. Write `StatusBarController.foo` instead. `lazy var` sidesteps this but only use lazy when deferred init is what you want.
- **Combine subscriptions filter to value changes.** `removeDuplicates()` + `dropFirst()` before triggering rebuilds. The permissions poll runs at 2 s; subscribing to `objectWillChange` rebuilt the status-bar menu twice a second until the snapshot dedupe landed (`StatusBarController.PermissionsSnapshot`).
- **`ObservableObject` + `@Published` debounce writes.** `ConfigStore.scheduleSave` is the template: 500 ms `Timer.scheduledTimer`, gated on an `isInitialized` flag so the init's `didSet` storm doesn't trigger a spurious save.
- **TOML round-trip preserves unknown keys.** Read into `TOMLTable`, mutate only what the UI models, write back. New top-level tables need `ensureTable("foo")` to fetch the *live* pointer back after insertion (TOMLKit's `subscript SET` copies the source node — first-assignment-per-fresh-table is silently dropped without this).

## Don't

- Don't call Anthropic / Notion APIs from the daemon. Outbound HTTP belongs in the pipeline.
- Don't add a key to `MeetingMetaSidecar.build` without also updating `mp.workflow.apply_overrides` on the Python side. They're a single contract; the sidecar is the only Swift↔Python surface.
- Don't `print(...)` for event-stream data. Use `Log.event(category:action:attributes:)` so `mp logs` / `mp analyze-detection` see it.
- Don't pile inline styles into a SwiftUI view. The shared primitives (`SettingsGroup`, `SettingsRow`, `SettingsSegmented`, `SettingsSlider`, `SettingsStatusPill`, `SettingsSecretField`, `SettingsHotkeyField` in `Preferences/PreferencesControls.swift`) are the design system. Add new primitives there rather than parallel one-offs.

## Where things live (quick index)

| Subsystem | Entry file |
|---|---|
| State machine + dispatch | `Coordinator.swift` |
| Detection | `Detector.swift`, `MeetingWindowProbe.swift`, `Resources/meeting_apps.toml` |
| Recording | `MeetingRecorder.swift`, `SystemAudioCapture.swift`, `SilenceDetector.swift` |
| Workflows | `Workflow.swift`, `WorkflowStore.swift`, `WorkflowMatcher.swift`, `WorkflowsView.swift` |
| Library UI | `LibraryWindow.swift`, `LibraryListView.swift`, `MeetingDetailView.swift`, `MeetingStore.swift` |
| Preferences | `PreferencesWindow.swift`, `Preferences/PreferencesView.swift`, `Preferences/PreferencesControls.swift`, `Preferences/UISettings.swift` |
| Permissions | `PermissionsCenter.swift` |
| Pipeline subprocess | `PipelineLauncher.swift` |
| Event log | `Logger.swift` (`Log.event` / `Log.writeLine` / `Log.main`) |
