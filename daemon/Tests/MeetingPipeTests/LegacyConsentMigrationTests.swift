import XCTest
@testable import MeetingPipe

/// UX97: the old "Always for {App}" file moves onto `recording.auto_consent_apps` once, and only
/// retiring the file makes it once (a contains check alone would re-add a bundle the owner removed).
final class LegacyConsentMigrationTests: XCTestCase {
    private var dir: URL!
    private var legacyURL: URL { dir.appendingPathComponent("auto_consent.json") }
    private var configURL: URL { dir.appendingPathComponent("config.toml") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ux97-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func writeLegacy(_ bundles: [String]) throws {
        try JSONEncoder().encode(bundles).write(to: legacyURL)
    }

    func test_noLegacyFile_isANoOp() {
        let store = ConfigStore(configURL: configURL)
        XCTAssertEqual(LegacyConsentMigration.run(legacyURL: legacyURL, into: store), .nothing)
        XCTAssertTrue(store.everyMeetingPrompts)
    }

    func test_twoBundles_migrateOnce_andASecondLaunchDoesNotDuplicate() throws {
        try writeLegacy(["us.zoom.xos", "com.microsoft.teams2"])
        let first = ConfigStore(configURL: configURL)
        XCTAssertEqual(LegacyConsentMigration.run(legacyURL: legacyURL, into: first), .migrated(added: 2))
        XCTAssertEqual(first.autoConsentApps, ["com.microsoft.teams2", "us.zoom.xos"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))

        let second = ConfigStore(configURL: configURL)
        XCTAssertEqual(second.autoConsentApps, ["com.microsoft.teams2", "us.zoom.xos"])
        XCTAssertEqual(LegacyConsentMigration.run(legacyURL: legacyURL, into: second), .nothing)
        XCTAssertEqual(second.autoConsentApps, ["com.microsoft.teams2", "us.zoom.xos"])
    }

    func test_aBundleAlreadyOnTheAllowlist_isNotAddedTwice() throws {
        let seeded = ConfigStore(configURL: configURL)
        seeded.autoConsentApps = ["us.zoom.xos"]
        try seeded.saveNow()
        try writeLegacy(["us.zoom.xos", "com.microsoft.teams2"])

        let store = ConfigStore(configURL: configURL)
        XCTAssertEqual(LegacyConsentMigration.run(legacyURL: legacyURL, into: store), .migrated(added: 1))
        XCTAssertEqual(store.autoConsentApps, ["us.zoom.xos", "com.microsoft.teams2"])
    }

    /// The reason "once" rests on removing the file: a revoke in Preferences survives a relaunch.
    func test_aBundleRemovedAfterMigration_staysRemovedAtTheNextLaunch() throws {
        try writeLegacy(["us.zoom.xos", "com.microsoft.teams2"])
        let first = ConfigStore(configURL: configURL)
        LegacyConsentMigration.run(legacyURL: legacyURL, into: first)
        first.removeAutoConsentApp("us.zoom.xos")
        try first.saveNow()

        let relaunched = ConfigStore(configURL: configURL)
        LegacyConsentMigration.run(legacyURL: legacyURL, into: relaunched)
        XCTAssertEqual(relaunched.autoConsentApps, ["com.microsoft.teams2"])
    }

    /// ARCH9: saves are refused over an unparsed config.toml, so the old file must stay for later.
    func test_anUnreadableConfig_keepsTheLegacyFile() throws {
        try Data("[recording\nnot toml".utf8).write(to: configURL)
        try writeLegacy(["us.zoom.xos"])
        let store = ConfigStore(configURL: configURL)
        XCTAssertNotNil(store.parseError)
        XCTAssertEqual(LegacyConsentMigration.run(legacyURL: legacyURL, into: store), .keptConfigUnreadable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    /// STOR9: unreadable is not empty, so it is neither migrated as empty nor deleted.
    func test_anUnreadableLegacyFile_isLeftAlone() throws {
        let original = try JSONEncoder().encode(["us.zoom.xos"])
        try original.write(to: legacyURL)
        StoreFiles.lock(legacyURL, in: self)
        let store = ConfigStore(configURL: configURL)
        XCTAssertEqual(LegacyConsentMigration.run(legacyURL: legacyURL, into: store), .keptLegacyUnreadable)
        StoreFiles.unlock(legacyURL)
        XCTAssertEqual(try Data(contentsOf: legacyURL), original)
        XCTAssertTrue(store.everyMeetingPrompts)
    }

    func test_aMalformedLegacyFile_isQuarantined() throws {
        try StoreFiles.garbage.write(to: legacyURL)
        let store = ConfigStore(configURL: configURL)
        XCTAssertEqual(LegacyConsentMigration.run(legacyURL: legacyURL, into: store), .quarantined)
        let copies = StoreFiles.corruptCopies(of: legacyURL)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: copies[0]), StoreFiles.garbage)
        XCTAssertTrue(store.everyMeetingPrompts)
    }
}
