import Foundation
import os

/// Moves disk-write work off an audio capture callback onto a private serial
/// queue. enqueue(_:) returns immediately; handle runs FIFO on the queue.
/// The unbounded backing queue never drops or blocks the producer - the contract
/// ADR 0009 mic/system frame parity depends on. finish() drains all pending
/// items synchronously so the caller can close the file immediately after.
/// Generic so enqueue/drain logic is testable with an in-memory sink.
///
/// REC25: unbounded is not the same as unwatched. The writer counts the bytes it is
/// holding (`pendingBytes`, plus the `highWaterBytes` peak), so a disk that hangs
/// instead of failing shows up as a growing number the recorder's 1 Hz ticks read
/// (`WriterBacklogPolicy`), rather than as memory nobody can see. The count is the
/// only addition: nothing here drops, blocks or reorders.
final class SerialBufferWriter<Item> {

    private struct Backlog {
        var pending = 0
        var highWater = 0
    }

    private let queue: DispatchQueue
    private let handle: (Item) -> Void
    private let size: (Item) -> Int
    private let backlog = OSAllocatedUnfairLock(initialState: Backlog())

    /// `size` is what one item costs while it waits, in bytes, read on the producer's
    /// thread at enqueue. The default counts nothing, for sinks that hold no audio.
    init(label: String, size: @escaping (Item) -> Int = { _ in 0 }, handle: @escaping (Item) -> Void) {
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.size = size
        self.handle = handle
    }

    /// Enqueue an item for async handling. Returns immediately; no I/O on the caller.
    func enqueue(_ item: Item) {
        enqueue(item, bytes: size(item))
    }

    /// Enqueue with an explicit byte cost instead of `size(item)`. For an item enqueued
    /// more than once whose memory is held once: REC10's system pad re-enqueues one
    /// shared 1 s silence buffer up to 900 times, which is one buffer of memory, not 900.
    func enqueue(_ item: Item, bytes: Int) {
        let bytes = max(0, bytes)
        backlog.withLock {
            $0.pending += bytes
            $0.highWater = max($0.highWater, $0.pending)
        }
        queue.async { [handle, backlog] in
            handle(item)
            backlog.withLock { $0.pending -= bytes }
        }
    }

    /// Bytes enqueued and not yet handled. Readable from any thread.
    var pendingBytes: Int { backlog.withLock { $0.pending } }

    /// The largest `pendingBytes` has been over this writer's life. Readable from any thread.
    var highWaterBytes: Int { backlog.withLock { $0.highWater } }

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

    /// Run `body` on the writer queue once every item enqueued before this call has been
    /// handled, including the backlog a timed-out `drain(timeout:)` abandoned. Returns
    /// immediately and never waits. REC23: a drain the stop gave up on still writes into the
    /// intermediates, so the recorder keeps their stem out of the orphan sweep until this
    /// fires.
    func whenDrained(_ body: @escaping @Sendable () -> Void) {
        queue.async(execute: body)
    }
}
