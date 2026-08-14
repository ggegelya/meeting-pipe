import Foundation

/// Moves disk-write work off an audio capture callback onto a private serial
/// queue. enqueue(_:) returns immediately; handle runs FIFO on the queue.
/// The unbounded backing queue never drops or blocks the producer - the contract
/// ADR 0009 mic/system frame parity depends on. finish() drains all pending
/// items synchronously so the caller can close the file immediately after.
/// Generic so enqueue/drain logic is testable with an in-memory sink.
final class SerialBufferWriter<Item> {

    private let queue: DispatchQueue
    private let handle: (Item) -> Void

    init(label: String, handle: @escaping (Item) -> Void) {
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.handle = handle
    }

    /// Enqueue an item for async handling. Returns immediately; no I/O on the caller.
    func enqueue(_ item: Item) {
        queue.async { [handle] in
            handle(item)
        }
    }

    /// Block until all previously enqueued items are handled. Do not call from the writer queue itself.
    func finish() {
        queue.sync {}
    }

    /// Block until all previously enqueued items are handled, but give up after
    /// `timeout` seconds. Returns true if the drain finished in time, false if it
    /// timed out. A sentinel is enqueued at the tail (so it runs only after every
    /// prior item) and waited on with a bounded semaphore; on timeout the drain is
    /// ABANDONED (it keeps running on the queue, which strong-captures the file it
    /// writes, so the file stays valid until the drain finishes) and the caller
    /// proceeds. Do not call from the writer queue itself. (REC7: a wedged disk
    /// write must not make `stop()` / `.stopping` inescapable.)
    @discardableResult
    func finish(timeout: TimeInterval) -> Bool {
        let sentinel = DispatchSemaphore(value: 0)
        queue.async { sentinel.signal() }
        return sentinel.wait(timeout: .now() + timeout) == .success
    }

    /// The same bounded drain as `finish(timeout:)`, but it SUSPENDS the caller
    /// instead of blocking its thread, so a `@MainActor` caller keeps the UI live
    /// while a wedged disk runs out the budget. The wait itself still has to be a
    /// blocking semaphore (a `DispatchQueue` offers nothing else), so it is parked on
    /// a global utility thread; nothing the caller owns is held.
    ///
    /// REC11: `stop()` became `@MainActor` so its teardown stops racing the main-thread
    /// owners of the fields it writes, and the synchronous `finish(timeout:)` would have
    /// bought that by freezing the app for the whole 10 s drain budget instead. Same
    /// abandon-on-timeout contract as the synchronous variant: the drain keeps running
    /// on the queue, which strong-captures the file it writes, so the file stays valid.
    @discardableResult
    func drain(timeout: TimeInterval) async -> Bool {
        let sentinel = DispatchSemaphore(value: 0)
        queue.async { sentinel.signal() }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: sentinel.wait(timeout: .now() + timeout) == .success)
            }
        }
    }
}
