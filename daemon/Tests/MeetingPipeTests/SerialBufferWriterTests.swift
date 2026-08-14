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
}
