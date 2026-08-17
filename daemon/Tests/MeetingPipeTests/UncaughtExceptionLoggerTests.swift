import XCTest
@testable import MeetingPipe

/// REC12(3): the next uncaught ObjC exception has to say what it was.
///
/// The four aborts of 2026-08-13 and 08-14 were reconstructed from four `.ips` files
/// correlated against `events.jsonl`, and the raise condition still ended up inferred: a
/// crash report's `Application Specific Information` holds only "abort() called", and
/// `NSException.reason` appears nowhere in it.
final class UncaughtExceptionLoggerTests: XCTestCase {

    private let raised = NSException(
        name: .invalidArgumentException,
        reason: "required condition is false: format.sampleRate == hwFormat.sampleRate",
        userInfo: nil
    )

    // MARK: - The line

    func test_the_line_carries_the_name_and_the_reason() {
        let line = UncaughtExceptionLogger.line(
            name: "NSInvalidArgumentException",
            reason: "required condition is false: IsFormatSampleRateAndChannelCountValid(format)",
            frames: []
        )
        XCTAssertTrue(line.contains("NSInvalidArgumentException"), line)
        XCTAssertTrue(
            line.contains("IsFormatSampleRateAndChannelCountValid"),
            "the reason is the entire point of this handler: \(line)"
        )
    }

    /// A raise with no reason still logs rather than dropping the only notice we get.
    func test_a_missing_reason_still_produces_a_line() {
        let line = UncaughtExceptionLogger.line(name: "NSGenericException", reason: nil, frames: [])
        XCTAssertTrue(line.contains("NSGenericException"), line)
        XCTAssertFalse(line.isEmpty)
    }

    /// One row, not a hundred. A backtrace pasted whole would push the useful half off the
    /// end of whatever reads it.
    func test_the_backtrace_is_capped_and_stays_one_row() {
        let frames = (0..<40).map { "\($0)  MeetingPipe  0x0000000100000000 frame\($0) + 4" }
        let line = UncaughtExceptionLogger.line(name: "NSGenericException", reason: "boom", frames: frames)
        XCTAssertTrue(line.contains("frame0"))
        XCTAssertFalse(line.contains("frame\(UncaughtExceptionLogger.frameLimit)"), "frame cap not applied")
        XCTAssertFalse(line.contains("\n"), "a multi-line log entry is not grep-able as one event")
    }

    // MARK: - The recording

    /// The real path, driven with a real `NSException` and without installing a
    /// process-wide handler in the test runner.
    func test_recording_an_exception_lands_on_both_logs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-uncaught-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", dir.path, 1)
        defer {
            unsetenv("MEETINGPIPE_LOGS_DIR")
            try? FileManager.default.removeItem(at: dir)
        }

        UncaughtExceptionLogger.record(raised)

        let text = try String(contentsOf: dir.appendingPathComponent("daemon.log"), encoding: .utf8)
        XCTAssertTrue(text.contains("NSInvalidArgumentException"), text)
        XCTAssertTrue(text.contains("format.sampleRate == hwFormat.sampleRate"), text)

        let events = try String(contentsOf: dir.appendingPathComponent("events.jsonl"), encoding: .utf8)
        let rows = events.split(separator: "\n").compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["action"] as? String == "uncaught_exception" else { return nil }
            return object
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["category"] as? String, "daemon")
        XCTAssertEqual(rows.first?["name"] as? String, "NSInvalidArgumentException")
    }
}
