import XCTest
@testable import MeetingPipe

/// OBS6: `Log.verbose` writes to the named log only while Verbose logging is on.
final class VerboseLogTests: XCTestCase {
    private var logs: URL!

    override func setUpWithError() throws {
        logs = FileManager.default.temporaryDirectory.appendingPathComponent("mp-obs6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDown() {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: logs)
    }

    private func detectorLog() -> String {
        (try? String(contentsOf: logs.appendingPathComponent("detector.log"), encoding: .utf8)) ?? ""
    }

    func test_writes_only_while_enabled() {
        Log.verbose("detector", "off line", enabled: { false })
        XCTAssertEqual(detectorLog(), "")
        Log.verbose("detector", "on line", enabled: { true })
        XCTAssertTrue(detectorLog().contains("verbose: on line"))
        XCTAssertFalse(detectorLog().contains("off line"))
    }

    /// The default gate is the live toggle: the key `UISettings` writes is the key `Log` reads.
    func test_the_default_gate_follows_the_preferences_toggle() {
        let settings = UISettings.shared
        let before = settings.verboseLogging
        defer { settings.verboseLogging = before }

        settings.verboseLogging = false
        XCTAssertFalse(Log.isVerbose())
        Log.verbose("detector", "while off")
        settings.verboseLogging = true
        XCTAssertTrue(Log.isVerbose())
        Log.verbose("detector", "while on")
        XCTAssertFalse(detectorLog().contains("while off"))
        XCTAssertTrue(detectorLog().contains("while on"))
    }
}
