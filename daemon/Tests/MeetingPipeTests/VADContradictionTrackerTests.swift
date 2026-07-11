import XCTest
@testable import MeetingPipe

/// MIC10 part 2: the pure dwell tracker. Clock-injected so the sustained-contradiction timing is
/// tested deterministically, mirroring `RMSGateProbeTests`.
final class VADContradictionTrackerTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_000_000)

    func test_no_contradiction_never_fires() {
        var current = base
        var tracker = VADContradictionTracker(dwellSeconds: 4.0, clock: { current })
        // App muted but no voice: expected muted, no contradiction.
        for _ in 0..<10 {
            XCTAssertFalse(tracker.observe(appMuted: true, vadActive: false))
            current = current.addingTimeInterval(1)
        }
        // Voice but app not muted: normal talking, no contradiction.
        for _ in 0..<10 {
            XCTAssertFalse(tracker.observe(appMuted: false, vadActive: true))
            current = current.addingTimeInterval(1)
        }
    }

    func test_sustained_contradiction_fires_after_the_dwell() {
        var current = base
        var tracker = VADContradictionTracker(dwellSeconds: 4.0, clock: { current })

        XCTAssertFalse(tracker.observe(appMuted: true, vadActive: true), "t=0 is below dwell")
        current = current.addingTimeInterval(1)
        XCTAssertFalse(tracker.observe(appMuted: true, vadActive: true), "t=1 is below dwell")
        current = current.addingTimeInterval(2)
        XCTAssertFalse(tracker.observe(appMuted: true, vadActive: true), "t=3 is still below dwell")
        current = current.addingTimeInterval(1)
        XCTAssertTrue(tracker.observe(appMuted: true, vadActive: true), "t=4 meets the 4 s dwell")
    }

    func test_fires_once_per_streak() {
        var current = base
        var tracker = VADContradictionTracker(dwellSeconds: 4.0, clock: { current })
        XCTAssertFalse(tracker.observe(appMuted: true, vadActive: true), "the first observation starts the streak")
        current = current.addingTimeInterval(5)
        XCTAssertTrue(tracker.observe(appMuted: true, vadActive: true), "fires once the dwell is met")
        // Still contradicting, but already discredited: no repeat fire.
        current = current.addingTimeInterval(5)
        XCTAssertFalse(tracker.observe(appMuted: true, vadActive: true))
        current = current.addingTimeInterval(5)
        XCTAssertFalse(tracker.observe(appMuted: true, vadActive: true))
    }

    func test_rearms_after_the_contradiction_clears() {
        var current = base
        var tracker = VADContradictionTracker(dwellSeconds: 4.0, clock: { current })
        XCTAssertFalse(tracker.observe(appMuted: true, vadActive: true), "start the streak")
        current = current.addingTimeInterval(5)
        XCTAssertTrue(tracker.observe(appMuted: true, vadActive: true))

        // The user stops the side-talk (VAD off): the streak resets.
        XCTAssertFalse(tracker.observe(appMuted: true, vadActive: false))

        // A fresh contradiction must arm from scratch, not fire immediately.
        XCTAssertFalse(tracker.observe(appMuted: true, vadActive: true), "re-armed streak starts at t=0")
        current = current.addingTimeInterval(4)
        XCTAssertTrue(tracker.observe(appMuted: true, vadActive: true), "fires again after another full dwell")
    }

    func test_reset_drops_an_in_flight_streak() {
        var current = base
        var tracker = VADContradictionTracker(dwellSeconds: 4.0, clock: { current })
        _ = tracker.observe(appMuted: true, vadActive: true)
        tracker.reset()
        current = current.addingTimeInterval(10)
        // Without reset this would fire (10 s > dwell); reset cleared the accumulator.
        XCTAssertFalse(tracker.observe(appMuted: true, vadActive: true))
    }
}
