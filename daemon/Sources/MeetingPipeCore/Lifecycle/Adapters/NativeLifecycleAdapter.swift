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
    /// true` in `PromotionEngine`. Since END17 a lone input drop opens a hold and confirms only
    /// after `PromotionEngine.loneDwell` (12 min), never sooner, and a drop that comes back reverts
    /// it; that is what keeps the flag safe here.
    ///
    /// Webex and Slack stay false, which is NOT a leftover from TECH-END1. Cisco holds the mic open
    /// post-call for ultrasound device discovery, so an input read there says nothing about whether
    /// the call is over, and that carve-out predates DET2. Neither was covered by the 2026-08-05
    /// probe either (Teams only), and `Coordinator` builds both without a `halBus`, which the
    /// initializer below requires for a true flag. Flipping either needs its own measurement first.
    public let usesProcessAudio: Bool
    /// END24: when set, the window signal follows window identity rather than title vocabulary.
    /// `titleMatch` then only picks the call window at the first present reading (the matching
    /// windows this ranks lowest); afterwards the reading is whether a locked window still exists.
    /// END30 gave Zoom the same identity mode. Nil keeps the title rule (Webex, Slack: unmeasured,
    /// left as they were).
    public let windowLockRank: ((String?) -> Int)?
    /// END24 amendment: the rank from which a lock is weak, the fallback rank that admits windows
    /// other than the call window (Teams' main window at 2; for Zoom, whose rank has two levels,
    /// any window without "Zoom Meeting" at 1). A weak lock's present reading never contradicts the
    /// Leave button's edge or reverts a hold, because such a window can outlive the call.
    public let windowWeakLockRank: Int?

    public init(
        bundleIDs: Set<String>,
        titleMatch: @escaping (String?) -> Bool,
        usesProcessAudio: Bool,
        windowLockRank: ((String?) -> Int)? = nil,
        windowWeakLockRank: Int? = nil
    ) {
        self.bundleIDs = bundleIDs
        self.titleMatch = titleMatch
        self.usesProcessAudio = usesProcessAudio
        self.windowLockRank = windowLockRank
        self.windowWeakLockRank = windowWeakLockRank
    }
}

public extension NativeLifecycleConfig {
    /// ShareableContent + AXLeaveButton + ProcessAudio (re-enabled by DET8; the only provider its probe measured).
    /// END24: the window signal follows the call window's identity, picked once through the same
    /// recognizer the scanner uses, because Teams' titles stopped carrying any vocabulary token on
    /// 2026-10-08 and the end side read every call window gone from then on.
    static let teams = NativeLifecycleConfig(
        bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
        titleMatch: MeetingTitlePatterns.teamsWindow,
        usesProcessAudio: true,
        windowLockRank: MeetingTitlePatterns.teamsLockRank,
        windowWeakLockRank: 2
    )

    /// ShareableContent + AXLeaveButton + ProcessAudio (same set as Teams). Zoom was not covered by
    /// DET8's probe, so this rides on the resolver being provider-agnostic rather than on a
    /// measurement: it matches `us.zoom.xos*` by the same prefix rule, and no match simply resolves
    /// to unresolved and holds prior state, which is the pre-DET8 behaviour rather than a new risk.
    static let zoom = NativeLifecycleConfig(
        bundleIDs: ["us.zoom.xos"],
        titleMatch: MeetingTitlePatterns.zoomWindow,
        usesProcessAudio: true,
        windowLockRank: MeetingTitlePatterns.zoomLockRank,
        windowWeakLockRank: 1
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

    /// Whether this bundle's process audio is read at all, on either side of the meeting.
    ///
    /// DET12 gave the start-side scan a process-audio read and pointed it at this predicate rather
    /// than a second list, so the measured/unmeasured boundary is stated once. It answers false for
    /// anything with no native config, which is every browser and every Chromium PWA: a native app's
    /// helper process on the mic names the app, while a browser on the mic names only the browser and
    /// never which tab, so the read that is trustworthy for Teams is ambiguous for Chrome. Whether a
    /// browser tab may be admitted on any evidence at all is DET6's question and gated on its own
    /// measurement.
    static func usesProcessAudio(bundleID: String) -> Bool {
        all.first { $0.bundleIDs.contains(bundleID) }?.usesProcessAudio ?? false
    }
}

/// Single parameterized adapter for native meeting clients (Teams, Zoom, Webex, Slack). Per-app differences live in `NativeLifecycleConfig`.
public final class NativeLifecycleAdapter: LifecycleAdapter {

    public var bundleIDs: Set<String> { config.bundleIDs }
    public let kind: MeetingLifecycleContext.Kind = .native
    public var publishesProcessAudio: Bool { processAudio != nil }

    private let config: NativeLifecycleConfig
    private let processAudio: ProcessAudioSignal?
    private let shareableContent: ShareableContentSignal
    private let axLeaveButton: AXLeaveButtonSignal
    /// END17 (2026-11-13 amendment, G025): the app quit, the one definitive end signal. Before it
    /// only the browser adapter started one, so ADR 0017's "app quit ends at once" never held for a
    /// native app (0 of 381 field ends carried it).
    private let workspace: WorkspaceSignal

    /// Context captured at `start` so `armLeaveButton` emits under the same context the engine matches against.
    private var startedContext: MeetingLifecycleContext?

    /// `halBus` required when `config.usesProcessAudio` is true; ignored for Webex/Slack.
    public init(
        config: NativeLifecycleConfig,
        halBus: CoreAudioHALBus? = nil,
        axBus: AXObserverBus,
        eventLog: EventLog = NoopEventLog(),
        workspace: WorkspaceSignal? = nil
    ) {
        precondition(
            !config.usesProcessAudio || halBus != nil,
            "NativeLifecycleConfig.usesProcessAudio requires a halBus"
        )
        self.config = config
        self.shareableContent = ShareableContentSignal(eventLog: eventLog)
        self.axLeaveButton = AXLeaveButtonSignal(axBus: axBus, eventLog: eventLog)
        self.workspace = workspace ?? WorkspaceSignal(eventLog: eventLog)
        if config.usesProcessAudio, let halBus {
            self.processAudio = ProcessAudioSignal(halBus: halBus, eventLog: eventLog)
        } else {
            self.processAudio = nil
        }
    }

    /// END18: the same adapter over signals a test built, so the real `AXLeaveButtonSignal` and
    /// `ShareableContentSignal` (fake probes and schedulers) run under it end to end.
    init(
        config: NativeLifecycleConfig,
        processAudio: ProcessAudioSignal?,
        shareableContent: ShareableContentSignal,
        axLeaveButton: AXLeaveButtonSignal,
        workspace: WorkspaceSignal = WorkspaceSignal()
    ) {
        self.config = config
        self.processAudio = processAudio
        self.shareableContent = shareableContent
        self.axLeaveButton = axLeaveButton
        self.workspace = workspace
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
            processAudio.onUnknown = {
                sink(PrimarySignalEvent(
                    kind: .processAudioIsRunningInput,
                    state: .unknown,
                    timestamp: Date(),
                    context: context
                ))
            }
        }
        // The context's own bundle, matched exactly (`WorkspaceSignal`), never the config's family
        // or a prefix: a definitive end has no hold, so a helper exiting must not end the call.
        workspace.onTerminated = { endedContext in
            sink(PrimarySignalEvent(
                kind: .workspaceAppTerminated,
                state: .ended,
                timestamp: Date(),
                context: endedContext
            ))
        }
        workspace.start(context: context)
        // END24 amendment: `onReading` carries the lock's strength too (and fires on a relock);
        // a title-rule app reads never weak, as before.
        shareableContent.onReading = { present, weak in
            sink(PrimarySignalEvent(
                kind: .shareableContentWindow,
                state: present ? .live : .ended,
                timestamp: Date(),
                context: context,
                weak: present && weak
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
        shareableContent.start(
            context: context,
            lockRank: config.windowLockRank,
            weakLockRank: config.windowWeakLockRank,
            titleMatch: config.titleMatch
        )
        // Start the Leave-button signal whenever we have a button OR a resolver. The
        // resolver lets the signal self-arm when the record-start walk missed the
        // button (Teams compact view exposes Mute but not Leave). Without this, a
        // missed Leave button left the meeting with only the window-gone backstop, so
        // the end went unseen until the user collapsed the Teams window (2026-06-12).
        // Browser / AX-denied handles carry neither, so the signal stays off there.
        if handle.leaveButton != nil || handle.resolveLeaveButton != nil {
            axLeaveButton.start(
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

    public var callWindow: CallWindowRead? { axLeaveButton.callWindow }

    public func rescueLeaveButton(_ element: AXUIElement) {
        guard let context = startedContext else { return }
        axLeaveButton.reassertOrArm(context: context, leaveButton: element)
    }

    /// END22: the mic and the window re-read and report. The Leave button is event-driven and has
    /// no current value to re-send; its next AX notification or rescue reports it.
    public func refreshReadings() {
        processAudio?.refresh()
        shareableContent.refresh()
    }

    public func stop() {
        processAudio?.stop()
        shareableContent.stop()
        axLeaveButton.stop()
        workspace.stop()
        startedContext = nil
    }
}
