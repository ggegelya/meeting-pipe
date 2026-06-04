import XCTest
@testable import MeetingPipeCore

final class RMSGateProbeTests: XCTestCase {

    final class TestClock {
        var now: Date = Date(timeIntervalSince1970: 0)
        func read() -> Date { now }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    func test_starts_closed() {
        let probe = RMSGateProbe()
        XCTAssertEqual(probe.state, .closed)
    }

    func test_opens_after_sustained_open_dwell() {
        let clock = TestClock()
        let probe = RMSGateProbe(
            closeThresholdDb: -55,
            openThresholdDb: -45,
            closeDwellMillis: 350,
            openDwellMillis: 80,
            clock: clock.read
        )
        var transitions: [RMSGateProbe.State] = []
        probe.onChange = { transitions.append($0) }

        XCTAssertEqual(probe.ingest(dBFS: -30), .closed)
        clock.advance(0.05)
        XCTAssertEqual(probe.ingest(dBFS: -30), .closed, "Should not open before dwell elapses")
        clock.advance(0.05)
        XCTAssertEqual(probe.ingest(dBFS: -30), .open)
        XCTAssertEqual(transitions, [.open])
    }

    func test_closes_after_sustained_close_dwell() {
        let clock = TestClock()
        let probe = RMSGateProbe(
            closeThresholdDb: -55,
            openThresholdDb: -45,
            closeDwellMillis: 350,
            openDwellMillis: 80,
            clock: clock.read
        )

        // Open the gate first.
        XCTAssertEqual(probe.ingest(dBFS: -30), .closed)
        clock.advance(0.1)
        XCTAssertEqual(probe.ingest(dBFS: -30), .open)

        var transitions: [RMSGateProbe.State] = []
        probe.onChange = { transitions.append($0) }

        clock.advance(0.1)
        XCTAssertEqual(probe.ingest(dBFS: -60), .open, "Close dwell has not elapsed")
        clock.advance(0.4)
        XCTAssertEqual(probe.ingest(dBFS: -60), .closed)
        XCTAssertEqual(transitions, [.closed])
    }

    func test_brief_spike_does_not_open_the_gate() {
        let clock = TestClock()
        let probe = RMSGateProbe(
            closeThresholdDb: -55,
            openThresholdDb: -45,
            closeDwellMillis: 350,
            openDwellMillis: 80,
            clock: clock.read
        )

        XCTAssertEqual(probe.ingest(dBFS: -30), .closed)
        clock.advance(0.03)
        XCTAssertEqual(probe.ingest(dBFS: -60), .closed, "Spike interrupted before dwell elapses")
        clock.advance(0.1)
        XCTAssertEqual(probe.ingest(dBFS: -60), .closed)
    }

    func test_brief_dip_does_not_close_the_gate() {
        let clock = TestClock()
        let probe = RMSGateProbe(
            closeThresholdDb: -55,
            openThresholdDb: -45,
            closeDwellMillis: 350,
            openDwellMillis: 80,
            clock: clock.read
        )
        XCTAssertEqual(probe.ingest(dBFS: -30), .closed)
        clock.advance(0.1)
        XCTAssertEqual(probe.ingest(dBFS: -30), .open)

        clock.advance(0.1)
        XCTAssertEqual(probe.ingest(dBFS: -60), .open)
        clock.advance(0.05)
        XCTAssertEqual(probe.ingest(dBFS: -30), .open, "Dip interrupted before dwell elapses")
        clock.advance(0.5)
        XCTAssertEqual(probe.ingest(dBFS: -30), .open)
    }

    func test_reset_returns_to_closed_and_clears_accumulators() {
        let clock = TestClock()
        let probe = RMSGateProbe(clock: clock.read)
        _ = probe.ingest(dBFS: -30)
        clock.advance(0.5)
        _ = probe.ingest(dBFS: -30)
        XCTAssertEqual(probe.state, .open)

        probe.reset()
        XCTAssertEqual(probe.state, .closed)

        // After reset a single sample should not immediately re-open.
        XCTAssertEqual(probe.ingest(dBFS: -30), .closed)
    }
}
