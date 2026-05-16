import Foundation

/// Structured-event sink for the lifecycle + gate subsystems.
///
/// `MeetingPipeCore` doesn't link against the executable target's
/// `Logger.swift`, so it can't call `Log.event` directly. The executable
/// wires a concrete implementation that forwards to `Log.event` at
/// `MeetingLifecycleCoordinator` construction time; tests pass an
/// in-memory recorder.
///
/// Attribute values follow the same contract as `Log.event`: must be
/// JSON-serialisable (String, Bool, Int, Double, Array, Dictionary, or
/// NSNull). The forwarder is responsible for dropping non-serialisable
/// entries silently rather than crashing the daemon.
public protocol EventLog: AnyObject {
    func emit(category: String, action: String, attributes: [String: Any])
}

/// No-op sink used when an `EventLog` is not wired (early init, tests
/// that don't care about telemetry).
public final class NoopEventLog: EventLog {
    public init() {}
    public func emit(category: String, action: String, attributes: [String: Any]) {}
}

/// Records every emit into a thread-safe buffer. Tests use this to
/// assert that the lifecycle coordinator logs the expected events.
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
