import ApplicationServices
import Foundation

/// AX mute-button probe. Wraps the meeting-app's mute-button
/// `AXUIElement` (resolved once by the executable's AX walk) and
/// emits `MuteLabels.State` transitions whenever the button's
/// `kAXValueChangedNotification` or `kAXTitleChangedNotification`
/// fires.
///
/// A 1 Hz health poll re-evaluates the button via
/// `AXUIElementCopyAttributeValue` to absorb Sequoia notification
/// drops; the poll also tolerates AX hiccups by treating an
/// unrecognised label as `.unknown` (the consumer keeps the prior
/// state).
///
/// Threading: `start` and `stop` must run on the main queue.
/// Notifications fire on main via `AXObserverBus`; the poll fires on
/// the scheduler's queue.
public final class AXMuteButtonProbe {

    public typealias Probe = (AXUIElement) -> AXTextBlob

    /// Tuple shape the recognise / label-extraction code wants. Keeps
    /// the AX scrape decoupled from the recogniser so the recogniser
    /// is testable without driving live AX.
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
    }

    public var onChange: ((Event) -> Void)?
    public private(set) var lastEvent: Event?

    public static let defaultPollInterval: TimeInterval = 1.0

    private let app: String
    private let axBus: AXObserverBus
    private let eventLog: EventLog
    private let catalogue: MuteLabels
    private let probe: Probe
    private let scheduler: Scheduler
    private let localeResolver: LocaleResolver
    private let pollInterval: TimeInterval

    private var element: AXUIElement?
    private var pid: pid_t = 0
    private var bundleID: String = ""
    private var tokens: [AXObserverBus.Token] = []
    private var cancelPoll: (() -> Void)?

    public init(
        app: String,
        axBus: AXObserverBus,
        catalogue: MuteLabels,
        eventLog: EventLog = NoopEventLog(),
        probe: @escaping Probe = AXMuteButtonProbe.defaultProbe,
        scheduler: @escaping Scheduler = AXMuteButtonProbe.defaultScheduler,
        localeResolver: @escaping LocaleResolver = AXMuteButtonProbe.defaultLocaleResolver,
        pollInterval: TimeInterval = AXMuteButtonProbe.defaultPollInterval
    ) {
        self.app = app
        self.axBus = axBus
        self.eventLog = eventLog
        self.catalogue = catalogue
        self.probe = probe
        self.scheduler = scheduler
        self.localeResolver = localeResolver
        self.pollInterval = pollInterval
    }

    public func start(
        pid: pid_t,
        bundleID: String,
        button: AXUIElement
    ) throws {
        stop()
        self.element = button
        self.pid = pid
        self.bundleID = bundleID
        for notification in [
            kAXValueChangedNotification,
            kAXTitleChangedNotification
        ] {
            let token = try axBus.subscribe(
                pid: pid, element: button, notification: notification as String
            ) { [weak self] in
                self?.evaluate(reason: "notification")
            }
            tokens.append(token)
        }
        cancelPoll = scheduler(pollInterval) { [weak self] in
            self?.evaluate(reason: "health_poll")
        }
        evaluate(reason: "initial")
    }

    public func stop() {
        for token in tokens { axBus.unsubscribe(token) }
        tokens.removeAll()
        cancelPoll?(); cancelPoll = nil
        element = nil
        pid = 0
        bundleID = ""
        lastEvent = nil
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
