import XCTest
@testable import MeetingPipeCore

/// OBS9: `verdict_changed` only when what the verdict does changes; the rest is counted into
/// `verdict_churn`.
final class MicGateChurnTests: XCTestCase {

    private let rmsHot = MicGateVerdict.hot(reason: .rmsAboveOpenThreshold)
    private let unmutedHot = MicGateVerdict.hot(reason: .confidentlyUnmuted)
    private let quiet = MicGateVerdict.silentByRMS(dwellMillis: 0)
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func test_a_reason_swap_does_not_change_the_effect_and_a_mute_does() {
        XCTAssertTrue(VerdictChurn.changesEffect(from: nil, to: rmsHot))
        XCTAssertFalse(VerdictChurn.changesEffect(from: rmsHot, to: unmutedHot))
        XCTAssertTrue(VerdictChurn.changesEffect(from: rmsHot, to: .mutedByApp(axLabel: "Unmute", locale: "en")))
        XCTAssertFalse(VerdictChurn.changesEffect(
            from: .mutedByApp(axLabel: "Unmute", locale: "en"), to: .mutedByApp(axLabel: "Unmute mic", locale: "en")
        ))
        XCTAssertTrue(VerdictChurn.changesEffect(from: rmsHot, to: quiet))
    }

    func test_churn_waits_for_its_minute_and_counts_rms_opens_and_closes() {
        var churn = VerdictChurn()
        churn.note(previous: rmsHot, next: unmutedHot, logged: false, at: t0)
        churn.note(previous: unmutedHot, next: quiet, logged: true, at: t0.addingTimeInterval(1))
        churn.note(previous: quiet, next: rmsHot, logged: true, at: t0.addingTimeInterval(2))
        XCTAssertNil(churn.drain(at: t0.addingTimeInterval(30), force: false))
        let row = churn.drain(at: t0.addingTimeInterval(61), force: false)
        XCTAssertEqual(row?["reason_swaps"] as? Int, 1)
        XCTAssertEqual(row?["rms_closes"] as? Int, 1)
        XCTAssertEqual(row?["rms_opens"] as? Int, 1)
        XCTAssertEqual(row?["window_sec"] as? Int, 61)
        XCTAssertNil(churn.drain(at: t0.addingTimeInterval(200), force: true), "drained counts are not written twice")
    }

    func test_an_alternating_reason_writes_one_change_and_one_churn_row_at_stop() throws {
        let log = RecordingEventLog()
        let gate = MicGate(
            catalogue: try MuteLabelsLoader.loadDefault(),
            halBus: CoreAudioHALBus(), axBus: AXObserverBus(), eventLog: log
        )
        // rms open with a confident unmute is `rms_above_open_threshold`; closed is `confidently_unmuted`.
        gate.debugUpdate { $0.axMute = .unmuted; $0.rmsState = .open }
        for _ in 0..<5 {
            gate.debugUpdate { $0.rmsState = .closed }
            gate.debugUpdate { $0.rmsState = .open }
        }
        gate.debugDrainPublishQueue()
        XCTAssertEqual(log.entries.filter { $0.action == "verdict_changed" }.count, 1)
        XCTAssertTrue(log.entries.filter { $0.action == "verdict_churn" }.isEmpty, "inside the minute, nothing yet")

        gate.debugUpdate { $0.axMute = .muted }
        gate.debugDrainPublishQueue()
        let changes = log.entries.filter { $0.action == "verdict_changed" }
        XCTAssertEqual(changes.count, 2, "a hot to muted change is written at once")
        XCTAssertEqual(changes.last?.attributes["verdict"], "muted_by_app")

        gate.stop()
        gate.debugDrainPublishQueue()
        let churn = log.entries.filter { $0.action == "verdict_churn" }
        XCTAssertEqual(churn.count, 1)
        XCTAssertEqual(churn.first?.attributes["reason_swaps"], "10")
    }
}
