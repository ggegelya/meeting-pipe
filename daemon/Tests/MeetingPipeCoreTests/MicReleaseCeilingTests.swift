import XCTest
@testable import MeetingPipeCore

/// END23: the Teams mic-release ceiling, pure. Snapshots are one a second on the monitor's clock.
final class MicReleaseCeilingTests: XCTestCase {

    private static let teams2 = "com.microsoft.teams2"
    private static let classic = "com.microsoft.teams"

    /// Teams 2 at `level`, classic Teams released and never held (the usual machine).
    private func snapshot(
        _ at: TimeInterval, _ level: MicHolderLevel, leftHeldAt: TimeInterval?,
        classic: MicHolderMonitor.Reading? = nil
    ) -> MicHolderMonitor.Snapshot {
        MicHolderMonitor.Snapshot(at: at, readings: [
            Self.teams2: .init(level: level, since: leftHeldAt ?? at, readAt: at, leftHeldAt: level == .held ? nil : leftHeldAt),
            Self.classic: classic ?? .init(level: .released, since: 0, readAt: at, leftHeldAt: nil),
        ])
    }

    /// Feed `level` once a second over `seconds`, from `from` inclusive; returns every decision.
    private func run(
        _ ceiling: inout MicReleaseCeiling, from: TimeInterval, seconds: Int, _ level: MicHolderLevel,
        leftHeldAt: TimeInterval?
    ) -> [(TimeInterval, MicReleaseCeiling.Decision)] {
        (0..<seconds).map { offset in
            let at = from + TimeInterval(offset)
            return (at, ceiling.observe(snapshot(at, level, leftHeldAt: leftHeldAt)))
        }
    }

    private func stops(_ decisions: [(TimeInterval, MicReleaseCeiling.Decision)]) -> [(TimeInterval, TimeInterval)] {
        decisions.compactMap { at, decision in
            if case .stop(let cut, _) = decision { return (at, cut) }
            return nil
        }
    }

    func testATeamsReleaseHeld120sStopsWithTheCutAtTheRelease() {
        var ceiling = MicReleaseCeiling(recordingStartedAt: 0)
        _ = run(&ceiling, from: 10, seconds: 50, .held, leftHeldAt: nil)
        // The monitor's first non-held sample was 60; the host first sees the release at 61.
        let decisions = run(&ceiling, from: 61, seconds: 200, .released, leftHeldAt: 60)
        XCTAssertEqual(decisions.first?.1, .releaseStarted(cut: 60))
        let stop = stops(decisions)
        XCTAssertEqual(stop.count, 1, "returned once")
        XCTAssertEqual(stop.first?.0, 181)
        XCTAssertEqual(stop.first?.1, 60, "the cut is the release, not the host's first sample")
    }

    func testA23sGapThatReturnsStopsNothingAndClearsTheClock() {
        var ceiling = MicReleaseCeiling(recordingStartedAt: 0)
        _ = run(&ceiling, from: 0, seconds: 10, .held, leftHeldAt: nil)
        XCTAssertTrue(stops(run(&ceiling, from: 10, seconds: 23, .released, leftHeldAt: 10)).isEmpty)
        _ = run(&ceiling, from: 33, seconds: 5, .held, leftHeldAt: nil)
        XCTAssertNil(ceiling.cut)
        XCTAssertEqual(ceiling.releasedSeconds, 0)
        // A later 110 s release does not inherit the first gap's 23 s.
        XCTAssertTrue(stops(run(&ceiling, from: 38, seconds: 110, .released, leftHeldAt: 38)).isEmpty)
    }

    func testUnknownInsideAReleasePausesTheClock() {
        var ceiling = MicReleaseCeiling(recordingStartedAt: 0)
        _ = run(&ceiling, from: 0, seconds: 5, .held, leftHeldAt: nil)
        XCTAssertTrue(stops(run(&ceiling, from: 5, seconds: 101, .released, leftHeldAt: 5)).isEmpty, "100 s counted")
        XCTAssertTrue(stops(run(&ceiling, from: 106, seconds: 30, .unknown, leftHeldAt: 5)).isEmpty)
        let resumed = run(&ceiling, from: 136, seconds: 30, .released, leftHeldAt: 5)
        let stop = stops(resumed)
        XCTAssertEqual(stop.first?.0, 156, "120 s of released samples, the unknown 30 s not among them")
        XCTAssertEqual(stop.first?.1, 5, "the pause keeps the release's cut")
    }

    func testAZoomSourcedRecordingNeverGetsTheCeiling() {
        XCTAssertFalse(MicReleaseCeiling.applies(toBundleID: "us.zoom.xos", isNative: true))
        XCTAssertFalse(MicReleaseCeiling.applies(toBundleID: "com.google.Chrome", isNative: false))
        XCTAssertFalse(MicReleaseCeiling.applies(toBundleID: Self.teams2, isNative: false), "Teams in a browser")
        XCTAssertFalse(MicReleaseCeiling.applies(toBundleID: nil, isNative: true), "a manual recording")
        XCTAssertTrue(MicReleaseCeiling.applies(toBundleID: Self.teams2, isNative: true))
        XCTAssertTrue(MicReleaseCeiling.applies(toBundleID: Self.classic, isNative: true))
    }

    func testAReleaseFromBeforeTheRecordingDoesNotArmIt() {
        var ceiling = MicReleaseCeiling(recordingStartedAt: 100)
        let decisions = run(&ceiling, from: 100, seconds: 300, .released, leftHeldAt: 40)
        XCTAssertTrue(stops(decisions).isEmpty)
        XCTAssertNil(ceiling.cut)
        // Once Teams holds inside the recording, its next release arms it.
        _ = run(&ceiling, from: 400, seconds: 5, .held, leftHeldAt: nil)
        XCTAssertEqual(stops(run(&ceiling, from: 405, seconds: 130, .released, leftHeldAt: 405)).count, 1)
    }

    func testARecordingWhereTeamsNeverHeldRuns300sWithNoStop() {
        var ceiling = MicReleaseCeiling(recordingStartedAt: 0)
        XCTAssertTrue(stops(run(&ceiling, from: 0, seconds: 300, .released, leftHeldAt: nil)).isEmpty)
    }

    func testTheCutIsTheLaterOfTheTwoFamiliesReleases() {
        var ceiling = MicReleaseCeiling(recordingStartedAt: 0)
        let classicReleased = MicHolderMonitor.Reading(level: .released, since: 50, readAt: 70, leftHeldAt: 50)
        let first = ceiling.observe(snapshot(70, .released, leftHeldAt: 65, classic: classicReleased))
        XCTAssertEqual(first, .releaseStarted(cut: 65))
        let classicHeld = MicHolderMonitor.Reading(level: .held, since: 71, readAt: 71)
        XCTAssertEqual(ceiling.observe(snapshot(71, .released, leftHeldAt: 65, classic: classicHeld)), .none)
        XCTAssertNil(ceiling.cut, "either family holding clears it")
        let missing = MicHolderMonitor.Snapshot(at: 72, readings: [
            Self.teams2: .init(level: .released, since: 65, readAt: 72, leftHeldAt: 65),
        ])
        XCTAssertEqual(ceiling.observe(missing), .none, "a family the snapshot lacks reads unknown")
        XCTAssertNil(ceiling.cut)
    }

    func testAHoldTooShortForTheHostToSeeRestartsTheClock() {
        var ceiling = MicReleaseCeiling(recordingStartedAt: 0)
        _ = run(&ceiling, from: 0, seconds: 5, .held, leftHeldAt: nil)
        _ = run(&ceiling, from: 6, seconds: 100, .released, leftHeldAt: 5)
        // Teams re-acquired and let go again between two host reads: `leftHeldAt` moved.
        let decisions = run(&ceiling, from: 106, seconds: 130, .released, leftHeldAt: 105)
        XCTAssertEqual(decisions.first?.1, .releaseStarted(cut: 105))
        XCTAssertEqual(stops(decisions).first?.0, 226)
        XCTAssertEqual(stops(decisions).first?.1, 105)
    }

    func testAGapLongerThanTheCapIsNotCredited() {
        var ceiling = MicReleaseCeiling(recordingStartedAt: 0)
        _ = ceiling.observe(snapshot(0, .held, leftHeldAt: nil))
        _ = ceiling.observe(snapshot(1, .released, leftHeldAt: 1))
        // The host stalled for 10 minutes: one sample, credited at most the cap.
        XCTAssertEqual(ceiling.observe(snapshot(601, .released, leftHeldAt: 1)), .none)
        XCTAssertEqual(ceiling.releasedSeconds, MicReleaseCeiling.maxCreditPerSample)
    }
}
