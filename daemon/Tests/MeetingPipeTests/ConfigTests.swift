import XCTest
@testable import MeetingPipe

final class ConfigTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-config-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func writeTOML(_ contents: String) -> URL {
        let url = tempDir.appendingPathComponent("config.toml")
        try! contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testParsesMinimalToml() throws {
        let url = writeTOML("""
        [recording]
        output_dir = "/tmp/recordings"
        audio_device = "MyDevice"
        sample_rate = 48000
        auto_consent_apps = ["us.zoom.xos", "com.microsoft.teams2"]
        """)
        let cfg = try Config.load(from: url)
        XCTAssertEqual(cfg.recording.audioDevice, "MyDevice")
        XCTAssertEqual(cfg.recording.sampleRate, 48000)
        XCTAssertEqual(cfg.recording.outputDir.path, "/tmp/recordings")
        XCTAssertEqual(cfg.recording.autoConsentApps, ["us.zoom.xos", "com.microsoft.teams2"])
    }

    func testFallsBackToDefaultsWhenSectionsMissing() throws {
        // Empty TOML → defaults.
        let url = writeTOML("")
        let cfg = try Config.load(from: url)
        XCTAssertEqual(cfg.recording.audioDevice, "Aggregate Device")
        XCTAssertEqual(cfg.recording.sampleRate, 16000)
        XCTAssertEqual(cfg.detection.manualHotkey, "ctrl+option+m")
        XCTAssertEqual(cfg.detection.debounceStartSec, 5)
        XCTAssertEqual(cfg.detection.debounceEndSec, 10)
        XCTAssertFalse(cfg.modes.regulatedMode)
    }

    func testRegulatedModeRoundTrips() throws {
        let url = writeTOML("""
        [modes]
        regulated_mode = true
        """)
        let cfg = try Config.load(from: url)
        XCTAssertTrue(cfg.modes.regulatedMode)
    }

    func testExpandsTilde() throws {
        let url = writeTOML(#"""
        [recording]
        output_dir = "~/Documents/Meetings/raw"
        """#)
        let cfg = try Config.load(from: url)
        // Tilde must be expanded — not literal "~".
        XCTAssertFalse(cfg.recording.outputDir.path.hasPrefix("~"))
        XCTAssertTrue(cfg.recording.outputDir.path.contains("Documents/Meetings/raw"))
    }

    func testDefaultFallbackInstantiates() {
        // Public API used when no config file exists.
        let cfg = Config.defaultFallback()
        XCTAssertEqual(cfg.recording.audioDevice, "Aggregate Device")
        XCTAssertEqual(cfg.detection.manualHotkey, "ctrl+option+m")
    }
}
