import AVFoundation
import Combine
import XCTest
@testable import MeetingPipe

/// PermissionsCenter is mostly a thin wrapper over TCC APIs that can't
/// be driven from XCTest — `AVCaptureDevice.authorizationStatus(for:)`
/// reads the host process's actual TCC state. So these tests cover the
/// observable shape: status mapping, kind metadata, and the
/// permission-granted broadcast that the Coordinator depends on for
/// auto-resume after restart.
final class PermissionsCenterTests: XCTestCase {

    func test_kind_metadata_is_present_for_every_case() {
        for kind in PermissionsCenter.Kind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty)
            XCTAssertFalse(kind.rationale.isEmpty)
        }
    }

    /// The permissionGranted publisher is the load-bearing piece for
    /// point (2) of the user report — detector reevaluation after a
    /// permission flip. The Coordinator subscribes to it; this asserts
    /// the contract directly via the public API.
    func test_permissionGranted_broadcasts_on_initial_grant_transition() {
        let center = PermissionsCenter.shared
        let exp = expectation(description: "granted broadcast")
        var observedKinds: [PermissionsCenter.Kind] = []
        let cancel = center.permissionGranted.sink { kind in
            observedKinds.append(kind)
            exp.fulfill()
        }
        // Drive a transition by calling the internal commit path
        // indirectly through refreshMic() with a stubbed authorization.
        // We can't stub the TCC API, so instead drive the broadcast
        // through a manual property write via KVO-friendly reflection:
        // simulate the flip by setting the published value through a
        // private mutator. The Combine subject is the contract — once
        // the value lands at `.granted`, subscribers must see one event.
        center.simulateStatusForTesting(.granted, kind: .microphone)
        wait(for: [exp], timeout: 1.0)
        cancel.cancel()
        XCTAssertEqual(observedKinds, [.microphone])
    }

    func test_permissionGranted_does_not_broadcast_on_repeat_grant() {
        let center = PermissionsCenter.shared
        center.simulateStatusForTesting(.granted, kind: .accessibility)
        // Reset the recorded value so the next transition is observable.
        let exp = expectation(description: "no repeat broadcast")
        exp.isInverted = true
        let cancel = center.permissionGranted
            .filter { $0 == .accessibility }
            .sink { _ in exp.fulfill() }
        // Second call with the same status: should NOT emit.
        center.simulateStatusForTesting(.granted, kind: .accessibility)
        wait(for: [exp], timeout: 0.3)
        cancel.cancel()
    }

    func test_status_lookup_matches_published_value() {
        let center = PermissionsCenter.shared
        center.simulateStatusForTesting(.denied, kind: .screenRecording)
        XCTAssertEqual(center.status(.screenRecording), .denied)
        center.simulateStatusForTesting(.granted, kind: .screenRecording)
        XCTAssertEqual(center.status(.screenRecording), .granted)
    }
}
