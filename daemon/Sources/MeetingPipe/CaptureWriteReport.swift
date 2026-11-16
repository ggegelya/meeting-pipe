import Foundation

/// REC22: what a recording's capture writers did, said once at stop: every failed write per
/// channel (the streaks REC3 escalates on and the scattered ones it never saw) and REC25's backlog
/// high-water mark, in bytes and in seconds of that channel's audio.
///
/// Pure, so the `stopping:` fields and the `capture_write_failures` event are pinned without a
/// recorder. Built after the writers drained; a drain that wedged leaves the writer queue owning
/// its tracker, so the counts are unknown rather than read mid-write.
struct CaptureWriteReport: Equatable {

    struct ChannelFailures: Equatable {
        let failures: Int
        let first: WriteFailureTracker.FailureCode?

        /// One channel's writers summed: a system file opened fresh mid-recording has a writer of
        /// its own, and the recording's total is all of them. The first failure is the earliest
        /// writer's.
        init(_ trackers: [WriteFailureTracker]) {
            failures = trackers.reduce(0) { $0 + $1.totalFailures }
            first = trackers.lazy.compactMap(\.firstFailure).first
        }

        init(failures: Int, first: WriteFailureTracker.FailureCode?) {
            self.failures = failures
            self.first = first
        }
    }

    /// Nil when the drain wedged (`write_failures=unknown`).
    let mic: ChannelFailures?
    let system: ChannelFailures?
    let micBacklogPeakBytes: Int
    let systemBacklogPeakBytes: Int
    let micBacklogPeakSec: Double
    let systemBacklogPeakSec: Double

    static func make(
        writerWedged: Bool,
        mic: [WriteFailureTracker],
        system: [WriteFailureTracker],
        micBacklogPeakBytes: Int,
        systemBacklogPeakBytes: Int,
        micBytesPerSecond: Double,
        systemBytesPerSecond: Double
    ) -> CaptureWriteReport {
        CaptureWriteReport(
            mic: writerWedged ? nil : ChannelFailures(mic),
            system: writerWedged ? nil : ChannelFailures(system),
            micBacklogPeakBytes: micBacklogPeakBytes,
            systemBacklogPeakBytes: systemBacklogPeakBytes,
            micBacklogPeakSec: seconds(micBacklogPeakBytes, at: micBytesPerSecond),
            systemBacklogPeakSec: seconds(systemBacklogPeakBytes, at: systemBytesPerSecond)
        )
    }

    private static func seconds(_ bytes: Int, at rate: Double) -> Double {
        guard rate > 0 else { return 0 }
        return (Double(bytes) / rate * 10).rounded() / 10
    }

    /// The tail of the `stopping:` line.
    var stoppingFields: String {
        var fields = String(
            format: "mic_backlog_peak_bytes=%d system_backlog_peak_bytes=%d mic_backlog_peak_sec=%.1f system_backlog_peak_sec=%.1f",
            micBacklogPeakBytes, systemBacklogPeakBytes, micBacklogPeakSec, systemBacklogPeakSec
        )
        if let mic, let system {
            fields += " mic_write_failures=\(mic.failures) system_write_failures=\(system.failures)"
        } else {
            fields += " write_failures=unknown (writer wedged)"
        }
        return fields
    }

    /// The `recorder`/`capture_write_failures` attributes, or nil when there is nothing to report:
    /// no failed write on either channel, or counts that are unknown because a drain wedged.
    var event: [String: Any]? {
        guard let mic, let system, mic.failures + system.failures > 0 else { return nil }
        return [
            "mic_write_failures": mic.failures,
            "system_write_failures": system.failures,
            "mic_first_domain": mic.first?.domain as Any,
            "mic_first_code": mic.first?.code as Any,
            "system_first_domain": system.first?.domain as Any,
            "system_first_code": system.first?.code as Any,
        ]
    }
}
