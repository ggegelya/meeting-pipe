import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// END9, the wiring half. `CallTeardownOracleTests` pins the decision; these pin that the
/// controller acts on it, that the surfaces move with it, and that the held tail is trimmed.
///
/// `rescueProvisionalEnd` itself is not driven here: it does a cross-process AX walk against a live
/// Teams, which no test on this machine or in CI has. What it does after that walk comes up empty
/// is one call, `beginTeardownHold`, and that is what these exercise.
@MainActor
final class CallTeardownHoldTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("end9-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private let context = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2", kind: .native, pid: 635
    )

    /// A SlimCore generation in `logDir`, holding `lines`. Named to the real family, because the
    /// resolver matches on family and a differently named file is invisible to it by design.
    private func writeSlimCoreLog(_ lines: [String], to logDir: URL) throws {
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let url = logDir.appendingPathComponent("MSTeamsNM_SlimCore_2026-08-20_00-00-00.99.log")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// A teardown line stamped `secondsAgo` before now. SlimCore prints UTC digits and suffixes the
    /// machine's local offset, which is a lie the parser deliberately ignores, so the fixture writes
    /// the same shape: UTC digits, arbitrary suffix.
    private func teardownLine(secondsAgo: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date().addingTimeInterval(-secondsAgo))
        return "\(stamp)+03:00 0x1 <INFO> "
            + "SlimCoreModule::WindowContentProtectionProvider: UnregisterCall 385"
    }

    /// Holds the watcher's next scheduled tick so a test steps the poll instead of racing a timer.
    private final class ManualScheduler {
        private var pending: (() -> Void)?
        var schedule: CallTeardownWatcher.Scheduler {
            { [weak self] _, action in
                self?.pending = action
                return { self?.pending = nil }
            }
        }
        func fire() {
            let action = pending
            pending = nil
            action?()
        }
    }

    private var scheduler = ManualScheduler()

    /// Build the log, start a watcher over it, then **append** the lines and tick.
    ///
    /// The append is not incidental. `CallTeardownWatcher`'s first resolve starts at end-of-file, so
    /// engaging it does not replay every call Teams has ever torn down, and a line written before
    /// the watcher started is invisible by design. Production appends while the tail is already
    /// warm, so the fixture has to as well or it tests a path that never runs.
    private func makeController(
        logLines: [String]?
    ) throws -> (MeetingSessionController, FakeSessionHost) {
        let host = FakeSessionHost(tempDir: tempDir, workflows: [])
        if let logLines = logLines {
            let logDir = tempDir.appendingPathComponent("Logs", isDirectory: true)
            try writeSlimCoreLog(["2026-08-20T08:00:00.000000+03:00 0x1 <INFO> pre-existing"], to: logDir)
            host.callTeardown = CallTeardownWatcher(
                directory: logDir,
                family: "MSTeamsNM_SlimCore_",
                scheduler: scheduler.schedule,
                readQueue: nil
            )
            host.callTeardown.start()

            let url = logDir.appendingPathComponent("MSTeamsNM_SlimCore_2026-08-20_00-00-00.99.log")
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((logLines.joined(separator: "\n") + "\n").utf8))
            try handle.close()
            scheduler.fire()
        }
        return (MeetingSessionController(coordinator: host), host)
    }

    // MARK: - The defect

    /// The whole fix, at the seam it actually bit. Teams' controls went away, Teams logged no
    /// teardown, so the end is held and the recording keeps running.
    func test_a_provisional_end_with_no_teardown_opens_a_hold() throws {
        // A generation that exists and is readable, but carries no teardown: the exact state during
        // an accessibility blackout on a live call.
        let (controller, host) = try makeController(logLines: ["2026-08-20T09:00:00.000000+03:00 0x1 <INFO> noise"])

        controller.beginTeardownHold(context: context)

        XCTAssertNotNil(controller.teardownHold, "the recording must not be stopped on an empty AX walk")
        XCTAssertEqual(host.hudSpy.confirmingEndStates, [true], "the HUD has to say why it is still recording")
        controller.releaseTeardownHold()
    }

    /// The false end resolving the way it should: the call comes back, the hold is dropped, and no
    /// recording was ever stopped. On 2026-08-20 this was 16 s of the owner restarting by hand.
    func test_the_call_coming_back_releases_the_hold_without_ending_anything() throws {
        let (controller, host) = try makeController(logLines: ["2026-08-20T09:00:00.000000+03:00 0x1 <INFO> noise"])
        controller.beginTeardownHold(context: context)
        XCTAssertNotNil(controller.teardownHold)

        controller.releaseTeardownHold(rescued: true)

        XCTAssertNil(controller.teardownHold)
        XCTAssertEqual(host.hudSpy.confirmingEndStates, [true, false])
        XCTAssertNil(controller.pendingEndTrimAt, "nothing ended, so there is nothing to trim")
    }

    // MARK: - A genuine end still ends

    /// The companion the spec requires. The teardown leads the AX edge, so it is already on disk
    /// when the hold would open, the first consult confirms, and no hold is ever entered.
    func test_a_teardown_on_disk_confirms_without_ever_holding() throws {
        let (controller, host) = try makeController(logLines: [teardownLine(secondsAgo: 1.3)])

        controller.beginTeardownHold(context: context)

        XCTAssertNil(controller.teardownHold, "a real end must not be delayed by this")
        XCTAssertTrue(
            host.hudSpy.confirmingEndStates.isEmpty,
            "a confirm on the first consult never shows the holding state, so an ordinary end looks unchanged"
        )
        XCTAssertNil(controller.pendingEndTrimAt, "nothing was held, so nothing is trimmed")
    }

    /// A previous call's teardown must not confirm this one. Back-to-back meetings are routine
    /// here, and the cooldown branch exists because of them.
    func test_a_stale_teardown_does_not_confirm() throws {
        // `host` is bound rather than discarded: the controller holds it `unowned`, so letting it
        // deallocate traps on the next access.
        let (controller, host) = try makeController(logLines: [teardownLine(secondsAgo: 600)])
        defer { withExtendedLifetime(host) {} }

        controller.beginTeardownHold(context: context)

        XCTAssertNotNil(controller.teardownHold, "a ten-minute-old teardown belongs to another call")
        controller.releaseTeardownHold()
    }

    /// The degradation that makes this change never worse than what it replaces: no readable log
    /// means the pre-END9 behaviour, an immediate confirm. `FakeSessionHost`'s default watcher
    /// points at a directory that does not exist, which is exactly that state.
    func test_an_unavailable_log_confirms_immediately_as_before() throws {
        let (controller, host) = try makeController(logLines: nil)

        controller.beginTeardownHold(context: context)

        XCTAssertNil(controller.teardownHold)
        XCTAssertTrue(host.hudSpy.confirmingEndStates.isEmpty)
    }

    // MARK: - Re-entrancy

    /// A second provisional for the same call must not re-stamp the hold, or a flapping signal
    /// pushes the 150 s cap out indefinitely and the ceiling stops being a ceiling.
    func test_a_second_provisional_does_not_restart_the_clock() throws {
        let (controller, host) = try makeController(logLines: ["2026-08-20T09:00:00.000000+03:00 0x1 <INFO> noise"])
        defer { withExtendedLifetime(host) {} }
        controller.beginTeardownHold(context: context)
        let firstStamp = controller.teardownHold?.startedAt

        controller.beginTeardownHold(context: context)

        XCTAssertEqual(controller.teardownHold?.startedAt, firstStamp)
        controller.releaseTeardownHold()
    }

    // MARK: - The trim arithmetic

    private func lengths(target: Double?) -> RecordingPostProcessor.MergeLengths {
        RecordingPostProcessor.MergeLengths(
            systemDelayMs: 0, padMic: true, targetDurationSec: target, expectedDurationSec: target
        )
    }

    /// A held tail is post-call audio, so the confirm cuts it off rather than publishing it.
    func test_a_trim_shortens_the_merge_target() {
        let trimmed = RecordingPostProcessor.applyTrim(lengths(target: 300), limitSeconds: 150)
        XCTAssertEqual(trimmed.targetDurationSec, 150)
        XCTAssertEqual(trimmed.expectedDurationSec, 150, "the plausibility check has to expect the trimmed length")
    }

    /// A trim may only ever shorten. A limit longer than the captured audio would otherwise pad
    /// silence onto the end, turning a safety measure into a fabricated tail.
    func test_a_trim_never_lengthens() {
        let trimmed = RecordingPostProcessor.applyTrim(lengths(target: 100), limitSeconds: 150)
        XCTAssertEqual(trimmed.targetDurationSec, 100)
    }

    /// Every ordinary stop passes nil, and REC9's policy has to come through untouched: a real end
    /// must publish byte-for-byte what it published before END9.
    func test_no_limit_leaves_the_policy_alone() {
        let original = lengths(target: 300)
        XCTAssertEqual(RecordingPostProcessor.applyTrim(original, limitSeconds: nil), original)
        XCTAssertEqual(RecordingPostProcessor.applyTrim(original, limitSeconds: 0), original)
    }

    /// The unreadable-duration case REC14 fixed still reaches ffmpeg with a cut when a trim is set,
    /// because a held end knows its own length even when the files do not.
    func test_a_trim_supplies_a_target_where_the_policy_had_none() {
        let trimmed = RecordingPostProcessor.applyTrim(lengths(target: nil), limitSeconds: 150)
        XCTAssertEqual(trimmed.targetDurationSec, 150)
    }
}
