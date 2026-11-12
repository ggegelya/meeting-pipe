import Foundation
import os

/// The one decision a system-audio start attempt makes when `SCStream.startCapture()`
/// finally returns: adopt the stream, or stop it at once because nobody is waiting for
/// it any more (REC17).
///
/// Pure and single-use: one ledger per `SystemAudioCapture`, which is one per attempt.
/// The host (`SystemAudioCapture`) owns the lock around it and consults it from the
/// recorder's timeout, from `stop()`, from the post-`startCapture()` path and from
/// both delegate callbacks. Lifted out so the ordering rule is testable without
/// ScreenCaptureKit, in the `SystemCaptureRetryPlanner` / `CaptureRecoveryPlanner` shape.
///
/// The defect it exists to close: on 2026-09-17 `startCapture()` returned **64 minutes**
/// after it was called. Nothing bounded the wait, and once something does, the abandoned
/// call still completes eventually. As written, that late completion adopted the stream
/// (`self.stream = stream`, "SCStream started", `systemDegraded = false`) and, had a
/// retry re-armed the channel in the meantime, delivered a second stream's buffers into
/// the live writer. An attempt that was abandoned first has exactly one correct move
/// when it completes: stop the stream it produced, deliver nothing, clear nothing.
struct SystemCaptureStartAttempt: Equatable {

    /// Why nobody is waiting on this attempt any more.
    enum Abandonment: String, Equatable {
        /// The recorder's start budget elapsed (`SystemAudioChannel.systemStartBudgetSeconds`).
        case timedOut = "timed_out"
        /// `SystemAudioCapture.stop()` ran before the start returned.
        case stopped = "stopped"
    }

    /// What `startCapture()`'s return should do.
    enum Completion: Equatable {
        /// Nobody abandoned the attempt: keep the stream and deliver its buffers.
        case adopt
        /// The attempt was abandoned first: stop the stream, deliver nothing, clear nothing.
        case discard(Abandonment)
    }

    private(set) var abandonment: Abandonment?
    private(set) var isCompleted = false

    /// REC28: true once `SystemAudioCapture.stop()` began, whatever state the attempt was in.
    /// The stop side's gate, kept apart from `abandonment` on purpose: `stopped()` is a no-op
    /// once the attempt completed, so an adopted stream whose `stopCapture()` hung kept
    /// delivering into whatever writer the channel held next, and folding this into
    /// `abandonment` would change what `completed()` answers and what a discard is logged as.
    private(set) var isDeliveryStopped = false

    /// True once the recorder or `stop()` gave up on this attempt. Both delegate callbacks
    /// gate on it, so an abandoned attempt's stream (late or not yet stopped) delivers no
    /// buffers and reports no death.
    var isAbandoned: Bool { abandonment != nil }

    /// Whether a buffer from this attempt's stream may reach the recorder: not abandoned and
    /// not being stopped. `didOutputSampleBuffer` consults both halves (REC17, REC28).
    var deliversBuffers: Bool { !isAbandoned && !isDeliveryStopped }

    /// `stop()` began (REC28). Set before `stopCapture()` is awaited, so the beat between the
    /// call and the stream actually stopping, which was about 7 minutes on 2026-06-05, delivers
    /// nothing. Changes neither `completed()`'s answer nor an existing abandonment.
    mutating func stopDelivery() {
        isDeliveryStopped = true
    }

    /// The recorder stopped waiting: the budget elapsed. First abandonment wins, so a
    /// later `stopped()` cannot relabel a timeout.
    mutating func timedOut() {
        if abandonment == nil { abandonment = .timedOut }
    }

    /// `stop()` ran before the start returned. First abandonment wins.
    mutating func stopped() {
        if abandonment == nil { abandonment = .stopped }
    }

    /// `startCapture()` returned. The answer is fixed by what happened before this call:
    /// an abandonment that lands *after* it finds an adopted stream, which `stop()` then
    /// stops the ordinary way.
    mutating func completed() -> Completion {
        isCompleted = true
        if let why = abandonment { return .discard(why) }
        return .adopt
    }
}

/// REC28: which system capture the channel is listening to. The channel outlives every
/// recording (`MeetingRecorder.systemChannel`, on the recorder the `Coordinator` builds once),
/// and a capture it has given up on can keep delivering: a stream whose `stopCapture()` hung
/// past `haltCapture`'s bound or the loss path's, or a stalled one that resumes. Its buffer
/// closure used to check only `systemFile != nil`, so the next recording's file, or the
/// retry's, took them: two streams interleaved, `systemFires` advanced past REC17's per-attempt
/// gate by the zombie, and REC9's head offset stamped from it.
///
/// Each arm takes a fresh number, never reused for the life of the channel, and the channel
/// invalidates it wherever it lets go of that capture. A buffer is accepted only under the live
/// number, and a start outcome is applied only to it. A number rather than `systemCapture ===
/// capture` because the buffer closure is handed to the capture's `init` and cannot capture
/// the capture. Pure; the channel owns the lock around it.
struct SystemCaptureGenerations: Equatable {
    /// The generation of the capture the channel currently holds; 0 means none.
    private(set) var live: UInt64 = 0
    private var issued: UInt64 = 0

    /// A new attempt is armed: issue its number and make it the live one.
    mutating func arm() -> UInt64 {
        issued &+= 1
        live = issued
        return live
    }

    /// The channel let go of its capture (halt, loss, a failed start, termination).
    mutating func invalidate() {
        live = 0
    }

    /// Whether `generation` is the capture the channel still holds.
    func isLive(_ generation: UInt64) -> Bool {
        generation != 0 && generation == live
    }

    /// The buffer closure's predicate: the attempt is the live one AND a file is open to take it.
    /// Consulted before `systemFires`, `systemFirstFrameUptime` or the writer are touched.
    func accepts(_ generation: UInt64, hasOpenFile: Bool) -> Bool {
        isLive(generation) && hasOpenFile
    }
}

/// Outcome of a bounded `SystemAudioCapture.start()`.
enum SystemCaptureStartOutcome: Equatable {
    /// The stream came up within the budget and was adopted.
    case started
    /// The stream came up within the budget but the attempt had been abandoned by then
    /// (a `stop()` that beat the start), so the capture stopped it rather than adopt it.
    case discarded(SystemCaptureStartAttempt.Abandonment)
    /// `start()` threw; carries the localized message.
    case failed(String)
    /// `start()` did not return within the budget. It is ABANDONED (still running inside
    /// ScreenCaptureKit); the caller marks the capture abandoned so the late completion
    /// discards itself, and routes the loss through `handleSystemAudioLost`.
    case timedOut
}

/// Await `start` for at most `seconds`. The async sibling of `boundedEngineStart`, for the
/// one start in the capture chain that was never bounded: `SCShareableContent` plus
/// `SCStream.startCapture()` are both unbounded awaits, and on 2026-09-17 they took 64
/// minutes between them while the far side of a call went unrecorded and every
/// recording-integrity fence stayed quiet (REC17). Wraps `runWithTimeout`, so the contract
/// is abandon-on-timeout: the start keeps running and the caller stops waiting.
///
/// Pulled out so the timeout / throw / adopt / discard branching is unit-testable without
/// ScreenCaptureKit.
func boundedSystemCaptureStart(
    seconds: Double,
    _ start: @escaping @Sendable () async throws -> SystemCaptureStartAttempt.Completion
) async -> SystemCaptureStartOutcome {
    let outcome = OSAllocatedUnfairLock<SystemCaptureStartOutcome?>(initialState: nil)
    let finished = await runWithTimeout(seconds: seconds) {
        do {
            switch try await start() {
            case .adopt:
                outcome.withLock { $0 = .started }
            case .discard(let why):
                outcome.withLock { $0 = .discarded(why) }
            }
        } catch {
            outcome.withLock { $0 = .failed(error.localizedDescription) }
        }
    }
    // `finished == false` is the timeout: runWithTimeout resumed on the timer, not the
    // operation, so the start is still running (abandoned).
    if !finished { return .timedOut }
    // `finished == true` means the operation wrote `outcome` before it resumed the
    // continuation. Default defensively if it is somehow unset.
    return outcome.withLock { $0 } ?? .timedOut
}
