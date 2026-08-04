import XCTest
@testable import MeetingPipeCore

/// MIC8. Every fixture line here is **verbatim** from the owner's own
/// `MSTeamsNM_SlimCore_2026-07-31_20-32-53.21.log`, so the parser is pinned against
/// the real format rather than against a guess at it. That file is also what the
/// standing regression test (`docs/spikes/mic8_log_correlation.py`) reads, so the
/// two agree by construction.
private enum SlimCoreFixtures {
    /// The transition line, both directions.
    static let unmute =
        "2026-08-03T07:30:24.277723+03:00 0x000000017168f000 <INFO> "
        + "AirPodsService: Input mute event received: unmute"
    static let mute =
        "2026-08-03T07:30:48.868581+03:00 0x00000001f2439d80 <INFO> "
        + "AirPodsService: Input mute event received: mute"

    /// The two neighbouring forms the parser deliberately ignores.
    static let setMuteState =
        "2026-08-03T07:30:48.868200+03:00 0x00000001f2439d80 <INFO> "
        + "AirPodsService: AirPodsService::SetMuteState: true with cause_id: "
        + "9e83a774-028f-4e57-9b36-f6b6d45fe2ec"
    static let notification =
        "2026-08-03T07:30:24.278507+03:00 0x00000001f2439d80 <INFO> "
        + "AirPodsService: AirPodsService InputMuteStateChangeNotification received with value: false"

    /// The false positive that would have confirmed the spike's false close: the
    /// hourly ECS config blob in the Teams *shell* log. The `hfpOsUnmuteFixEnabled`
    /// fragment is verbatim; the surrounding 100 KB of JSON is elided.
    static let ecsConfigBlob =
        "2026-08-04T14:31:02.101021+03:00 0x00000001f2439d80 <INFO> ConfigService: ecs payload "
        + #"{"hfpCallManager":{"hfpAsyncDeviceWatcherInit":false,"hfpOsUnmuteFixEnabled":false}}"#

    /// SlimCore flushes mid-line: the live file's last line is routinely truncated
    /// (measured, the tail of the live generation was `native_modules::Remot`).
    static let truncated =
        "2026-08-04T12:36:32.214215+03:00 0x00000001f2439d80 <INFO> native_modules::Remot"

    /// `2026-08-03T07:30:24.277723+03:00` is 07:30:24.277723 **UTC**, not 04:30:24 UTC.
    static let unmuteAtUTC = SlimCoreFixtures.utc(
        year: 2026, month: 8, day: 3, hour: 7, minute: 30, second: 24, fraction: 0.277723
    )

    static func utc(
        year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, fraction: Double = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )
        return components.date!.addingTimeInterval(fraction)
    }
}

final class SlimCoreMuteLogTests: XCTestCase {

    func test_parses_both_transition_directions() {
        XCTAssertEqual(SlimCoreMuteLog.parse(line: SlimCoreFixtures.mute)?.muted, true)
        XCTAssertEqual(SlimCoreMuteLog.parse(line: SlimCoreFixtures.unmute)?.muted, false)
    }

    /// The gotcha that is silently wrong by the local offset and correct-looking on a
    /// UTC machine: SlimCore prints UTC and suffixes the machine's local offset.
    func test_timestamp_is_the_naive_reading_as_utc_not_the_printed_offset() throws {
        let reading = try XCTUnwrap(SlimCoreMuteLog.parse(line: SlimCoreFixtures.unmute))
        XCTAssertEqual(
            reading.at.timeIntervalSince1970,
            SlimCoreFixtures.unmuteAtUTC.timeIntervalSince1970,
            accuracy: 0.0005,
            "the printed +03:00 is a lie; 07:30:24.277723 is the UTC reading"
        )
        // The wrong reading (applying the offset) lands three hours earlier. Pin the
        // distance so a future "fix" that honours the suffix fails here.
        let offsetApplied = SlimCoreFixtures.unmuteAtUTC.addingTimeInterval(-3 * 3600)
        XCTAssertGreaterThan(
            abs(reading.at.timeIntervalSince(offsetApplied)), 3599,
            "parsing the offset as real would shift every event by the local offset"
        )
    }

    /// A bare `mute` token matches the hourly ECS config blob's feature-flag key, and
    /// truncated to 200 chars it reads exactly like a hit. Anchoring on the whole
    /// message is what keeps that out.
    func test_ignores_the_ecs_config_blob_false_positive() {
        XCTAssertNil(SlimCoreMuteLog.parse(line: SlimCoreFixtures.ecsConfigBlob))
    }

    /// The neighbouring forms are not parsed on purpose: the correlation measured the
    /// transition line, and the three do not fire 1:1.
    func test_ignores_the_neighbouring_line_forms() {
        XCTAssertNil(SlimCoreMuteLog.parse(line: SlimCoreFixtures.setMuteState))
        XCTAssertNil(SlimCoreMuteLog.parse(line: SlimCoreFixtures.notification))
    }

    func test_ignores_unrelated_and_truncated_lines() {
        XCTAssertNil(SlimCoreMuteLog.parse(line: SlimCoreFixtures.truncated))
        XCTAssertNil(SlimCoreMuteLog.parse(line: ""))
        XCTAssertNil(SlimCoreMuteLog.parse(line: "AirPodsService: Input mute event received: "))
        XCTAssertNil(
            SlimCoreMuteLog.parse(line: "no timestamp AirPodsService: Input mute event received: mute")
        )
    }

    /// The resolution defect that hid this signal for ten days: the shell log rotates
    /// hourly and the media log weekly, so the file carrying mute lines is never the
    /// newest in its own directory. Resolve by family, never by mtime alone.
    func test_resolves_by_family_not_by_mtime() throws {
        let dir = try TempDir()
        try dir.write("MSTeamsNM_SlimCore_2026-07-29_11-24-33.19.log", "old\n", modified: -7200)
        try dir.write("MSTeamsNM_SlimCore_2026-07-31_20-32-53.21.log", "live\n", modified: -3600)
        // Fresher than both, and the trap: a flat newest-N cut takes these.
        try dir.write("MSTeams_2026-08-04_17-31-19.19.log", "shell\n", modified: -1)
        try dir.write("TeamsSwitcher.log_2026-07-31_20-33-18.539.log", "switcher\n", modified: 0)

        let newest = try XCTUnwrap(SlimCoreMuteLog.newest(in: dir.url, family: "MSTeamsNM_SlimCore_"))
        XCTAssertEqual(newest.lastPathComponent, "MSTeamsNM_SlimCore_2026-07-31_20-32-53.21.log")
    }

    func test_absent_family_resolves_to_nil() throws {
        let dir = try TempDir()
        try dir.write("MSTeams_2026-08-04_17-31-19.19.log", "shell\n", modified: 0)
        XCTAssertNil(SlimCoreMuteLog.newest(in: dir.url, family: "MSTeamsNM_SlimCore_"))
    }
}

final class LogMuteAdapterTests: XCTestCase {

    private let teams = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2", kind: .native, pid: 4242
    )

    /// A fresh watch joins the live generation at its end. Without this a meeting
    /// would replay every toggle Teams has logged since its last restart, and the
    /// gate would open on a week-old `unmute`.
    func test_start_joins_the_live_generation_at_its_end() throws {
        let dir = try TempDir()
        try dir.write("MSTeamsNM_SlimCore_2026-07-31_20-32-53.21.log", SlimCoreFixtures.mute + "\n")
        let rig = try Rig(directory: dir)

        try rig.start(context: teams)
        XCTAssertEqual(rig.events, [], "history before the watch started is not a transition")
    }

    func test_appended_transitions_reach_the_sink_once_per_state_change() throws {
        let dir = try TempDir()
        let generation = "MSTeamsNM_SlimCore_2026-07-31_20-32-53.21.log"
        try dir.write(generation, "")
        let rig = try Rig(directory: dir)
        try rig.start(context: teams)

        try dir.append(generation, SlimCoreFixtures.mute + "\n")
        rig.step()
        XCTAssertEqual(rig.events, [.muted])

        try dir.append(generation, SlimCoreFixtures.unmute + "\n")
        rig.step()
        XCTAssertEqual(rig.events, [.muted, .unmuted])

        // Same state again: the sink is edge-triggered, so MicGate never sees it.
        try dir.append(generation, SlimCoreFixtures.unmute + "\n")
        rig.step()
        XCTAssertEqual(rig.events, [.muted, .unmuted])
    }

    /// Only the last transition in a batch is applied: replaying a batch would flap
    /// the verdict through states that were already superseded before we read them.
    func test_a_batch_applies_only_its_final_state() throws {
        let dir = try TempDir()
        let generation = "MSTeamsNM_SlimCore_2026-07-31_20-32-53.21.log"
        try dir.write(generation, "")
        let rig = try Rig(directory: dir)
        try rig.start(context: teams)

        try dir.append(
            generation,
            SlimCoreFixtures.mute + "\n" + SlimCoreFixtures.unmute + "\n" + SlimCoreFixtures.mute + "\n"
        )
        rig.step()
        XCTAssertEqual(rig.events, [.muted])
    }

    /// SlimCore flushes mid-line, so a tick must carry the remainder rather than
    /// parse half a line and drop the transition when the rest arrives.
    func test_a_partial_line_is_held_until_its_newline_arrives() throws {
        let dir = try TempDir()
        let generation = "MSTeamsNM_SlimCore_2026-07-31_20-32-53.21.log"
        try dir.write(generation, "")
        let rig = try Rig(directory: dir)
        try rig.start(context: teams)

        let split = SlimCoreFixtures.mute.index(SlimCoreFixtures.mute.startIndex, offsetBy: 60)
        try dir.append(generation, String(SlimCoreFixtures.mute[..<split]))
        rig.step()
        XCTAssertEqual(rig.events, [], "half a line is not a transition")

        try dir.append(generation, String(SlimCoreFixtures.mute[split...]) + "\n")
        rig.step()
        XCTAssertEqual(rig.events, [.muted])
    }

    /// Rotation is per Teams restart, so the adapter re-resolves the generation
    /// instead of holding a file handle, and reads the fresh one from the start
    /// (everything in it is newer than the meeting).
    func test_rotation_moves_to_the_new_generation_and_reads_it_whole() throws {
        let dir = try TempDir()
        try dir.write("MSTeamsNM_SlimCore_2026-07-31_20-32-53.21.log", "", modified: -60)
        let rig = try Rig(directory: dir)
        try rig.start(context: teams)

        try dir.write(
            "MSTeamsNM_SlimCore_2026-08-04_18-00-00.22.log",
            SlimCoreFixtures.mute + "\n", modified: 0
        )
        rig.step()
        XCTAssertEqual(rig.events, [.muted])
        XCTAssertTrue(rig.log.entries.contains {
            $0.action == "log_mute_generation_resolved"
                && $0.attributes["generation"] == "MSTeamsNM_SlimCore_2026-08-04_18-00-00.22.log"
        })
    }

    /// An absent line degrades to **unknown**, never to unmuted. `AirPodsService` is
    /// a misnomer for this component, but the measurement cannot rule out a
    /// dependency on AirPods being connected for output, so a silent log has to let
    /// the AX read carry rather than assert the mic is live.
    func test_absent_family_never_reports_unmuted() throws {
        let dir = try TempDir()
        try dir.write("MSTeams_2026-08-04_17-31-19.19.log", SlimCoreFixtures.mute + "\n")
        let rig = try Rig(directory: dir)

        try rig.start(context: teams)
        rig.step()
        rig.step()

        XCTAssertEqual(rig.events, [])
        XCTAssertEqual(
            rig.log.entries.filter { $0.action == "log_mute_source_missing" }.count, 1,
            "a missing log says so once, not at the poll rate"
        )
    }

    func test_stop_disarms_the_poll() throws {
        let dir = try TempDir()
        let generation = "MSTeamsNM_SlimCore_2026-07-31_20-32-53.21.log"
        try dir.write(generation, "")
        let rig = try Rig(directory: dir)
        try rig.start(context: teams)

        rig.adapter.stop()
        try dir.append(generation, SlimCoreFixtures.mute + "\n")
        rig.step()
        XCTAssertEqual(rig.events, [], "a stopped adapter must not keep reading")
    }

    // MARK: - Rig

    /// Adapter under test with a manual scheduler and a synchronous read path, so a
    /// tick is one call and nothing sleeps.
    private final class Rig {
        let adapter: LogMuteAdapter
        let log = RecordingEventLog()
        private let scheduler = LogTickScheduler()
        private(set) var events: [MuteLabels.State] = []

        init(directory: TempDir) throws {
            adapter = LogMuteAdapter(
                config: LogMuteConfig(
                    bundleIDs: ["com.microsoft.teams2"], app: "teams",
                    directory: directory.url, family: "MSTeamsNM_SlimCore_"
                ),
                eventLog: log,
                scheduler: scheduler.schedule,
                readQueue: nil
            )
        }

        func start(context: MeetingLifecycleContext) throws {
            try adapter.start(context: context, handle: MicGateAdapterHandle()) { [weak self] event in
                self?.events.append(event.state)
            }
        }

        func step() { scheduler.step() }
    }
}

/// One-shot scheduler driver: holds the pending tick and runs it on demand.
private final class LogTickScheduler {
    private var pending: (() -> Void)?

    lazy var schedule: LogMuteAdapter.Scheduler = { [weak self] _, action in
        self?.pending = action
        return { [weak self] in self?.pending = nil }
    }

    func step() {
        let action = pending
        pending = nil
        action?()
    }
}

/// A scratch directory with mtime control, so the family-resolution gotcha can be pinned.
private final class TempDir {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mic8-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// `modified` is seconds relative to now.
    func write(_ name: String, _ contents: String, modified: TimeInterval? = nil) throws {
        let file = url.appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        if let modified = modified {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(modified)], ofItemAtPath: file.path
            )
        }
    }

    func append(_ name: String, _ contents: String) throws {
        let file = url.appendingPathComponent(name)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contents.utf8))
    }
}
