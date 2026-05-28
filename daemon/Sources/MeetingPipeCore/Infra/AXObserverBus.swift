import ApplicationServices
import Foundation

/// Single-owner registration point for Accessibility observers. Gives `MeetingLifecycleCoordinator` (Leave-button/title changes) and `MicGate` (Mute-button value/title changes) one registration path, one queue, one teardown. Each `subscribe` maps 1:1 to a backend `Token`; TECH-C13 specced per-PID coalescing but it was never built. Threading: all entry points serialised on `queue`; handlers dispatched on main so subscribers can touch AppKit/Coordinator state without a hop.
public final class AXObserverBus {

    /// Identifies a single AX subscription on a specific element + name.
    public struct Subscription {
        public let pid: pid_t
        public let notification: String

        public init(pid: pid_t, notification: String) {
            self.pid = pid
            self.notification = notification
        }
    }

    public protocol Backend: AnyObject {
        /// Returns a teardown closure; should throw on `AXObserverAddNotification` error so the bus can surface it to the caller's `EventLog`.
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

    /// Subscribe to an AX notification on a specific element. Handlers fire on main.
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

    /// Tear down all active observers. Called at shutdown and after each meeting so PIDs that quit don't leak observers.
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

/// Test/no-op backend: records no observer but returns a teardown so bus bookkeeping is identical to production.
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
