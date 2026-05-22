import ApplicationServices
import Foundation

/// One native (non-browser) meeting client described as data, for
/// `NativeLifecycleAdapter`. Collapses what used to be a separate
/// per-app adapter class (Teams / Zoom / Webex / Slack) into a row.
public struct NativeLifecycleConfig {
    public let bundleIDs: Set<String>
    public let titleMatch: (String?) -> Bool
    /// Teams and Zoom fuse process-input audio as a PRIMARY signal.
    /// Webex and Slack deliberately do not: Cisco documents that Webex
    /// holds the microphone open after a call for ultrasound device
    /// discovery, which would read as a false `process_audio = live`.
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
    /// Teams 2.x: ShareableContent + ProcessAudio + AXLeaveButton.
    static let teams = NativeLifecycleConfig(
        bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
        titleMatch: MeetingTitlePatterns.teams,
        usesProcessAudio: true
    )

    /// Zoom: same PRIMARY set as Teams.
    static let zoom = NativeLifecycleConfig(
        bundleIDs: ["us.zoom.xos"],
        titleMatch: MeetingTitlePatterns.zoom,
        usesProcessAudio: true
    )

    /// Webex: ShareableContent + AXLeaveButton only. Covers the legacy
    /// `com.cisco.webexmeetingsapp` and the unified Webex App
    /// (`com.cisco.spark`).
    static let webex = NativeLifecycleConfig(
        bundleIDs: ["com.cisco.webexmeetingsapp", "com.cisco.spark"],
        titleMatch: MeetingTitlePatterns.webex,
        usesProcessAudio: false
    )

    /// Slack huddles, native `com.tinyspeck.slackmacgap`:
    /// ShareableContent + AXLeaveButton only.
    static let slack = NativeLifecycleConfig(
        bundleIDs: ["com.tinyspeck.slackmacgap"],
        titleMatch: MeetingTitlePatterns.slackHuddle,
        usesProcessAudio: false
    )
}

/// Lifecycle adapter for native meeting clients. One parameterized
/// class in place of the byte-identical Teams / Zoom / Webex / Slack
/// adapters; the per-app differences live in `NativeLifecycleConfig`.
/// The browser path keeps its own `BrowserMeetingLifecycleAdapter`
/// (diverged signal fusion + PWA handling).
public final class NativeLifecycleAdapter: LifecycleAdapter {

    public var bundleIDs: Set<String> { config.bundleIDs }
    public let kind: MeetingLifecycleContext.Kind = .native

    private let config: NativeLifecycleConfig
    private let processAudio: ProcessAudioSignal?
    private let shareableContent: ShareableContentSignal
    private let axLeaveButton: AXLeaveButtonSignal

    /// Context captured at `start`. `armLeaveButton` reuses it so the
    /// late-armed signal emits events under the same context the
    /// promotion engine matches against.
    private var startedContext: MeetingLifecycleContext?

    /// `halBus` is required when `config.usesProcessAudio` is true and
    /// ignored otherwise (Webex / Slack do not fuse process audio).
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
        if let leaveButton = handle.leaveButton {
            try axLeaveButton.start(context: context, leaveButton: leaveButton)
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
