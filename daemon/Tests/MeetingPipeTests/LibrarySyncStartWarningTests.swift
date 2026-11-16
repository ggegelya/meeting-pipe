import XCTest
@testable import MeetingPipe

/// SEC18: the start-time warning for a synced library, as a pure decision over the capture mode and a
/// stubbed detector result.
final class LibrarySyncStartWarningTests: XCTestCase {

    private let dropbox = CloudSyncDetector.SyncProvider(
        name: "Dropbox", evidence: "in Dropbox", root: URL(fileURLWithPath: "/tmp/Dropbox")
    )

    func test_the_regulated_gate_over_a_synced_library_warns_once() {
        var w = LibrarySyncStartWarning()
        XCTAssertEqual(w.consider(captureMode: .regulatedGate, provider: dropbox), .warn(providerName: "Dropbox"))
        XCTAssertEqual(
            w.consider(captureMode: .regulatedGate, provider: dropbox), .none,
            "a second recording in the same session stays quiet"
        )
        XCTAssertFalse(w.mayWarn(captureMode: .regulatedGate))
    }

    func test_capture_first_modes_never_warn() {
        var w = LibrarySyncStartWarning()
        XCTAssertEqual(w.consider(captureMode: .captureFirst, provider: dropbox), .none)
        XCTAssertEqual(w.consider(captureMode: .captureFirstRedact, provider: dropbox), .none)
        XCTAssertTrue(w.mayWarn(captureMode: .regulatedGate), "a skipped mode does not spend the one warning")
        XCTAssertFalse(w.mayWarn(captureMode: .captureFirst))
    }

    func test_a_local_library_never_warns_and_does_not_spend_the_latch() {
        var w = LibrarySyncStartWarning()
        XCTAssertEqual(w.consider(captureMode: .regulatedGate, provider: nil), .none)
        XCTAssertEqual(w.consider(captureMode: .regulatedGate, provider: dropbox), .warn(providerName: "Dropbox"))
    }

    func test_the_copy_names_the_provider_and_has_no_em_dash() {
        let body = LibrarySyncStartWarning.body(providerName: "iCloud Drive")
        XCTAssertTrue(body.contains("iCloud Drive"))
        XCTAssertFalse(body.contains("\u{2014}"))
    }
}
