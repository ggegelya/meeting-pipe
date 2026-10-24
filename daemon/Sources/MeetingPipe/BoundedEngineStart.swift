import Foundation
import os

/// Outcome of a bounded `AVAudioEngine.start()`.
enum EngineStartOutcome: Equatable {
    /// The engine started within the budget.
    case started
    /// `start()` returned by throwing; carries the localized message.
    case failed(String)
    /// `start()` did not return within the budget. It is ABANDONED (keeps
    /// running in the background); the caller tears down and surfaces an error.
    case timedOut
}

/// Run the blocking `startEngine` (an `AVAudioEngine.start()` call) off the
/// caller's thread and bound it by `seconds`, so a CoreAudio start that wedges
/// on a transitioning audio route can no longer freeze the caller. A Bluetooth
/// headset renegotiating HFP was observed on 2026-06-12 to hang `engine.start()`
/// for ~42 s on the main thread, freezing the whole app ("Record did nothing").
///
/// Pulled out of `MeetingRecorder` so the timeout / throw / success branching is
/// unit testable without a real wedged audio device. Wraps `runBlockingWithTimeout`,
/// which implements abandon-on-timeout off the cooperative pool (see
/// RunWithTimeout.swift; the `Task` form starved its own deadline, CI8).
func boundedEngineStart(
    seconds: Double,
    _ startEngine: @escaping @Sendable () throws -> Void
) async -> EngineStartOutcome {
    let outcome = OSAllocatedUnfairLock<EngineStartOutcome?>(initialState: nil)
    let finished = await runBlockingWithTimeout(seconds: seconds) {
        do {
            try startEngine()
            outcome.withLock { $0 = .started }
        } catch {
            outcome.withLock { $0 = .failed(error.localizedDescription) }
        }
    }
    // `finished == false` is the timeout: the semaphore wait expired before the
    // start returned, so the start is still running (abandoned).
    if !finished { return .timedOut }
    // `finished == true` means the start returned and signalled the semaphore,
    // so `outcome` was written first. Default defensively if it is somehow unset.
    return outcome.withLock { $0 } ?? .timedOut
}
