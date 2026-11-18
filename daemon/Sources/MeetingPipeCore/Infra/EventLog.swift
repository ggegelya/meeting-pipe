import Foundation

/// Structured-event sink for the lifecycle + gate subsystems. `MeetingPipeCore` can't call `Log.event` directly (no link to the executable target); the executable wires a concrete implementation at `MeetingLifecycleCoordinator` construction time and tests pass `RecordingEventLog`. Attribute values must be JSON-serialisable (String, Bool, Int, Double, Array, Dictionary, NSNull); the forwarder (`Log.event`) coerces anything else to its string form, and a non-finite number to null, rather than dropping the event (PERF13).
public protocol EventLog: AnyObject {
    func emit(category: String, action: String, attributes: [String: Any])
    /// OBS9: a high-volume diagnostic row (HAL subscribe churn, process-audio resolution, a
    /// teardown source missing). The daemon writes it to `diagnostics.jsonl`, so it cannot rotate
    /// lifecycle rows out of `events.jsonl`. A sink with no second family records it as `emit`.
    func emitDiagnostic(category: String, action: String, attributes: [String: Any])
}

extension EventLog {
    public func emitDiagnostic(category: String, action: String, attributes: [String: Any]) {
        emit(category: category, action: action, attributes: attributes)
    }
}

/// No-op sink for early init and tests that don't assert events.
public final class NoopEventLog: EventLog {
    public init() {}
    public func emit(category: String, action: String, attributes: [String: Any]) {}
}

/// Thread-safe in-memory recorder for tests that assert lifecycle/gate events.
///
/// It ships in Core, a production target, on purpose: both test targets use it
/// (`MeetingPipeCoreTests` throughout the signal and gate suites, `MeetingPipeTests`
/// in `MeetingAXWindowWatcherTests`), and two SPM test targets cannot share a source
/// file. Moving it into one tree would mean either a copy that drifts or a third
/// target existing only to hold this class. It is a deliberate cross-target test
/// seam, not something a dead-code sweep should reclaim.
public final class RecordingEventLog: EventLog {
    public struct Entry: Equatable {
        public let category: String
        public let action: String
        public let attributes: [String: String]
    }

    private let lock = NSLock()
    private var buffer: [Entry] = []
    private var diagnosticBuffer: [String] = []

    public init() {}

    /// Recorded in `entries` like any row, and its action also in `diagnosticActions`, so a test can
    /// tell which family a row was routed to (OBS9).
    public func emitDiagnostic(category: String, action: String, attributes: [String: Any]) {
        emit(category: category, action: action, attributes: attributes)
        lock.lock()
        diagnosticBuffer.append(action)
        lock.unlock()
    }

    /// The actions that went through `emitDiagnostic`, in order.
    public var diagnosticActions: [String] {
        lock.lock()
        defer { lock.unlock() }
        return diagnosticBuffer
    }

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
        diagnosticBuffer.removeAll()
        lock.unlock()
    }
}
