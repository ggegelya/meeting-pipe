import XCTest
@testable import MeetingPipe

/// T3: `Notifier`'s response routing, a consent surface that had no coverage.
/// A tap here decides whether a live recording stops and which System Settings
/// pane opens, and it was four independent prefix-matched `if` blocks with
/// nothing enforcing that the id namespaces stay disjoint.
final class NotificationRouterTests: XCTestCase {

    private typealias R = NotificationRouter

    private func route(
        id: String,
        action: String = "",
        isDefault: Bool = false,
        doneEntry: R.DoneEntry? = nil
    ) -> R.Decision {
        R.route(id: id, action: action, isDefault: isDefault, doneEntry: doneEntry)
    }

    private let done = R.DoneEntry(stem: "20260714-120000", hasPageURL: true)

    // MARK: - Done notifications

    func test_looks_good_marks_and_consumes() {
        let d = route(id: "done-1", action: R.actionLooksGood, doneEntry: done)
        XCTAssertEqual(d.routes, [.markLooksGood(stem: "20260714-120000")])
        XCTAssertTrue(d.consumeDoneEntry)
    }

    func test_edit_summary_routes_and_consumes() {
        let d = route(id: "done-1", action: R.actionEditSummary, doneEntry: done)
        XCTAssertEqual(d.routes, [.editSummary(stem: "20260714-120000")])
        XCTAssertTrue(d.consumeDoneEntry)
    }

    /// An empty stem is a pre-correctable notification: there is nothing to
    /// mark, but the entry is still consumed so it cannot be re-fired.
    func test_empty_stem_routes_nowhere_but_still_consumes() {
        let entry = R.DoneEntry(stem: "", hasPageURL: false)
        for action in [R.actionLooksGood, R.actionEditSummary] {
            let d = route(id: "done-1", action: action, doneEntry: entry)
            XCTAssertEqual(d.routes, [], action)
            XCTAssertTrue(d.consumeDoneEntry, action)
        }
    }

    func test_open_page_needs_a_url() {
        XCTAssertEqual(
            route(id: "done-1", action: R.actionOpen, doneEntry: done).routes, [.openPage]
        )
        let noURL = R.DoneEntry(stem: "s", hasPageURL: false)
        let d = route(id: "done-1", action: R.actionOpen, doneEntry: noURL)
        XCTAssertEqual(d.routes, [])
        XCTAssertTrue(d.consumeDoneEntry, "the explicit action consumes even with no URL")
    }

    /// A plain banner tap opens the page when there is one, and otherwise does
    /// nothing AND keeps the entry, so a later explicit action still works.
    func test_default_tap_on_a_done_notification() {
        let d = route(id: "done-1", isDefault: true, doneEntry: done)
        XCTAssertEqual(d.routes, [.openPage])
        XCTAssertTrue(d.consumeDoneEntry)

        let noURL = route(id: "done-1", isDefault: true, doneEntry: R.DoneEntry(stem: "s", hasPageURL: false))
        XCTAssertEqual(noURL.routes, [])
        XCTAssertFalse(noURL.consumeDoneEntry)
    }

    func test_unknown_id_routes_nowhere() {
        let d = route(id: "something-else", isDefault: true)
        XCTAssertEqual(d.routes, [])
        XCTAssertFalse(d.consumeDoneEntry)
    }

    // MARK: - Permission notifications

    func test_accessibility_startup_wins_over_the_generic_perm_prefix() {
        // It also starts with `perm-`, so order matters: falling through would
        // open Screen Recording for an Accessibility prompt.
        for action in [R.actionOpenAccessibilitySettings, ""] {
            let d = route(id: R.accessibilityStartupID, action: action, isDefault: action.isEmpty)
            XCTAssertEqual(d.routes, [.openAccessibilitySettings], action)
        }
    }

    func test_generic_permission_notification_opens_screen_recording() {
        XCTAssertEqual(
            route(id: "perm-startup", action: R.actionOpenSettings).routes,
            [.openScreenRecordingSettings]
        )
        XCTAssertEqual(route(id: "perm-startup", isDefault: true).routes, [.openScreenRecordingSettings])
    }

    /// The regression this extraction found. `notifyMicOnlyRecording`'s
    /// `.granted` case says the permission is fine and the recorder got no
    /// audio, go read the log. It used to be posted as `perm-stop-<file>`, so a
    /// plain tap matched the `perm-` rule and opened the Screen Recording pane,
    /// which cannot help. Its own namespace now routes it nowhere.
    func test_mic_only_granted_banner_does_not_open_screen_recording() {
        let d = route(id: R.micOnlyIDPrefix + "20260714-120000.wav", isDefault: true)
        XCTAssertEqual(d.routes, [], "an informational banner must not deep-link to Settings")
    }

    /// The denied / unknown states ARE permission problems and keep the prefix.
    func test_mic_only_denied_banner_still_opens_settings() {
        XCTAssertEqual(
            route(id: "perm-stop-20260714-120000.wav", isDefault: true).routes,
            [.openScreenRecordingSettings]
        )
    }

    // MARK: - Still-meeting (TECH-C2)

    func test_only_the_explicit_action_stops_a_recording() {
        let id = R.stillMeetingIDPrefix + UUID().uuidString
        XCTAssertEqual(route(id: id, action: R.actionStopRecording).routes, [.stopRecording])
        XCTAssertEqual(route(id: id, action: R.actionKeepRecording).routes, [.keepRecording])
        XCTAssertEqual(
            route(id: id, isDefault: true).routes, [.keepRecording],
            "an accidental banner tap must never kill an active meeting"
        )
    }

    func test_unrecognised_action_on_still_meeting_does_nothing() {
        let id = R.stillMeetingIDPrefix + "x"
        XCTAssertEqual(route(id: id, action: "MP_SOMETHING_ELSE").routes, [])
    }

    // MARK: - Skip-late (UX10)

    func test_start_late_on_action_or_tap() {
        let id = R.skipLateIDPrefix + "us.zoom.xos"
        XCTAssertEqual(route(id: id, action: R.actionStartLate).routes, [.startLate])
        XCTAssertEqual(route(id: id, isDefault: true).routes, [.startLate])
        XCTAssertEqual(route(id: id, action: "MP_OTHER").routes, [])
    }

    // MARK: - The property nothing enforced

    /// The four id namespaces must stay disjoint. Nothing in the code enforces
    /// it, and a fifth prefix chosen carelessly (say `still-meeting-late-`)
    /// would double-fire: stop a recording AND start one. Exhaustive over every
    /// namespace against every action, including a plain tap.
    func test_no_id_ever_matches_two_namespaces() {
        let ids = [
            "done-\(UUID().uuidString)",
            R.accessibilityStartupID,
            "perm-startup",
            "perm-stop-a.wav",
            R.micOnlyIDPrefix + "a.wav",
            R.stillMeetingIDPrefix + "x",
            R.skipLateIDPrefix + "us.zoom.xos",
        ]
        let actions = [
            "", R.actionOpen, R.actionLooksGood, R.actionEditSummary, R.actionOpenSettings,
            R.actionOpenAccessibilitySettings, R.actionStopRecording, R.actionKeepRecording,
            R.actionStartLate,
        ]
        for id in ids {
            for action in actions {
                for isDefault in [true, false] {
                    // `done-` ids are the only ones carrying an entry, and they
                    // are what the first block keys on.
                    let entry = id.hasPrefix("done-") ? done : nil
                    let d = route(id: id, action: action, isDefault: isDefault, doneEntry: entry)
                    XCTAssertLessThanOrEqual(
                        d.routes.count, 1,
                        "id=\(id) action=\(action) isDefault=\(isDefault) fired \(d.routes)"
                    )
                }
            }
        }
    }

    /// A response with no matching entry and an unknown action is a no-op, not a
    /// crash and not a stray delegate call.
    func test_actions_only_fire_for_their_own_namespace() {
        XCTAssertEqual(route(id: "perm-startup", action: R.actionStopRecording).routes, [])
        XCTAssertEqual(route(id: R.stillMeetingIDPrefix + "x", action: R.actionOpenSettings).routes, [])
        XCTAssertEqual(route(id: R.skipLateIDPrefix + "x", action: R.actionLooksGood).routes, [])
    }
}
