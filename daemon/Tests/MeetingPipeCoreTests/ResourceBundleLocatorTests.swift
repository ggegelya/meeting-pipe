import XCTest
@testable import MeetingPipeCore

/// DIST4: resource bundles resolve from the installed app's `Contents/Resources`, an `.app` missing one degrades instead of reaching SwiftPM's `fatalError`ing `Bundle.module`, and only `swift run` / `swift test` fall back to `.module`. Driven against fake bundles on disk, since the real `.app` case is what `scripts/test-app-relocation.sh` covers.
final class ResourceBundleLocatorTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        // A fresh path per test: `Bundle(url:)` caches instances by path.
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ResourceBundleLocatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// `Fake.app/Contents/{Info.plist,MacOS,Resources}`, optionally with `Thing_Thing.bundle/payload.toml` in Resources.
    private func makeApp(withBundle: Bool) throws -> Bundle {
        let contents = root.appendingPathComponent("Fake.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "test.resource-bundle-locator",
            "CFBundleExecutable": "Fake",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if withBundle {
            try makeResourceBundle(in: resources)
        }
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Fake.app")))
    }

    private func makeResourceBundle(in dir: URL) throws {
        let bundle = dir.appendingPathComponent("Thing_Thing.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "x = 1\n".write(to: bundle.appendingPathComponent("payload.toml"), atomically: true, encoding: .utf8)
    }

    func test_installed_app_reads_the_bundle_from_contents_resources() throws {
        let app = try makeApp(withBundle: true)
        let bundle = try XCTUnwrap(ResourceBundleLocator.bundle(named: "Thing_Thing", main: app))
        XCTAssertTrue(bundle.bundlePath.hasSuffix("Fake.app/Contents/Resources/Thing_Thing.bundle"), bundle.bundlePath)
        XCTAssertNotNil(bundle.url(forResource: "payload", withExtension: "toml"))
    }

    func test_app_missing_the_bundle_degrades_to_main_and_never_returns_nil() throws {
        // nil would send the caller to `Bundle.module`, whose accessor `fatalError`s once the
        // build tree is gone: the DI-1 crash loop. Main instead makes every lookup miss.
        let app = try makeApp(withBundle: false)
        let bundle = try XCTUnwrap(ResourceBundleLocator.bundle(named: "Thing_Thing", main: app))
        XCTAssertEqual(bundle.bundleURL.standardizedFileURL, app.bundleURL.standardizedFileURL)
        XCTAssertNil(bundle.url(forResource: "payload", withExtension: "toml"))
    }

    func test_outside_an_app_without_the_bundle_returns_nil_so_the_caller_uses_bundle_module() throws {
        let plain = try XCTUnwrap(Bundle(url: root))
        XCTAssertNil(ResourceBundleLocator.bundle(named: "Thing_Thing", main: plain))
    }

    func test_outside_an_app_a_side_by_side_bundle_is_found() throws {
        // `swift run`: the bare executable's directory holds the bundle, as `.build/release` does.
        try makeResourceBundle(in: root)
        let plain = try XCTUnwrap(Bundle(url: root))
        let bundle = try XCTUnwrap(ResourceBundleLocator.bundle(named: "Thing_Thing", main: plain))
        XCTAssertNotNil(bundle.url(forResource: "payload", withExtension: "toml"))
    }

    func test_core_bundle_name_matches_what_swiftpm_generated() {
        // Under `swift test` this resolves through `Bundle.module`, so its file name is SwiftPM's
        // own; the hardcoded name is what an installed app looks up in Contents/Resources.
        XCTAssertEqual(Bundle.coreResources.bundleURL.deletingPathExtension().lastPathComponent, Bundle.coreResourceBundleName)
        XCTAssertNotNil(Bundle.coreResources.url(forResource: "MuteLabels", withExtension: "toml"))
    }
}
