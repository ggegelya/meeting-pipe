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
///
/// For genuinely async work only: an operation that SUSPENDS while it waits. Both the
/// operation and the deadline run as `Task`s on Swift's cooperative pool, and a closure
/// that BLOCKS its thread (a synchronous `AVAudioEngine` call, a `Thread.sleep`, a
/// semaphore wait) holds a pool thread until it returns. Enough of those and the
/// deadline cannot be scheduled, so the bound silently becomes "as long as the wedge".
/// A blocking closure goes through `runBlockingWithTimeout` (CI8).
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

/// The synchronous sibling of `runWithTimeout`, for the two paths that cannot
/// suspend: a private `DispatchQueue` block (`MicLevelMonitor.start`) and the
/// synchronous termination flush (`MeetingRecorder.flushIntermediatesForTermination`,
/// which runs under `applicationWillTerminate` / the SIGTERM dispatch source and has
/// no async context to await in).
///
/// `operation` runs on a global utility thread and the caller waits on a semaphore
/// with a deadline. Same abandon-on-timeout contract as `runWithTimeout`: on timeout
/// the operation keeps running on that thread and the caller proceeds. Returns true
/// if it finished within the budget, false if it timed out.
///
/// The caller's thread IS blocked for up to `seconds`, which is the whole point: it
/// is for a caller that must give the call its chance before proceeding but must not
/// wait on it forever. That makes the budget real freeze time for whoever calls it,
/// so keep it short, and don't reach for it from a path that could `await` instead.
///
/// REC13: every synchronous `AVAudioEngine` call in this app now goes through here,
/// directly or from an async caller via `runBlockingWithTimeout` (which is what
/// `boundedEngineStart` and `EngineTeardown.run` use). On 2026-08-14 the engine's own serial queue wedged
/// (blocked in 2516 of 2516 samples), and every unbounded call into it inherited that
/// wedge, which is what kept a recording in `.stopping` for 52 minutes.
@discardableResult
func runBoundedSync(
    seconds: Double,
    _ operation: @escaping @Sendable () -> Void
) -> Bool {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        operation()
        done.signal()
    }
    return done.wait(timeout: .now() + max(0, seconds)) == .success
}

/// The async sibling of `runBoundedSync`, for an operation that BLOCKS its thread
/// rather than suspending (a synchronous `AVAudioEngine` call) and a caller that can
/// `await`. Same abandon-on-timeout contract and return value as `runWithTimeout`:
/// true if it finished within the budget, false if it timed out and was left running.
///
/// CI8: why this exists beside `runWithTimeout`. That one runs its operation and its
/// deadline as `Task`s on Swift's cooperative pool, which has one thread per core and
/// never grows. A blocking operation keeps its pool thread until it returns, so every
/// abandoned wedge holds one, and once they hold them all the deadline meant to abandon
/// the next call cannot be scheduled. The bound was only as good as the core count: on
/// the 3-core CI runner `EngineTeardown.run`'s three wedged steps took 5.4 s against a
/// 2.45 s bound, and under a one-thread pool (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`)
/// they took 15 s, one full wedge each.
///
/// Here the operation runs on GCD through `runBoundedSync`, whose deadline is a
/// semaphore timeout that needs no thread to fire, and the cooperative pool is touched
/// only for the hop back into the caller's task. The GCD thread that waits on the
/// semaphore is blocked for at most `seconds`.
func runBlockingWithTimeout(
    seconds: Double,
    _ operation: @escaping @Sendable () -> Void
) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: runBoundedSync(seconds: seconds, operation))
        }
    }
}
