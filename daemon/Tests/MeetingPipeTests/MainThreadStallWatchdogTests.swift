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

    /// Blocks the main queue for 400 ms and sees exactly one row.
    func testBlockedMainQueueEmitsOneRow() {
        let lock = NSLock()
        var rows: [[String: Any]] = []
        let wd = MainThreadStallWatchdog(
            interval: 0.05,
            // Above the 100 ms default so a loaded runner's spurious wait before the block cannot
            // take the one row and suppress the real stall.
            thresholdMs: 300,
            context: { ["recording": false] },
            emit: { attrs in lock.lock(); rows.append(attrs); lock.unlock() }
        )
        wd.start()
        // Let a couple of healthy pings through, then block main.
        let warm = expectation(description: "warm")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { warm.fulfill() }
        wait(for: [warm], timeout: 2)
        let blocked = expectation(description: "blocked")
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.4); blocked.fulfill() }
        wait(for: [blocked], timeout: 3)
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
