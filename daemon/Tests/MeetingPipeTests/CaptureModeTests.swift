import XCTest
@testable import MeetingPipe

final class CaptureModeTests: XCTestCase {

    func test_default_resolves_to_capture_first_no_redaction() {
        XCTAssertEqual(
            CaptureMode.resolve(regulated: false, nda: false, redactMuted: false),
            .captureFirst
        )
    }

    func test_opt_in_redaction_resolves_to_capture_first_redact() {
        XCTAssertEqual(
            CaptureMode.resolve(regulated: false, nda: false, redactMuted: true),
            .captureFirstRedact
        )
    }

    func test_regulated_forces_the_no_audio_at_rest_gate() {
        XCTAssertEqual(CaptureMode.resolve(regulated: true, nda: false, redactMuted: false), .regulatedGate)
    }

    func test_nda_forces_the_no_audio_at_rest_gate() {
        XCTAssertEqual(CaptureMode.resolve(regulated: false, nda: true, redactMuted: false), .regulatedGate)
    }

    func test_regulated_overrides_redaction_opt_in() {
        // No audio at rest wins over the offline-redaction opt-in.
        XCTAssertEqual(CaptureMode.resolve(regulated: true, nda: false, redactMuted: true), .regulatedGate)
        XCTAssertEqual(CaptureMode.resolve(regulated: false, nda: true, redactMuted: true), .regulatedGate)
    }

    func test_both_flags_still_resolve_to_the_gate() {
        XCTAssertEqual(CaptureMode.resolve(regulated: true, nda: true, redactMuted: false), .regulatedGate)
    }

    func test_capturesLosslessly_for_both_capture_first_variants() {
        XCTAssertTrue(CaptureMode.captureFirst.capturesLosslessly)
        XCTAssertTrue(CaptureMode.captureFirstRedact.capturesLosslessly)
        XCTAssertFalse(CaptureMode.regulatedGate.capturesLosslessly)
    }

    func test_marker_round_trips() {
        XCTAssertEqual(CaptureMode(marker: CaptureMode.captureFirst.marker), .captureFirst)
        XCTAssertEqual(CaptureMode(marker: CaptureMode.captureFirstRedact.marker), .captureFirstRedact)
        XCTAssertEqual(CaptureMode(marker: CaptureMode.regulatedGate.marker), .regulatedGate)
        XCTAssertEqual(CaptureMode(marker: " capture_first\n"), .captureFirst, "tolerates trailing whitespace")
        XCTAssertNil(CaptureMode(marker: "nonsense"))
    }
}
