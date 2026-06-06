import ApplicationServices
import Foundation

/// AX mute-button probe. Watches `kAXValueChangedNotification` and `kAXTitleChangedNotification` on the meeting app's mute `AXUIElement`. A 1 Hz health poll absorbs Sequoia notification drops; transient `.unknown` results latch the prior known state (see `evaluate` inline comment). Threading: `start`/`stop` on main; notifications fire on main via `AXObserverBus`; poll fires on the scheduler's queue.
public final class AXMuteButtonProbe {

    public typealias Probe = (AXUIElement) -> AXTextBlob

    /// AX attribute bundle passed to `recognize`; decouples the scrape from the recogniser for unit tests.
    public struct AXTextBlob: Equatable {
        public let title: String?
        public let help: String?
        public let description: String?

        public init(title: String? = nil, help: String? = nil, description: String? = nil) {
            self.title = title
            self.help = help
            self.description = description
        }
    }

    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void
    public typealias LocaleResolver = () -> String

    public struct Event: Equatable {
        public let state: MuteLabels.State
        public let label: String?
        public let locale: String

        /// Public so out-of-band producers (e.g. the mute-state poller) can build events for `MicGate.injectAxMuteEvent`.
        public init(state: MuteLabels.State, label: String?, locale: String) {
            self.state = state
            self.label = label
            self.locale = locale
        }
    }

    public var onChange: ((Event) -> Void)?
    public private(set) var lastEvent: Event?

    public static let defaultPollInterval: TimeInterval = 1.0
    /// TECH-PERF5: the backed-off health-poll rate used while the AX
    /// value/title notifications are delivering.
    public static let defaultSlowPollInterval: TimeInterval = 5.0
    /// TECH-MIC6: consecutive `.unknown` reads before the probe re-resolves its
    /// cached element via a fresh tree walk. At the ~1 Hz health-poll rate a
    /// stale element keeps (no notifications back the cadence off), so this is
    /// ~5 s of an unreadable control before a recovery attempt.
    public static let defaultRearmThreshold: Int = 5

    private let app: String
    private let axBus: AXObserverBus
    private let eventLog: EventLog
    private let catalogue: MuteLabels
    private let probe: Probe
    private let scheduler: Scheduler
    private let localeResolver: LocaleResolver
    private let pollInterval: TimeInterval
    private let slowPollInterval: TimeInterval
    private let rearmThreshold: Int

    private var element: AXUIElement?
    private var pid: pid_t = 0
    private var bundleID: String = ""
    private var tokens: [AXObserverBus.Token] = []
    private var cancelPoll: (() -> Void)?
    private var cadence: AdaptivePollCadence
    private var currentPollInterval: TimeInterval = 0
    /// Re-resolve the live mute button via a fresh tree walk; injected at `start`
    /// by the daemon (TECH-MIC6). Nil when the caller cannot re-walk (then the
    /// probe just keeps latching, the pre-MIC6 behaviour).
    private var resolveElement: (() -> AXUIElement?)?
    /// Consecutive `.unknown` reads since the last confident state.
    private var consecutiveUnknown: Int = 0

    public init(
        app: String,
        axBus: AXObserverBus,
        catalogue: MuteLabels,
        eventLog: EventLog = NoopEventLog(),
        probe: @escaping Probe = AXMuteButtonProbe.defaultProbe,
        scheduler: @escaping Scheduler = AXMuteButtonProbe.defaultScheduler,
        localeResolver: @escaping LocaleResolver = AXMuteButtonProbe.defaultLocaleResolver,
        pollInterval: TimeInterval = AXMuteButtonProbe.defaultPollInterval,
        slowPollInterval: TimeInterval = AXMuteButtonProbe.defaultSlowPollInterval,
        rearmThreshold: Int = AXMuteButtonProbe.defaultRearmThreshold
    ) {
        self.app = app
        self.axBus = axBus
        self.eventLog = eventLog
        self.catalogue = catalogue
        self.probe = probe
        self.scheduler = scheduler
        self.localeResolver = localeResolver
        self.pollInterval = pollInterval
        self.slowPollInterval = slowPollInterval
        self.rearmThreshold = max(1, rearmThreshold)
        self.cadence = AdaptivePollCadence(fast: pollInterval, slow: slowPollInterval)
    }

    public func start(
        pid: pid_t,
        bundleID: String,
        button: AXUIElement,
        resolveElement: (() -> AXUIElement?)? = nil
    ) throws {
        stop()
        self.element = button
        self.pid = pid
        self.bundleID = bundleID
        self.resolveElement = resolveElement
        self.consecutiveUnknown = 0
        for notification in [
            kAXValueChangedNotification,
            kAXTitleChangedNotification
        ] {
            let token = try axBus.subscribe(
                pid: pid, element: button, notification: notification as String
            ) { [weak self] in
                self?.cadence.noteListener()   // TECH-PERF5: notification is delivering
                self?.evaluate(reason: "notification")
            }
            tokens.append(token)
        }
        cadence = AdaptivePollCadence(fast: pollInterval, slow: slowPollInterval)
        startPoll(interval: cadence.initialInterval)
        evaluate(reason: "initial")
    }

    /// Arm (or re-arm) the health poll at `interval`, backing the rate off while
    /// the AX value/title notifications are delivering and speeding back up once
    /// they go quiet (TECH-PERF5). Re-armed only from the poll callback's thread.
    private func startPoll(interval: TimeInterval) {
        cancelPoll?()
        currentPollInterval = interval
        cancelPoll = scheduler(interval) { [weak self] in
            guard let self = self else { return }
            self.evaluate(reason: "health_poll")
            let next = self.cadence.intervalAfterPoll()
            if next != self.currentPollInterval {
                self.startPoll(interval: next)
            }
        }
    }

    public func stop() {
        for token in tokens { axBus.unsubscribe(token) }
        tokens.removeAll()
        cancelPoll?(); cancelPoll = nil
        currentPollInterval = 0
        element = nil
        pid = 0
        bundleID = ""
        lastEvent = nil
        resolveElement = nil
        consecutiveUnknown = 0
    }

    func evaluate(reason: String) {
        guard let element = element else { return }
        let blob = probe(element)
        let locale = localeResolver()
        let state = catalogue.recognize(
            app: app, locale: locale,
            title: blob.title, help: blob.help, description: blob.description
        )
        let label = labelFromBlob(blob)
        let event = Event(state: state, label: label, locale: locale)

        // TECH-MIC6: a cached element that goes stale (Teams 2 re-render, compact
        // view, "Mic is not available") reads `.unknown` forever. Count the
        // streak and, past the threshold, re-resolve via a fresh tree walk so the
        // read recovers instead of latching the prior state until the call ends.
        // The latch below still holds the prior state across the streak; the
        // re-arm just retargets the element it reads.
        if state == .unknown {
            noteUnknownAndMaybeRearm(reason: reason)
        } else {
            consecutiveUnknown = 0
        }

        if event == lastEvent { return }

        // Suppress transient `.unknown` once a real state was
        // observed. Teams 2 shows "Mic is not available" on its
        // mute button during call setup, then briefly returns nil
        // for the title; both decode to `.unknown` and the original
        // code propagated those to MicGate. Clearing `axMute` made
        // the verdict fall through to VAD / RMS for ~90 s while the
        // user was actually muted in Teams, leaking their voice
        // into the recording. Latching the prior known state keeps
        // `mutedByApp` in place across the glitch; the next real
        // `.muted` or `.unmuted` event resumes normal flow.
        if state == .unknown, let prev = lastEvent, prev.state != .unknown {
            eventLog.emit(category: "micgate", action: "ax_mute_button_state_kept", attributes: [
                "bundle_id": bundleID,
                "pid": Int(pid),
                "app": app,
                "locale": locale,
                "reason": reason,
                "kept_state": prev.state == .muted ? "muted" : "unmuted",
                "transient_label": label as Any
            ])
            return
        }

        let previous = lastEvent
        lastEvent = event
        eventLog.emit(category: "micgate", action: "ax_mute_button_state", attributes: [
            "bundle_id": bundleID,
            "pid": Int(pid),
            "app": app,
            "locale": locale,
            "state": state == .muted ? "muted" : (state == .unmuted ? "unmuted" : "unknown"),
            "label": label as Any,
            "reason": reason,
            "previous": previous.map { "\($0.state) / \($0.label as Any)" } as Any
        ])
        onChange?(event)
    }

    /// Count the `.unknown` streak and, once it crosses `rearmThreshold`,
    /// re-resolve the cached element via the injected fresh-tree-walk resolver
    /// (TECH-MIC6). The element is swapped so the next read targets the live
    /// control; the value/title notifications are deliberately NOT re-subscribed
    /// (RealAXBackend caches one AXObserver per pid and re-registering proved
    /// fragile, see `MeetingAXWindowWatcher`), so the health poll reads the fresh
    /// element and the window watcher remains the independent backstop. The
    /// counter resets each attempt so re-resolution is throttled to one walk per
    /// `rearmThreshold` polls rather than every poll.
    private func noteUnknownAndMaybeRearm(reason: String) {
        consecutiveUnknown += 1
        guard consecutiveUnknown >= rearmThreshold, let resolve = resolveElement else { return }
        consecutiveUnknown = 0
        guard let fresh = resolve() else { return }
        element = fresh
        eventLog.emit(category: "micgate", action: "ax_mute_button_rearmed", attributes: [
            "bundle_id": bundleID,
            "pid": Int(pid),
            "app": app,
            "reason": reason,
        ])
    }

    private func labelFromBlob(_ blob: AXTextBlob) -> String? {
        if let title = blob.title, !title.isEmpty { return title }
        if let help = blob.help, !help.isEmpty { return help }
        if let description = blob.description, !description.isEmpty { return description }
        return nil
    }

    // MARK: - Default seams

    public static let defaultScheduler: Scheduler = { interval, action in
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            action()
        }
        return { timer.invalidate() }
    }

    public static let defaultLocaleResolver: LocaleResolver = {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    public static let defaultProbe: Probe = { element in
        AXTextBlob(
            title: copyStringAttribute(element, kAXTitleAttribute),
            help: copyStringAttribute(element, kAXHelpAttribute),
            description: copyStringAttribute(element, kAXDescriptionAttribute)
        )
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard status == .success else { return nil }
        return ref as? String
    }
}
