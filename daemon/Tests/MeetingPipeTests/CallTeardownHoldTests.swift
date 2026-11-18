import XCTest
@testable import MeetingPipe
import MeetingPipeTestSupport
@testable import MeetingPipeCore

/// END9 and END17, the wiring half. `CallTeardownOracleTests` pins the decision; these pin that the
/// controller acts on it, that the surfaces move with it, and that the held tail is marked for
/// trimming, then kept or cut by posture.
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

            try appendToGeneration(logLines)
            scheduler.tick()
        }
        return (MeetingSessionController(coordinator: host), host)
    }

    private var generationURL: URL {
        tempDir.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MSTeamsNM_SlimCore_2026-08-20_00-00-00.99.log")
    }

    private func appendToGeneration(_ lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: generationURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }

    /// Age the generation's mtime to `seconds` ago and let the watcher read it, which is how every
    /// quiet call looks: SlimCore writes only on events and buffers them until a call boundary, so
    /// the file's clock sits at the previous teardown for the length of the call (END12).
    private func ageGeneration(by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: generationURL.path
        )
        scheduler.tick()
    }

    // MARK: - The defect

    /// The whole fix, at the seam it actually bit. Teams' controls went away, Teams logged no
    /// teardown, so the end is held and the recording keeps running.
    func test_a_provisional_end_with_no_teardown_opens_a_hold() throws {
        // A generation that exists and is readable, but carries no teardown: the exact state during
        // an accessibility blackout on a live call.
        let (controller, host) = try makeController(logLines: ["2026-08-20T09:00:00.000000+03:00 0x1 <INFO> noise"])

        controller.beginTeardownHold(context: context)

        XCTAssertNotNil(controller.holdPolicy.hold, "the recording must not be stopped on an empty AX walk")
        XCTAssertEqual(host.hudSpy.confirmingEndStates, [true], "the HUD has to say why it is still recording")
        controller.releaseTeardownHold()
    }

    /// The false end resolving the way it should: the call comes back, the hold is dropped, and no
    /// recording was ever stopped. On 2026-08-20 this was 16 s of the owner restarting by hand.
    func test_the_call_coming_back_releases_the_hold_without_ending_anything() throws {
        let (controller, host) = try makeController(logLines: ["2026-08-20T09:00:00.000000+03:00 0x1 <INFO> noise"])
        controller.beginTeardownHold(context: context)
        XCTAssertNotNil(controller.holdPolicy.hold)

        controller.releaseTeardownHold(rescued: true)

        XCTAssertNil(controller.holdPolicy.hold)
        XCTAssertEqual(host.hudSpy.confirmingEndStates, [true, false])
        XCTAssertNil(controller.pendingEndTrimAt, "nothing ended, so there is nothing to trim")
    }

    // MARK: - A genuine end still ends

    /// The companion the spec requires. The teardown leads the AX edge, so it is already on disk
    /// when the hold would open, the first consult confirms, and no hold is ever entered.
    func test_a_teardown_on_disk_confirms_without_ever_holding() throws {
        let (controller, host) = try makeController(logLines: [teardownLine(secondsAgo: 1.3)])

        controller.beginTeardownHold(context: context)

        XCTAssertNil(controller.holdPolicy.hold, "a real end must not be delayed by this")
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

        XCTAssertNotNil(controller.holdPolicy.hold, "a ten-minute-old teardown belongs to another call")
        controller.releaseTeardownHold()
    }

    /// END17: an unreadable log is "no evidence", never a confirm. It used to confirm at once on the
    /// theory that this could only ever be neutral; END10 measured the source flapping 323 times and
    /// END15 6131 times, so an end landing in a blind second was a chop. `FakeSessionHost`'s default
    /// watcher points at a directory that does not exist, which is exactly that state.
    func test_an_unavailable_log_holds_rather_than_confirming_END17() throws {
        let (controller, host) = try makeController(logLines: nil)

        controller.beginTeardownHold(context: context)
        controller.consultTeardownOracle(now: Date().addingTimeInterval(3_600))

        XCTAssertNotNil(controller.holdPolicy.hold, "an oracle that cannot see is not evidence of an end")
        XCTAssertEqual(host.hudSpy.confirmingEndStates, [true])
        controller.releaseTeardownHold()
    }

    // MARK: - END16: the hold-side rows and the Teams-family gate

    private func withEventLog(_ body: (URL) throws -> Void) throws {
        let logs = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }
        try body(logs)
    }

    private func rows(_ action: String, in logs: URL) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    /// G053 at the host: a Teams teardown half a second ago, a native Zoom hold. Zoom's end must not
    /// be confirmed by it, and the hold asks the watcher nothing.
    func test_a_teams_teardown_does_not_confirm_a_zoom_hold_END16() throws {
        try withEventLog { logs in
            let (controller, host) = try makeController(logLines: [teardownLine(secondsAgo: 0.5)])
            defer { withExtendedLifetime(host) {} }
            let zoom = MeetingLifecycleContext(bundleID: "us.zoom.xos", kind: .native, pid: 88)

            controller.beginTeardownHold(context: zoom)
            controller.consultTeardownOracle()

            XCTAssertNotNil(controller.holdPolicy.hold, "another app's teardown is no evidence about Zoom")
            controller.releaseTeardownHold()
            XCTAssertTrue(rows("lifecycle_teardown_consult", in: logs).isEmpty, "a hold that does not consult logs no consult, nor a resolved row")
            let held = rows("lifecycle_end_held", in: logs).first
            XCTAssertEqual(held?["consults_teardown"] as? Bool, false)
            XCTAssertNil(held?["tail_offset"], "a Zoom hold carries none of Teams' log")
        }
    }

    /// The measurement the 60 s Teams end waits on: an edge row on the first consult, the counts
    /// (blind consults among them) once when the hold resolves, and the oracle's view in the held row.
    func test_a_blind_teams_hold_logs_its_first_consult_and_its_counts_once_END16() throws {
        try withEventLog { logs in
            let (controller, host) = try makeController(logLines: nil)
            defer { withExtendedLifetime(host) {} }

            controller.beginTeardownHold(context: context)
            controller.consultTeardownOracle()
            controller.consultTeardownOracle()
            controller.releaseTeardownHold()

            let held = try XCTUnwrap(rows("lifecycle_end_held", in: logs).first)
            XCTAssertEqual(held["consults_teardown"] as? Bool, true)
            XCTAssertNotNil(held["tail_offset"])
            let consults = rows("lifecycle_teardown_consult", in: logs)
            XCTAssertEqual(consults.map { $0["edge"] as? String }, ["first", "resolved"])
            XCTAssertEqual(consults.first?["available"] as? Bool, false)
            XCTAssertEqual(consults.last?["consults"] as? Int, 3)
            XCTAssertEqual(consults.last?["blind_consults"] as? Int, 3)
            XCTAssertEqual(consults.last?["resolution"] as? String, "released")
        }
    }

    /// A readable log: the first consult carries the newest teardown's age and where it fell against
    /// the hold, and a new teardown line landing mid-hold is an edge of its own.
    func test_a_readable_teams_hold_logs_a_new_teardown_line_as_an_edge_END16() throws {
        try withEventLog { logs in
            let (controller, host) = try makeController(logLines: [teardownLine(secondsAgo: 600)])
            defer { withExtendedLifetime(host) {} }

            controller.beginTeardownHold(context: context)
            controller.consultTeardownOracle()   // the same stamp: no row
            try appendToGeneration([teardownLine(secondsAgo: 0)])
            scheduler.tick()
            controller.consultTeardownOracle()   // confirms on the fresh line, and resolves

            let consults = rows("lifecycle_teardown_consult", in: logs)
            XCTAssertEqual(consults.map { $0["edge"] as? String }, ["first", "stamp_changed", "resolved"])
            XCTAssertEqual(consults.first?["available"] as? Bool, true)
            XCTAssertGreaterThan(consults.first?["teardown_age_sec"] as? Double ?? 0, 500)
            XCTAssertLessThan(consults.first?["teardown_after_hold_start_sec"] as? Double ?? 0, -500)
            XCTAssertEqual(consults.last?["blind_consults"] as? Int, 0)
            XCTAssertEqual(consults.last?["resolution"] as? String, "teardown")
            XCTAssertNil(controller.holdPolicy.hold, "the fresh line confirmed it")
        }
    }

    // MARK: - END12: a quiet log is not a dead log

    /// The 2026-09-02 12:36 cut: the Leave button went invalid five minutes into a live call, the
    /// generation had last been written three minutes before the recording began, and END10's
    /// stale rule confirmed on the first consult with no hold, no timer and no HUD. The owner put
    /// the meeting back on record by hand 4 s later. Red against that rule.
    func test_a_generation_not_written_since_the_recording_began_still_holds() throws {
        let (controller, host) = try makeController(logLines: ["2026-08-20T09:00:00.000000+03:00 0x1 <INFO> noise"])
        defer { withExtendedLifetime(host) {} }
        try ageGeneration(by: 180)
        host.recorderSpy.startedAt = Date().addingTimeInterval(-30)

        controller.beginTeardownHold(context: context)

        XCTAssertNotNil(controller.holdPolicy.hold, "a quiet log is not a dead log; the call is still up")
        XCTAssertNotNil(controller.cancelHoldTimer, "the hold has to keep consulting, not confirm once")
        XCTAssertEqual(host.hudSpy.confirmingEndStates, [true], "the HUD has to say why it is still recording")
        controller.releaseTeardownHold()
    }

    /// The 2026-09-02 10:10 shape: the same stale-looking mtime, and Teams' teardown lands on the
    /// tick after the provisional opened. The hold's next consult confirms it. Under the stale rule
    /// the first consult had already confirmed for the wrong reason, and the timer that exists to
    /// catch a late teardown was never created, so a false end in this state was a cut.
    func test_a_teardown_landing_inside_the_hold_confirms_despite_a_stale_looking_mtime() throws {
        let (controller, host) = try makeController(logLines: ["2026-08-20T09:00:00.000000+03:00 0x1 <INFO> noise"])
        defer { withExtendedLifetime(host) {} }
        try ageGeneration(by: 180)
        host.recorderSpy.startedAt = Date().addingTimeInterval(-30)
        controller.beginTeardownHold(context: context)
        XCTAssertNotNil(controller.holdPolicy.hold, "the stale-looking mtime must not confirm on its own")

        try appendToGeneration([teardownLine(secondsAgo: 0.5)])
        scheduler.tick()
        controller.consultTeardownOracle()

        XCTAssertNil(controller.holdPolicy.hold, "the teardown belongs to this call and confirms it")
        XCTAssertEqual(host.hudSpy.confirmingEndStates, [true, false], "a confirmed hold clears the HUD")
        XCTAssertNil(controller.pendingEndTrimAt, "a sub-second hold is not trimmed")
    }

    // MARK: - END13: the cap does not fire over a live signal

    /// The 2026-09-04 14:05 cut, replayed at the wiring seam. An ax-leave-led provisional, a
    /// generation carrying no teardown for this call (Teams has logged none to this day), and
    /// process audio reporting the call up throughout: `value: true` at 13:33:52 with no further
    /// emission for the rest of the meeting, and `process_audio_object_resolved` still listing 5
    /// objects at 14:02. The cap confirmed at 160.8 s, trimmed 2 m 49 s of live meeting out of
    /// `20260904-133358.wav` and split the meeting across two library rows.
    ///
    /// Red against `main`, where the hold was gone and `hudSpy.confirmingEndStates` read
    /// `[true, false]` by 150 s.
    func test_the_2026_09_04_hold_survives_the_cap_while_process_audio_says_the_call_is_up() throws {
        let (controller, host) = try makeController(
            logLines: ["2026-08-20T09:00:00.000000+03:00 0x1 <INFO> noise"]
        )
        defer { withExtendedLifetime(host) {} }
        // The tree blanked and came back with a Mute button and no Leave button, so the AX side
        // says "ended" for the whole hold. The cross-class signal says otherwise.
        host.liveCallSignal = .callIsUp
        host.recorderSpy.startedAt = Date().addingTimeInterval(-1_872)

        controller.beginTeardownHold(context: context)
        guard let openedAt = controller.holdPolicy.hold?.startedAt else {
            return XCTFail("the provisional must open a hold")
        }
        controller.consultTeardownOracle(now: openedAt.addingTimeInterval(160.8))

        XCTAssertNotNil(
            controller.holdPolicy.hold,
            "160.8 s in, four independent readings said the call was live; the recording must still be running"
        )
        XCTAssertNil(controller.pendingEndTrimAt, "nothing confirmed, so nothing is cut")
        XCTAssertEqual(host.hudSpy.confirmingEndStates, [true], "the hold is still open, not resolved")
        controller.releaseTeardownHold()
    }

    /// END17: the host has no wall clock any more. Past the old 150 s cap and the old 7200 s
    /// ceiling, with no live reading at all, the hold is still open; the engine's dwells end it.
    func test_the_host_never_ends_a_hold_on_its_own_clock_END17() throws {
        let (controller, host) = try makeController(
            logLines: ["2026-08-20T09:00:00.000000+03:00 0x1 <INFO> noise"]
        )
        defer { withExtendedLifetime(host) {} }
        host.liveCallSignal = .unknown

        controller.beginTeardownHold(context: context)
        guard let openedAt = controller.holdPolicy.hold?.startedAt else {
            return XCTFail("the provisional must open a hold")
        }
        for held in [150.0, 160.8, 7_201.0] {
            controller.consultTeardownOracle(now: openedAt.addingTimeInterval(held))
            XCTAssertNotNil(controller.holdPolicy.hold, "\(held) s held is not evidence the call ended")
        }
        XCTAssertNil(controller.pendingEndTrimAt)
        controller.releaseTeardownHold()
    }

    // MARK: - END17: every weak end holds, and an end concludes it

    /// A browser hold opens with the recorder running and the HUD saying why, and never asks Teams'
    /// log: a Teams call ending in the background must not end a Meet recording.
    func test_a_browser_hold_shows_the_hud_and_never_consults_teams_END17() throws {
        let (controller, host) = try makeController(logLines: [teardownLine(secondsAgo: 0.5)])
        defer { withExtendedLifetime(host) {} }
        let browser = MeetingLifecycleContext(bundleID: "com.google.Chrome", kind: .browser, pid: 77)

        controller.beginTeardownHold(context: browser)

        XCTAssertNotNil(controller.holdPolicy.hold, "a Teams teardown says nothing about a browser meeting")
        XCTAssertEqual(host.hudSpy.confirmingEndStates, [true])
        controller.releaseTeardownHold()
    }

    /// A held end the engine confirmed on its pair or a definitive signal marks where the hold began
    /// as the trim point when no process audio reported (END21), and clears the HUD.
    func test_concluding_a_hold_marks_its_start_as_the_trim_point_END17() throws {
        let (controller, host) = try makeController(logLines: nil)
        defer { withExtendedLifetime(host) {} }
        controller.beginTeardownHold(context: context)
        guard let openedAt = controller.holdPolicy.hold?.startedAt else {
            return XCTFail("the provisional must open a hold")
        }

        controller.concludeTeardownHold(
            now: openedAt.addingTimeInterval(PromotionEngine.defaultConfirmDwell), conclusion: .engineEnd
        )

        XCTAssertNil(controller.holdPolicy.hold)
        XCTAssertEqual(controller.pendingEndTrimAt, openedAt)
        XCTAssertEqual(host.hudSpy.confirmingEndStates, [true, false])
    }

    // MARK: - Re-entrancy

    /// A second provisional for the same call must not re-stamp the hold, or a flapping signal
    /// moves the trim point, which is where the held tail starts.
    func test_a_second_provisional_does_not_restart_the_clock() throws {
        let (controller, host) = try makeController(logLines: ["2026-08-20T09:00:00.000000+03:00 0x1 <INFO> noise"])
        defer { withExtendedLifetime(host) {} }
        controller.beginTeardownHold(context: context)
        let firstStamp = controller.holdPolicy.hold?.startedAt

        controller.beginTeardownHold(context: context)

        XCTAssertEqual(controller.holdPolicy.hold?.startedAt, firstStamp)
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
