import XCTest
@testable import MeetingPipeCore

final class MicGateVerdictTests: XCTestCase {

    func test_hot_verdict_admits_live_audio() {
        XCTAssertTrue(MicGateVerdict.hot(reason: .voiceActivityDetected).passesLiveAudio)
        XCTAssertTrue(MicGateVerdict.hot(reason: .rmsAboveOpenThreshold).passesLiveAudio)
    }

    func test_non_hot_verdicts_block_live_audio() {
        XCTAssertFalse(MicGateVerdict.mutedByApp(axLabel: "Unmute", locale: "en").passesLiveAudio)
        XCTAssertFalse(MicGateVerdict.mutedByHardware.passesLiveAudio)
        XCTAssertFalse(MicGateVerdict.silentByRMS(dwellMillis: 400).passesLiveAudio)
        XCTAssertFalse(MicGateVerdict.uncertain(reasons: ["vad_unavailable"]).passesLiveAudio)
    }

    func test_labels_serialise_to_snake_case() {
        XCTAssertEqual(MicGateVerdict.hot(reason: .voiceActivityDetected).label, "hot")
        XCTAssertEqual(MicGateVerdict.mutedByApp(axLabel: "Unmute", locale: "en").label, "muted_by_app")
        XCTAssertEqual(MicGateVerdict.mutedByHardware.label, "muted_by_hardware")
        XCTAssertEqual(MicGateVerdict.silentByRMS(dwellMillis: 350).label, "silent_by_rms")
        XCTAssertEqual(MicGateVerdict.uncertain(reasons: []).label, "uncertain")
    }
}
