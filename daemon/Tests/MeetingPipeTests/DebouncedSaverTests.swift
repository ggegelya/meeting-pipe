import XCTest
@testable import MeetingPipe

/// CONC8: the one debounced-save skeleton the three stores share.
final class DebouncedSaverTests: XCTestCase {

    private final class Counter {
        private let lock = NSLock()
        private var _saves = 0, _results = 0, _prepares = 0
        private var _workOnMain: [Bool] = [], _resultOnMain: [Bool] = []
        func save(onMain: Bool) { lock.lock(); _saves += 1; _workOnMain.append(onMain); lock.unlock() }
        func result(onMain: Bool) { lock.lock(); _results += 1; _resultOnMain.append(onMain); lock.unlock() }
        func prepare() { lock.lock(); _prepares += 1; lock.unlock() }
        var saves: Int { lock.lock(); defer { lock.unlock() }; return _saves }
        var results: Int { lock.lock(); defer { lock.unlock() }; return _results }
        var prepares: Int { lock.lock(); defer { lock.unlock() }; return _prepares }
        var workOnMain: [Bool] { lock.lock(); defer { lock.unlock() }; return _workOnMain }
        var resultOnMain: [Bool] { lock.lock(); defer { lock.unlock() }; return _resultOnMain }
    }

    private func makeSaver(_ c: Counter, interval: TimeInterval = 0.1, skip: Bool = false) -> DebouncedSaver {
        DebouncedSaver(
            interval: interval,
            queue: DebouncedSaver.makeQueue(label: "test.saver"),
            prepare: {
                c.prepare()
                if skip { return nil }
                return { c.save(onMain: Thread.isMainThread) }
            },
            completion: { _ in c.result(onMain: Thread.isMainThread) }
        )
    }

    private func spin(until done: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    func test_a_burst_of_schedules_makes_one_save() {
        let c = Counter()
        // The interval must outlast the gap between two schedules even on a loaded
        // CI runner, where a 20 ms run-loop turn has taken over 100 ms and split the burst.
        let saver = makeSaver(c, interval: 1.0)
        for _ in 0..<5 {
            saver.schedule()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        spin(until: { c.results == 1 })
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.3))
        XCTAssertEqual(c.saves, 1)
        XCTAssertEqual(c.results, 1)
    }

    func test_the_work_runs_off_main_and_the_result_arrives_on_main() {
        let c = Counter()
        let saver = makeSaver(c)
        saver.schedule()
        spin(until: { c.results == 1 })
        XCTAssertEqual(c.workOnMain, [false])
        XCTAssertEqual(c.resultOnMain, [true])
    }

    func test_a_prepare_returning_nil_runs_nothing() {
        let c = Counter()
        let saver = makeSaver(c, skip: true)
        saver.schedule()
        spin(until: { c.prepares == 1 })
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
        XCTAssertEqual(c.prepares, 1)
        XCTAssertEqual(c.saves, 0)
        XCTAssertEqual(c.results, 0)
    }

    func test_flush_saves_once_and_the_cancelled_timer_fires_nothing() {
        let c = Counter()
        let saver = makeSaver(c)
        saver.schedule()
        saver.flush()
        XCTAssertEqual(c.saves, 1, "flush saves synchronously")
        XCTAssertEqual(c.results, 1)
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.35))
        XCTAssertEqual(c.saves, 1)
    }

    func test_a_schedule_from_a_background_queue_still_yields_one_save() {
        let c = Counter()
        let saver = makeSaver(c)
        let queued = expectation(description: "scheduled off main")
        DispatchQueue.global().async {
            saver.schedule()
            saver.schedule()
            queued.fulfill()
        }
        wait(for: [queued], timeout: 2)
        spin(until: { c.results == 1 })
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.3))
        XCTAssertEqual(c.saves, 1)
    }

    /// `performNow` goes through the same serial queue as the debounced work, so an explicit save lands
    /// after one already in flight (GCD may run the closure itself on the calling thread, which is the
    /// point of an explicit, blocking save).
    func test_performNow_waits_behind_a_save_already_in_flight() throws {
        let order = NSMutableArray()
        let saver = DebouncedSaver(
            interval: 0.05,
            queue: DebouncedSaver.makeQueue(label: "test.saver.order"),
            prepare: { { Thread.sleep(forTimeInterval: 0.3); order.add("debounced") } },
            completion: { _ in }
        )
        saver.schedule()
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.15))  // the debounced work is now running
        try saver.performNow { order.add("explicit") }
        XCTAssertEqual(order as? [String], ["debounced", "explicit"])
    }
}
