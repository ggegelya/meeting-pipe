import Foundation
import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// END10 item 8: fence the wiring, not the unit.
///
/// END9's oracle was correct, well tested, and never ran. `CallTeardownHoldTests` built its own
/// watcher and called `start()` on it by hand, so it pinned `decide()` and the hold state machine
/// while hard-coding the exact production state that was broken: `Coordinator.start()` never
/// started the real watcher, and `Coordinator.swift` carried a doc comment claiming it did. The
/// suite could not have failed on that, and 28 green tests said the feature shipped.
///
/// So the claim under test here is the wiring itself. T7 moved the watchers behind
/// `SessionWatchers`, and `SessionWatchersTests` checks from fakes that every member starts and
/// that the production set holds all three, so what is left here is the one line no headless test
/// can reach: that `Coordinator.start()` calls `watchers.startAll()` at all. It stays a source
/// fence because the real `Coordinator` builds a status-bar item, four windows and the AX and HAL
/// buses, none of which stands up headless in a unit test. When `start()` cannot be found the
/// fence fails rather than skips (T7): a skip reads as a pass in XCTest and in `swift test`'s exit
/// code, so a rename used to switch the fence off with the suite still green.
final class CoordinatorWiringFenceTests: XCTestCase {

    private struct FenceTargetMissing: Error {
        let message: String
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
            .deletingLastPathComponent()   // repo root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The body of `func start()` in `Coordinator.swift`, brace-matched from its opening line.
    private func coordinatorStartBody() throws -> String {
        let text = try source("daemon/Sources/MeetingPipe/Coordinator.swift")
        guard let start = text.range(of: "\n    func start() {") else {
            let message = "Coordinator.start() was renamed or moved; this fence needs updating with it"
            XCTFail(message)
            throw FenceTargetMissing(message: message)
        }
        var depth = 0
        var body = ""
        for character in text[start.lowerBound...] {
            body.append(character)
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { break }
            }
        }
        return body
    }

    /// The defect itself: a watcher that is constructed and never started reports "no opinion"
    /// forever, and `decide` turns that into an immediate confirm on every provisional end.
    func testCoordinatorStartStartsTheSessionWatchers() throws {
        let body = try coordinatorStartBody()
        XCTAssertTrue(
            body.contains("watchers.startAll()"),
            "Coordinator.start() does not start its session watchers. Every provisional end will "
                + "confirm with oracle_unavailable on its first consult, which is the "
                + "END9-shipped-dead defect END10 fixed: 16 meetings chopped and restarted by hand "
                + "between 2026-07-13 and 2026-08-21."
        )
    }

    /// A watcher constructed at the property is only half the wiring; this pins the other half so a
    /// future edit cannot quietly drop the construction and leave `start()` calling into nothing.
    func testCoordinatorHoldsATeamsCallTeardownWatcher() throws {
        let text = try source("daemon/Sources/MeetingPipe/Coordinator.swift")
        XCTAssertTrue(
            text.contains("CallTeardownWatcher.teams("),
            "Coordinator no longer builds the Teams call-teardown watcher"
        )
    }

    /// END9's doc comment asserted a start that did not exist for the whole life of the feature.
    /// A comment is not a fence, so the one that replaced it must sit next to a real call.
    func testTheWatcherIsRunnableAndReportsIt() {
        let watcher = CallTeardownWatcher(
            directory: URL(fileURLWithPath: NSTemporaryDirectory()),
            family: "MSTeamsNM_SlimCore_",
            scheduler: { _, _ in {} },
            readQueue: nil
        )
        XCTAssertFalse(watcher.isRunning, "a fresh watcher is not running")
        watcher.start()
        XCTAssertTrue(watcher.isRunning, "start() has to be observable, or no fence can check it")
        watcher.stop()
        XCTAssertFalse(watcher.isRunning)
    }
}
