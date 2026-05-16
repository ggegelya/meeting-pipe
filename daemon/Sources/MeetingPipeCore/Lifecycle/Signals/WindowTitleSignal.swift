import ApplicationServices
import Foundation

/// Corroborating signal: AX title-change on a meeting window.
///
/// Subscribes via `AXObserverBus` to `kAXTitleChangedNotification` on
/// a window element the adapter resolves at meeting start. Used to
/// catch title transitions that signal the meeting has moved to a
/// post-call surface, e.g. Google Meet leaving the `Meet · <code>`
/// pattern, Teams leaving the localised "Meeting" / "Reunión" / …
/// label set.
///
/// The signal does not interpret the title - it forwards every
/// non-empty change to the consumer plus an event log line. The
/// adapter's title regex decides whether the new title is still
/// "in meeting".
///
/// Threading: `start` and `stop` must run on the main queue. The
/// notification handler is dispatched on main by `AXObserverBus`.
public final class WindowTitleSignal {

    public typealias Probe = (AXUIElement) -> String?

    public var onChange: ((String) -> Void)?
    public private(set) var lastTitle: String?

    private let axBus: AXObserverBus
    private let eventLog: EventLog
    private let probe: Probe

    private var token: AXObserverBus.Token?
    private var window: AXUIElement?
    private var context: MeetingLifecycleContext?

    public init(
        axBus: AXObserverBus,
        eventLog: EventLog = NoopEventLog(),
        probe: @escaping Probe = WindowTitleSignal.defaultProbe
    ) {
        self.axBus = axBus
        self.eventLog = eventLog
        self.probe = probe
    }

    public func start(context: MeetingLifecycleContext, window: AXUIElement) throws {
        stop()
        self.context = context
        self.window = window
        token = try axBus.subscribe(
            pid: context.pid,
            element: window,
            notification: kAXTitleChangedNotification as String
        ) { [weak self] in
            self?.evaluate(reason: "title_changed_notification")
        }
        evaluate(reason: "initial")
    }

    public func stop() {
        if let token = token { axBus.unsubscribe(token); self.token = nil }
        window = nil
        context = nil
        lastTitle = nil
    }

    func evaluate(reason: String) {
        guard let context = context, let window = window else { return }
        let title = probe(window)
        if title == lastTitle { return }
        let previous = lastTitle
        lastTitle = title
        eventLog.emit(category: "signal", action: "window_title_changed", attributes: [
            "bundle_id": context.bundleID,
            "title": title as Any,
            "previous": previous as Any,
            "reason": reason
        ])
        if let title = title { onChange?(title) }
    }

    public static let defaultProbe: Probe = { element in
        var ref: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref)
        guard status == .success else { return nil }
        return ref as? String
    }
}
