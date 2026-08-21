import Foundation
import XCTest
@testable import MeetingPipeCore

/// END10: the watcher half of the call-teardown oracle.
///
/// There was no suite here before this task, which is the direct reason END9 shipped broken.
/// `CallTeardownHoldTests` pinned `decide()` and the hold state machine, both of which were
/// correct, over a hand-started watcher pointed at `/nonexistent`, so it hard-coded the exact
/// production state that was broken and could never have failed on it.
final class CallTeardownWatcherTests: XCTestCase {

    private var tempDir = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("END10-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static let family = "MSTeamsNM_SlimCore_"

    @discardableResult
    private func writeGeneration(_ name: String, contents: String = "start\n") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Steps the poll by hand instead of racing a real timer.
    private final class ManualScheduler {
        private let lock = NSLock()
        private var pending: (() -> Void)?
        var schedule: CallTeardownWatcher.Scheduler {
            { [self] _, action in
                lock.lock(); pending = action; lock.unlock()
                return { [self] in lock.lock(); pending = nil; lock.unlock() }
            }
        }
        func fire() {
            lock.lock(); let action = pending; pending = nil; lock.unlock()
            action?()
        }
        var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }
    }

    // MARK: - Item 2: the tail has to tick more than once

    /// Red against a `Timer.scheduledTimer` re-armed from `readQueue`: the timer attaches to a run
    /// loop that is never run on a GCD worker, so `tickCount` stops at 1 and never moves again.
    /// This is the defect that would have kept the oracle dead even once it was started.
    func testDefaultSchedulerReArmsOffTheMainQueue() throws {
        try writeGeneration("MSTeamsNM_SlimCore_2026-08-20_00-00-00.99.log")
        let watcher = CallTeardownWatcher(
            directory: tempDir, family: Self.family,
            pollInterval: 0.02
        )
        watcher.start()
        // Nothing here touches the main run loop; production consults from main but the tail's
        // own re-arm must not depend on that.
        let deadline = Date().addingTimeInterval(3.0)
        while watcher.tickCount < 3, Date() < deadline { usleep(20_000) }
        watcher.stop()
        XCTAssertGreaterThanOrEqual(
            watcher.tickCount, 3,
            "the tail stopped re-arming; a run-loop Timer scheduled from readQueue ticks exactly once"
        )
    }

    func testStopEndsTheTail() throws {
        try writeGeneration("MSTeamsNM_SlimCore_2026-08-20_00-00-00.99.log")
        let scheduler = ManualScheduler()
        let watcher = CallTeardownWatcher(
            directory: tempDir, family: Self.family,
            scheduler: scheduler.schedule, readQueue: nil
        )
        watcher.start()
        XCTAssertTrue(watcher.isRunning)
        watcher.stop()
        XCTAssertFalse(watcher.isRunning)
        let before = watcher.tickCount
        scheduler.fire()
        XCTAssertEqual(watcher.tickCount, before, "a fired tick after stop() must be dropped")
    }

    // MARK: - Item 3: hysteresis on `available`

    /// Red without hysteresis: one failed resolve inside an open hold flips `available` false, and
    /// `decide` confirms immediately on the next consult. 323 single-tick flaps were measured in
    /// the field corpus, 8 of them during one live recording.
    func testSingleFailedResolveDoesNotDropAvailability() throws {
        let url = try writeGeneration("MSTeamsNM_SlimCore_2026-08-20_00-00-00.99.log")
        let scheduler = ManualScheduler()
        let watcher = CallTeardownWatcher(
            directory: tempDir, family: Self.family,
            scheduler: scheduler.schedule, readQueue: nil
        )
        watcher.start()
        XCTAssertTrue(watcher.snapshot().available, "a present log resolves available on tick 1")

        try FileManager.default.removeItem(at: url)
        scheduler.fire()
        XCTAssertTrue(
            watcher.snapshot().available,
            "one flap must not fail the oracle open: the longest observed run of consecutive "
                + "resolve failures in the whole field corpus is 1"
        )
    }

    func testAvailabilityDropsAfterTheMeasuredRunOfFailures() throws {
        let url = try writeGeneration("MSTeamsNM_SlimCore_2026-08-20_00-00-00.99.log")
        let scheduler = ManualScheduler()
        let watcher = CallTeardownWatcher(
            directory: tempDir, family: Self.family,
            scheduler: scheduler.schedule, readQueue: nil
        )
        watcher.start()
        try FileManager.default.removeItem(at: url)
        for _ in 0..<CallTeardownWatcher.unavailableAfterFailures { scheduler.fire() }
        XCTAssertFalse(
            watcher.snapshot().available,
            "a log that is genuinely gone still has to reach unavailable, or every end holds the cap"
        )
    }

    func testAvailabilityRisesImmediatelyOnRecovery() throws {
        let url = try writeGeneration("MSTeamsNM_SlimCore_2026-08-20_00-00-00.99.log")
        let scheduler = ManualScheduler()
        let watcher = CallTeardownWatcher(
            directory: tempDir, family: Self.family,
            scheduler: scheduler.schedule, readQueue: nil
        )
        watcher.start()
        try FileManager.default.removeItem(at: url)
        for _ in 0..<CallTeardownWatcher.unavailableAfterFailures { scheduler.fire() }
        XCTAssertFalse(watcher.snapshot().available)

        try writeGeneration("MSTeamsNM_SlimCore_2026-08-20_00-00-00.99.log")
        scheduler.fire()
        XCTAssertTrue(
            watcher.snapshot().available,
            "only the fall is damped; a resolve that worked is proof the log is back"
        )
    }

    // MARK: - Item 5: the snapshot carries the generation's mtime

    func testSnapshotCarriesTheGenerationMtime() throws {
        let url = try writeGeneration("MSTeamsNM_SlimCore_2026-08-20_00-00-00.99.log")
        let frozen = Date(timeIntervalSince1970: 1_750_000_000)
        try FileManager.default.setAttributes([.modificationDate: frozen], ofItemAtPath: url.path)
        let scheduler = ManualScheduler()
        let watcher = CallTeardownWatcher(
            directory: tempDir, family: Self.family,
            scheduler: scheduler.schedule, readQueue: nil
        )
        watcher.start()
        let written = try XCTUnwrap(watcher.snapshot().logLastWrittenAt)
        XCTAssertEqual(
            written.timeIntervalSince1970, frozen.timeIntervalSince1970, accuracy: 1.0,
            "without the mtime the oracle cannot tell a dead log from a quiet one"
        )
    }

    // MARK: - Item 4: the resolver's failure is legible

    func testMissingDirectoryIsReportedWithACause() throws {
        let missing = tempDir.appendingPathComponent("gone", isDirectory: true)
        let events = RecordingEventLog()
        let scheduler = ManualScheduler()
        let watcher = CallTeardownWatcher(
            directory: missing, family: Self.family,
            scheduler: scheduler.schedule, readQueue: nil, eventLog: events
        )
        watcher.start()
        let rows = events.entries.filter { $0.action == "call_teardown_source_missing" }
        XCTAssertEqual(rows.count, 1, "one row per distinct cause, not one per tick")
        let reason = try XCTUnwrap(rows.first?.attributes["reason"])
        XCTAssertTrue(
            reason.contains("NSCocoaErrorDomain") || reason.contains("260"),
            "the row has to name the cause; 'it returned nothing' is what END10 item 4 removes, got: \(reason)"
        )
        scheduler.fire()
        XCTAssertEqual(
            events.entries.filter { $0.action == "call_teardown_source_missing" }.count, 1,
            "the same cause must not be re-emitted every tick"
        )
    }

    // MARK: - Item 7: generations rank by the name's stamp, not mtime

    /// Red against an mtime sort: touching an older generation makes it outrank the live one, and
    /// the tail then follows a rotated file that no longer receives teardown lines.
    func testGenerationsRankByNameNotMtime() throws {
        let older = try writeGeneration("MSTeamsNM_SlimCore_2026-08-01_10-00-00.10.log")
        try writeGeneration("MSTeamsNM_SlimCore_2026-08-20_10-00-00.99.log")
        // The older generation is touched last, which is exactly the case that misranked.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: older.path
        )
        let newest = try XCTUnwrap(
            SlimCoreMuteLog.newest(in: tempDir, family: Self.family)?.lastPathComponent
        )
        XCTAssertEqual(
            newest, "MSTeamsNM_SlimCore_2026-08-20_10-00-00.99.log",
            "the name encodes creation order and never moves; mtime is the field that does"
        )
    }

    func testUnparsableNameFallsBackToMtime() throws {
        let plain = try writeGeneration("MSTeamsNM_SlimCore_nostamp.log")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(7200)], ofItemAtPath: plain.path
        )
        try writeGeneration("MSTeamsNM_SlimCore_2026-08-20_10-00-00.99.log")
        XCTAssertEqual(
            SlimCoreMuteLog.newest(in: tempDir, family: Self.family)?.lastPathComponent,
            "MSTeamsNM_SlimCore_nostamp.log",
            "a name that does not parse still has to rank, by mtime"
        )
    }

    func testListingReportsFailureForAMissingDirectory() {
        let listed = SlimCoreMuteLog.listing(
            in: tempDir.appendingPathComponent("nope", isDirectory: true), family: Self.family
        )
        XCTAssertTrue(listed.generations.isEmpty)
        XCTAssertNotNil(listed.failure, "a directory that cannot be listed has to say why")
    }

    func testListingSucceedsQuietlyWhenTheFamilyIsSimplyAbsent() throws {
        try writeGeneration("SomeOtherFamily_2026-08-20_10-00-00.log")
        let listed = SlimCoreMuteLog.listing(in: tempDir, family: Self.family)
        XCTAssertTrue(listed.generations.isEmpty)
        XCTAssertNil(
            listed.failure,
            "a readable directory with no matching family is absence, not a failure, and must not "
                + "be reported as one"
        )
    }
}
