import Darwin
import Foundation
import os

/// REC20 item 3: what one transcription costs in memory, measured rather than estimated.
///
/// Transcription runs inside the daemon, the process that records, and back-to-back meetings mean
/// meeting N transcribes while meeting N+1 records. Nothing in the daemon read its own footprint
/// before this, so the "about 2 GB peak for a 3 h recording" on the watch list was arithmetic. One
/// probe brackets one `FluidAudioRunner.transcribe`: it reads `phys_footprint` (the figure Activity
/// Monitor's Memory column and jetsam both use) at the start, samples it four times a second on a
/// utility queue for the peak, and emits one `transcription` / `transcription_memory` row at the
/// end. Fifteen minutes after the last job it emits one more (`phase: "idle"`), which is what
/// says whether the models `FluidAudioRunner` keeps resident for the daemon's lifetime cost
/// anything once the job is over (REC20's amendment, item 3).
///
/// The sampler can miss a spike shorter than its interval, so `lifetime_peak_bytes`
/// (`ledger_phys_footprint_peak`, the kernel's own high-water mark for the process) rides along:
/// a job whose sampled peak sits well under a lifetime peak that moved during it had a spike the
/// sampler did not see.
final class TranscriptionMemoryProbe {

    struct Reading: Equatable, Sendable {
        /// `task_vm_info.phys_footprint`.
        let footprint: UInt64
        /// `task_vm_info.ledger_phys_footprint_peak`, the process's high-water mark.
        let lifetimePeak: UInt64
    }

    /// Minutes after the last job at which the idle reading is taken.
    static let idleMinutes: Double = 15
    static let sampleIntervalSeconds: Double = 0.25

    private let read: @Sendable () -> Reading?
    private let emit: (String, [String: Any]) -> Void
    private let idleDelaySeconds: Double?
    private let physicalMemory: UInt64
    private let start: Reading?
    private let peak: OSAllocatedUnfairLock<UInt64>
    private var timer: DispatchSourceTimer?
    private var finished = false

    /// The one pending idle reading, replaced by every job so only the last job's fires.
    private static let pendingIdle = OSAllocatedUnfairLock<DispatchWorkItem?>(initialState: nil)

    /// The defaults are production's. Tests inject a scripted reader and an event sink, and pass
    /// `idleDelaySeconds: nil` (or a short delay) so nothing lands in the real event log.
    init(
        read: @escaping @Sendable () -> Reading? = TranscriptionMemoryProbe.currentReading,
        emit: @escaping (String, [String: Any]) -> Void = { action, attributes in
            Log.event(category: "transcription", action: action, attributes: attributes)
        },
        sampleInterval: Double = TranscriptionMemoryProbe.sampleIntervalSeconds,
        idleDelaySeconds: Double? = TranscriptionMemoryProbe.idleMinutes * 60,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        startsSampler: Bool = true
    ) {
        self.read = read
        self.emit = emit
        self.idleDelaySeconds = idleDelaySeconds
        self.physicalMemory = physicalMemory
        let start = read()
        self.start = start
        let peak = OSAllocatedUnfairLock<UInt64>(initialState: start?.footprint ?? 0)
        self.peak = peak
        // A job starting cancels the previous job's idle reading: the process is not idle.
        Self.pendingIdle.withLock { $0?.cancel(); $0 = nil }
        guard startsSampler else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + sampleInterval, repeating: sampleInterval, leeway: .milliseconds(50))
        timer.setEventHandler {
            guard let footprint = read()?.footprint else { return }
            peak.withLock { $0 = max($0, footprint) }
        }
        self.timer = timer
        timer.resume()
    }

    /// Take one sample now. The sampler's tick, callable by a test.
    func sample() {
        guard let footprint = read()?.footprint else { return }
        peak.withLock { $0 = max($0, footprint) }
    }

    /// Stop sampling, emit the job's row, and arm the idle reading. Once per probe; `audioSec` is
    /// nil when the job failed before its audio was read. Returns the attributes it emitted, or
    /// nil when no reading could be taken at all.
    @discardableResult
    func finish(audioSec: Double?) -> [String: Any]? {
        guard !finished else { return nil }
        finished = true
        timer?.cancel()
        timer = nil
        let end = read()
        if let footprint = end?.footprint { peak.withLock { $0 = max($0, footprint) } }
        defer { scheduleIdleReading() }
        guard let start = start, let end = end else { return nil }
        let peakBytes = peak.withLock { $0 }
        let attributes: [String: Any] = [
            "phase": "job",
            "audio_sec": audioSec.map { ($0 * 10).rounded() / 10 } as Any,
            "footprint_start_bytes": start.footprint,
            "footprint_peak_bytes": peakBytes,
            "footprint_end_bytes": end.footprint,
            "lifetime_peak_bytes": end.lifetimePeak,
            "physical_memory_bytes": physicalMemory,
            "peak_fraction": Self.fraction(peakBytes, of: physicalMemory),
        ]
        emit("transcription_memory", attributes)
        return attributes
    }

    /// Peak as a share of physical memory, to three places. REC20 states the threshold the
    /// follow-up decision reads against: 0.25.
    static func fraction(_ bytes: UInt64, of physical: UInt64) -> Double {
        guard physical > 0 else { return 0 }
        return (Double(bytes) / Double(physical) * 1000).rounded() / 1000
    }

    private func scheduleIdleReading() {
        guard let delay = idleDelaySeconds else { return }
        let read = self.read
        let emit = self.emit
        let physical = physicalMemory
        let item = DispatchWorkItem {
            guard let reading = read() else { return }
            emit("transcription_memory", [
                "phase": "idle",
                "minutes_after_job": (delay / 60 * 10).rounded() / 10,
                "footprint_bytes": reading.footprint,
                "lifetime_peak_bytes": reading.lifetimePeak,
                "physical_memory_bytes": physical,
            ])
        }
        Self.pendingIdle.withLock { $0?.cancel(); $0 = item }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// This process's footprint, from `task_info(TASK_VM_INFO)`. Nil if the call fails.
    @Sendable
    static func currentReading() -> Reading? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Reading(
            footprint: UInt64(clamping: info.phys_footprint),
            lifetimePeak: UInt64(clamping: info.ledger_phys_footprint_peak)
        )
    }
}
