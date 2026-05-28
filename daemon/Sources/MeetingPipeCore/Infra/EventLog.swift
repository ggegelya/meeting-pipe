import Foundation

/// Structured-event sink for the lifecycle + gate subsystems. `MeetingPipeCore` can't call `Log.event` directly (no link to the executable target); the executable wires a concrete implementation at `MeetingLifecycleCoordinator` construction time and tests pass `RecordingEventLog`. Attribute values must be JSON-serialisable (String, Bool, Int, Double, Array, Dictionary, NSNull); the forwarder drops non-serialisable entries silently.
public protocol EventLog: AnyObject {
    func emit(category: String, action: String, attributes: [String: Any])
}

/// No-op sink for early init and tests that don't assert events.
public final class NoopEventLog: EventLog {
    public init() {}
    public func emit(category: String, action: String, attributes: [String: Any]) {}
}

/// Thread-safe in-memory recorder for tests that assert lifecycle/gate events.
public final class RecordingEventLog: EventLog {
    public struct Entry: Equatable {
        public let category: String
        public let action: String
        public let attributes: [String: String]
    }

    private let lock = NSLock()
    private var buffer: [Entry] = []

    public init() {}

    public func emit(category: String, action: String, attributes: [String: Any]) {
        let stringified = attributes.reduce(into: [String: String]()) { acc, pair in
            acc[pair.key] = String(describing: pair.value)
        }
        lock.lock()
        buffer.append(Entry(category: category, action: action, attributes: stringified))
        lock.unlock()
    }

    public var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    public func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }
}
