import Foundation

/// Serializes work off a latency-sensitive producer (an audio capture
/// callback) and onto a private serial queue. The producer calls
/// `enqueue(_:)`, which returns immediately; the `handle` closure runs
/// the real work (a disk write) on the serial queue, in FIFO order,
/// one item at a time.
///
/// No item is dropped: the backing `DispatchQueue` is unbounded, so
/// `enqueue` never blocks the producer and never discards. That is the
/// contract the recorder's mic / system frame parity (ADR 0009)
/// depends on - every buffer that enters a capture callback reaches
/// disk.
///
/// `finish()` blocks until every item enqueued before the call has
/// been handled, so the caller can close the underlying file
/// immediately afterwards.
///
/// Generic over the item so the enqueue / drain logic is unit-testable
/// with a plain in-memory sink, no AVFoundation.
final class SerialBufferWriter<Item> {

    private let queue: DispatchQueue
    private let handle: (Item) -> Void

    init(label: String, handle: @escaping (Item) -> Void) {
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.handle = handle
    }

    /// Hand an item to the serial queue. Returns immediately; the
    /// producer thread does no I/O.
    func enqueue(_ item: Item) {
        queue.async { [handle] in
            handle(item)
        }
    }

    /// Block until every item enqueued before this call has been
    /// handled. Safe to call from any thread except the writer queue
    /// itself.
    func finish() {
        queue.sync {}
    }
}
