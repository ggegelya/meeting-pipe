import XCTest
import MeetingPipeTestSupport

/// T13: the shared test support's own contract, since every migrated test leans on it.
final class TestSupportTests: XCTestCase {

    func test_aOneShotFireRunsOnceAndConsumes() {
        let scheduler = ManualScheduler()
        var runs = 0
        _ = scheduler.schedule(5) { runs += 1 }
        XCTAssertEqual(scheduler.lastDelay, 5)
        scheduler.fire()
        scheduler.fire()
        XCTAssertEqual(runs, 1)
        XCTAssertFalse(scheduler.hasPending)
    }

    func test_aTickKeepsTheTimerArmedAndCancelStopsIt() {
        let scheduler = ManualScheduler()
        var runs = 0
        let cancel = scheduler.schedule(1) { runs += 1 }
        scheduler.tick()
        scheduler.tick()
        XCTAssertEqual(runs, 2)
        cancel()
        cancel()  // a second cancel is not counted
        scheduler.tick()
        XCTAssertEqual(runs, 2)
        XCTAssertEqual(scheduler.cancellations, 1)
        XCTAssertEqual(scheduler.scheduleCount, 1)
    }

    func test_everyUncancelledRegistrationStaysLive() {
        let scheduler = ManualScheduler()
        _ = scheduler.schedule(1) {}
        let second = scheduler.schedule(2) {}
        XCTAssertEqual(scheduler.pendingDelays, [1, 2])
        second()
        XCTAssertEqual(scheduler.pendingDelays, [1], "a re-arm that never cancelled stays visible")
    }

    @MainActor
    func test_waitUntilSeesAConditionThatFlipsAfterSeveralHops() async {
        var flag = false
        Task { @MainActor in
            for _ in 0..<5 { await Task.yield() }
            await drainMain()
            flag = true
        }
        let held = await waitUntil { flag }
        XCTAssertTrue(held)
    }

    @MainActor
    func test_waitUntilAnswersFalseAtItsDeadline() async {
        let start = Date()
        let held = await waitUntil(timeout: 0.2) { false }
        XCTAssertFalse(held)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    @MainActor
    func test_drainMainRunsWhatWasAlreadyQueued() async {
        var ran = false
        DispatchQueue.main.async { ran = true }
        await drainMain()
        XCTAssertTrue(ran)
    }
}
