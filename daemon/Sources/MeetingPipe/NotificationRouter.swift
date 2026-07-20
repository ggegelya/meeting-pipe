import Foundation

/// The pure notification-response routing behind `Notifier` (T3).
///
/// `Notifier`'s delegate callback is a consent surface: a tap decides whether a
/// live recording stops, whether a summary is marked good, and which System
/// Settings pane opens. It was four independent `if` blocks over string
/// prefixes, untested, with nothing enforcing that the four id namespaces stay
/// disjoint (`done-`, `perm-`, `still-meeting-`, `skip-late-`). They happen to
/// be today; a fifth namespace chosen carelessly would double-fire.
///
/// Lifting it to a table makes the whole matrix assertable, and it immediately
/// surfaced a real misroute (see `micOnlyIDPrefix`).
enum NotificationRouter {

    // MARK: - Identifiers
    //
    // The category and action strings registered with UNUserNotificationCenter.
    // They live here rather than on `Notifier` because this is the type that
    // interprets them; `Notifier` aliases them for its own registration.

    static let doneCategory = "MP_DONE"
    static let doneCorrectableCategory = "MP_DONE_CORRECTABLE"
    static let doneCorrectableLocalCategory = "MP_DONE_CORRECTABLE_LOCAL"
    static let actionOpen = "MP_OPEN_PAGE"
    static let actionLooksGood = "MP_LOOKS_GOOD"
    static let actionEditSummary = "MP_EDIT_SUMMARY"
    static let permCategory = "MP_PERM"
    static let actionOpenSettings = "MP_OPEN_SETTINGS"
    static let stillMeetingCategory = "MP_STILL_MEETING"
    static let accessibilityCategory = "MP_ACCESSIBILITY"
    static let actionOpenAccessibilitySettings = "MP_OPEN_ACCESS_SETTINGS"
    static let actionStopRecording = "MP_STOP_RECORDING"
    static let actionKeepRecording = "MP_KEEP_RECORDING"
    static let actionStartLate = "MP_START_LATE"

    static let stillMeetingIDPrefix = "still-meeting-"
    static let skipLateIDPrefix = "skip-late-"
    static let permIDPrefix = "perm-"
    static let accessibilityStartupID = "perm-accessibility-startup"

    /// The mic-only-recording banner deliberately does NOT use `permIDPrefix`.
    ///
    /// It used to (`perm-stop-<file>`), for all three permission states, and the
    /// `.granted` state is not a permission problem at all: its body says the
    /// permission is fine but no system audio reached the recorder, go read
    /// `recorder.log`. It sets no category and no action button, so the only
    /// possible interaction is a plain tap, which is `isDefault`, which matched
    /// the `perm-` rule below and opened the Screen Recording pane, the one
    /// place that cannot help. Its own id namespace routes it nowhere, which is
    /// the correct outcome for an informational banner.
    static let micOnlyIDPrefix = "recorder-silent-"

    // MARK: - Routing

    /// What a response asks the delegate to do. A response can produce more than
    /// one only if the id namespaces ever overlap, which is exactly what the
    /// exhaustiveness test watches for.
    enum Route: Equatable {
        case markLooksGood(stem: String)
        case editSummary(stem: String)
        case openPage
        case openAccessibilitySettings
        case openScreenRecordingSettings
        case stopRecording
        case keepRecording
        case startLate
    }

    /// The per-notification state `Notifier` keeps for a "done" notification.
    /// `hasPageURL` rather than the URL itself: routing only branches on
    /// presence, and the host owns the value.
    struct DoneEntry: Equatable {
        var stem: String
        var hasPageURL: Bool

        init(stem: String, hasPageURL: Bool) {
            self.stem = stem
            self.hasPageURL = hasPageURL
        }
    }

    struct Decision: Equatable {
        var routes: [Route]
        /// Whether the host drops its `doneEntries` record for this id.
        var consumeDoneEntry: Bool
    }

    /// - Parameters:
    ///   - id: the notification request identifier.
    ///   - action: `response.actionIdentifier`.
    ///   - isDefault: `action == UNNotificationDefaultActionIdentifier`, passed
    ///     in rather than compared here so this file needs no UserNotifications
    ///     import and stays testable without a notification center.
    ///   - doneEntry: the host's record for `id`, when it has one.
    static func route(
        id: String,
        action: String,
        isDefault: Bool,
        doneEntry: DoneEntry?
    ) -> Decision {
        var routes: [Route] = []
        var consume = false

        if let entry = doneEntry {
            switch action {
            case actionLooksGood:
                // An empty stem means the notification predates the correctable
                // categories; the row would have nothing to mark.
                if !entry.stem.isEmpty { routes.append(.markLooksGood(stem: entry.stem)) }
                consume = true
            case actionEditSummary:
                if !entry.stem.isEmpty { routes.append(.editSummary(stem: entry.stem)) }
                consume = true
            case actionOpen:
                if entry.hasPageURL { routes.append(.openPage) }
                consume = true
            default:
                if isDefault, entry.hasPageURL {
                    routes.append(.openPage)
                    consume = true
                }
            }
        }

        // Permission notifications: any tap opens the relevant Settings pane.
        // The accessibility id is checked first because it also carries the
        // `perm-` prefix and must not fall through to Screen Recording.
        if id == accessibilityStartupID,
           action == actionOpenAccessibilitySettings || isDefault {
            routes.append(.openAccessibilitySettings)
        } else if id.hasPrefix(permIDPrefix),
                  action == actionOpenSettings || isDefault {
            routes.append(.openScreenRecordingSettings)
        }

        // TECH-C2: only the explicit "Stop recording" action stops. "Keep
        // recording" and a plain banner tap restart the silence countdown, so an
        // accidental tap can no longer kill an active meeting.
        if id.hasPrefix(stillMeetingIDPrefix) {
            if action == actionStopRecording {
                routes.append(.stopRecording)
            } else if action == actionKeepRecording || isDefault {
                routes.append(.keepRecording)
            }
        }

        // UX10: "Start recording" (or a banner tap) on a timeout-skip
        // notification rebuilds the source from `userInfo` and starts late. The
        // host still owns the decode, so an undecodable payload drops the route.
        if id.hasPrefix(skipLateIDPrefix),
           action == actionStartLate || isDefault {
            routes.append(.startLate)
        }

        return Decision(routes: routes, consumeDoneEntry: consume)
    }
}
