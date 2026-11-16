import XCTest
@testable import MeetingPipe

/// SEC36: the pure decision, offline, with no FluidAudio call.
final class SpeechModelGateTests: XCTestCase {

    func test_zero_egress_refuses_when_either_model_is_missing() {
        XCTAssertEqual(SpeechModelGate.decide(zeroEgress: true, missing: [.asr]), .refuse(missing: [.asr]))
        XCTAssertEqual(SpeechModelGate.decide(zeroEgress: true, missing: [.diarizer]), .refuse(missing: [.diarizer]))
        XCTAssertEqual(
            SpeechModelGate.decide(zeroEgress: true, missing: [.asr, .diarizer]),
            .refuse(missing: [.asr, .diarizer]))
    }

    func test_zero_egress_proceeds_when_both_are_present() {
        XCTAssertEqual(SpeechModelGate.decide(zeroEgress: true, missing: []), .proceed)
    }

    func test_normal_mode_proceeds_with_models_missing() {
        XCTAssertEqual(SpeechModelGate.decide(zeroEgress: false, missing: [.asr, .diarizer]), .proceed)
    }

    func test_loaded_managers_count_as_present_whatever_the_cache_says() {
        XCTAssertEqual(SpeechModelGate.missing(loaded: [.asr, .diarizer], present: []), [])
        XCTAssertEqual(SpeechModelGate.missing(loaded: [.asr], present: []), [.diarizer])
        XCTAssertEqual(SpeechModelGate.missing(loaded: [], present: [.asr]), [.diarizer])
        XCTAssertEqual(SpeechModelGate.missing(loaded: [], present: []), [.asr, .diarizer])
        XCTAssertEqual(SpeechModelGate.missing(loaded: [], present: [.asr, .diarizer]), [])
    }

    func test_the_refusal_reason_is_one_the_library_row_shows_as_written() {
        let shown = FailurePresentation(diagnostics: SpeechModelGate.reason)
        XCTAssertEqual(shown.explanation, SpeechModelGate.reason)
        XCTAssertLessThanOrEqual(SpeechModelGate.reason.count, 260)
        XCTAssertFalse(SpeechModelGate.reason.contains("/"))
    }

    func test_diarizer_presence_needs_both_model_bundles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sec36-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertFalse(FluidAudioRunner.diarizerModelsPresent(in: dir))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("pyannote_segmentation.mlmodelc"), withIntermediateDirectories: true)
        XCTAssertFalse(FluidAudioRunner.diarizerModelsPresent(in: dir))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("wespeaker_v2.mlmodelc"), withIntermediateDirectories: true)
        XCTAssertTrue(FluidAudioRunner.diarizerModelsPresent(in: dir))
    }
}
