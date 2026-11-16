import XCTest
@testable import MeetingPipe

/// The pure span-bound prompt hold (DET18). Locking in:
///   - A skip and a timeout's offer are both holds; only the skip is a skip.
///   - A live reading keeps the hold however long the call runs.
///   - For a microphone-span app, a positive "off" read with no confident winner ends the span at
///     once, and so does the app vanishing from the scan; an unknown read is ignorance.
///   - Ignorance lapses the hold after the grace, counted per feed and capped per gap.
///   - A title-span app has no positive end.
///   - A mic-tier hold reads only the mic-busy feed.
///   - Holds are per bundle, and `clear` drops one.
final class SkippedMeetingLatchTests: XCTestCase {

    private static let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Teams")
    private static let zoom = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")
    private static let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func latch() -> SkippedMeetingLatch {
        SkippedMeetingLatch(ignoranceGraceSec: 60, maxGapSec: 12)
    }

    func test_no_entry_means_no_hold() {
        let l = latch()
        XCTAssertFalse(l.isHeld(bundleID: Self.teams.bundleID))
        XCTAssertFalse(l.isSkipped(bundleID: Self.teams.bundleID))
    }

    func test_skip_and_offer_are_both_holds_but_only_one_is_a_skip() {
        var l = latch()
        l.arm(source: Self.teams, mode: .skipped, liveness: .processAudio, at: Self.t0)
        l.arm(source: Self.zoom, mode: .offered, liveness: .processAudio, at: Self.t0)
        XCTAssertTrue(l.isSkipped(bundleID: Self.teams.bundleID))
        XCTAssertTrue(l.isHeld(bundleID: Self.zoom.bundleID))
        XCTAssertFalse(l.isSkipped(bundleID: Self.zoom.bundleID))
        XCTAssertTrue(l.isOffered(bundleID: Self.zoom.bundleID))
    }

    func test_a_live_microphone_keeps_the_hold_for_an_hour() {
        var l = latch()
        l.arm(source: Self.teams, mode: .skipped, liveness: .processAudio, at: Self.t0)
        for i in 1...300 {
            let ended = l.feedScan([Self.teams.bundleID: .init(processAudio: true)], at: Self.t0.addingTimeInterval(Double(i) * 12))
            XCTAssertTrue(ended.isEmpty)
        }
        XCTAssertTrue(l.isHeld(bundleID: Self.teams.bundleID))
    }

    func test_two_positive_off_reads_with_no_winner_end_the_span() {
        var l = latch()
        l.arm(source: Self.teams, mode: .skipped, liveness: .processAudio, at: Self.t0)
        XCTAssertTrue(l.feedScan([Self.teams.bundleID: .init(processAudio: false)], at: Self.t0.addingTimeInterval(1)).isEmpty)
        let ended = l.feedScan([Self.teams.bundleID: .init(processAudio: false)], at: Self.t0.addingTimeInterval(4))
        XCTAssertEqual(ended.map(\.source), [Self.teams])
        XCTAssertFalse(l.isHeld(bundleID: Self.teams.bundleID))
    }

    func test_an_unknown_read_is_not_an_end() {
        var l = latch()
        l.arm(source: Self.teams, mode: .skipped, liveness: .processAudio, at: Self.t0)
        _ = l.feedScan([Self.teams.bundleID: .init(processAudio: nil)], at: Self.t0.addingTimeInterval(12))
        XCTAssertTrue(l.isHeld(bundleID: Self.teams.bundleID))
    }

    func test_ignorance_lapses_after_the_grace_and_a_long_gap_counts_one_poll() {
        var l = latch()
        l.arm(source: Self.teams, mode: .skipped, liveness: .processAudio, at: Self.t0)
        // One huge gap (the scans were gated) adds only 12 s.
        _ = l.feedScan([Self.teams.bundleID: .init()], at: Self.t0.addingTimeInterval(3_600))
        XCTAssertEqual(l.entry(bundleID: Self.teams.bundleID)?.unseenSec, 12)
        var at = Self.t0.addingTimeInterval(3_600)
        for _ in 1...3 {
            at = at.addingTimeInterval(12)
            _ = l.feedScan([Self.teams.bundleID: .init()], at: at)
        }
        XCTAssertTrue(l.isHeld(bundleID: Self.teams.bundleID), "48 s of ignorance is inside DET9's grace")
        at = at.addingTimeInterval(12)
        let ended = l.feedScan([Self.teams.bundleID: .init()], at: at)
        XCTAssertEqual(ended.count, 1)
    }

    func test_the_verdict_table() {
        typealias L = SkippedMeetingLatch
        XCTAssertEqual(L.verdict(liveness: .processAudio, kind: .native, reading: nil), .gone)
        XCTAssertEqual(L.verdict(liveness: .processAudio, kind: .native, reading: .init(processAudio: true)), .live)
        XCTAssertEqual(L.verdict(liveness: .processAudio, kind: .native, reading: .init(processAudio: false, isWinner: true)), .live)
        XCTAssertEqual(L.verdict(liveness: .processAudio, kind: .native, reading: .init(processAudio: false)), .absent)
        XCTAssertEqual(L.verdict(liveness: .processAudio, kind: .native, reading: .init(processAudio: nil)), .unknown)
        XCTAssertEqual(L.verdict(liveness: .title, kind: .browser, reading: nil), .unknown)
        XCTAssertEqual(L.verdict(liveness: .title, kind: .browser, reading: .init(titleMatch: true)), .live)
        XCTAssertEqual(L.verdict(liveness: .title, kind: .native, reading: .init(isWinner: true)), .live)
        XCTAssertEqual(L.verdict(liveness: .title, kind: .native, reading: .init()), .unknown)
    }

    func test_mic_busy_holds_ignore_scans_and_end_on_a_change_of_holder() {
        var l = latch()
        let slack = AppSource(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack")
        l.arm(source: slack, mode: .offered, liveness: .micBusy, at: Self.t0)
        XCTAssertTrue(l.feedScan([:], at: Self.t0.addingTimeInterval(600)).isEmpty)
        XCTAssertTrue(l.feedMicBusy(busyBundle: slack.bundleID, at: Self.t0.addingTimeInterval(601)).isEmpty)
        XCTAssertEqual(l.feedMicBusy(busyBundle: nil, at: Self.t0.addingTimeInterval(602)).map(\.source), [slack])
    }

    func test_holds_are_per_bundle_and_clear_drops_one() {
        var l = latch()
        l.arm(source: Self.teams, mode: .skipped, liveness: .processAudio, at: Self.t0)
        l.arm(source: Self.zoom, mode: .skipped, liveness: .processAudio, at: Self.t0)
        for i in 1...2 {
            _ = l.feedScan(
                [Self.teams.bundleID: .init(processAudio: false), Self.zoom.bundleID: .init(processAudio: true)],
                at: Self.t0.addingTimeInterval(Double(i))
            )
        }
        XCTAssertFalse(l.isHeld(bundleID: Self.teams.bundleID))
        XCTAssertTrue(l.isHeld(bundleID: Self.zoom.bundleID))
        l.clear(bundleID: Self.zoom.bundleID)
        XCTAssertFalse(l.isHeld(bundleID: Self.zoom.bundleID))
    }
}
