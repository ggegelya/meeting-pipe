import XCTest
@testable import MeetingPipeCore

final class MicOnlySilenceBackstopTests: XCTestCase {

    func test_does_not_trigger_below_window() {
        let backstop = MicOnlySilenceBackstop(windowSeconds: 480)
        var triggered = false
        backstop.onTriggered = { _ in triggered = true }

        let start = Date(timeIntervalSince1970: 0)
        backstop.ingest(verdict: .silentByRMS(dwellMillis: 0), hasSystemAudio: false, at: start)
        backstop.ingest(
            verdict: .silentByRMS(dwellMillis: 0),
            hasSystemAudio: false,
            at: start.addingTimeInterval(400)
        )
        XCTAssertFalse(triggered)
        XCTAssertFalse(backstop.triggered)
    }

    func test_triggers_after_window_elapses() {
        let backstop = MicOnlySilenceBackstop(windowSeconds: 480)
        var firedAt: Date?
        backstop.onTriggered = { firedAt = $0 }

        let start = Date(timeIntervalSince1970: 0)
        backstop.ingest(verdict: .silentByRMS(dwellMillis: 0), hasSystemAudio: false, at: start)
        backstop.ingest(
            verdict: .silentByRMS(dwellMillis: 0),
            hasSystemAudio: false,
            at: start.addingTimeInterval(480)
        )
        XCTAssertNotNil(firedAt)
        XCTAssertTrue(backstop.triggered)
    }

    func test_system_audio_resets_accumulator() {
        let backstop = MicOnlySilenceBackstop(windowSeconds: 480)
        var triggered = false
        backstop.onTriggered = { _ in triggered = true }

        let start = Date(timeIntervalSince1970: 0)
        backstop.ingest(verdict: .silentByRMS(dwellMillis: 0), hasSystemAudio: false, at: start)
        backstop.ingest(
            verdict: .silentByRMS(dwellMillis: 0),
            hasSystemAudio: true,
            at: start.addingTimeInterval(100)
        )
        backstop.ingest(
            verdict: .silentByRMS(dwellMillis: 0),
            hasSystemAudio: false,
            at: start.addingTimeInterval(500)
        )
        XCTAssertFalse(triggered, "System audio mid-window must reset the accumulator")
    }

    func test_hot_verdict_resets_accumulator() {
        let backstop = MicOnlySilenceBackstop(windowSeconds: 480)
        var triggered = false
        backstop.onTriggered = { _ in triggered = true }

        let start = Date(timeIntervalSince1970: 0)
        backstop.ingest(verdict: .silentByRMS(dwellMillis: 0), hasSystemAudio: false, at: start)
        backstop.ingest(
            verdict: .hot(reason: .voiceActivityDetected),
            hasSystemAudio: false,
            at: start.addingTimeInterval(100)
        )
        backstop.ingest(
            verdict: .silentByRMS(dwellMillis: 0),
            hasSystemAudio: false,
            at: start.addingTimeInterval(500)
        )
        XCTAssertFalse(triggered, "User speaking must reset the accumulator")
    }

    func test_confidently_unmuted_floor_still_counts_as_silence() {
        // TECH-MIC5: the confidently-unmuted floor reports .hot to keep audio,
        // but the user is quiet, so the forgotten-recording backstop must still
        // fire on a long unmuted-but-silent stretch (it would not if .hot blanket
        // reset the accumulator).
        let backstop = MicOnlySilenceBackstop(windowSeconds: 480)
        var firedAt: Date?
        backstop.onTriggered = { firedAt = $0 }

        let start = Date(timeIntervalSince1970: 0)
        backstop.ingest(verdict: .hot(reason: .confidentlyUnmuted), hasSystemAudio: false, at: start)
        backstop.ingest(
            verdict: .hot(reason: .confidentlyUnmuted),
            hasSystemAudio: false,
            at: start.addingTimeInterval(480)
        )
        XCTAssertEqual(firedAt, start.addingTimeInterval(480),
                       "unmuted-but-quiet must still accrue toward the silence backstop")
    }

    func test_triggered_state_is_sticky() {
        let backstop = MicOnlySilenceBackstop(windowSeconds: 480)
        var triggerCount = 0
        backstop.onTriggered = { _ in triggerCount += 1 }

        let start = Date(timeIntervalSince1970: 0)
        backstop.ingest(verdict: .silentByRMS(dwellMillis: 0), hasSystemAudio: false, at: start)
        backstop.ingest(
            verdict: .silentByRMS(dwellMillis: 0),
            hasSystemAudio: false,
            at: start.addingTimeInterval(500)
        )
        backstop.ingest(
            verdict: .silentByRMS(dwellMillis: 0),
            hasSystemAudio: false,
            at: start.addingTimeInterval(1000)
        )
        XCTAssertEqual(triggerCount, 1, "Backstop must fire at most once per reset cycle")
    }

    func test_reset_re_arms_the_backstop() {
        let backstop = MicOnlySilenceBackstop(windowSeconds: 480)
        var triggerCount = 0
        backstop.onTriggered = { _ in triggerCount += 1 }

        let start = Date(timeIntervalSince1970: 0)
        backstop.ingest(verdict: .silentByRMS(dwellMillis: 0), hasSystemAudio: false, at: start)
        backstop.ingest(
            verdict: .silentByRMS(dwellMillis: 0),
            hasSystemAudio: false,
            at: start.addingTimeInterval(500)
        )
        XCTAssertEqual(triggerCount, 1)

        backstop.reset()
        backstop.ingest(verdict: .silentByRMS(dwellMillis: 0), hasSystemAudio: false, at: start.addingTimeInterval(1000))
        backstop.ingest(
            verdict: .silentByRMS(dwellMillis: 0),
            hasSystemAudio: false,
            at: start.addingTimeInterval(1500)
        )
        XCTAssertEqual(triggerCount, 2)
    }

    func test_muted_by_app_counts_as_silence() {
        let backstop = MicOnlySilenceBackstop(windowSeconds: 480)
        var triggered = false
        backstop.onTriggered = { _ in triggered = true }
        let start = Date(timeIntervalSince1970: 0)

        backstop.ingest(
            verdict: .mutedByApp(axLabel: "Unmute", locale: "en"),
            hasSystemAudio: false, at: start
        )
        backstop.ingest(
            verdict: .mutedByApp(axLabel: "Unmute", locale: "en"),
            hasSystemAudio: false, at: start.addingTimeInterval(500)
        )
        XCTAssertTrue(triggered, "An app-muted user with no system audio is still a forgotten recording")
    }
}
