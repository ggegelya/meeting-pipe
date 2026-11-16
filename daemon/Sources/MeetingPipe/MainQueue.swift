import Foundation

/// CONC6: the runtime half of `MeetingSessionController`'s main-queue rule.
///
/// The controller is `@unchecked Sendable` because every stored property is touched only on the main queue,
/// and `Coordinator` (a plain `NSObject`, not `@MainActor`) is the same. That was a comment. A future hop
/// that called one of its methods from a cooperative-pool continuation (the CI8 class of mistake) would
/// race the session state silently, and `-strict-concurrency=targeted` does not look.
///
/// `assertMainQueue()` is `dispatchPrecondition(.onQueue(.main))` compiled under `#if DEBUG` only, so a wrong
/// hop fails a test or a dev build and never a release recording. Call it first in every non-private
/// instance method of the controller (`MainQueueFenceTests` fails the suite when one does not).
@inline(__always)
func assertMainQueue() {
    #if DEBUG
    dispatchPrecondition(condition: .onQueue(.main))
    #endif
}

enum MainQueue {
    /// The predicate the precondition enforces, for a test: a trapping precondition cannot be caught
    /// in-process, so the test pins this instead of the trap.
    static var isCurrent: Bool { Thread.isMainThread }
}
