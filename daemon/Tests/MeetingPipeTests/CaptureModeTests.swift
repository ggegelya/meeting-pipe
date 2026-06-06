import XCTest
@testable import MeetingPipe

final class CaptureModeTests: XCTestCase {

    func test_default_resolves_to_capture_first() {
        XCTAssertEqual(CaptureMode.resolve(regulated: false, nda: false), .captureFirst)
    }

    func test_regulated_forces_the_no_audio_at_rest_gate() {
        XCTAssertEqual(CaptureMode.resolve(regulated: true, nda: false), .regulatedGate)
    }

    func test_nda_forces_the_no_audio_at_rest_gate() {
        XCTAssertEqual(CaptureMode.resolve(regulated: false, nda: true), .regulatedGate)
    }

    func test_both_flags_still_resolve_to_the_gate() {
        XCTAssertEqual(CaptureMode.resolve(regulated: true, nda: true), .regulatedGate)
    }

    func test_capturesLosslessly_only_for_capture_first() {
        XCTAssertTrue(CaptureMode.captureFirst.capturesLosslessly)
        XCTAssertFalse(CaptureMode.regulatedGate.capturesLosslessly)
    }
}
