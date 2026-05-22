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
}
