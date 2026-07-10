import XCTest
@testable import MeetingPipe

/// AI4-FINISH: the digest LaunchAgent plist mapping (pure; no disk / launchctl).
final class DigestSchedulerServiceTests: XCTestCase {
    func test_plist_maps_schedule_and_program() {
        let dict = DigestSchedulerService.plistDictionary(
            program: ["/usr/bin/mp", "digest"], weekday: 1, hour: 9, minute: 30, logDir: "/logs"
        )
        XCTAssertEqual(dict["Label"] as? String, "com.meetingpipe.digest")
        XCTAssertEqual(dict["ProgramArguments"] as? [String], ["/usr/bin/mp", "digest"])
        let cal = dict["StartCalendarInterval"] as? [String: Int]
        XCTAssertEqual(cal?["Weekday"], 1)   // Monday
        XCTAssertEqual(cal?["Hour"], 9)
        XCTAssertEqual(cal?["Minute"], 30)
        XCTAssertEqual(dict["StandardOutPath"] as? String, "/logs/digest.out.log")
        // A scheduled one-shot, not a resident daemon: no RunAtLoad / KeepAlive.
        XCTAssertNil(dict["RunAtLoad"])
        XCTAssertNil(dict["KeepAlive"])
    }

    func test_sunday_maps_to_launchd_zero() {
        let dict = DigestSchedulerService.plistDictionary(
            program: ["mp", "digest"], weekday: 7, hour: 8, minute: 0, logDir: "/l"
        )
        let cal = dict["StartCalendarInterval"] as? [String: Int]
        XCTAssertEqual(cal?["Weekday"], 0, "ISO Sunday (7) maps to launchd Sunday (0)")
    }

    func test_out_of_range_time_is_clamped() {
        let dict = DigestSchedulerService.plistDictionary(
            program: [], weekday: 3, hour: 99, minute: -5, logDir: "/l"
        )
        let cal = dict["StartCalendarInterval"] as? [String: Int]
        XCTAssertEqual(cal?["Hour"], 23)
        XCTAssertEqual(cal?["Minute"], 0)
    }

    func test_plist_serializes_to_valid_xml() throws {
        let dict = DigestSchedulerService.plistDictionary(
            program: ["/usr/bin/mp", "digest"], weekday: 2, hour: 10, minute: 0, logDir: "/l"
        )
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let round = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
        XCTAssertEqual(round?["Label"] as? String, "com.meetingpipe.digest")
    }
}
