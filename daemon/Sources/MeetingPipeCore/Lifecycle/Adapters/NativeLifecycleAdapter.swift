import ApplicationServices
import Foundation

/// Per-app config row for `NativeLifecycleAdapter`. Replaces the old per-app adapter classes.
public struct NativeLifecycleConfig {
    public let bundleIDs: Set<String>
    public let titleMatch: (String?) -> Bool
    /// TECH-END1: false for every provider now. The `kAudioProcessPropertyIsRunningInput`
    /// signal needs the PID-to-HAL-process-object translation, which returns object 0 under
    /// our capture model: we capture system audio via ScreenCaptureKit, hold no audio-tap
    /// authorization, and never create a Core Audio process tap, so the HAL process-object
    /// list is empty for us and no PID ever resolves. It produced 0 successful reads in
    /// 19.8 days (13,407 `process_audio_unresolved`). Kept as a flag + wired machinery so
    /// the signal can be revived if we ever adopt a process tap; until then it stays false,
    /// which also stops the per-run unresolved log spam by never constructing the signal.
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
        if let leaveButton = handle.leaveButton {
            try axLeaveButton.start(
                context: context,
                leaveButton: leaveButton,
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
