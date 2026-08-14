import AVFoundation
import XCTest
@testable import MeetingPipe

/// DET10: the `detector.mic_device_unavailable` attribute vocabulary. These strings are read by a
/// human in the event log and by `mp analyze-detection`'s dead-input diagnosis, so they are pinned
/// rather than left to a later refactor to rename.
final class MicInputAvailabilityTests: XCTestCase {

    func test_every_authorization_status_has_a_snake_case_label() {
        XCTAssertEqual(MicInputAvailability.authorizationLabel(.authorized), "authorized")
        XCTAssertEqual(MicInputAvailability.authorizationLabel(.denied), "denied")
        XCTAssertEqual(MicInputAvailability.authorizationLabel(.restricted), "restricted")
        XCTAssertEqual(MicInputAvailability.authorizationLabel(.notDetermined), "not_determined")
    }

    /// The two faults that produce the same nil device must not collapse to one label: "no audio
    /// input on this Mac" and "the microphone grant is denied" take different fixes.
    func test_denied_and_authorized_are_distinguishable() {
        XCTAssertNotEqual(
            MicInputAvailability.authorizationLabel(.denied),
            MicInputAvailability.authorizationLabel(.authorized)
        )
    }

    /// The log is grepped, and every other action and attribute in the stream is snake_case
    /// (CONVENTIONS.md "Event log schema"), so no label may arrive camelCase or dotted.
    func test_labels_are_snake_case() {
        let all: [AVAuthorizationStatus] = [.authorized, .denied, .restricted, .notDetermined]
        for status in all {
            let label = MicInputAvailability.authorizationLabel(status)
            XCTAssertFalse(label.isEmpty)
            XCTAssertEqual(label, label.lowercased(), "label must be lowercase: \(label)")
            XCTAssertFalse(label.contains("."), "label must not be dotted: \(label)")
            XCTAssertFalse(label.contains(" "), "label must not contain spaces: \(label)")
        }
    }
}
