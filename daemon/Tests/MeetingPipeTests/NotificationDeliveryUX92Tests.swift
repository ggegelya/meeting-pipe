import UserNotifications
import XCTest
@testable import MeetingPipe

/// UX92: every post records whether the system took it, a denied or banners-off Notifications
/// permission shows in the menu, Finish setup and doctor, and the HUD warns before the silence
/// backstop stops a live recording.
final class NotificationDeliveryUX92Tests: XCTestCase {

    // MARK: - One post path that records

    private final class FakeCenter: NotificationCenterPosting {
        var error: Error?
        private(set) var added: [UNNotificationRequest] = []
        func add(_ request: UNNotificationRequest, completion: @escaping @Sendable (Error?) -> Void) {
            added.append(request)
            completion(error)
        }
    }

    private final class Rows: @unchecked Sendable {
        var rows: [(NotificationKind, String?, Error?)] = []
    }

    private func request(title: String, body: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        return UNNotificationRequest(identifier: "x", content: content, trigger: nil)
    }

    func test_a_post_with_a_stem_records_kind_and_stem_and_no_text() {
        let attrs = NotificationPostRecord.attributes(kind: .failure, stem: "20260511-143110", error: nil)
        XCTAssertEqual(attrs["kind"] as? String, "failure")
        XCTAssertEqual(attrs["stem"] as? String, "20260511-143110")
        XCTAssertEqual(Set(attrs.keys), ["kind", "stem"], "never the title or body")
        XCTAssertNil(NotificationPostRecord.failureLine(kind: .failure, error: nil))
    }

    func test_a_failing_add_records_the_error_and_writes_the_daemon_line() {
        let center = FakeCenter()
        center.error = NSError(domain: UNErrorDomain, code: 1)
        let rows = Rows()
        let poster = NotificationPoster(center: center) { kind, stem, error in rows.rows.append((kind, stem, error)) }
        poster.post(request(title: "Placeholder Topic", body: "Placeholder body"), kind: .stillMeeting)
        XCTAssertEqual(center.added.count, 1)
        XCTAssertEqual(rows.rows.count, 1)
        XCTAssertEqual(rows.rows[0].0, .stillMeeting)

        var emitted: [[String: Any]] = []
        var lines: [String] = []
        NotificationPostRecord.record(kind: .stillMeeting, stem: nil, error: rows.rows[0].2,
                                      emit: { emitted.append($0) }, writeLine: { lines.append($0) })
        XCTAssertEqual(emitted.first?["kind"] as? String, "still_meeting")
        XCTAssertEqual(emitted.first?["error_domain"] as? String, UNErrorDomain)
        XCTAssertEqual(emitted.first?["error_code"] as? Int, 1)
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].contains("Placeholder"))
    }

    func test_the_notifier_posts_only_through_the_recording_path() throws {
        let source = try String(contentsOf: Self.sources.appendingPathComponent("Notifier.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("UNUserNotificationCenter.current().add("), "every add goes through NotificationPoster")
    }

    // MARK: - Authorization: denied and banners off both count as off

    func test_denied_or_banners_off_is_off_and_granted_is_not() {
        XCTAssertTrue(NotificationAuthReading(status: "denied", alertsEnabled: nil).isOff)
        XCTAssertTrue(NotificationAuthReading(status: "granted", alertsEnabled: false).isOff)
        XCTAssertFalse(NotificationAuthReading(status: "granted", alertsEnabled: true).isOff)
        XCTAssertEqual(NotificationAuthReading(status: "granted", alertsEnabled: false).attributes["alerts"] as? String,
                       "disabled")
    }

    func test_notifications_off_adds_the_menu_line_and_never_the_generic_permission_row() {
        let off = StatusBarModel.Inputs(notificationsOff: true)
        XCTAssertTrue(StatusBarModel.permissionConsequences(off).contains(StatusBarModel.notificationsOffTitle))
        XCTAssertFalse(StatusBarModel.hasPendingPermissionIssue(off))
        XCTAssertFalse(StatusBarModel.permissionConsequences(.init()).contains(StatusBarModel.notificationsOffTitle))
    }

    func test_finish_setup_lists_notifications_when_off() {
        XCTAssertTrue(SetupChecklist.decide(.init(notificationsOff: true)).contains(.notifications))
        XCTAssertEqual(SetupChecklist.Item.notifications.fix, .permissions)
        XCTAssertFalse(SetupChecklist.decide(.init()).contains(.notifications))
    }

    // MARK: - Doctor

    func test_the_doctor_probe_warns_when_off_and_says_unknown_without_a_reading() {
        XCTAssertTrue(DoctorCommand.defaultProbes().map(\.name).contains("permission.notifications"))
        XCTAssertTrue(DoctorCommand.daemonSelfCheckProbes().map(\.name).contains("permission.notifications"))
        let unknown = DoctorCommand.probeNotifications(nil)
        XCTAssertEqual(unknown.status, .ok)
        XCTAssertTrue(unknown.message.hasPrefix("unknown"))
        XCTAssertEqual(DoctorCommand.probeNotifications(.init(status: "denied", alertsEnabled: nil)).status, .warn)
        XCTAssertEqual(DoctorCommand.probeNotifications(.init(status: "granted", alertsEnabled: false)).status, .warn)
        XCTAssertEqual(DoctorCommand.probeNotifications(.init(status: "granted", alertsEnabled: true)).status, .ok)
    }

    // MARK: - The HUD says the recording is about to stop

    func test_the_stopping_soon_label_and_its_precedence() {
        let label = HUDStateLabel.resolve(micCaptureLost: false, lowSpace: nil, offRecord: false,
                                          stoppingSoon: true, confirmingEnd: true)
        XCTAssertEqual(label.text, "No audio, stopping soon")
        XCTAssertEqual(HUDStateLabel.resolve(micCaptureLost: false, lowSpace: nil, offRecord: true,
                                             stoppingSoon: true, confirmingEnd: false).text, "Off the record")
        XCTAssertEqual(HUDStateLabel.resolve(micCaptureLost: true, lowSpace: nil, offRecord: false,
                                             stoppingSoon: true, confirmingEnd: false).text, "Mic lost")
    }

    func test_the_nudge_sets_the_hud_and_keep_recording_clears_it() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mp-ux92-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = FakeSessionHost(tempDir: dir)
        let controller = MeetingSessionController(coordinator: host)
        host.stateMachine.setRecording(file: dir.appendingPathComponent("20261116-120000.wav"), source: nil, summaryMode: .auto)
        controller.handleIdleNotify()
        controller.handleIdleNotify()
        XCTAssertEqual(host.hudSpy.stoppingSoonStates, [true], "set once")
        XCTAssertEqual(host.notifierSpy.stillMeetingCount, 2, "the banner is still posted too")
        controller.keepRecordingFromNudge()
        XCTAssertEqual(host.hudSpy.stoppingSoonStates, [true, false])
    }

    private static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe")
    }
}
