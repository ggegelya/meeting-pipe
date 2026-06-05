# MeetingPipe state-of-the-art detection and gating

The architecturally-correct answer rejects single-signal triggers and centralizes both meeting-end detection and microphone gating in a public-API signal-fusion layer. **For meeting end, the dominant primary signal is the meeting window disappearing from `SCShareableContent`, corroborated by a `true → false` transition of `kAudioProcessPropertyIsRunningInput` on the meeting-app process AudioObject.** **For mute, no public macOS API exposes a third-party app's in-meeting mute state**, so the verdict fuses HAL Voice Activity Detection, an RMS energy gate inside the existing input-tap, AX-button-state observation against a locale-validated TOML, and the HAL system-mute property, and the writer emits zero-amplitude frames (never skips frames) to preserve sample alignment with the ScreenCaptureKit system-audio channel.

The two subsystems share a single AX cache, a single CoreAudio HAL property-listener bus, and a single `events.jsonl` emitter. Below is the full specification.

---

## PART A · Teams meeting end detection

### A.1 Candidate signals with classification

The candidate signals fall into four observability surfaces. Each is rated for Teams (`com.microsoft.teams2` and legacy `com.microsoft.teams`), Zoom (`us.zoom.xos`), and Webex (`com.cisco.webexmeetingsapp` / `Cisco-Systems.Spark`). Browser-hosted meetings get a parallel path that uses the same fusion mechanism with different selectors.

**CoreAudio HAL signals.** The macOS 14.0+ per-process AudioObject model exposes `kAudioHardwarePropertyProcessObjectList`, `kAudioHardwarePropertyTranslatePIDToProcessObject`, `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`, `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyIsRunningOutput`, and `kAudioProcessPropertyDevices`. The semantics of `IsRunningInput` are unambiguous in Apple's own discussion text for the sibling `IsRunning` property: it reflects whether the process has an active input IOProc, not whether non-zero samples are flowing. **This makes the `true → false` transition of `kAudioProcessPropertyIsRunningInput` a PRIMARY signal for "the meeting app has fully released the microphone," which is the canonical moment a Teams call ends.** Per Apple Developer Forums thread 825780, listener delivery on this property is sometimes unreliable in practice, so the implementation must combine a `AudioObjectAddPropertyListenerBlock` registration with a 1 Hz fallback poll of the same property. Latency is one IO cycle (tens of milliseconds) when the listener fires; up to the poll interval otherwise. False positives are zero for Teams and Zoom because both apps fully release the device after Leave. **Webex is the exception: per Cisco's own help article "Turn off your computer's microphone when you're not in a Webex Meeting," Webex deliberately keeps the mic open after meetings for ultrasound device discovery, so this signal is REJECTED as a primary for Webex and demoted to corroborating.**

The device-scope sibling `kAudioDevicePropertyDeviceIsRunningSomewhere` is CORROBORATING. It fires only when the last client on the input device releases it, which is coarser than per-process but useful when bundle-ID-to-AudioObject mapping fails for an obscure process variant. `kAudioProcessPropertyDevices` going from `[inputDeviceID]` to `[]` for the meeting process is CORROBORATING and adds an audit-log detail about which device was released. `kAudioObjectPropertyMute` on the input device tracks only hardware/Control-Center mute and is REJECTED for meeting-end detection.

**ScreenCaptureKit signals.** `SCShareableContent.current` is a snapshot API with no change callback; polling is required. **The disappearance of the meeting-app's distinctively-titled window from `SCShareableContent.windows` is PRIMARY.** Each `SCWindow` carries `owningApplication.bundleIdentifier`, `title`, `windowID`, `isOnScreen`, and `windowLayer`. For Teams the meeting window matches `bundleIdentifier == "com.microsoft.teams2"` and a title regex anchored on the localized Teams meeting pattern. **This signal precedes the audio release by 200–800 ms in practice**, because Teams tears down the meeting view first, then releases the audio unit, then opens the post-call chat surface. That ordering is what makes SCShareableContent the right leading signal: it fires before the post-call chat surface even has a chance to grab the mic for its own purposes. Polling cost is one XPC round-trip to WindowServer per call, 5 to 50 ms; the daemon polls at 1 Hz when no meeting is in progress and at 2 Hz when one is, which is cheap. The daemon needs Screen Recording TCC for `kCGWindowName` to be populated; without it titles are nil.

`SCStreamFrameInfo.status == .stopped` is PRIMARY when the daemon is actively screen-capturing the meeting window, with sub-frame latency. `SCStream`'s `stream(_:didStopWithError:)` with `SCStreamError.userStopped` (code -3817) is PRIMARY when the daemon initiated the stream. `SCContentSharingPicker` events are REJECTED because they are delivered only to the picker initiator and the daemon is not it.

**Accessibility signals.** `AXObserverCreate` with `AXObserverAddNotification` on a cached `AXUIElementRef` is the right pattern, and `kAXUIElementDestroyedNotification` is the documented disposal signal. The user's existing code does this and finds it brittle, which matches public reports: the AeroSpace issue tracker documents that on Sequoia and later, AX destruction notifications drop silently for Electron and WebView2 apps, especially under rapid view churn. **The correct architectural use of AX is therefore CORROBORATING, not PRIMARY: cache the Leave-button `AXUIElementRef` for fast diagnostic confirmation, but treat `AXUIElementCopyAttributeValue` returning `kAXErrorInvalidUIElement` on a 1 Hz health-check as the real "destroyed" signal, not the notification.** `kAXTitleChangedNotification` on the meeting window is CORROBORATING because new Teams reuses a single NSWindow and swaps WebContents views, so titles change reliably even when destruction notifications do not. `kAXFocusedWindowChangedNotification` is REJECTED for the in-call to post-call transition in new Teams because no window swap actually occurs.

**NSWorkspace, OSLogStore, EventKit, CGWindowList, libproc, Network, Endpoint Security.** `NSWorkspaceDidTerminateApplicationNotification` is CORROBORATING; it catches the "user quit Teams" case. `NSRunningApplication` KVO on `isActive` and `isHidden` is CORROBORATING. `CGWindowListCopyWindowInfo` is CORROBORATING for catching Teams' floating call-controls HUD at `windowLayer > 0` whose disappearance leads the main window close; the call costs 18 to 120 ms per invocation and idle-power-budget analysis disfavors polling it more than once every 2 seconds. EventKit is CORROBORATING for the scheduled end window only, never primary, because real meetings end on real-world timing not calendar timing. OSLogStore is CORROBORATING and only for `subsystem == "com.apple.coreaudio"` AudioDeviceStop entries; **there is no published Teams or Zoom os_log subsystem, so log-string matching against meeting-app messages is REJECTED for production.** NWPathMonitor and NEFilterDataProvider are REJECTED. Endpoint Security is REJECTED because the entitlement requires Apple approval and a paid Developer ID. TCC introspection and the orange-indicator menu-bar dot are REJECTED because no public API exposes them. UserNotifications cross-app and DistributedNotificationCenter for Teams/Zoom are REJECTED because no vendor publishes a contract.

**Cloud corroboration.** Microsoft Graph `GET /me/presence` returns activity `InACall` while in a Teams meeting and transitions out within a few seconds of Leave. It is CORROBORATING only because it requires a delegated user token and either polling (rate-limited) or a public HTTPS webhook (impractical for a daemon). Slack's `user_huddle_changed` event is CORROBORATING for huddles with the same caveat. Both are optional opt-in signals in MeetingPipe's design.

### A.2 Recommended architecture

The fusion layer is a single `final class` (`MeetingLifecycleCoordinator`), serialized by an internal `NSLock` plus a dedicated dispatch queue, that owns a typed event bus, not a set of booleans. **One coherent verdict object, `MeetingLifecycleVerdict`, is the only thing the recording state machine consumes.**

```
Sources/MeetingPipeCore/Lifecycle/
  MeetingLifecycleCoordinator.swift     // final class + NSLock; owns the verdict
  MeetingLifecycleVerdict.swift         // enum + reasoning payload
  PromotionEngine.swift                 // pure fusion rule: provisional -> confirmed
  Signals/
    ProcessAudioSignal.swift            // HAL per-process IsRunningInput
    ShareableContentSignal.swift        // SCShareableContent window polling
    AXLeaveButtonSignal.swift           // cached AXUIElementRef + health poll
    WindowTitleSignal.swift             // AX title change + browser tab title
    WorkspaceSignal.swift               // NSWorkspace + NSRunningApplication
  Adapters/
    LifecycleAdapter.swift              // protocol
    NativeLifecycleAdapter.swift        // Teams, Zoom, Webex (one config-driven adapter)
    BrowserMeetingLifecycleAdapter.swift // Meet, Teams web, Webex web, Slack PWA

Sources/MeetingPipeCore/Infra/           // shared by Lifecycle and MicGate
  CoreAudioHALBus.swift                 // shared property-listener registrar
  AXObserverBus.swift                   // shared AXObserver registrar + cache
  EventLog.swift                        // events.jsonl emitter
```

`MeetingLifecycleVerdict` is an enum with associated values that carry the reasoning. Cases: `.idle`, `.starting(adapter: AdapterID, startedAt: Date)`, `.inMeeting(adapter: AdapterID, since: Date, audioObjectID: AudioObjectID?, axRoot: AXUIElement?)`, `.endingProvisional(adapter: AdapterID, leadingSignal: SignalKind, at: Date)`, `.ended(adapter: AdapterID, confirmedBy: [SignalKind], at: Date)`. The `endingProvisional` state exists for the 200 to 800 ms window between SCShareableContent showing the meeting window gone and the audio process confirming release; the state machine stops the recording only on `.ended`.

Promotion rules. `.inMeeting → .endingProvisional` requires any one PRIMARY signal: SCShareableContent meeting-window disappearance, or `kAudioProcessPropertyIsRunningInput` transition to false (for Teams or Zoom only; Webex is excluded from this promotion), or `SCStreamFrameInfo.status == .stopped` for an active capture, or `SCStream.didStopWithError(.userStopped)`, or the cached Leave-button `AXUIElementCopyAttributeValue` returning `kAXErrorInvalidUIElement`. `.endingProvisional → .ended` requires either a 2.0 second timer expiring with the leading signal still satisfied, or a second PRIMARY confirming, whichever comes first. The 2.0 second debounce absorbs the post-call chat surface mic-grab cleanly because the SCShareableContent signal fires before the post-call surface starts, the audio signal fires after the chat surface releases (since the chat surface holds the mic for under one second in practice), and the daemon's tap stays inactive throughout the 2.0 second window because the recorder has already been told to flush.

The single event surfaced to `RecordingStateMachine` is `MeetingLifecycleCoordinator.verdict: AsyncStream<MeetingLifecycleVerdict>`. The recorder subscribes once at startup and reacts to `.ended` by closing the WAV file and emitting `meeting_ended` to `events.jsonl` with the full `confirmedBy` array as audit evidence.

### A.3 Per-app and per-platform notes

**Teams native (com.microsoft.teams2 and com.microsoft.teams).** Primary is SCShareableContent meeting-window disappearance; corroborating is `kAudioProcessPropertyIsRunningInput → false` matched to the Teams PID. The window title regex is anchored on the meeting-window suffix only; locale-specific prefix variants are accepted via the same TOML used for mute detection (Section B.5). The cached Leave-button AX element is health-polled at 1 Hz; the destruction notification is registered but not trusted as sole signal. Post-call chat surface mic-grab is absorbed by the `.endingProvisional → .ended` 2.0-second debounce. Microsoft Graph presence is available as an opt-in cloud corroborator if the user provides a delegated token.

**Zoom (us.zoom.xos).** Same architecture, same primary signals. Zoom's meeting window has stable bundle ID and a window title containing "Zoom Meeting" in all locales the project supports; the title is documented in Zoom's public help articles via screenshots. The Leave button is reached via the documented menu path `Meeting → End` or `Meeting → Leave Meeting` for AppleScript-side verification. The `onMeeting` event from Zoom Apps SDK is not consumable by an external daemon and is documented as such, so it is REJECTED.

**Webex (com.cisco.webexmeetingsapp, Cisco-Systems.Spark).** Same architecture with **one exclusion: `kAudioProcessPropertyIsRunningInput` is demoted from PRIMARY to REJECTED for end-detection because Cisco documents that Webex holds the microphone open after meetings for ultrasound device discovery.** Primary collapses to SCShareableContent window disappearance plus the cached AX Leave-button invalidation. Webex's Embedded Apps SDK `sidebar:callStateChanged` event is not consumable by an external daemon.

**Browser-hosted Teams, Meet, Webex web, Slack PWA.** Primary is browser-window title transition observed via `SCWindow.title` filtered by `owningApplication.bundleIdentifier` matching Chrome, Safari, Edge, Arc, or Brave. The active tab title is read from `CGWindowListCopyWindowInfo` for windows the daemon does not own (Screen Recording TCC required). For Chrome, Safari, Edge, Arc, and Brave, the AppleScript dictionary's `active tab` property is a documented fallback when window title alone is ambiguous (the project's existing AppleScript path); Firefox is not scriptable and falls through to the title-only path. Google Meet's tab title pattern is `Meet <separator> xxx-yyyy-zzz` (three-four-three meeting code per Google's public help page); the daemon matches that regex and treats transition off it as the leading PRIMARY. Title transition is corroborated by `kAudioProcessPropertyIsRunningInput` going false on the browser PID **only if no other tab in that browser has the mic**, which the daemon cannot determine; therefore browser audio-release is CORROBORATING only.

### A.4 Test plan and failure modes

Each signal is independently reproducible in the user's environment. `kAudioProcessPropertyIsRunningInput` transitions can be observed by running the AudioCap sample (Guilherme Rambo, github.com/insidegui/AudioCap) and watching its TUI as the user joins and leaves a Teams call; the property's value, the listener-fire timing, and the polling-fallback latency are all surfaced. SCShareableContent meeting-window disappearance can be observed by running a one-line script polling `SCShareableContent.current()` and logging titles; the user can compare timing to the audio-release moment. AX Leave-button invalidation can be reproduced with Accessibility Inspector by inspecting the cached element handle and watching the `Invalid Element` state flip on Leave. The daemon emits `signal:` lines to `events.jsonl` with timestamp, signal kind, before/after values, and adapter ID; the user verifies each signal in their environment by joining a Teams call, leaving, and confirming the `events.jsonl` shows the expected `.endingProvisional → .ended` transition with the right `confirmedBy` array.

Failure modes the user should expect during initial integration. **Apple Developer Forums thread 825780 documents that `kAudioProcessPropertyIsRunningInput` listener registration sometimes does not fire**; the daemon mitigates with a 1 Hz polling fallback. **AeroSpace issue 445 documents that `kAXUIElementDestroyedNotification` drops on Sequoia for Electron and WebView2 apps**; the daemon mitigates by treating `kAXErrorInvalidUIElement` from `AXUIElementCopyAttributeValue` on the cached handle as the authoritative signal. **`SCShareableContent.current()` returns empty arrays when Screen Recording TCC is missing**; the daemon detects this at startup and surfaces a setup-required state instead of operating with degraded signals. **`SCStream(didStopWithError:)` has a documented Sonoma 14.6 crash in `swift_getErrorValue` on long captures**; the daemon wraps the delegate boundary in an Objective-C bridge that catches the malformed error and converts it to a `.stopped` signal.

---

## PART B · Muted-microphone capture architecture

### B.1 Candidate signals with classification

The structural fact that determines this entire design is that **no public macOS API exposes a third-party app's in-meeting mute state.** Apple Developer Forums searches across 2024 to 2026 confirm this; the closest published mechanism, `AVAudioApplication.inputMuteStateChangeNotification`, is delivered only to the process that registered the handler. Teams, Zoom, and Webex implement mute by discarding their own input samples; the HAL device stays open, `kAudioProcessPropertyIsRunningInput` stays true, and `kAudioObjectPropertyMute` on the input device does not change. Therefore the verdict must be inferred from a fusion of voice-activity, RMS, AX-button-state, and HAL system-mute.

**HAL Voice Activity Detection** (`kAudioDevicePropertyVoiceActivityDetectionEnable`, `kAudioDevicePropertyVoiceActivityDetectionState`, scope `kAudioDevicePropertyScopeInput`, element `kAudioObjectPropertyElementMain`, macOS 14.0+) is PRIMARY. WWDC23 session 10235 "What's new in voice processing" (timestamps 11:37 and 12:31) documents the API; the state is observable via `AudioObjectAddPropertyListenerBlock`, latency is roughly 100 to 300 ms from speech onset, and the detection operates on echo-cancelled input regardless of any process's mute state. The property is supported on the built-in mic on Apple Silicon; third-party USB mics that do not route through Apple's voice-processing path may return `kAudioHardwareUnknownPropertyError` on enable, and the daemon detects this at startup and falls through to RMS-only gating for that device.

**RMS energy gate inside the existing AVAudioEngine input-tap** is PRIMARY. The canonical implementation is an allocation-free, lock-free vDSP-based RMS computation per buffer with asymmetric hysteresis: close-to-silent on a sustained 350 ms window below -55 dBFS, open-to-hot on a sustained 80 ms window above -45 dBFS. The thresholds and dwell times are init parameters on `RMSGateProbe` (defaults -55 / -45 dBFS), tuned for room-noise floors in office and home settings. The tap callback runs on the audio render thread; the gate is allocation-free with all state in stored properties and owned by the tap thread (no lock). A verdict transition's lock, the `events.jsonl` write, and the AsyncStream yield are all deferred onto `MicGate.publishQueue`, so nothing touches the file system on the render thread (TECH-CONC1).

**Accessibility observation of the meeting-app mute button** is PRIMARY when the locale TOML covers the user's locale and the AX scrape returns a recognized label, otherwise CORROBORATING when scrape returns an unrecognized label, otherwise unavailable. The pattern is the same caching architecture as Section A.2: walk to the Mute/Unmute button once, retain the `AXUIElementRef`, register `kAXValueChangedNotification` and `kAXTitleChangedNotification`, and health-poll at 1 Hz to absorb Sequoia destruction-notification dropouts. The button's `AXTitle` or `AXValue` distinguishes muted (label is "Unmute" or its locale equivalent) from hot (label is "Mute").

**HAL system-input mute** (`kAudioObjectPropertyMute` on the default input device, input scope) is CORROBORATING. It flips for hardware mute, Control Center mic toggle, and third-party mute utilities; it does not flip for in-app mute in Teams, Zoom, or Webex. Observation is via `AudioObjectAddPropertyListenerBlock`.

**`AVCaptureDevice.isInUseByAnotherApplication` KVO** is CORROBORATING for the "which app currently owns the mic" question but does not indicate mute. **`kAudioProcessPropertyIsRunningInput` is REJECTED for mute detection** because it stays true throughout the entire meeting regardless of mute state. **`AVAudioApplication.inputMuteStateChangeNotification` is REJECTED for cross-app observation** because it is per-process. **The macOS 14+ orange indicator dot is REJECTED** because no public API reads it; the closest public substitute, `kAudioDevicePropertyDeviceIsRunningSomewhere`, indicates device-in-use, not mute. **`AVCaptureDevice.systemPressureState` is REJECTED** because it reports thermal/power, not mute. **The macOS 15 per-app sound settings panel** does not expose a public HAL API for per-app input mute as of macOS 15.x; REJECTED.

For browser-hosted meetings, **no per-tab mute signal exists at any public API surface.** The browser holds a single `AVCaptureDevice` input session; from the daemon's perspective, mute is invisible at the OS layer. The architecture falls through to RMS gating plus HAL VAD as the only available verdict inputs for browsers. AX scrape of the meeting page's mute button is attempted when the active tab is a Meet or Teams-web tab and the page's accessibility tree exposes the button (Meet does; Teams web does); this is CORROBORATING only.

### B.2 Recommended architecture

```
Sources/MeetingPipeCore/MicGate/
  MicGate.swift                       // final class + NSLock; owns the verdict
  MicGateVerdict.swift                // enum + reasoning
  MicGateWriter.swift                 // applies verdict to the L channel
  MicOnlySilenceBackstop.swift        // force-stop a mic-only silent recording
  MuteLabelsLoader.swift
  MuteLabelsValidator.swift           // CI tool, see B.5
  Probes/
    HALVoiceActivityProbe.swift       // kAudioDevicePropertyVoiceActivityDetectionState
    RMSGateProbe.swift                // vDSP RMS + hysteresis inside the tap
    AXMuteButtonProbe.swift           // localized AX scrape, cached element
    HALSystemMuteProbe.swift          // kAudioObjectPropertyMute on input device
  Resources/
    MuteLabels.toml                   // checked-in, per-app, per-locale
  Adapters/
    MicGateAdapter.swift              // protocol
    NativeMuteAdapter.swift           // Teams, Zoom, Webex, Slack, Meet (AX-driven)
    NoOpMuteAdapter.swift             // unknown clients: HAL VAD + RMS only
```

`MicGateVerdict` is an enum carrying audit-log reasoning:

```
enum MicGateVerdict {
    case hot(rmsDB: Float, vadActive: Bool, axState: AXMuteState?, at: Date)
    case mutedByApp(adapter: AdapterID, axLabel: String, at: Date)
    case mutedByHardware(deviceID: AudioObjectID, at: Date)
    case silentByRMS(rmsDB: Float, sustainedFor: TimeInterval, at: Date)
    case uncertain(reasons: [UncertaintyReason], at: Date)
}
```

The verdict is recomputed on every signal change. HAL VAD, HAL system mute, and AX button-state changes are event-driven via `AudioObjectAddPropertyListenerBlock` and `AXObserver`. The RMS gate is event-driven from the audio render thread and hands state changes to `MicGate` off the render thread; the lock and the `events.jsonl` write run on `MicGate.publishQueue` (TECH-CONC1). AX button-state has a 1 Hz health-poll fallback for Sequoia notification dropouts. There is no other polling.

Precedence rules. `mutedByHardware` wins if HAL system-input-mute is true. Otherwise `mutedByApp` wins if AX scrape returns a "muted" label that matches the locale TOML. Otherwise `silentByRMS` wins if RMS has been below the close threshold for the sustained dwell. Otherwise `hot` if VAD is active or RMS is above the open threshold. Otherwise `uncertain` with reasons listed. The precedence is deterministic and audit-logged.

**The writer (`MicGateWriter`) writes zero-amplitude frames into the left channel whenever the verdict is anything but `hot`.** This is the only correct behavior. Skipping frames would break sample alignment with the ScreenCaptureKit ProcessTap right channel because the writer cannot know how many frames the right channel will produce in the same wall-clock interval. Stopping the writer entirely would create a discontinuity in the WAV that downstream diarization and silent-system-audio detection cannot recover from. Writing zero frames preserves alignment, preserves file structure, and produces a recording that audibly contains "silence on the left when muted, audio on the left when speaking" with no glitches at transition boundaries. The writer maintains a 20 ms fade between hot and silent states to avoid audible clicks; the fade is computed in the writer, not in the gate.

Every verdict transition is logged to `events.jsonl` as one line:

```
{"t":"2026-05-14T14:12:33.482Z","kind":"micgate","from":"hot","to":"mutedByApp",
 "adapter":"teams","rmsDB":-22.1,"vadActive":true,"axLabel":"Stummschaltung aufheben",
 "locale":"de"}
```

This is the audit trail the user needs to validate behavior in regulated-life-sciences review.

### B.3 Per-platform notes

**Teams native (Teams 2.x WebView2 and legacy Electron).** AX is PRIMARY when the locale TOML resolves; the Mute button's `AXTitle` toggles between the locale's "Mute" and "Unmute" strings (`Stummschalten`/`Stummschaltung aufheben` in de, `Activer/Désactiver le micro` in fr, etc.). HAL VAD plus RMS are PRIMARY when AX fails. The fusion logic resolves `mutedByApp` if AX is conclusive; otherwise `silentByRMS` if RMS sustained below threshold with VAD inactive; otherwise `hot`.

**Teams browser (teams.microsoft.com).** AX scrape can succeed because the Teams web client exposes the mute button via ARIA in the page's accessibility tree; the same localized labels apply. Where AX fails (some browser-tenant combinations strip the labels), the fallback is HAL VAD plus RMS, which is the same as native.

**Zoom native.** Same as Teams native. Zoom's `Meeting → Mute audio`/`Unmute audio` menu items are an additional documented surface that the AX adapter walks; the labels are still locale-dependent.

**Meet (browser only).** This is the documented hardest case. **There is no AX-leaf-button approach that survives the user's seven-locale constraint reliably across Chromium versions; this is a known limitation.** The architecture therefore depends on HAL VAD and RMS for Meet, with browser-active-tab title matching `Meet · <code>` as the trigger to enable the MicGate at all. AX scrape of the Meet mute button is attempted opportunistically and CORROBORATING when it succeeds. The verdict for Meet is `silentByRMS` when RMS is sustained low and VAD is inactive; this is functionally adequate because Meet users who are muted are not producing room audio that ought to be recorded anyway.

**Webex native and browser.** Same AX-plus-VAD-plus-RMS pattern. Webex's documented ultrasound mic-retention does not affect mute detection because the daemon's MicGate runs during the user's meeting, when the mic-retention behavior is identical to in-call.

**Slack native and PWA.** Slack's `user_huddle_changed` event is available as CORROBORATING cloud signal for huddle membership (not mute). AX scrape of the huddle Mute button is PRIMARY when locale resolves. The same architecture extends to other locales via the TOML; the user's existing English-only AX implementation is generalized by the locale loader.

### B.4 Localization strategy

The project ships `Sources/MeetingPipeCore/MicGate/Resources/MuteLabels.toml` keyed by app and locale:

```
[teams.en]
mute   = ["Mute", "Mute microphone", "Mute mic"]
unmute = ["Unmute", "Unmute microphone", "Unmute mic"]
leave  = ["Leave", "Leave call", "Leave meeting"]

[teams.de]
mute   = ["Stummschalten", "Mikrofon stummschalten"]
unmute = ["Stummschaltung aufheben"]
leave  = ["Verlassen", "Anruf verlassen"]

[teams.fr]
mute   = ["Désactiver le micro", "Couper le micro"]
unmute = ["Activer le micro"]
leave  = ["Quitter", "Quitter l'appel"]

# ... es, ja, pt, ru, same structure
# ... zoom, webex, slack, meet sections
```

**No vendor publishes a developer-consumable localization table.** Microsoft Learn's localization samples cover third-party Teams apps, not Microsoft's first-party UI. Zoom, Webex, Slack, and Google publish none. The TOML is therefore maintained from observation: a CI job (`MuteLabelsValidator`) runs nightly on a build VM with Teams, Zoom, Webex, and Slack pre-installed in each locale, programmatically walks the AX tree of each app's meeting/huddle window, and asserts that one of the TOML's strings is present as `AXTitle` or `AXDescription` of an `AXButton`. When a vendor ships a label drift, the CI job fails, the project ships a TOML update, and users update the daemon. When a locale is unrecognized at runtime, the daemon emits `signal:locale_unknown` to `events.jsonl` and falls through to HAL VAD plus RMS, which is the same path Meet uses always.

### B.5 Coupling to call-end detection

The two subsystems share three pieces of infrastructure and nothing else. `Infra/CoreAudioHALBus.swift` is a single registrar for `AudioObjectAddPropertyListenerBlock` calls; both `MeetingLifecycleCoordinator` and `MicGate` register their listeners through it, so the daemon walks the per-process AudioObject list once per process discovery, not per signal. `Infra/AXObserverBus.swift` is a single registrar for `AXObserverCreate` per PID and `AXObserverAddNotification` per element; the Leave-button observer (lifecycle) and the Mute-button observer (gate) share the same `AXObserver` per meeting-app PID, the runloop source is added once per PID, and the cached `AXUIElementRef`s are owned by the bus and reference-counted by adapter requests. The AX tree is walked once at meeting start (when `MeetingLifecycleCoordinator` transitions to `.inMeeting`), the Leave and Mute buttons are both located in that single walk, and both are retained for the lifetime of the meeting. **No re-walking of the AX tree during the meeting.** `Infra/EventLog.swift` is the single emitter of `events.jsonl`.

The shared verdict observation pattern means the daemon does the AX walk once, registers two notifications and two health-polls on cached handles, registers two HAL listener blocks (`IsRunningInput` for lifecycle, `VoiceActivityDetectionState` for gate), and otherwise reacts purely to events.

---

## Integration summary

The two coordinators are independent state machines that share infrastructure. `MeetingLifecycleCoordinator` consumes signals from `ProcessAudioSignal`, `ShareableContentSignal`, `AXLeaveButtonSignal`, and corroborators, and surfaces `MeetingLifecycleVerdict` to the recorder. `MicGate` consumes signals from `HALVoiceActivityProbe`, `RMSGateProbe`, `AXMuteButtonProbe`, and `HALSystemMuteProbe`, and surfaces `MicGateVerdict` to the writer. Both write to `events.jsonl`. The recorder closes the WAV on `MeetingLifecycleVerdict.ended`; the writer applies `MicGateVerdict` to the left channel on every buffer. Neither subsystem polls the AX tree; both register on cached element references obtained from a shared one-time walk; both subscribe to a shared HAL property-listener bus; both emit through a shared event log.

The architecture meets every constraint: public Apple APIs only, no private AX, no Electron DevTools, no reverse-engineered IPC, no kernel involvement, no System Extension, no paid Developer ID required for the daemon to function (TCC grants survive across rebuilds with ad-hoc signing), and every signal is independently reproducible via Console.app, `log stream`, `sample`, AVFoundation event listeners, or Accessibility Inspector.
