import XCTest
@testable import MeetingPipe

/// REC13(4): a stop that does not complete must be readable from `events.jsonl`.
///
/// On 2026-08-14 `state_change recording -> stopping` was the last event for 52
/// minutes, so diagnosing it needed a live `sample` of the running process. These
/// pin the event, its elapsed-time attribute, and the disarm path.
final class StopStallWatchdogTests: XCTestCase {

    private let file = URL(fileURLWithPath: "/tmp/20260814-163455.wav")

    /// Point `Log` at a scratch directory so these read back exactly the rows they
    /// wrote. `Log.logsDir` already refuses the user's real log under XCTest
    /// (`LoggerTests` pins that); this narrows it further to one test's own events.
    private func withScratchLogs(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-stall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", dir.path, 1)
        defer {
            unsetenv("MEETINGPIPE_LOGS_DIR")
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir)
    }

    private func stallRows(in dir: URL) throws -> [[String: Any]] {
        let events = dir.appendingPathComponent("events.jsonl")
        guard let text = try? String(contentsOf: events, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["action"] as? String == "stop_exceeded_ceiling" else { return nil }
            return object
        }
    }

    @MainActor
    func test_emits_an_auditable_event_carrying_the_elapsed_time() throws {
        try withScratchLogs { dir in
            let ceiling = 0.05
            let watchdog = StopStallWatchdog(ceilingSeconds: ceiling)
            let stalled = expectation(description: "onStall fired")
            let reported = OSAllocatedUnfairLockBox<TimeInterval>(-1)

            watchdog.arm(file: file) { elapsed in
                reported.value = elapsed
                stalled.fulfill()
            }
            wait(for: [stalled], timeout: 5)

            XCTAssertGreaterThanOrEqual(reported.value, ceiling)

            let rows = try stallRows(in: dir)
            XCTAssertEqual(rows.count, 1, "the stall must leave exactly one auditable row")
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(row["category"] as? String, "recorder")
            XCTAssertEqual(row["file"] as? String, "20260814-163455.wav")
            XCTAssertEqual(row["ceiling_s"] as? Double, ceiling)
            let elapsed = try XCTUnwrap(row["elapsed_s"] as? Double)
            XCTAssertGreaterThanOrEqual(
                elapsed, ceiling,
                "elapsed_s is the whole point: without it the row cannot tell a 90 s stop from a 52 minute one"
            )
        }
    }

    /// The normal case: a stop that completes disarms the watchdog, and nothing is
    /// emitted. A canary that cries on every stop is worse than no canary.
    @MainActor
    func test_a_completed_stop_emits_nothing() throws {
        try withScratchLogs { dir in
            let watchdog = StopStallWatchdog(ceilingSeconds: 0.05)
            watchdog.arm(file: file) { _ in XCTFail("disarmed watchdog must not fire") }
            watchdog.disarm()

            let settled = expectation(description: "past the ceiling")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
            wait(for: [settled], timeout: 5)

            XCTAssertEqual(try stallRows(in: dir).count, 0)
        }
    }

    /// Re-arming replaces the pending fire rather than stacking a second one, so two
    /// stops in a row cannot double-report.
    @MainActor
    func test_rearming_replaces_the_pending_fire() throws {
        try withScratchLogs { dir in
            let watchdog = StopStallWatchdog(ceilingSeconds: 0.05)
            let stalled = expectation(description: "onStall fired once")
            stalled.expectedFulfillmentCount = 1
            stalled.assertForOverFulfill = true

            watchdog.arm(file: file) { _ in stalled.fulfill() }
            watchdog.arm(file: file) { _ in stalled.fulfill() }
            wait(for: [stalled], timeout: 5)

            let settled = expectation(description: "no second fire")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
            wait(for: [settled], timeout: 5)

            XCTAssertEqual(try stallRows(in: dir).count, 1)
        }
    }

    /// The owner-facing sentence carries the elapsed time and no jargon; PRODUCT.md's
    /// register, and the reason the copy is derived here rather than at the call site.
    func test_stall_message_names_the_elapsed_time() {
        let message = StopStallWatchdog.stallMessage(elapsed: 95.4)
        XCTAssertTrue(message.contains("95"), message)
        XCTAssertFalse(message.contains("AVAudioEngine"), "no internals in owner-facing copy")
        XCTAssertFalse(message.contains("stopping"), "the state name is not owner vocabulary")
    }
}
