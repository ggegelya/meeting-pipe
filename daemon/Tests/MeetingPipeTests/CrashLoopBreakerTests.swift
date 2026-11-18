import XCTest
@testable import MeetingPipe

/// UX82 item 2: the crash-loop breaker. Pure: a history and a clock in, a verdict out.
final class CrashLoopBreakerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    /// Fold `n` unclean launches `gap` seconds apart, starting at `t0`.
    private func launches(_ n: Int, gap: TimeInterval, from history: [Date] = []) -> CrashLoopBreaker.Verdict {
        var history = history
        var verdict = CrashLoopBreaker.Verdict(history: history, tripped: false, count: 0)
        for i in 0..<n {
            verdict = CrashLoopBreaker.decide(history: history, now: t0.addingTimeInterval(Double(i) * gap), previousExit: "unclean")
            history = verdict.history
        }
        return verdict
    }

    func test_five_crashes_inside_a_minute_do_not_trip() {
        let verdict = launches(5, gap: 10)
        XCTAssertFalse(verdict.tripped)
        XCTAssertEqual(verdict.count, 5)
    }

    func test_six_crashes_inside_a_minute_trip() {
        let verdict = launches(6, gap: 10)
        XCTAssertTrue(verdict.tripped)
        XCTAssertEqual(verdict.count, 6)
    }

    func test_launches_after_a_clean_exit_do_not_count() {
        var history: [Date] = []
        for (i, exit) in ["quit", "relaunch", "sigterm", "first_launch", "quit", "relaunch", "quit"].enumerated() {
            let verdict = CrashLoopBreaker.decide(history: history, now: t0.addingTimeInterval(Double(i)), previousExit: exit)
            XCTAssertFalse(verdict.tripped, exit)
            history = verdict.history
        }
        XCTAssertTrue(history.isEmpty, "a requested relaunch, a quit and a login leave no trace")
    }

    func test_old_crashes_age_out_of_the_window() {
        let spaced = launches(6, gap: 15)   // 0, 15, ..., 75 s: never six inside 60 s
        XCTAssertFalse(spaced.tripped)
        XCTAssertEqual(spaced.count, 4, "only the launches inside the last minute remain")
    }

    func test_the_history_is_bounded() {
        let verdict = launches(30, gap: 1)
        XCTAssertEqual(verdict.history.count, CrashLoopBreaker.historyLimit)
        XCTAssertTrue(verdict.tripped)
    }

    /// Quitting the safe mode and reopening inside the minute follows a clean exit: it starts
    /// normally even though the window still holds six crashes.
    func test_a_clean_launch_after_a_trip_starts_normally() {
        let tripped = launches(6, gap: 1)
        let after = CrashLoopBreaker.decide(history: tripped.history, now: t0.addingTimeInterval(10), previousExit: "quit")
        XCTAssertFalse(after.tripped)
    }

    func test_the_history_round_trips_through_its_file_and_reset_clears_it() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("breaker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<6 {
            _ = CrashLoopBreaker.evaluate(logsDir: dir, previousExit: "unclean", now: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(CrashLoopBreaker.load(from: dir.appendingPathComponent(CrashLoopBreaker.fileName)).count, 6)
        CrashLoopBreaker.reset(logsDir: dir)
        XCTAssertFalse(CrashLoopBreaker.evaluate(logsDir: dir, previousExit: "unclean", now: t0.addingTimeInterval(7)).tripped)
    }

    /// The breaker is wiring `App.main` alone can do, so the calling is fenced on the source:
    /// after `LaunchRecord.begin` (it reads that verdict) and before `NSApplication` exists.
    func test_app_main_consults_the_breaker_before_the_app_runs() throws {
        let app = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MeetingPipe/App.swift"),
            encoding: .utf8
        )
        let begin = try XCTUnwrap(app.range(of: "let previous = LaunchRecord.begin()"))
        let breaker = try XCTUnwrap(app.range(of: "CrashLoopBreaker.evaluate(logsDir: Log.logsDir, previousExit: previous.exit)"))
        let run = try XCTUnwrap(app.range(of: "app.run()"))
        XCTAssertLessThan(begin.lowerBound, breaker.lowerBound)
        XCTAssertLessThan(breaker.lowerBound, run.lowerBound)
        XCTAssertTrue(app.contains("if let count = AppDelegate.safeModeLaunchCount {"), "a tripped launch starts the safe mode")
    }
}

