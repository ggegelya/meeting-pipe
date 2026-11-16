import Foundation

/// END16: when a log source's outage is worth an event row. Pure; the hosts (`CallTeardownWatcher`,
/// `LogMuteAdapter`) own the clock and the `EventLog`.
///
/// Both hosts used to promise one row per outage and deliver one per flap: the success path cleared
/// the "reported" flag on every good tick, so a listing that failed about once a minute for 26 days
/// wrote 16,861 `call_teardown_source_missing` rows (14.7 percent of the event log) and 649
/// `log_mute_source_missing`. Here a cause is reported at most once per `interval`, the failures
/// suppressed in between ride on the next row's count, and the first success after an outage whose
/// row was written reports the outage's length. An outage inside the hour whose missing row was
/// suppressed gets no recovered row; its failed ticks are counted into the next missing row. Kept outside each host's per-session reset (stop
/// and start), so a recording boundary does not reopen the hour.
public struct SourceOutageReport: Equatable, Sendable {

    public static let defaultInterval: TimeInterval = 3600

    public struct Missing: Equatable, Sendable {
        public let cause: String
        /// Failed ticks since the previous missing row, this one included.
        public let failures: Int
    }

    public struct Recovered: Equatable, Sendable {
        public let outageSec: TimeInterval
        /// Failed ticks in the outage just ended.
        public let failures: Int
    }

    public let interval: TimeInterval
    private var lastRowAt: [String: Date] = [:]
    private var failuresSinceRow = 0
    private var outageStartedAt: Date?
    private var outageFailures = 0
    private var outageReported = false

    public init(interval: TimeInterval = SourceOutageReport.defaultInterval) {
        self.interval = interval
    }

    /// A failed tick. Returns the row to emit, or nil while this cause is inside its interval.
    public mutating func failure(cause: String, at now: Date) -> Missing? {
        if outageStartedAt == nil {
            outageStartedAt = now
            outageFailures = 0
        }
        outageFailures += 1
        failuresSinceRow += 1
        if let last = lastRowAt[cause], now.timeIntervalSince(last) < interval { return nil }
        lastRowAt[cause] = now
        outageReported = true
        defer { failuresSinceRow = 0 }
        return Missing(cause: cause, failures: failuresSinceRow)
    }

    /// A good tick. Returns the recovered row when it ends an outage whose missing row was written.
    public mutating func success(at now: Date) -> Recovered? {
        guard let started = outageStartedAt else { return nil }
        defer {
            outageStartedAt = nil
            outageFailures = 0
            outageReported = false
        }
        guard outageReported else { return nil }
        return Recovered(outageSec: now.timeIntervalSince(started), failures: outageFailures)
    }
}
