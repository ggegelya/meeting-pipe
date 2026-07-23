import XCTest
@testable import MeetingPipe

/// STOR4: the backup agent's schedule mapping (pure; no disk / launchctl). The
/// plist body itself is pinned by `LaunchAgentSchedulerTests`.
final class BackupSchedulerServiceTests: XCTestCase {

    func test_daily_drops_the_weekday_so_it_fires_every_day() {
        let s = BackupSchedulerService.schedule(frequency: .daily, weekday: 3, hour: 21, minute: 0)
        XCTAssertNil(s.weekday, "a daily backup must not pin a weekday, whatever the picker holds")
        XCTAssertEqual(s.hour, 21)
        XCTAssertEqual(s.minute, 0)
    }

    func test_weekly_pins_the_chosen_weekday() {
        let s = BackupSchedulerService.schedule(frequency: .weekly, weekday: 7, hour: 8, minute: 15)
        XCTAssertEqual(s.weekday, 7)
        XCTAssertEqual(s.hour, 8)
        XCTAssertEqual(s.minute, 15)
    }

    func test_frequency_round_trips_through_its_persisted_string() {
        for frequency in BackupSchedulerService.Frequency.allCases {
            XCTAssertEqual(
                BackupSchedulerService.Frequency(rawValue: frequency.rawValue), frequency
            )
        }
        XCTAssertNil(BackupSchedulerService.Frequency(rawValue: "fortnightly"))
    }

    func test_label_is_its_own_agent() {
        XCTAssertEqual(BackupSchedulerService.label, "com.meetingpipe.backup")
        XCTAssertTrue(
            BackupSchedulerService.plistURL.path
                .hasSuffix("Library/LaunchAgents/com.meetingpipe.backup.plist")
        )
    }
}
