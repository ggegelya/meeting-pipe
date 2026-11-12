import os
import XCTest
@testable import MeetingPipe

/// Tests for the enqueue / drain logic that moves capture-callback disk
/// writes off the latency-sensitive delivery thread. Driven with a plain
/// in-memory sink so the FIFO / no-drop / drain contract is exercised
/// without AVFoundation.
final class SerialBufferWriterTests: XCTestCase {

    func test_enqueue_then_finish_delivers_every_item_in_order() {
        var received: [Int] = []
        let writer = SerialBufferWriter<Int>(label: "test.order") { received.append($0) }

        for i in 0..<1000 { writer.enqueue(i) }
        writer.finish()

        XCTAssertEqual(received, Array(0..<1000))
    }

    func test_finish_on_an_empty_writer_returns_immediately() {
        var handled = 0
        let writer = SerialBufferWriter<Int>(label: "test.empty") { _ in handled += 1 }

        writer.finish()

        XCTAssertEqual(handled, 0)
    }

    /// The no-drop contract: every item enqueued, even under concurrent
    /// producers, reaches the handler. The handler itself runs serially,
    /// so the plain counter is safe to mutate inside it.
    func test_no_item_is_dropped_under_concurrent_enqueue() {
        let total = 4000
        var handled = 0
        let writer = SerialBufferWriter<Int>(label: "test.concurrent") { _ in handled += 1 }

        DispatchQueue.concurrentPerform(iterations: total) { writer.enqueue($0) }
        writer.finish()

        XCTAssertEqual(handled, total)
    }

    /// `finish()` must block until the last queued item is fully handled,
    /// so the recorder can close the file straight after draining.
    func test_finish_blocks_until_a_slow_handler_completes() {
        var done = false
        let writer = SerialBufferWriter<Int>(label: "test.slow") { _ in
            Thread.sleep(forTimeInterval: 0.05)
            done = true
        }

        writer.enqueue(1)
        writer.finish()

        XCTAssertTrue(done)
    }

    /// REC7: `finish(timeout:)` returns true when the drain completes in time.
    func test_finish_with_timeout_returns_true_when_drain_completes() {
        var received: [Int] = []
        let writer = SerialBufferWriter<Int>(label: "test.timeout.ok") { received.append($0) }

        for i in 0..<100 { writer.enqueue(i) }
        XCTAssertTrue(writer.finish(timeout: 5))

        XCTAssertEqual(received, Array(0..<100))
    }

    /// REC7: a permanently-wedged handler (a stuck disk write) must not hang the
    /// caller. `finish(timeout:)` returns false near its budget; the drain is
    /// ABANDONED, not cancelled, so the test releases it afterwards to avoid leaking
    /// the queue thread. This is the exact case that used to make `.stopping`
    /// inescapable.
    func test_finish_with_timeout_returns_false_when_handler_wedges() {
        let gate = DispatchSemaphore(value: 0)
        let writer = SerialBufferWriter<Int>(label: "test.timeout.wedged") { _ in
            gate.wait()  // blocks until the test releases it
        }
        writer.enqueue(1)

        let start = Date()
        let drained = writer.finish(timeout: 0.2)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(drained, "a wedged handler times out")
        XCTAssertLessThan(elapsed, 2.0, "finish(timeout:) returns near its budget, not after the wedge clears")
        gate.signal()  // let the abandoned handler finish so its queue thread exits
    }

    /// REC11(a): the termination flush drains synchronously, because
    /// `applicationWillTerminate` and the SIGTERM handler cannot await. It used to call
    /// the UNBOUNDED `finish()` there while `stop()` used the bounded variant on the same
    /// writers, so a full disk or a stalled volume hung quit forever on the main thread.
    /// This is the bound that replaced it: a wedged writer is abandoned inside the
    /// budget, so quit always proceeds and whatever landed is still on disk for the
    /// orphan sweep.
    func test_a_wedged_writer_is_abandoned_within_the_termination_budget() {
        let gate = DispatchSemaphore(value: 0)
        let writer = SerialBufferWriter<Int>(label: "test.termination.wedged") { _ in gate.wait() }
        writer.enqueue(1)

        let start = Date()
        let drained = writer.finish(timeout: 0.2)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(drained, "the flush learns the drain was abandoned, so it can log it")
        XCTAssertLessThan(elapsed, 2.0, "quit proceeds inside the budget rather than blocking forever")
        gate.signal()
    }

    // MARK: - drain (REC11)

    func test_drain_returns_true_when_the_drain_completes() async {
        var received: [Int] = []
        let writer = SerialBufferWriter<Int>(label: "test.drain.ok") { received.append($0) }

        for i in 0..<100 { writer.enqueue(i) }
        let drained = await writer.drain(timeout: 5)

        XCTAssertTrue(drained)
        XCTAssertEqual(received, Array(0..<100))
    }

    func test_drain_returns_false_when_the_handler_wedges() async {
        let gate = DispatchSemaphore(value: 0)
        let writer = SerialBufferWriter<Int>(label: "test.drain.wedged") { _ in gate.wait() }
        writer.enqueue(1)

        let start = Date()
        let drained = await writer.drain(timeout: 0.2)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(drained, "a wedged handler times out")
        XCTAssertLessThan(elapsed, 2.0, "drain returns near its budget, not after the wedge clears")
        gate.signal()
    }

    /// The property `drain` exists for: `stop()` is `@MainActor` since REC11, and the
    /// synchronous `finish(timeout:)` would have paid for that by freezing the app for
    /// the whole 10 s drain budget. Awaiting a wedged drain from the main actor must
    /// leave the main actor free to run other work, which is what this pins - the
    /// main-actor task below completes while the drain is still outstanding.
    @MainActor
    func test_drain_suspends_the_main_actor_instead_of_blocking_it() async {
        let gate = DispatchSemaphore(value: 0)
        let writer = SerialBufferWriter<Int>(label: "test.drain.nonblocking") { _ in gate.wait() }
        writer.enqueue(1)

        var ranDuringTheDrain = false
        async let drained = writer.drain(timeout: 1.0)
        // Scheduled after the drain started; it can only run if the main actor is free.
        let interleaved = Task { @MainActor in ranDuringTheDrain = true }

        await interleaved.value
        XCTAssertTrue(ranDuringTheDrain, "the main actor kept running while the drain was outstanding")

        let result = await drained
        XCTAssertFalse(result)
        gate.signal()
    }

    // MARK: - whenDrained (REC23)

    /// `whenDrained` is the recorder's signal that nothing more will be written into a
    /// stem's intermediates, so it must run behind every item enqueued before it.
    func test_whenDrained_runs_only_after_every_item_enqueued_before_it() {
        let log = OSAllocatedUnfairLock(initialState: [String]())
        let writer = SerialBufferWriter<Int>(label: "test.whenDrained.order") { item in
            Thread.sleep(forTimeInterval: 0.001)
            log.withLock { $0.append("item\(item)") }
        }
        for i in 0..<20 { writer.enqueue(i) }
        let ran = expectation(description: "whenDrained ran")
        writer.whenDrained {
            log.withLock { $0.append("drained") }
            ran.fulfill()
        }

        wait(for: [ran], timeout: 5)
        let entries = log.withLock { $0 }
        XCTAssertEqual(entries.last, "drained")
        XCTAssertEqual(entries.dropLast(), ArraySlice((0..<20).map { "item\($0)" }))
    }

    /// The case it exists for: a bounded drain timed out at stop and was abandoned, and the
    /// backlog keeps writing. The closure must wait for that backlog, not for the timeout.
    func test_whenDrained_waits_for_the_backlog_an_abandoned_drain_left() async {
        let gate = DispatchSemaphore(value: 0)
        let handled = OSAllocatedUnfairLock(initialState: 0)
        let writer = SerialBufferWriter<Int>(label: "test.whenDrained.abandoned") { _ in
            gate.wait()
            handled.withLock { $0 += 1 }
        }
        writer.enqueue(1)
        writer.enqueue(2)
        let drained = await writer.drain(timeout: 0.1)
        XCTAssertFalse(drained, "the precondition: the bounded drain gave up")

        let ranAfter = OSAllocatedUnfairLock(initialState: -1)
        let ran = expectation(description: "whenDrained ran")
        writer.whenDrained {
            ranAfter.withLock { $0 = handled.withLock { $0 } }
            ran.fulfill()
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(ranAfter.withLock { $0 }, -1, "nothing runs while the abandoned backlog is still wedged")

        gate.signal()
        gate.signal()
        await fulfillment(of: [ran], timeout: 5)
        XCTAssertEqual(ranAfter.withLock { $0 }, 2, "it ran behind both items the abandoned drain was still writing")
    }

    // MARK: - Pending bytes (REC25)

    /// A handler blocked on a semaphore is the stalled disk: nothing finishes, so every enqueued
    /// size is still pending and the high-water mark holds it. Released and drained, the count is
    /// back to 0 and the mark keeps the peak, which is what the `stopping:` line reports.
    func test_pending_bytes_track_a_blocked_handler_and_the_mark_keeps_the_peak() {
        let gate = DispatchSemaphore(value: 0)
        let writer = SerialBufferWriter<Int>(label: "test.rec25.pending", size: { $0 }) { _ in gate.wait() }

        for size in [100, 250, 4_000] { writer.enqueue(size) }
        XCTAssertEqual(writer.pendingBytes, 4_350)
        XCTAssertEqual(writer.highWaterBytes, 4_350)

        for _ in 0..<3 { gate.signal() }
        XCTAssertTrue(writer.finish(timeout: 5))
        XCTAssertEqual(writer.pendingBytes, 0)
        XCTAssertEqual(writer.highWaterBytes, 4_350)
    }

    /// The count is taken on the producer side, so two capture threads enqueueing at once must not
    /// lose an increment.
    func test_enqueues_from_two_threads_keep_the_count_exact() {
        let gate = DispatchSemaphore(value: 0)
        let writer = SerialBufferWriter<Int>(label: "test.rec25.threads", size: { $0 }) { _ in gate.wait() }
        let perThread = 2_000

        DispatchQueue.concurrentPerform(iterations: 2) { thread in
            for _ in 0..<perThread { writer.enqueue(thread == 0 ? 3 : 7) }
        }
        XCTAssertEqual(writer.pendingBytes, perThread * 3 + perThread * 7)

        for _ in 0..<(perThread * 2) { gate.signal() }
        XCTAssertTrue(writer.finish(timeout: 10))
        XCTAssertEqual(writer.pendingBytes, 0)
    }

    /// REC10's pad enqueues one shared buffer many times; the override charges it once.
    func test_an_explicit_byte_cost_overrides_the_size() {
        let gate = DispatchSemaphore(value: 0)
        let writer = SerialBufferWriter<Int>(label: "test.rec25.override", size: { $0 }) { _ in gate.wait() }

        writer.enqueue(1_000, bytes: 1_000)
        for _ in 0..<9 { writer.enqueue(1_000, bytes: 0) }
        XCTAssertEqual(writer.pendingBytes, 1_000)

        for _ in 0..<10 { gate.signal() }
        XCTAssertTrue(writer.finish(timeout: 5))
        XCTAssertEqual(writer.pendingBytes, 0)
    }

    /// Without a size the writer counts nothing, which is what every non-audio sink wants.
    func test_a_writer_without_a_size_counts_nothing() {
        let writer = SerialBufferWriter<Int>(label: "test.rec25.nosize") { _ in }
        writer.enqueue(42)
        writer.finish()
        XCTAssertEqual(writer.highWaterBytes, 0)
    }
}
