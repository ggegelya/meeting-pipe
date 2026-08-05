import ApplicationServices
import Foundation

/// Per-app config row for `NativeLifecycleAdapter`. Replaces the old per-app adapter classes.
public struct NativeLifecycleConfig {
    public let bundleIDs: Set<String>
    public let titleMatch: (String?) -> Bool
    /// TECH-END1 turned this off for every provider; DET8 turned it back on for Teams and Zoom
    /// on 2026-08-05. The signal had 0 successful reads in 19.8 days (13,419
    /// `process_audio_unresolved`, every OSStatus `noErr`, so the HAL answered and reported no
    /// process object rather than refusing), and DET2 measured on a real Mac against a live call
    /// that neither the Screen Recording grant, a live bare process tap, nor a private aggregate
    /// device changed that. The tap hypothesis stays refuted rather than untried. What DET2 got
    /// wrong is the conclusion: all three mechanisms asked about the `MSTeams` SHELL PID, the one
    /// the daemon detects, and the shell never registers as a CoreAudio client at all. Enumerating
    /// `kAudioHardwarePropertyProcessObjectList` instead (2026-07-30, no TCC grant) found
    /// `com.microsoft.teams2.modulehost`, the SlimCore media stack MIC8 proved owns the mic, and an
    /// owner-run live-call probe on 2026-08-05 returned GO: input true at the call's first event
    /// and false within 11.4 s of the leave, against a 60 s bar. `ProcessAudioSignal` now resolves
    /// by enumerate-and-match, and `processAudioIsRunningInput` carries `requiresCorroboration ==
    /// true` in `PromotionEngine`. Those two ship together: the flag is only safe to set here
    /// because a lone input drop cannot solo-confirm an end.
    ///
    /// Webex and Slack stay false, which is NOT a leftover from TECH-END1. Cisco holds the mic open
    /// post-call for ultrasound device discovery, so an input read there says nothing about whether
    /// the call is over, and that carve-out predates DET2. Neither was covered by the 2026-08-05
    /// probe either (Teams only), and `Coordinator` builds both without a `halBus`, which the
    /// initializer below requires for a true flag. Flipping either needs its own measurement first.
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
    /// ShareableContent + AXLeaveButton + ProcessAudio (re-enabled by DET8; the only provider its probe measured).
    static let teams = NativeLifecycleConfig(
        bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
        titleMatch: MeetingTitlePatterns.teams,
        usesProcessAudio: true
    )

    /// ShareableContent + AXLeaveButton + ProcessAudio (same set as Teams). Zoom was not covered by
    /// DET8's probe, so this rides on the resolver being provider-agnostic rather than on a
    /// measurement: it matches `us.zoom.xos*` by the same prefix rule, and no match simply resolves
    /// to unresolved and holds prior state, which is the pre-DET8 behaviour rather than a new risk.
    static let zoom = NativeLifecycleConfig(
        bundleIDs: ["us.zoom.xos"],
        titleMatch: MeetingTitlePatterns.zoom,
        usesProcessAudio: true
    )

    /// ShareableContent + AXLeaveButton. Covers legacy `com.cisco.webexmeetingsapp` and the unified
    /// Webex App (`com.cisco.spark`). ProcessAudio stays off: Cisco holds the mic open post-call for
    /// ultrasound device discovery, so an input read cannot say whether the call is over.
    static let webex = NativeLifecycleConfig(
        bundleIDs: ["com.cisco.webexmeetingsapp", "com.cisco.spark"],
        titleMatch: MeetingTitlePatterns.webex,
        usesProcessAudio: false
    )

    /// ShareableContent + AXLeaveButton for `com.tinyspeck.slackmacgap`. ProcessAudio stays off,
    /// unmeasured and grouped with Webex since TECH-END1.
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
