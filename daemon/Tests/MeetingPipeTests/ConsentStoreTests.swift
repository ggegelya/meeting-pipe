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
