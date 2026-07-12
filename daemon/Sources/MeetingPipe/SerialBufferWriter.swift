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
}
