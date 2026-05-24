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

The fusion layer is a single Swift actor that owns a typed event bus, not a set of booleans. **One coherent verdict object, `MeetingLifecycleVerdict`, is the only thing the recording state machine consumes.**

```
Sources/MeetingPipeCore/Lifecycle/
  MeetingLifecycleCoordinator.swift     // actor; owns the verdict
  MeetingLifecycleVerdict.swift         // enum + reasoning payload
  Signals/
    ProcessAudioSignal.swift            // HAL per-process IsRunningInput
    InputDeviceSignal.swift             // HAL device IsRunningSomewhere
    ShareableContentSignal.swift        // SCShareableContent window polling
    AXLeaveButtonSignal.swift           // cached AXUIElementRef + health poll
    WindowTitleSignal.swift             // AX title change + browser tab title
    WorkspaceSignal.swift               // NSWorkspace + NSRunningApplication
    CalendarContextSignal.swift         // EventKit hysteresis hints
  Adapters/
    TeamsLifecycleAdapter.swift
    ZoomLifecycleAdapter.swift
    WebexLifecycleAdapter.swift
    BrowserMeetingLifecycleAdapter.swift // Meet, Teams web, Webex web, Slack PWA
  Infra/
    CoreAudioHALBus.swift               // shared property-listener registrar
    AXObserverBus.swift                 // shared AXObserver registrar + cache
    EventLog.swift                      // events.jsonl emitter
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

**RMS energy gate inside the existing AVAudioEngine input-tap** is PRIMARY. The canonical implementation is an allocation-free, lock-free vDSP-based RMS computation per buffer with asymmetric hysteresis: close-to-silent on a sustained 350 ms window below -55 dBFS, open-to-hot on a sustained 80 ms window above -45 dBFS. The thresholds and dwell times are tuned for room-noise floors in office and home settings and exposed as compile-time constants in `MicGate/Thresholds.swift`. The tap callback runs on the audio render thread; the gate uses two `os_unfair_lock`-free atomic state variables and a small ring buffer of dB values, no allocations, no logging from the callback.

**AVAudioInputNode `setMutedSpeechActivityEventListener`** is PRIMARY for the daemon's own engine and provides a free corroboration that the RMS gate is correctly identifying speech, because the daemon can mute its own voice-processing input and use this listener as a ground-truth speech-detector that runs in parallel to RMS. This is a daemon-internal calibration signal, not a meeting-app mute signal.

**Accessibility observation of the meeting-app mute button** is PRIMARY when the locale TOML covers the user's locale and the AX scrape returns a recognized label, otherwise CORROBORATING when scrape returns an unrecognized label, otherwise unavailable. The pattern is the same caching architecture as Section A.2: walk to the Mute/Unmute button once, retain the `AXUIElementRef`, register `kAXValueChangedNotification` and `kAXTitleChangedNotification`, and health-poll at 1 Hz to absorb Sequoia destruction-notification dropouts. The button's `AXTitle` or `AXValue` distinguishes muted (label is "Unmute" or its locale equivalent) from hot (label is "Mute").

**HAL system-input mute** (`kAudioObjectPropertyMute` on the default input device, input scope) is CORROBORATING. It flips for hardware mute, Control Center mic toggle, and third-party mute utilities; it does not flip for in-app mute in Teams, Zoom, or Webex. Observation is via `AudioObjectAddPropertyListenerBlock`.

**`AVCaptureDevice.isInUseByAnotherApplication` KVO** is CORROBORATING for the "which app currently owns the mic" question but does not indicate mute. **`kAudioProcessPropertyIsRunningInput` is REJECTED for mute detection** because it stays true throughout the entire meeting regardless of mute state. **`AVAudioApplication.inputMuteStateChangeNotification` is REJECTED for cross-app observation** because it is per-process. **The macOS 14+ orange indicator dot is REJECTED** because no public API reads it; the closest public substitute, `kAudioDevicePropertyDeviceIsRunningSomewhere`, indicates device-in-use, not mute. **`AVCaptureDevice.systemPressureState` is REJECTED** because it reports thermal/power, not mute. **The macOS 15 per-app sound settings panel** does not expose a public HAL API for per-app input mute as of macOS 15.x; REJECTED.

For browser-hosted meetings, **no per-tab mute signal exists at any public API surface.** The browser holds a single `AVCaptureDevice` input session; from the daemon's perspective, mute is invisible at the OS layer. The architecture falls through to RMS gating plus HAL VAD as the only available verdict inputs for browsers. AX scrape of the meeting page's mute button is attempted when the active tab is a Meet or Teams-web tab and the page's accessibility tree exposes the button (Meet does; Teams web does); this is CORROBORATING only.

### B.2 Recommended architecture

```
Sources/MeetingPipeCore/MicGate/
  MicGate.swift                       // actor; owns the verdict
  MicGateVerdict.swift                // enum + reasoning
  MicGateWriter.swift                 // applies verdict to the L channel
  Probes/
    HALVoiceActivityProbe.swift       // kAudioDevicePropertyVoiceActivityDetectionState
    RMSGateProbe.swift                // vDSP RMS + hysteresis inside the tap
    AXMuteButtonProbe.swift           // localized AX scrape, cached element
    HALSystemMuteProbe.swift          // kAudioObjectPropertyMute on input device
    InternalSpeechProbe.swift         // AVAudioInputNode muted-speech listener
  Locale/
    MuteLabels.toml                   // checked-in, per-app, per-locale
    MuteLabelsLoader.swift
    MuteLabelsValidator.swift         // CI tool, see B.5
  Adapters/
    TeamsMuteAdapter.swift
    ZoomMuteAdapter.swift
    WebexMuteAdapter.swift
    MeetMuteAdapter.swift
    SlackMuteAdapter.swift
    BrowserMuteAdapter.swift          // generic browser fallback
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

The verdict is recomputed on every signal change. HAL VAD, HAL system mute, and AX button-state changes are event-driven via `AudioObjectAddPropertyListenerBlock` and `AXObserver`. The RMS gate is event-driven from the audio render thread and posts state changes via a single-producer single-consumer atomic. AX button-state has a 1 Hz health-poll fallback for Sequoia notification dropouts. There is no other polling.

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

The project ships `Sources/MeetingPipeCore/MicGate/Locale/MuteLabels.toml` keyed by app and locale:

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

---

## Backlog updates

**TECH-G-MIC · MicGate verdict subsystem · L · TECH-C13**

Spec. Replace MeetingMuteProbe with MicGate, a verdict-fusion subsystem that determines whether the recorded left channel should contain microphone audio or zero-amplitude frames at each buffer boundary. The verdict fuses HAL Voice Activity Detection on the default input device, an RMS energy gate inside the existing AVAudioEngine input tap with asymmetric hysteresis (close at sustained -55 dBFS for 350 ms, open at sustained -45 dBFS for 80 ms), Accessibility observation of the meeting-app Mute button against a locale TOML covering en, es, fr, de, ja, pt, ru, and HAL system-input-mute via kAudioObjectPropertyMute. The verdict is one of hot, mutedByApp, mutedByHardware, silentByRMS, uncertain, with reasoning attached. The writer emits zero-amplitude frames with a 20 ms fade on transitions whenever the verdict is anything but hot. The Mute button AXUIElementRef is obtained from a single AX-tree walk at meeting start, retained for the meeting lifetime, observed via kAXValueChangedNotification and kAXTitleChangedNotification on a shared AXObserver per PID, and health-polled at 1 Hz via AXUIElementCopyAttributeValue to absorb Sequoia destruction-notification dropouts. HAL VAD is enabled at meeting start via kAudioDevicePropertyVoiceActivityDetectionEnable on the default input device and observed via kAudioDevicePropertyVoiceActivityDetectionState through the shared CoreAudioHALBus. Every verdict transition is logged as one line to events.jsonl with from, to, rmsDB, vadActive, axLabel, locale, and adapter fields. Browser-hosted meetings and unrecognized locales fall through to HAL-VAD-plus-RMS-only, which produces silentByRMS when the user is not speaking.

Files. Sources/MeetingPipeCore/MicGate/MicGate.swift, MicGateVerdict.swift, MicGateWriter.swift, Probes/HALVoiceActivityProbe.swift, Probes/RMSGateProbe.swift, Probes/AXMuteButtonProbe.swift, Probes/HALSystemMuteProbe.swift, Probes/InternalSpeechProbe.swift, Locale/MuteLabels.toml, Locale/MuteLabelsLoader.swift, Locale/MuteLabelsValidator.swift, Adapters/TeamsMuteAdapter.swift, Adapters/ZoomMuteAdapter.swift, Adapters/WebexMuteAdapter.swift, Adapters/MeetMuteAdapter.swift, Adapters/SlackMuteAdapter.swift, Adapters/BrowserMuteAdapter.swift, Infra/CoreAudioHALBus.swift, Infra/AXObserverBus.swift, Infra/EventLog.swift. Remove Sources/MeetingPipeCore/MeetingMuteProbe.swift and its references.

Acceptance. With Teams in German locale, joining a call and toggling mute, events.jsonl shows micgate transitions hot to mutedByApp with axLabel "Stummschaltung aufheben" and locale "de". With Meet in any browser, joining a call and remaining silent, events.jsonl shows micgate transitions to silentByRMS within 400 ms of speech cessation, and the recorded left channel contains zero-amplitude frames with sample alignment preserved against the right channel (verified by frame-count equality between channels in the resulting WAV). With Control Center mic muted, events.jsonl shows mutedByHardware. With a USB mic that does not support HAL VAD, the daemon logs signal:vad_unsupported once at startup and operates correctly on RMS only.

Stop-and-ask. If the TOML for any of the seven locales returns zero matches against a live Teams 2.x install during initial integration. If HAL VAD enable returns kAudioHardwareUnknownPropertyError on the user's built-in mic on their Apple Silicon target. If frame-count equality fails between left and right channels by more than one frame in any 10-minute recording.

Deps. TECH-C13.

**TECH-C13 · MeetingLifecycleCoordinator verdict subsystem · L · none**

Spec. Replace the existing Teams-AX-Leave-button-plus-title-pattern end detector with MeetingLifecycleCoordinator, a verdict-fusion subsystem that surfaces a single MeetingLifecycleVerdict to RecordingStateMachine. The coordinator consumes PRIMARY signals from ShareableContentSignal (SCShareableContent polled at 2 Hz when a meeting is active, 1 Hz otherwise, filtered by owningApplication.bundleIdentifier and a locale-tolerant title regex), ProcessAudioSignal (per-process kAudioProcessPropertyIsRunningInput on the meeting-app AudioObject, listener registered plus 1 Hz polling fallback, excluded as primary for Webex), AXLeaveButtonSignal (cached AXUIElementRef on the Leave button, observed via kAXUIElementDestroyedNotification, health-polled at 1 Hz with kAXErrorInvalidUIElement treated as authoritative), and SCStream stopped signals when the daemon owns a stream. Corroborating signals are WorkspaceSignal (NSWorkspaceDidTerminateApplicationNotification, NSRunningApplication KVO), AX title-change on the meeting window, CGWindowList HUD-window disappearance polled at 0.5 Hz, EventKit scheduled-end hysteresis, and optional Graph presence or Slack user_huddle_changed when the user provides cloud tokens. The verdict transitions through .idle, .starting, .inMeeting, .endingProvisional (any one PRIMARY satisfied), and .ended (a second PRIMARY confirming or 2.0 second debounce elapsing with the leading signal still satisfied). RecordingStateMachine consumes the verdict via AsyncStream and closes the WAV on .ended. The 2.0 second debounce absorbs the post-call chat surface mic-grab cleanly without RepromptCooldown. The cached AX Leave-button reference is obtained from the same AX-tree walk that TECH-G-MIC uses for the Mute button, through the shared AXObserverBus. HAL property listeners are registered through the shared CoreAudioHALBus. Every signal change and verdict transition is logged to events.jsonl.

Files. Sources/MeetingPipeCore/Lifecycle/MeetingLifecycleCoordinator.swift, MeetingLifecycleVerdict.swift, Signals/ProcessAudioSignal.swift, Signals/InputDeviceSignal.swift, Signals/ShareableContentSignal.swift, Signals/AXLeaveButtonSignal.swift, Signals/WindowTitleSignal.swift, Signals/WorkspaceSignal.swift, Signals/CalendarContextSignal.swift, Adapters/TeamsLifecycleAdapter.swift, Adapters/ZoomLifecycleAdapter.swift, Adapters/WebexLifecycleAdapter.swift, Adapters/BrowserMeetingLifecycleAdapter.swift, Infra/CoreAudioHALBus.swift, Infra/AXObserverBus.swift, Infra/EventLog.swift. Remove the existing Teams-AX-Leave-button-only detector and the window-title-pattern matcher.

Acceptance. Joining and leaving a Teams 2.x call in English produces events.jsonl entries inMeeting then endingProvisional with leadingSignal "shareable_content_window_gone" within 800 ms of clicking Leave, then ended within 2.0 seconds total with confirmedBy containing both "shareable_content_window_gone" and "process_audio_is_running_input_false". The WAV closes cleanly with no audio from the post-call chat surface present in the file. Joining and leaving a Zoom call produces the same transitions with the Zoom adapter. Joining and leaving a Webex call produces .ended with confirmedBy containing "shareable_content_window_gone" and "ax_leave_button_invalid" but never "process_audio_is_running_input_false" (Webex ultrasound retention by design). Joining and leaving a Google Meet call in Chrome produces .ended with leadingSignal "browser_tab_title_left_meet_pattern". The AX tree is walked exactly once per meeting (verified by an assertion counter exposed in debug builds). kAXUIElementDestroyedNotification dropout on Sequoia does not prevent .ended within 2.5 seconds of Leave (verified by killing the notification path in a test build and confirming the health-poll path fires).

Stop-and-ask. If SCShareableContent returns empty arrays at daemon startup (Screen Recording TCC not granted; surface SetupRequired state instead of running with degraded signals). If kAudioProcessPropertyIsRunningInput listener never fires for the Teams or Zoom process on the user's Mac (file FB and fall back to 1 Hz polling for that PID; do not ship a polling-only path silently). If the post-call chat surface mic-grab exceeds 2.0 seconds on the user's specific Teams build (extend the debounce to 3.0 seconds after measurement, not before).

Deps. None.

**TECH-LIB-MIX · Library playback mono mixdown · S · none**

Spec. The library window's audio playback defaults to a real-time mono mixdown of the stereo WAV instead of stereo playback. The on-disk WAV stays stereo (mic-L, system-R) for diarization and silent-system-audio detectability per the existing design. The mixdown is computed in the playback path as 0.5 times left plus 0.5 times right per sample, applied through an AVAudioMixerNode pan-to-center configuration on the player node, with no modification to the source file. A toggle in the library window's playback controls switches between mono mixdown (default) and original stereo for users who explicitly want the channel separation. The toggle state is persisted per library, not globally. The mixdown avoids the "input in left ear, output in right ear" listening confusion that the stereo-on-headphones default produces.

Files. Sources/MeetingPipeLibrary/Playback/LibraryPlayer.swift, Sources/MeetingPipeLibrary/Playback/PlaybackChannelMode.swift, Sources/MeetingPipeLibrary/Views/PlaybackControlsView.swift, Sources/MeetingPipeLibrary/Storage/LibraryPreferences.swift.

Acceptance. Opening any existing stereo recording in the library and clicking play produces mono audio on both ears by default. The on-disk WAV is byte-identical before and after playback (verified by SHA-256). The stereo toggle in the playback controls switches to original stereo and persists across library window close and reopen. The mixdown introduces no audible clipping on recordings where left and right are both near full-scale (verified by playing back a test recording of a loud call).

Stop-and-ask. If AVAudioMixerNode pan-to-center produces audible phase artifacts on any test recording (switch to explicit per-buffer 0.5L plus 0.5R summation in an AVAudioSourceNode render block, not a mixer pan).

Deps. None.