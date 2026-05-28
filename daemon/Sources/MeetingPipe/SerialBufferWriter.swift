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
}
