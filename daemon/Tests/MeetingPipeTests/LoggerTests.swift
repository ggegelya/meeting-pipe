import XCTest
@testable import MeetingPipe

/// TECH-END4 (d): `swift test` must never write into the user's production
/// `~/Library/Logs/MeetingPipe/events.jsonl`. These pin the `Log.logsDir`
/// redirect so the dogfood corpus the END band analyzes stays clean.
final class LoggerTests: XCTestCase {
    func test_logsDir_honors_explicit_env_override() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-logs-\(UUID().uuidString)", isDirectory: true)
        setenv("MEETINGPIPE_LOGS_DIR", tmp.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }
        XCTAssertEqual(Log.logsDir.standardizedFileURL, tmp.standardizedFileURL)
    }

    func test_logsDir_under_test_never_touches_production() {
        // No explicit override: the XCTest auto-isolation must keep us out of
        // the real logs directory regardless.
        unsetenv("MEETINGPIPE_LOGS_DIR")
        let production = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MeetingPipe", isDirectory: true)
        XCTAssertNotEqual(
            Log.logsDir.standardizedFileURL,
            production.standardizedFileURL,
            "swift test must not write into the user's real events.jsonl"
        )
    }
}
