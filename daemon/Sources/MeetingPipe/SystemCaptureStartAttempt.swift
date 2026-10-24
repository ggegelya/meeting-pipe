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

    /// True once the recorder or `stop()` gave up on this attempt. Both delegate callbacks
    /// gate on it, so an abandoned attempt's stream (late or not yet stopped) delivers no
    /// buffers and reports no death.
    var isAbandoned: Bool { abandonment != nil }

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
