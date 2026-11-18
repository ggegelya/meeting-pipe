import XCTest
@testable import MeetingPipe

final class ConsentStoreTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("consent-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    func testEmptyByDefault() {
        let s = ConsentStore(url: tempURL)
        XCTAssertFalse(s.isAutoConsented(bundleID: "us.zoom.xos"))
    }

    func testRoundTripsAcrossInstances() {
        let s1 = ConsentStore(url: tempURL)
        s1.setAutoConsented(bundleID: "us.zoom.xos", value: true)

        let s2 = ConsentStore(url: tempURL)
        XCTAssertTrue(s2.isAutoConsented(bundleID: "us.zoom.xos"))
    }

    func testRevokesConsent() {
        let s = ConsentStore(url: tempURL)
        s.setAutoConsented(bundleID: "us.zoom.xos", value: true)
        XCTAssertTrue(s.isAutoConsented(bundleID: "us.zoom.xos"))

        s.setAutoConsented(bundleID: "us.zoom.xos", value: false)
        XCTAssertFalse(s.isAutoConsented(bundleID: "us.zoom.xos"))

        let reloaded = ConsentStore(url: tempURL)
        XCTAssertFalse(reloaded.isAutoConsented(bundleID: "us.zoom.xos"))
    }

    func testIndependentBundleIDs() {
        let s = ConsentStore(url: tempURL)
        s.setAutoConsented(bundleID: "us.zoom.xos", value: true)
        s.setAutoConsented(bundleID: "com.microsoft.teams2", value: true)

        XCTAssertTrue(s.isAutoConsented(bundleID: "us.zoom.xos"))
        XCTAssertTrue(s.isAutoConsented(bundleID: "com.microsoft.teams2"))
        XCTAssertFalse(s.isAutoConsented(bundleID: "com.tinyspeck.slackmacgap"))
    }

    func testToleratesCorruptFile() {
        try? "this is not json".data(using: .utf8)?.write(to: tempURL)
        // Should not throw — bad data is treated as empty state.
        let s = ConsentStore(url: tempURL)
        XCTAssertFalse(s.isAutoConsented(bundleID: "us.zoom.xos"))
        // And we can still write to it.
        s.setAutoConsented(bundleID: "us.zoom.xos", value: true)
        XCTAssertTrue(ConsentStore(url: tempURL).isAutoConsented(bundleID: "us.zoom.xos"))
    }
}

// MARK: - STOR9: unreadable is not empty

extension ConsentStoreTests {
    /// The defect: a broken allowlist loaded as empty, and the next "Always for this app" saved
    /// that one app over every app already on it.
    func test_stor9_a_malformed_file_is_quarantined_before_the_next_save() throws {
        try StoreFiles.garbage.write(to: tempURL)
        let store = ConsentStore(url: tempURL)
        store.setAutoConsented(bundleID: "us.zoom.xos", value: true)

        let copies = StoreFiles.corruptCopies(of: tempURL)
        XCTAssertEqual(copies.count, 1)
        addTeardownBlock { copies.forEach { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertEqual(try Data(contentsOf: copies[0]), StoreFiles.garbage)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(contentsOf: tempURL)), ["us.zoom.xos"])
    }

    func test_stor9_an_unreadable_file_refuses_and_is_left_alone() throws {
        let original = try JSONEncoder().encode(["com.microsoft.teams2", "us.zoom.xos"])
        try original.write(to: tempURL)
        StoreFiles.lock(tempURL, in: self)
        let store = ConsentStore(url: tempURL)
        store.setAutoConsented(bundleID: "com.tinyspeck.slackmacgap", value: true)
        XCTAssertFalse(store.isAutoConsented(bundleID: "com.tinyspeck.slackmacgap"))
        StoreFiles.unlock(tempURL)
        XCTAssertEqual(try Data(contentsOf: tempURL), original)
    }
}
