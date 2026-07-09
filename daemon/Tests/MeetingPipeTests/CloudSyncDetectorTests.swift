import Darwin
import XCTest
@testable import MeetingPipe

/// SEC12's detector, over a fake `$HOME` in a temp directory. The xattr cases
/// stamp real extended attributes rather than mocking the read, so they exercise
/// the same `listxattr(2)` path production does.
final class CloudSyncDetectorTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-cloudsync-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    private func mkdir(_ components: String...) throws -> URL {
        var url = home!
        for component in components {
            url = url.appendingPathComponent(component, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `com.apple.file-provider-domain-id` is protected and cannot be written by
    /// an unprivileged process; `com.apple.icloud.desktop` can, and it is the
    /// attribute that actually marks Desktop & Documents sync.
    private func stamp(_ url: URL, _ name: String) throws {
        let value: [UInt8] = [1]
        let result = url.path.withCString { path in
            name.withCString { attribute in
                setxattr(path, attribute, value, value.count, 0, 0)
            }
        }
        try XCTSkipIf(result != 0, "cannot set \(name) here (errno \(errno))")
    }

    private func detect(_ path: URL) -> CloudSyncDetector.SyncProvider? {
        CloudSyncDetector.detect(path: path, home: home)
    }

    // MARK: The negative case, which has to stay negative

    func test_a_plain_library_is_not_synced() throws {
        XCTAssertNil(detect(try mkdir("Meetings", "raw")))
    }

    func test_a_plain_documents_folder_is_not_synced() throws {
        // The regression that matters: iCloud Drive on, Desktop & Documents off.
        // Nothing is stamped, so nothing should fire.
        XCTAssertNil(detect(try mkdir("Documents", "Meetings", "raw")))
    }

    // MARK: CloudStorage roots

    func test_cloudstorage_roots_name_their_provider() throws {
        let cases = [
            ("OneDrive-Contoso", "OneDrive"),
            ("GoogleDrive-me@example.com", "Google Drive"),
            ("Dropbox-Personal", "Dropbox"),
            ("iCloudDrive", "iCloud Drive"),
        ]
        for (directory, expected) in cases {
            let library = try mkdir("Library", "CloudStorage", directory, "raw")
            XCTAssertEqual(detect(library)?.name, expected, directory)
        }
    }

    func test_an_unknown_cloudstorage_provider_still_warns() throws {
        let library = try mkdir("Library", "CloudStorage", "Weirdsync-acct", "raw")
        XCTAssertEqual(detect(library)?.name, CloudSyncDetector.unidentified)
    }

    func test_the_cloudstorage_container_itself_is_not_a_provider() throws {
        XCTAssertNil(detect(try mkdir("Library", "CloudStorage")))
    }

    // MARK: iCloud Drive proper

    func test_mobile_documents_is_icloud_drive() throws {
        let library = try mkdir("Library", "Mobile Documents", "com~apple~CloudDocs", "raw")
        XCTAssertEqual(detect(library)?.name, "iCloud Drive")
    }

    // MARK: Extended attributes

    func test_the_icloud_desktop_xattr_on_an_ancestor_is_detected() throws {
        // How macOS actually marks Desktop & Documents sync: an xattr on
        // `~/Documents`. Not a symlink, and nothing `resolvingSymlinksInPath`
        // can see.
        let documents = try mkdir("Documents")
        let library = try mkdir("Documents", "Meetings", "raw")
        try stamp(documents, CloudSyncDetector.iCloudDesktopAttribute)

        let provider = detect(library)
        XCTAssertEqual(provider?.name, "iCloud Drive")
        XCTAssertEqual(provider?.root.resolvingSymlinksInPath(), documents.resolvingSymlinksInPath())
    }

    func test_a_synced_home_is_itself_detected() throws {
        try stamp(home, CloudSyncDetector.iCloudDesktopAttribute)
        XCTAssertNotNil(detect(try mkdir("Meetings", "raw")),
                        "home is the last ancestor checked, not the first one skipped")
    }

    func test_extendedAttributeNames_reads_what_was_written() throws {
        let dir = try mkdir("attrs")
        try stamp(dir, CloudSyncDetector.iCloudDesktopAttribute)
        XCTAssertTrue(
            CloudSyncDetector.extendedAttributeNames(at: dir)
                .contains(CloudSyncDetector.iCloudDesktopAttribute)
        )
    }

    func test_extendedAttributeNames_of_a_missing_path_is_empty() {
        XCTAssertEqual(
            CloudSyncDetector.extendedAttributeNames(at: home.appendingPathComponent("nope")), []
        )
    }

    // MARK: Legacy clients

    func test_legacy_directory_names_are_detected() throws {
        XCTAssertEqual(detect(try mkdir("Dropbox", "Meetings", "raw"))?.name, "Dropbox")
        XCTAssertEqual(detect(try mkdir("Google Drive", "raw"))?.name, "Google Drive")
        XCTAssertEqual(detect(try mkdir("Box Sync", "raw"))?.name, "Box")
    }

    // MARK: Bounds

    func test_detection_does_not_walk_above_home() throws {
        // A "Dropbox" folder above $HOME is somebody else's business.
        let realHome = home.appendingPathComponent("Dropbox/user", isDirectory: true)
        let library = realHome.appendingPathComponent("Meetings/raw", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        XCTAssertNil(CloudSyncDetector.detect(path: library, home: realHome))
    }

    func test_a_library_outside_home_terminates_at_the_filesystem_root() throws {
        // Must not loop forever when `home` is never an ancestor.
        XCTAssertNil(CloudSyncDetector.detect(path: URL(fileURLWithPath: "/tmp"), home: home))
    }

    // MARK: Symlinks

    func test_a_library_symlinked_into_a_sync_folder_is_detected() throws {
        let real = try mkdir("Library", "CloudStorage", "Dropbox-Personal", "raw")
        let link = home.appendingPathComponent("Meetings")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(detect(link)?.name, "Dropbox")
    }
}
