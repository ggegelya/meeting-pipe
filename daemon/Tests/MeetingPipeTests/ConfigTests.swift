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
        sample_rate = 48000
        auto_consent_apps = ["us.zoom.xos", "com.microsoft.teams2"]
        """)
        let cfg = try Config.load(from: url)
        XCTAssertEqual(cfg.recording.sampleRate, 48000)
        XCTAssertEqual(cfg.recording.outputDir.path, "/tmp/recordings")
        XCTAssertEqual(cfg.recording.autoConsentApps, ["us.zoom.xos", "com.microsoft.teams2"])
    }

    func testFallsBackToDefaultsWhenSectionsMissing() throws {
        // Empty TOML → defaults.
        let url = writeTOML("")
        let cfg = try Config.load(from: url)
        XCTAssertEqual(cfg.recording.sampleRate, 16000)
        XCTAssertEqual(cfg.detection.manualHotkey, "ctrl+option+m")
        XCTAssertEqual(cfg.detection.forceStopHotkey, "ctrl+option+shift+m")
        XCTAssertEqual(cfg.detection.debounceStartSec, 5)
        XCTAssertEqual(cfg.detection.debounceEndSec, 5)
        XCTAssertFalse(cfg.modes.regulatedMode)
    }

    func testParsesForceStopHotkeyOverride() throws {
        // TECH-C5: user-provided override flows through Config.load.
        let url = writeTOML("""
        [detection]
        force_stop_hotkey = "cmd+shift+x"
        """)
        let cfg = try Config.load(from: url)
        XCTAssertEqual(cfg.detection.forceStopHotkey, "cmd+shift+x")
        // Manual hotkey untouched by force-stop change.
        XCTAssertEqual(cfg.detection.manualHotkey, "ctrl+option+m")
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
        XCTAssertEqual(cfg.recording.sampleRate, 16000)
        XCTAssertEqual(cfg.detection.manualHotkey, "ctrl+option+m")
    }

    func testParsesPerBundleDebounceOverrides() throws {
        // TECH-C4: optional [detection.debounce_end_per_bundle] sub-table
        // populates a bundle-keyed override map. Mixed int/double values
        // are both accepted because TOML doesn't auto-coerce.
        let url = writeTOML("""
        [detection]
        debounce_end_sec = 5

        [detection.debounce_end_per_bundle]
        "us.zoom.xos" = 7
        "com.google.Chrome" = 15.5
        """)
        let cfg = try Config.load(from: url)
        XCTAssertEqual(cfg.detection.debounceEndSec, 5)
        XCTAssertEqual(cfg.detection.debounceEndPerBundle["us.zoom.xos"], 7)
        XCTAssertEqual(cfg.detection.debounceEndPerBundle["com.google.Chrome"], 15.5)
    }

    func testMissingPerBundleDebounceIsEmpty() throws {
        let url = writeTOML("")
        let cfg = try Config.load(from: url)
        XCTAssertTrue(cfg.detection.debounceEndPerBundle.isEmpty)
    }

    func testIgnoresLegacyFieldsWithoutCrashing() throws {
        // Older configs may still have audio_device / capture_mode etc.
        // We don't read them anymore but parsing should silently succeed.
        let url = writeTOML("""
        [recording]
        output_dir = "/tmp/x"
        sample_rate = 16000
        audio_device = "old-aggregate"
        capture_mode = "process_tap"
        mic_device = "old-mic"
        auto_route_output = true
        """)
        let cfg = try Config.load(from: url)
        XCTAssertEqual(cfg.recording.sampleRate, 16000)
        XCTAssertEqual(cfg.recording.outputDir.path, "/tmp/x")
    }
}
