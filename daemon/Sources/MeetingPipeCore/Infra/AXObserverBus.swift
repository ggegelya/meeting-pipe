import ApplicationServices
import Foundation

/// Single-owner registration point for Accessibility observers.
///
/// `MeetingLifecycleCoordinator` (Leave-button destruction notifications,
/// title changes) and `MicGate` (Mute-button value + title changes) both
/// need to observe AX notifications on the meeting-app process. The bus
/// caches one `AXObserver` per PID and multiplexes notification handlers
/// off of it so a single AX-tree walk satisfies both consumers, per the
/// "AX tree walked exactly once per meeting" requirement in TECH-C13.
///
/// The skeleton lands in TECH-C13 step 1. Real registration via
/// `AXObserverAddNotification` is wired in step 2 alongside the
/// `AXLeaveButtonSignal`. For now the bus only owns the bookkeeping and
/// the test seam; the default `NoopAXBackend` records no observer but
/// returns a teardown so the bus's accounting matches production.
///
/// Threading: every entry point is serialised on `queue`. Handlers are
/// dispatched on the main queue so subscribers can touch AppKit /
/// `Coordinator` state without a hop.
public final class AXObserverBus {

    /// Identifies a single AX subscription on a specific element + name.
    public struct Subscription: Hashable {
        public let pid: pid_t
        public let notification: String

        public init(pid: pid_t, notification: String) {
            self.pid = pid
            self.notification = notification
        }
    }

    public protocol Backend: AnyObject {
        /// Returns a teardown closure that the bus stores against the
        /// subscription token. Implementations should fail loud if
        /// `AXObserverAddNotification` errors (the bus surfaces the
        /// error to the caller's `EventLog`).
        func register(
            pid: pid_t,
            element: AXUIElement,
            notification: String,
            handler: @escaping () -> Void
        ) throws -> () -> Void
    }

    public struct Token: Hashable {
        fileprivate let id: UInt64
    }

    public enum BusError: Error, LocalizedError {
        case backendFailed(AXError)

        public var errorDescription: String? {
            switch self {
            case .backendFailed(let err):
                return "AXObserverBus backend registration failed (AXError=\(err.rawValue))"
            }
        }
    }

    private struct Entry {
        let subscription: Subscription
        let teardown: () -> Void
    }

    private let backend: Backend
    private let eventLog: EventLog
    private let queue = DispatchQueue(label: "MeetingPipeCore.AXObserverBus")
    private var entries: [Token: Entry] = [:]
    private var nextID: UInt64 = 0

    public init(backend: Backend = NoopAXBackend(), eventLog: EventLog = NoopEventLog()) {
        self.backend = backend
        self.eventLog = eventLog
    }

    /// Subscribe to an AX notification on a specific element. Handlers
    /// fire on the main queue; callers can synchronously touch
    /// Coordinator state without an extra hop.
    public func subscribe(
        pid: pid_t,
        element: AXUIElement,
        notification: String,
        handler: @escaping () -> Void
    ) throws -> Token {
        let token = try queue.sync { () throws -> Token in
            let teardown = try backend.register(
                pid: pid,
                element: element,
                notification: notification,
                handler: {
                    DispatchQueue.main.async(execute: handler)
                }
            )
            nextID += 1
            let token = Token(id: nextID)
            entries[token] = Entry(
                subscription: Subscription(pid: pid, notification: notification),
                teardown: teardown
            )
            return token
        }
        eventLog.emit(category: "axbus", action: "subscribed", attributes: [
            "pid": Int(pid),
            "notification": notification
        ])
        return token
    }

    public func unsubscribe(_ token: Token) {
        queue.sync {
            guard let entry = entries.removeValue(forKey: token) else { return }
            entry.teardown()
            eventLog.emit(category: "axbus", action: "unsubscribed", attributes: [
                "pid": Int(entry.subscription.pid),
                "notification": entry.subscription.notification
            ])
        }
    }

    /// Tear down every active observer. Called at daemon shutdown and
    /// after each meeting ends so PIDs that quit don't leak observers.
    public func reset() {
        queue.sync {
            for entry in entries.values { entry.teardown() }
            entries.removeAll()
        }
    }

    public var activeSubscriptionCount: Int {
        queue.sync { entries.count }
    }
}

/// Default backend used until the real AX wiring lands. Records no
/// observer but returns a teardown so the bus's bookkeeping behaves
/// identically to production. Step 2 (TECH-C13) replaces this with a
/// real `AXObserverAddNotification` backend that caches one observer
/// per PID and multiplexes handlers off of it.
public final class NoopAXBackend: AXObserverBus.Backend {
    public init() {}

    public func register(
        pid: pid_t,
        element: AXUIElement,
        notification: String,
        handler: @escaping () -> Void
    ) throws -> () -> Void {
        return {}
    }
}
