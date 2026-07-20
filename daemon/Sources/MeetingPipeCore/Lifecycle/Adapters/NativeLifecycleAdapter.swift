import ApplicationServices
import Foundation

/// Per-app config row for `NativeLifecycleAdapter`. Replaces the old per-app adapter classes.
public struct NativeLifecycleConfig {
    public let bundleIDs: Set<String>
    public let titleMatch: (String?) -> Bool
    /// TECH-END1: false for every provider, and DET2 made that permanent. The
    /// `kAudioProcessPropertyIsRunningInput` signal needs the PID-to-HAL-process-object
    /// translation, which returns object 0: 0 successful reads in 19.8 days (13,419
    /// `process_audio_unresolved`, every OSStatus `noErr`, so the HAL answers and reports
    /// no process object rather than refusing). The obvious fix was to blame our capture
    /// model (ScreenCaptureKit, no audio-tap authorization, no process tap) and adopt a
    /// tap. DET2 measured that on a real Mac against a live call while holding the Screen
    /// Recording grant: object 0 from the grant alone, from a live bare process tap, and
    /// from a private aggregate device around that tap, with tap and aggregate both
    /// constructing fine. The tap hypothesis is refuted, not untried, so this flag stays
    /// false and the machinery is kept only to re-measure cheaply if a future macOS changes
    /// process-object authorization. Never constructing the signal also stops the log spam.
    /// See `docs/spikes/det2-process-tap-attribution.md`.
    /// (Webex/Slack were already false: Cisco holds the mic open post-call for ultrasound.)
    public let usesProcessAudio: Bool

    public init(
        bundleIDs: Set<String>,
        titleMatch: @escaping (String?) -> Bool,
        usesProcessAudio: Bool
    ) {
        self.bundleIDs = bundleIDs
        self.titleMatch = titleMatch
        self.usesProcessAudio = usesProcessAudio
    }
}

public extension NativeLifecycleConfig {
    /// ShareableContent + AXLeaveButton (ProcessAudio disabled, TECH-END1).
    static let teams = NativeLifecycleConfig(
        bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
        titleMatch: MeetingTitlePatterns.teams,
        usesProcessAudio: false
    )

    /// ShareableContent + AXLeaveButton (same set as Teams; ProcessAudio disabled, TECH-END1).
    static let zoom = NativeLifecycleConfig(
        bundleIDs: ["us.zoom.xos"],
        titleMatch: MeetingTitlePatterns.zoom,
        usesProcessAudio: false
    )

    /// ShareableContent + AXLeaveButton. Covers legacy `com.cisco.webexmeetingsapp` and the unified Webex App (`com.cisco.spark`).
    static let webex = NativeLifecycleConfig(
        bundleIDs: ["com.cisco.webexmeetingsapp", "com.cisco.spark"],
        titleMatch: MeetingTitlePatterns.webex,
        usesProcessAudio: false
    )

    /// ShareableContent + AXLeaveButton for `com.tinyspeck.slackmacgap`.
    static let slack = NativeLifecycleConfig(
        bundleIDs: ["com.tinyspeck.slackmacgap"],
        titleMatch: MeetingTitlePatterns.slackHuddle,
        usesProcessAudio: false
    )

    /// Every shipped native config. The DET4 coverage fence
    /// (`MeetingAppRegistryFenceTests`) asserts these bundle IDs cover every `[native]`
    /// entry in `meeting_apps.toml`, so a native row can never sit adapterless (the
    /// pre-DET4 dead `com.skype.skype` / `com.google.meet` rows). The daemon builds one
    /// `NativeLifecycleAdapter` per entry (see `Coordinator`).
    static let all: [NativeLifecycleConfig] = [.teams, .zoom, .webex, .slack]
}

/// Single parameterized adapter for native meeting clients (Teams, Zoom, Webex, Slack). Per-app differences live in `NativeLifecycleConfig`.
public final class NativeLifecycleAdapter: LifecycleAdapter {

    public var bundleIDs: Set<String> { config.bundleIDs }
    public let kind: MeetingLifecycleContext.Kind = .native

    private let config: NativeLifecycleConfig
    private let processAudio: ProcessAudioSignal?
    private let shareableContent: ShareableContentSignal
    private let axLeaveButton: AXLeaveButtonSignal

    /// Context captured at `start` so `armLeaveButton` emits under the same context the engine matches against.
    private var startedContext: MeetingLifecycleContext?

    /// `halBus` required when `config.usesProcessAudio` is true; ignored for Webex/Slack.
    public init(
        config: NativeLifecycleConfig,
        halBus: CoreAudioHALBus? = nil,
        axBus: AXObserverBus,
        eventLog: EventLog = NoopEventLog()
    ) {
        precondition(
            !config.usesProcessAudio || halBus != nil,
            "NativeLifecycleConfig.usesProcessAudio requires a halBus"
        )
        self.config = config
        self.shareableContent = ShareableContentSignal(eventLog: eventLog)
        self.axLeaveButton = AXLeaveButtonSignal(axBus: axBus, eventLog: eventLog)
        if config.usesProcessAudio, let halBus {
            self.processAudio = ProcessAudioSignal(halBus: halBus, eventLog: eventLog)
        } else {
            self.processAudio = nil
        }
    }

    public func start(
        context: MeetingLifecycleContext,
        handle: LifecycleAdapterHandle,
        sink: @escaping (PrimarySignalEvent) -> Void
    ) throws {
        startedContext = context
        if let processAudio {
            processAudio.onChange = { value in
                sink(PrimarySignalEvent(
                    kind: .processAudioIsRunningInput,
                    state: value ? .live : .ended,
                    timestamp: Date(),
                    context: context
                ))
            }
        }
        shareableContent.onChange = { present in
            sink(PrimarySignalEvent(
                kind: .shareableContentWindow,
                state: present ? .live : .ended,
                timestamp: Date(),
                context: context
            ))
        }
        axLeaveButton.onChange = { state in
            sink(PrimarySignalEvent(
                kind: .axLeaveButton,
                state: state == .invalid ? .ended : .live,
                timestamp: Date(),
                context: context
            ))
        }
        if let processAudio {
            try processAudio.start(context: context)
        }
        shareableContent.start(context: context, titleMatch: config.titleMatch)
        // Start the Leave-button signal whenever we have a button OR a resolver. The
        // resolver lets the signal self-arm when the record-start walk missed the
        // button (Teams compact view exposes Mute but not Leave). Without this, a
        // missed Leave button left the meeting with only the window-gone backstop, so
        // the end went unseen until the user collapsed the Teams window (2026-06-12).
        // Browser / AX-denied handles carry neither, so the signal stays off there.
        if handle.leaveButton != nil || handle.resolveLeaveButton != nil {
            try axLeaveButton.start(
                context: context,
                leaveButton: handle.leaveButton,
                resolveElement: handle.resolveLeaveButton
            )
        }
    }

    public func armLeaveButton(_ element: AXUIElement) {
        guard let context = startedContext else { return }
        axLeaveButton.armIfNeeded(context: context, leaveButton: element)
    }

    public func stop() {
        processAudio?.stop()
        shareableContent.stop()
        axLeaveButton.stop()
        startedContext = nil
    }
}
