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
        XCTAssertEqual(rows.first?["over_budget"] as? Bool, true)
        XCTAssertEqual(rows.first?["recording"] as? Bool, false)
    }
}
