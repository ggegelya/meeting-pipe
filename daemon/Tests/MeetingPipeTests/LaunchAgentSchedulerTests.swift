import XCTest
@testable import MeetingPipe

/// The shared scheduled-LaunchAgent plist mapping (pure; no disk / launchctl).
/// AI4-FINISH pinned this for the digest; STOR4 lifted it out for the backup agent.
final class LaunchAgentSchedulerTests: XCTestCase {
    private func dict(
        label: String = "com.example.job",
        program: [String] = ["/usr/bin/mp", "digest"],
        weekday: Int? = 1,
        hour: Int = 9,
        minute: Int = 30,
        logBasename: String = "digest",
        logDir: String = "/logs"
    ) -> [String: Any] {
        LaunchAgentScheduler.plistDictionary(
            label: label,
            program: program,
            schedule: .init(weekday: weekday, hour: hour, minute: minute),
            logBasename: logBasename,
            logDir: logDir
        )
    }

    func test_plist_maps_schedule_and_program() {
        let d = dict()
        XCTAssertEqual(d["Label"] as? String, "com.example.job")
        XCTAssertEqual(d["ProgramArguments"] as? [String], ["/usr/bin/mp", "digest"])
        let cal = d["StartCalendarInterval"] as? [String: Int]
        XCTAssertEqual(cal?["Weekday"], 1)   // Monday
        XCTAssertEqual(cal?["Hour"], 9)
        XCTAssertEqual(cal?["Minute"], 30)
        XCTAssertEqual(d["StandardOutPath"] as? String, "/logs/digest.out.log")
        XCTAssertEqual(d["StandardErrorPath"] as? String, "/logs/digest.err.log")
        // A scheduled one-shot, not a resident daemon: no RunAtLoad / KeepAlive.
        XCTAssertNil(d["RunAtLoad"])
        XCTAssertNil(d["KeepAlive"])
    }

    func test_sunday_maps_to_launchd_zero() {
        let cal = dict(weekday: 7)["StartCalendarInterval"] as? [String: Int]
        XCTAssertEqual(cal?["Weekday"], 0, "ISO Sunday (7) maps to launchd Sunday (0)")
    }

    func test_a_nil_weekday_omits_the_key_so_launchd_fires_daily() {
        let cal = dict(weekday: nil)["StartCalendarInterval"] as? [String: Int]
        XCTAssertNil(cal?["Weekday"], "a missing Weekday is how launchd expresses every day")
        XCTAssertEqual(cal?["Hour"], 9)
        XCTAssertEqual(cal?["Minute"], 30)
    }

    func test_out_of_range_time_is_clamped() {
        let cal = dict(hour: 99, minute: -5)["StartCalendarInterval"] as? [String: Int]
        XCTAssertEqual(cal?["Hour"], 23)
        XCTAssertEqual(cal?["Minute"], 0)
    }

    func test_log_paths_follow_the_basename() {
        let d = dict(logBasename: "backup", logDir: "/l")
        XCTAssertEqual(d["StandardOutPath"] as? String, "/l/backup.out.log")
        XCTAssertEqual(d["StandardErrorPath"] as? String, "/l/backup.err.log")
    }

    func test_plist_serializes_to_valid_xml() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict(), format: .xml, options: 0
        )
        let round = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
        XCTAssertEqual(round?["Label"] as? String, "com.example.job")
    }

    func test_a_daily_plist_also_serializes() throws {
        // A dictionary carrying no Weekday still has to round-trip; launchd reads
        // the resulting XML, so an unserializable shape is a silent no-fire.
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict(weekday: nil), format: .xml, options: 0
        )
        let round = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
        XCTAssertNil((round?["StartCalendarInterval"] as? [String: Any])?["Weekday"])
    }

    func test_plist_url_is_the_per_user_launch_agents_dir() {
        let url = LaunchAgentScheduler.plistURL(label: "com.meetingpipe.thing")
        XCTAssertTrue(url.path.hasSuffix("Library/LaunchAgents/com.meetingpipe.thing.plist"))
    }
}
