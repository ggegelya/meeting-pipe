import Foundation
import os

/// Awaits `operation`, but returns after `seconds` even if it has not finished.
/// On timeout the operation is ABANDONED: it keeps running in the background, but
/// the caller stops waiting on it. Returns true if it finished within the budget,
/// false if it timed out.
///
/// Why not `withTaskGroup`: a task group awaits every child at scope exit, which
/// would re-introduce the hang when the operation is the stuck one. This resumes
/// the continuation on whichever of operation / timeout finishes first, and never
/// blocks on the loser.
///
/// Used by `MeetingRecorder.stop()` so a stuck ScreenCaptureKit `stopCapture`
/// (observed 2026-06-05: a meeting wedged in "stopping..." for ~7 minutes) can no
/// longer hang the stop sequence; stop() always proceeds to the ffmpeg merge.
func runWithTimeout(
    seconds: Double,
    _ operation: @escaping @Sendable () async -> Void
) async -> Bool {
    let resumedOnce = OSAllocatedUnfairLock(initialState: false)

    @Sendable func resumeOnce(_ continuation: CheckedContinuation<Bool, Never>, completed: Bool) {
        let shouldResume = resumedOnce.withLock { alreadyResumed -> Bool in
            if alreadyResumed { return false }
            alreadyResumed = true
            return true
        }
        if shouldResume { continuation.resume(returning: completed) }
    }

    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        Task {
            await operation()
            resumeOnce(continuation, completed: true)
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            resumeOnce(continuation, completed: false)
        }
    }
}
