import XCTest
@testable import MeetingPipe

/// SEC35: the Storage pane's warning for a backup folder that a sync client owns.
final class BackupDestinationAdviceTests: XCTestCase {

    private let dropbox = CloudSyncDetector.SyncProvider(
        name: "Dropbox", evidence: "under ~/Library/CloudStorage/Dropbox-Personal",
        root: URL(fileURLWithPath: "/tmp/Dropbox-Personal")
    )

    func test_a_local_folder_gets_no_warning() {
        XCTAssertNil(BackupDestinationAdvice.syncWarning(provider: nil, promisesZeroEgress: false))
        XCTAssertNil(BackupDestinationAdvice.syncWarning(provider: nil, promisesZeroEgress: true))
    }

    func test_a_synced_folder_names_the_provider_and_what_the_archive_holds() throws {
        let text = try XCTUnwrap(BackupDestinationAdvice.syncWarning(provider: dropbox, promisesZeroEgress: false))
        XCTAssertTrue(text.contains("Dropbox"))
        XCTAssertTrue(text.contains("recordings and transcripts"))
        XCTAssertFalse(text.contains("promises that nothing leaves"), "the stronger wording is for zero egress only")
    }

    func test_the_wording_is_stronger_under_regulated_mode_or_an_nda_workflow() throws {
        let plain = try XCTUnwrap(BackupDestinationAdvice.syncWarning(provider: dropbox, promisesZeroEgress: false))
        let strong = try XCTUnwrap(BackupDestinationAdvice.syncWarning(provider: dropbox, promisesZeroEgress: true))
        XCTAssertNotEqual(plain, strong)
        XCTAssertTrue(strong.contains("nothing leaves this Mac"))
        XCTAssertTrue(strong.contains("Dropbox"))
    }

    func test_the_real_detector_feeds_it_for_a_path_under_a_sync_root() throws {
        // The picker passes `CloudSyncDetector.detect(path:)` straight in, so a folder under a fake
        // `~/Library/CloudStorage/Dropbox-*` must produce a warning and a plain one must not.
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-backupadvice-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let synced = home.appendingPathComponent("Library/CloudStorage/Dropbox-Personal/backups", isDirectory: true)
        let local = home.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: synced, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        XCTAssertNotNil(BackupDestinationAdvice.syncWarning(
            provider: CloudSyncDetector.detect(path: synced, home: home), promisesZeroEgress: false))
        XCTAssertNil(BackupDestinationAdvice.syncWarning(
            provider: CloudSyncDetector.detect(path: local, home: home), promisesZeroEgress: false))
    }
}
