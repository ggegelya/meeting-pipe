import XCTest
@testable import MeetingPipe

/// AI4-FINISH: what stays digest-specific after STOR4 lifted the plist body into
/// `LaunchAgentScheduler` (whose mapping `LaunchAgentSchedulerTests` pins).
final class DigestSchedulerServiceTests: XCTestCase {
    func test_label_is_distinct_from_the_resident_daemon_agent() {
        XCTAssertEqual(DigestSchedulerService.label, "com.meetingpipe.digest")
        XCTAssertNotEqual(DigestSchedulerService.label, "com.meetingpipe.daemon")
        XCTAssertNotEqual(DigestSchedulerService.label, BackupSchedulerService.label)
    }

    func test_plist_url_is_the_per_user_launch_agents_dir() {
        XCTAssertTrue(
            DigestSchedulerService.plistURL.path
                .hasSuffix("Library/LaunchAgents/com.meetingpipe.digest.plist")
        )
    }
}
