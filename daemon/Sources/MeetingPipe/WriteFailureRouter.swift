import Foundation

/// REC25: carries a capture writer's failures to `onWriteFailure`, and only for the recording the
/// writer belongs to.
///
/// REC3's trackers used to be two recorder fields that `start()` replaced on main, while a writer
/// abandoned by the previous stop's drain (REC7) kept reporting into whichever tracker was
/// current. A run of 32 failures from that backlog then force-stopped a healthy recording, or
/// posted "Recording stopped" with nothing recording, and the reset itself raced the old queue's
/// mutation of the same struct. Two changes close it:
///
/// - **Each writer owns its tracker.** `makeOutcomeHandler` builds a fresh `WriteFailureTracker`
///   inside the closure it returns, and that closure is the writer's own, so only that writer's
///   serial queue ever mutates it. Nothing outside can reset it, and nothing else can feed it.
/// - **An escalation names its recording.** `beginRecording()` (from `start()`) opens a new
///   generation and `endRecording()` (from the top of `stop()`) closes it. Each handler captures
///   the generation it was built under, and the main-queue hop delivers an escalation only when
///   that generation is still the live one. Anything else, a previous recording's writer, or a
///   writer whose recording has already ended, is logged as `recorder`/`write_failure_stale`
///   and never reaches `onWriteFailure`.
///
/// Main-only, apart from the handlers it returns, which run on their writer's queue and touch
/// only their own tracker and this type's `let`s until they hop to main.
final class WriteFailureRouter {

    /// What the Coordinator does with a live escalation: notify, then force-stop (REC3 / AUD-7).
    /// Read on main, at delivery.
    var onWriteFailure: ((RecordingWriteFailure.Decision) -> Void)?

    /// The generation of the recording in progress, or nil between recordings. Main-only.
    private(set) var liveGeneration: UInt64?
    private var lastGeneration: UInt64 = 0

    private let threshold: Int
    private let mainHop: (@escaping () -> Void) -> Void
    private let freeSpace: (URL) -> (freeBytes: Int64?, volumeName: String?)
    private let emit: (String, [String: Any]) -> Void

    /// The defaults are production's. Tests inject a synchronous hop, a fixed free-space reading
    /// and an event sink, so the seam runs without a disk, a run loop or the real event log.
    init(
        threshold: Int = WriteFailureTracker.defaultThreshold,
        mainHop: @escaping (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async { work() } },
        freeSpace: @escaping (URL) -> (freeBytes: Int64?, volumeName: String?) = RecordingWriteFailure.freeSpace(at:),
        emit: @escaping (String, [String: Any]) -> Void = { action, attributes in
            Log.event(category: "recorder", action: action, attributes: attributes)
        }
    ) {
        self.threshold = threshold
        self.mainHop = mainHop
        self.freeSpace = freeSpace
        self.emit = emit
    }

    /// Open a new recording's generation. From `start()`, on main, before any writer is built.
    func beginRecording() {
        lastGeneration &+= 1
        liveGeneration = lastGeneration
    }

    /// Close the live generation. From the top of `stop()` and from a failed `start()`, on main.
    /// A writer still draining after this reports into a generation nobody is listening to.
    func endRecording() {
        liveGeneration = nil
    }

    /// The outcome callback for one writer, built on main as the writer is. Call the result on the
    /// writer's own queue with each write's success. The tracker lives in the closure and the
    /// generation is captured by value, which is the whole fix: see the type doc.
    func makeOutcomeHandler(channel: CaptureWriteChannel, directory: URL) -> (Bool) -> Void {
        let generation = lastGeneration
        var tracker = WriteFailureTracker(threshold: threshold)
        return { [weak self] success in
            guard tracker.record(success: success) else { return }
            self?.escalate(
                channel: channel, consecutive: tracker.consecutiveFailures,
                generation: generation, directory: directory
            )
        }
    }

    /// On the writer's queue, once per tracker: decide the cause off main (REC19 reads the
    /// volume's free space here, which can be slow on the volume that is failing), then hop.
    private func escalate(channel: CaptureWriteChannel, consecutive: Int, generation: UInt64, directory: URL) {
        let space = freeSpace(directory)
        let decision = RecordingWriteFailure.decide(
            channel: channel.rawValue, freeBytes: space.freeBytes, volumeName: space.volumeName
        )
        mainHop { [weak self] in
            self?.deliver(decision, consecutive: consecutive, generation: generation)
        }
    }

    /// On main: the live recording's escalation goes to `onWriteFailure`; anyone else's is logged
    /// and dropped.
    private func deliver(_ decision: RecordingWriteFailure.Decision, consecutive: Int, generation: UInt64) {
        guard generation == liveGeneration else {
            emit("write_failure_stale", [
                "channel": decision.channel,
                "generation": Int(generation),
                "live_generation": liveGeneration.map { Int($0) as Any } ?? NSNull(),
                "consecutive_failures": consecutive,
                "cause": decision.cause.rawValue,
            ])
            Log.writeLine("recorder", "WARN: \(decision.channel) writer from recording generation \(generation) failed \(consecutive) consecutive writes after its recording ended - not stopping anything")
            return
        }
        emit("recording_error", [
            "channel": decision.channel,
            "consecutive_failures": consecutive,
            "cause": decision.cause.rawValue,
            "free_bytes": decision.freeBytes as Any,
        ])
        Log.writeLine("recorder", "ERROR: \(decision.channel) writer failed \(consecutive) consecutive writes (cause=\(decision.cause.rawValue) free_bytes=\(decision.freeBytes.map(String.init) ?? "unreadable")); force-stopping to preserve the intact prefix")
        onWriteFailure?(decision)
    }

    /// On main, from the backlog tick (`WriterBacklogPolicy` said `.stop`): the writers have not
    /// failed, they have stopped finishing, so this is `writer_stalled` and reads no free space.
    /// Current by construction, since only a live recording's tick gets here; checked anyway.
    func escalateBacklog(channel: CaptureWriteChannel, pendingBytes: Int) {
        guard liveGeneration != nil else { return }
        let decision = RecordingWriteFailure.stalled(channel: channel.rawValue)
        emit("recording_error", [
            "channel": decision.channel,
            "cause": decision.cause.rawValue,
            "free_bytes": NSNull(),
            "pending_bytes": pendingBytes,
        ])
        Log.writeLine("recorder", "ERROR: capture writers hold \(pendingBytes) bytes unwritten (largest backlog: \(decision.channel)) - the output volume stopped finishing writes; force-stopping to preserve the intact prefix")
        onWriteFailure?(decision)
    }
}
