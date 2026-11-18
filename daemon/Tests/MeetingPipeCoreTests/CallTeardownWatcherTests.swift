import Foundation
import XCTest
@testable import MeetingPipeCore
import MeetingPipeTestSupport

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

    /// Steps the poll by hand instead of racing a real timer. Repeating, as the production timer
    /// is since END16: `fire()` keeps the action until the cancel closure clears it, so a
    /// multi-fire test cannot go quietly vacuous after its first tick.

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
        XCTAssertFalse(scheduler.hasPending, "stop() must cancel the repeating timer, not only outrun it")
        let before = watcher.tickCount
        scheduler.tick()
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
        scheduler.tick()
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
        for _ in 0..<CallTeardownWatcher.unavailableAfterFailures { scheduler.tick() }
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
        for _ in 0..<CallTeardownWatcher.unavailableAfterFailures { scheduler.tick() }
        XCTAssertFalse(watcher.snapshot().available)

        try writeGeneration("MSTeamsNM_SlimCore_2026-08-20_00-00-00.99.log")
        scheduler.tick()
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
        XCTAssertEqual(events.diagnosticActions, ["call_teardown_source_missing"], "OBS9: a diagnostics.jsonl row")
        let reason = try XCTUnwrap(rows.first?.attributes["reason"])
        XCTAssertTrue(
            reason.contains("NSCocoaErrorDomain") || reason.contains("260"),
            "the row has to name the cause; 'it returned nothing' is what END10 item 4 removes, got: \(reason)"
        )
        scheduler.tick()
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

    // MARK: - END16

    /// An in-memory SlimCore folder that counts the calls the read path makes.
    private final class FakeFolder {
        var files: [String: Data] = [:]
        var mtimes: [String: Date] = [:]
        var listingFails = false
        var statFails = false
        private(set) var listings = 0
        private(set) var stats = 0
        let dir = "/fake/Logs"

        func path(_ name: String) -> String { dir + "/" + name }
        func append(_ name: String, _ text: String) { files[path(name), default: Data()].append(Data(text.utf8)) }

        var fileSystem: SlimCoreMuteLog.FileSystem {
            SlimCoreMuteLog.FileSystem(
                names: { [self] _ in
                    listings += 1
                    if listingFails { throw NSError(domain: NSCocoaErrorDomain, code: 256) }
                    return files.keys.map { ($0 as NSString).lastPathComponent }
                },
                stat: { [self] path in
                    stats += 1
                    guard !statFails, let data = files[path] else { return nil }
                    return (UInt64(data.count), mtimes[path] ?? Date(timeIntervalSince1970: 0))
                },
                read: { [self] path, offset in
                    guard let data = files[path], offset <= UInt64(data.count) else { return nil }
                    return data.subdata(in: Int(offset)..<data.count)
                }
            )
        }
    }

    private static let generation = "MSTeamsNM_SlimCore_2026-11-01_09-00-00.10.log"
    private static let teardownLine = "2026-11-12T14:32:40.100000+02:00 0x1 <INFO> SlimCoreModule::WindowContentProtectionProvider: UnregisterCall 406\n"
    private static let registerLine = "2026-11-12T14:00:00.000000+02:00 0x1 <INFO> SlimCoreModule::WindowContentProtectionProvider: SetWindowContentProtection 406\n"

    private func fakeWatcher(
        _ folder: FakeFolder, scheduler: ManualScheduler, events: EventLog = NoopEventLog(),
        clock: LockedBox<Date> = LockedBox(Date(timeIntervalSince1970: 1_000_000))
    ) -> CallTeardownWatcher {
        CallTeardownWatcher(
            directory: URL(fileURLWithPath: folder.dir), family: Self.family,
            scheduler: scheduler.schedule, readQueue: nil, eventLog: events,
            fileSystem: folder.fileSystem, now: { clock.get() }
        )
    }

    func testManyTicksAreDrivenByOneTimer() throws {
        let folder = FakeFolder()
        folder.append(Self.generation, "start\n")
        let scheduler = ManualScheduler()
        let watcher = fakeWatcher(folder, scheduler: scheduler)
        watcher.start()
        for _ in 0..<10 { scheduler.tick() }
        XCTAssertEqual(watcher.tickCount, 11)
        XCTAssertEqual(scheduler.scheduleCount, 1, "one repeating timer, not one per tick")
    }

    func testATickThatIsNotRelistingStatsOnlyTheTailedFile() throws {
        let folder = FakeFolder()
        folder.append(Self.generation, "start\n")
        folder.append("MSTeamsNM_SlimCore_2026-10-01_09-00-00.10.log", "old\n")
        let scheduler = ManualScheduler()
        let clock = LockedBox(Date(timeIntervalSince1970: 1_000_000))
        let watcher = fakeWatcher(folder, scheduler: scheduler, clock: clock)
        watcher.start()   // first tick lists
        let (listings, stats) = (folder.listings, folder.stats)
        clock.set(clock.get().addingTimeInterval(1))
        scheduler.tick()
        XCTAssertEqual(folder.listings, listings, "no listing inside relistInterval")
        XCTAssertEqual(folder.stats - stats, 1, "one stat: the generation being tailed")

        clock.set(clock.get().addingTimeInterval(CallTeardownWatcher.relistInterval))
        scheduler.tick()
        XCTAssertEqual(folder.listings, listings + 1, "a listing once relistInterval has passed")
    }

    func testListingParsesEachNameOnce() {
        let folder = FakeFolder()
        for day in 1...9 { folder.append("MSTeamsNM_SlimCore_2026-10-0\(day)_09-00-00.10.log", "x\n") }
        let parses = LockedBox(0)
        let listed = SlimCoreMuteLog.listing(
            in: URL(fileURLWithPath: folder.dir), family: Self.family, fileSystem: folder.fileSystem,
            parseName: { name in parses.mutate { $0 += 1 }; return SlimCoreMuteLog.nameTimestamp(name) }
        )
        XCTAssertEqual(listed.generations.count, 9)
        XCTAssertEqual(parses.get(), 9, "one parse per name, not two per comparison")
        XCTAssertEqual(listed.generations.last?.url.lastPathComponent, "MSTeamsNM_SlimCore_2026-10-09_09-00-00.10.log")
    }

    func testSnapshotIsNotHeldUpByATicksParse() throws {
        let folder = FakeFolder()
        folder.append(Self.generation, "start\n")
        let parsing = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let watcher = CallTeardownWatcher(
            directory: URL(fileURLWithPath: folder.dir), family: Self.family,
            scheduler: { _, _ in {} }, readQueue: DispatchQueue(label: "END16.parse"),
            fileSystem: folder.fileSystem,
            parse: { chunk, pending in
                parsing.signal()
                _ = release.wait(timeout: .now() + 2)
                return SlimCoreTeardownLog.lines(inChunk: chunk, pending: pending)
            }
        )
        watcher.start()
        XCTAssertEqual(parsing.wait(timeout: .now() + 2), .success)
        let started = Date()
        _ = watcher.snapshot()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "snapshot() waited on a parse")
        release.signal()
        watcher.stop()
    }

    func testIdleCadenceWhileTeamsIsNotRunningKeepsAvailability() throws {
        let folder = FakeFolder()
        folder.append(Self.generation, "start\n")
        let scheduler = ManualScheduler()
        let watcher = fakeWatcher(folder, scheduler: scheduler)
        watcher.start()
        XCTAssertEqual(scheduler.scheduledDelays, [CallTeardownWatcher.defaultPollInterval], "1 Hz until told otherwise")
        XCTAssertTrue(watcher.snapshot().available)

        watcher.setTeamsRunning(false)
        XCTAssertEqual(scheduler.scheduledDelays.last, CallTeardownWatcher.idlePollInterval)
        XCTAssertEqual(watcher.currentPollInterval, CallTeardownWatcher.idlePollInterval)
        XCTAssertTrue(watcher.snapshot().available, "slowing down must not lapse the oracle")

        let ticks = watcher.tickCount
        let listings = folder.listings
        watcher.setTeamsRunning(true)
        XCTAssertEqual(scheduler.scheduledDelays.last, CallTeardownWatcher.defaultPollInterval)
        XCTAssertEqual(watcher.tickCount, ticks + 1, "a launch ticks at once, before any consult")
        XCTAssertEqual(folder.listings, listings + 1, "a launch lists, since a launch is when Teams rotates")
        XCTAssertTrue(watcher.snapshot().available)
    }

    func testATeamsQuitTicksAtOnce() throws {
        let folder = FakeFolder()
        folder.append(Self.generation, "start\n")
        let scheduler = ManualScheduler()
        let watcher = fakeWatcher(folder, scheduler: scheduler)
        watcher.start()
        folder.append(Self.generation, Self.teardownLine)
        watcher.setTeamsRunning(false)
        XCTAssertNotNil(watcher.snapshot().lastTeardownAt, "the teardown a quit flushed was read at once, not 30 s later")
    }

    func testALineWrittenAcrossAFailedListingIsStillRead() throws {
        // F160: the old tick dropped `current` on a failed listing, and the next success started at
        // end of file, so these bytes were never read.
        let folder = FakeFolder()
        folder.append(Self.generation, "start\n")
        let scheduler = ManualScheduler()
        let clock = LockedBox(Date(timeIntervalSince1970: 1_000_000))
        let watcher = fakeWatcher(folder, scheduler: scheduler, clock: clock)
        watcher.start()
        // Half a line is read and carried before the failure, the rest is written during it.
        folder.append(Self.generation, "2026-11-12T14:32:40.100000+02:00 0x1 <INFO> SlimCoreModule::Window")
        scheduler.tick()

        folder.listingFails = true
        folder.statFails = true
        folder.append(Self.generation, "ContentProtec")
        clock.set(clock.get().addingTimeInterval(11))
        scheduler.tick()
        folder.listingFails = false
        folder.statFails = false
        folder.append(Self.generation, "tionProvider: UnregisterCall 406\n")
        clock.set(clock.get().addingTimeInterval(11))
        scheduler.tick()
        XCTAssertNotNil(watcher.snapshot().lastTeardownAt)
    }

    func testAFailedListingStillReadsTheTailedGeneration() throws {
        let folder = FakeFolder()
        folder.append(Self.generation, "start\n")
        let scheduler = ManualScheduler()
        let clock = LockedBox(Date(timeIntervalSince1970: 1_000_000))
        let events = RecordingEventLog()
        let watcher = fakeWatcher(folder, scheduler: scheduler, events: events, clock: clock)
        watcher.start()
        folder.listingFails = true
        folder.append(Self.generation, Self.teardownLine)
        clock.set(clock.get().addingTimeInterval(11))
        scheduler.tick()
        XCTAssertNotNil(watcher.snapshot().lastTeardownAt)
        XCTAssertTrue(watcher.snapshot().available)
        XCTAssertEqual(events.entries.filter { $0.action == "call_teardown_source_missing" }.count, 1)
    }

    func testARotationStartsTheNewGenerationAtZero() throws {
        let folder = FakeFolder()
        folder.append(Self.generation, "start\n")
        let scheduler = ManualScheduler()
        let watcher = fakeWatcher(folder, scheduler: scheduler)
        watcher.start()
        folder.append("MSTeamsNM_SlimCore_2026-11-12_09-00-00.10.log", Self.teardownLine)
        watcher.setTeamsRunning(false)
        watcher.setTeamsRunning(true)   // a launch forces the listing that finds the rotation
        XCTAssertNotNil(watcher.snapshot().lastTeardownAt, "a generation newer than the tail is read from 0")
    }

    func testThreeFlapsInAnHourLogOneMissingAndOneRecoveredRow() throws {
        let folder = FakeFolder()
        folder.append(Self.generation, "start\n")
        let scheduler = ManualScheduler()
        let clock = LockedBox(Date(timeIntervalSince1970: 1_000_000))
        let events = RecordingEventLog()
        let watcher = fakeWatcher(folder, scheduler: scheduler, events: events, clock: clock)
        watcher.start()
        for _ in 0..<3 {
            folder.listingFails = true
            clock.set(clock.get().addingTimeInterval(11))
            scheduler.tick()
            folder.listingFails = false
            clock.set(clock.get().addingTimeInterval(11))
            scheduler.tick()
        }
        let missing = events.entries.filter { $0.action == "call_teardown_source_missing" }
        let recovered = events.entries.filter { $0.action == "call_teardown_source_recovered" }
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(missing.first?.attributes["failures"], "1")
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.attributes["outage_sec"], "11.0")

        // Past the hour the next failure reports again, carrying the two that were suppressed.
        clock.set(clock.get().addingTimeInterval(3600))
        folder.listingFails = true
        scheduler.tick()
        XCTAssertEqual(events.entries.filter { $0.action == "call_teardown_source_missing" }.last?.attributes["failures"], "3")
    }

    func testAStatOnlyTickDoesNotEndAListingOutage() throws {
        // In production a failed listing is followed a second later by a stat-only tick that reads
        // the tailed file fine; that proves nothing about the folder and must not close the outage.
        let folder = FakeFolder()
        folder.append(Self.generation, "start\n")
        let scheduler = ManualScheduler()
        let clock = LockedBox(Date(timeIntervalSince1970: 1_000_000))
        let events = RecordingEventLog()
        let watcher = fakeWatcher(folder, scheduler: scheduler, events: events, clock: clock)
        watcher.start()
        folder.listingFails = true
        clock.set(clock.get().addingTimeInterval(11))
        scheduler.tick()
        for _ in 0..<5 {
            clock.set(clock.get().addingTimeInterval(1))
            scheduler.tick()
        }
        XCTAssertFalse(events.entries.contains { $0.action == "call_teardown_source_recovered" })
        folder.listingFails = false
        clock.set(clock.get().addingTimeInterval(5))
        scheduler.tick()
        let recovered = events.entries.filter { $0.action == "call_teardown_source_recovered" }
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.attributes["outage_sec"], "10.0", "the outage runs to the listing that worked")
    }

    func testEachParsedLineIsLoggedWithItsOwnTimeAndAHashedID() throws {
        let folder = FakeFolder()
        folder.append(Self.generation, "start\n")
        let scheduler = ManualScheduler()
        let events = RecordingEventLog()
        let watcher = fakeWatcher(folder, scheduler: scheduler, events: events)
        watcher.start()
        folder.append(Self.generation, Self.registerLine)
        scheduler.tick()
        XCTAssertNil(watcher.snapshot().lastTeardownAt, "a registration line must never read as a teardown")
        folder.append(Self.generation, Self.teardownLine)
        scheduler.tick()

        let rows = events.entries.filter { $0.action == "call_teardown_line" }
        XCTAssertEqual(rows.map { $0.attributes["kind"] }, ["register", "unregister"])
        XCTAssertEqual(rows.last?.attributes["line_at"], "2026-11-12T14:32:40.100Z", "SlimCore prints UTC with a local offset")
        XCTAssertEqual(rows.first?.attributes["call_id_hash"], rows.last?.attributes["call_id_hash"], "one call pairs")
        XCTAssertFalse(rows.contains { $0.attributes.values.contains("406") }, "the raw call id is never logged")
        XCTAssertNotNil(rows.last?.attributes["read_lag_sec"])
        XCTAssertNotNil(watcher.snapshot().lastTeardownAt)
    }

    func testSourceOutageReportRateLimitsPerCause() {
        var report = SourceOutageReport(interval: 3600)
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(report.failure(cause: "a", at: t0), .init(cause: "a", failures: 1))
        XCTAssertNil(report.failure(cause: "a", at: t0.addingTimeInterval(1)))
        XCTAssertEqual(report.failure(cause: "b", at: t0.addingTimeInterval(2)), .init(cause: "b", failures: 2),
                       "a different cause reports at once, carrying the suppressed failure")
        XCTAssertEqual(report.success(at: t0.addingTimeInterval(10)), .init(outageSec: 10, failures: 3))
        XCTAssertNil(report.success(at: t0.addingTimeInterval(11)), "one recovered row per outage")
        XCTAssertNil(report.failure(cause: "a", at: t0.addingTimeInterval(20)))
        XCTAssertNil(report.success(at: t0.addingTimeInterval(21)), "no recovered row for an outage nobody was told about")
    }
}
