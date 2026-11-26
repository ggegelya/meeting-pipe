import XCTest
@testable import MeetingPipe

/// PERF11: the pure decision at the audit's thresholds, and one real stall end to end.
final class MainThreadStallWatchdogTests: XCTestCase {

    func testBelowThresholdEmitsNothing() {
        XCTAssertEqual(StallDetector.decide(waitMs: 99, nowUptime: 100, lastEmitUptime: nil, suppressedSoFar: 0), .none)
    }

    func testThresholdEmitsWithoutOverBudget() {
        XCTAssertEqual(StallDetector.decide(waitMs: 100, nowUptime: 100, lastEmitUptime: nil, suppressedSoFar: 0),
                       .emit(overBudget: false, suppressed: 0))
        XCTAssertEqual(StallDetector.decide(waitMs: 249, nowUptime: 100, lastEmitUptime: nil, suppressedSoFar: 0),
                       .emit(overBudget: false, suppressed: 0))
    }

    func testBudgetBreachIsFlagged() {
        XCTAssertEqual(StallDetector.decide(waitMs: 250, nowUptime: 100, lastEmitUptime: nil, suppressedSoFar: 0),
                       .emit(overBudget: true, suppressed: 0))
    }

    func testRateLimitWindowSuppressesThenCarriesCount() {
        XCTAssertEqual(StallDetector.decide(waitMs: 300, nowUptime: 105, lastEmitUptime: 100, suppressedSoFar: 0), .suppress)
        XCTAssertEqual(StallDetector.decide(waitMs: 300, nowUptime: 109.9, lastEmitUptime: 100, suppressedSoFar: 3), .suppress)
        XCTAssertEqual(StallDetector.decide(waitMs: 300, nowUptime: 110, lastEmitUptime: 100, suppressedSoFar: 3),
                       .emit(overBudget: true, suppressed: 3))
    }

    func testSubThresholdInsideWindowIsNotCounted() {
        XCTAssertEqual(StallDetector.decide(waitMs: 50, nowUptime: 101, lastEmitUptime: 100, suppressedSoFar: 2), .none)
    }

    /// OBS7: the row names the last click and how long ago it ran. Load-proof the same way as the
    /// test below: a 1 s block against a 300 ms threshold, and the test waits for the row itself.
    func testStallRowCarriesTheLastUIActionWhenOneExists() {
        let lock = NSLock()
        var rows: [[String: Any]] = []
        let rowSeen = expectation(description: "row")
        rowSeen.assertForOverFulfill = false
        let wd = MainThreadStallWatchdog(
            interval: 0.05, thresholdMs: 300,
            lastUIAction: { (seq: 7, sinceMs: 412) },
            emit: { attrs in lock.lock(); rows.append(attrs); lock.unlock(); rowSeen.fulfill() }
        )
        wd.start()
        let warm = expectation(description: "warm")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { warm.fulfill() }
        wait(for: [warm], timeout: 2)
        let blocked = expectation(description: "blocked")
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: Self.blockSeconds); blocked.fulfill() }
        wait(for: [blocked], timeout: 5)
        wait(for: [rowSeen], timeout: 5)
        wd.stop()
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(rows.first?["last_ui_seq"] as? Int, 7)
        XCTAssertEqual(rows.first?["since_ui_action_ms"] as? Int, 412)
    }

    /// How long the two 300 ms-threshold tests block main. It used to be 400 ms, which left the
    /// utility-QoS ping timer 100 ms of slack: a ping posted more than 100 ms into the block waits
    /// under the threshold, so a loaded CI runner that ran the timer late saw no row at all and both
    /// OBS7 assertions read nil (run 45841630605, 2026-11-26). At 1 s the timer can be 700 ms late.
    static let blockSeconds: TimeInterval = 1.0

    /// Blocks the main queue for `blockSeconds` and sees exactly one row. The test waits for the row
    /// rather than a fixed delay after the block, and the default 10 s rate limit holds any later
    /// stall back, so "exactly one" is still checked.
    func testBlockedMainQueueEmitsOneRow() {
        let lock = NSLock()
        var rows: [[String: Any]] = []
        let rowSeen = expectation(description: "row")
        rowSeen.assertForOverFulfill = false
        let wd = MainThreadStallWatchdog(
            interval: 0.05,
            // Above the 100 ms default so a loaded runner's spurious wait before the block cannot
            // take the one row and suppress the real stall.
            thresholdMs: 300,
            context: { ["recording": false] },
            emit: { attrs in lock.lock(); rows.append(attrs); lock.unlock(); rowSeen.fulfill() }
        )
        wd.start()
        // Let a couple of healthy pings through, then block main.
        let warm = expectation(description: "warm")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { warm.fulfill() }
        wait(for: [warm], timeout: 2)
        let blocked = expectation(description: "blocked")
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: Self.blockSeconds); blocked.fulfill() }
        wait(for: [blocked], timeout: 5)
        wait(for: [rowSeen], timeout: 5)
        let after = expectation(description: "after")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { after.fulfill() }
        wait(for: [after], timeout: 2)
        wd.stop()
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(rows.count, 1)
        XCTAssertGreaterThanOrEqual((rows.first?["duration_ms"] as? Int) ?? 0, 300)
        XCTAssertEqual(rows.first?["recording"] as? Bool, false)
    }

    /// PERF11 amendment: the shipped interval sits in the 20 to 50 ms range, so a ping understates
    /// a stall by at most a quarter of the log threshold.
    func testShippedIntervalIsFineEnoughForTheThreshold() {
        XCTAssertGreaterThanOrEqual(MainThreadStallWatchdog.defaultInterval, 0.020)
        XCTAssertLessThanOrEqual(MainThreadStallWatchdog.defaultInterval, 0.050)
        XCTAssertLessThanOrEqual(MainThreadStallWatchdog.defaultInterval * 1000, StallDetector.logThresholdMs / 4)
    }

    /// PERF11 amendment: the watchdog at its shipped interval and threshold logs a real stall and
    /// measures most of it. Built not to split on a slow runner: the rate limit is off, so a
    /// spurious wait before the block (which a loaded runner can produce at a 100 ms threshold)
    /// adds a row rather than suppressing the real one, and the bounds are loose. The block is
    /// 1 s; the assertion is only that some row measured at least half of it, which needs one
    /// ping posted inside the block's first 500 ms against a 25 ms tick.
    func testShippedValuesCatchAndMeasureABlockedMainQueue() {
        let lock = NSLock()
        var rows: [[String: Any]] = []
        let wd = MainThreadStallWatchdog(
            rateLimitSeconds: 0,
            context: { ["recording": false] },
            emit: { attrs in lock.lock(); rows.append(attrs); lock.unlock() }
        )
        wd.start()
        let warm = expectation(description: "warm")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { warm.fulfill() }
        wait(for: [warm], timeout: 5)
        let blocked = expectation(description: "blocked")
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 1.0); blocked.fulfill() }
        wait(for: [blocked], timeout: 10)
        let after = expectation(description: "after")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { after.fulfill() }
        wait(for: [after], timeout: 5)
        wd.stop()
        lock.lock(); defer { lock.unlock() }
        let longest = rows.compactMap { $0["duration_ms"] as? Int }.max() ?? 0
        XCTAssertGreaterThanOrEqual(longest, 500, "the 1 s block is logged and mostly measured")
        XCTAssertEqual(rows.first { ($0["duration_ms"] as? Int) == longest }?["over_budget"] as? Bool, true)
    }
}
