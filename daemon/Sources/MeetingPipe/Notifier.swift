import AppKit
import UserNotifications

/// Outcomes the Coordinator cares about. Both the on-screen prompt panel
/// (`MeetingPromptWindow`) and the "Done, open in Notion" notification
/// route into this delegate, so the state machine has one entry point per
/// outcome regardless of the surface that produced it.
protocol NotifierDelegate: AnyObject {
    func notifier(_ notifier: Notifier, didChooseRecord source: AppSource)
    func notifier(_ notifier: Notifier, didChooseSkip source: AppSource)
    func notifier(_ notifier: Notifier, didChooseAlways source: AppSource)
    func notifier(_ notifier: Notifier, didOpenPage url: URL)
    /// User clicked "Open Settings" on a Screen-Recording permission warning.
    func notifierDidRequestScreenRecordingSettings(_ notifier: Notifier)
    /// User clicked "Looks good" on the published-meeting notification.
    /// `recordingsDir` is the parent directory of the recording (where
    /// the run sidecar + summary JSON live).
    func notifier(
        _ notifier: Notifier,
        didMarkLooksGoodFor stem: String,
        recordingsDir: URL
    )
    /// User clicked "Edit summary" on the published-meeting notification
    /// or selected a meeting from the Recent meetings… submenu.
    func notifier(
        _ notifier: Notifier,
        didRequestEditSummaryFor stem: String,
        recordingsDir: URL
    )
}

/// Wraps UNUserNotificationCenter for the informational banner notifications
/// (recording started / processing / done / error). The "Record this
/// meeting?" prompt itself lives in `MeetingPromptWindow` — banners get
/// silenced under Focus modes and are easy to miss; the floating panel
/// is the primary surface.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    weak var delegate: NotifierDelegate?

    private static let doneCategory = "MP_DONE"
    private static let doneCorrectableCategory = "MP_DONE_CORRECTABLE"
    private static let doneCorrectableLocalCategory = "MP_DONE_CORRECTABLE_LOCAL"
    private static let actionOpen = "MP_OPEN_PAGE"
    private static let actionLooksGood = "MP_LOOKS_GOOD"
    private static let actionEditSummary = "MP_EDIT_SUMMARY"
    private static let permCategory = "MP_PERM"
    private static let actionOpenSettings = "MP_OPEN_SETTINGS"

    /// Per-notification state. We keep this richer than the previous
    /// id->URL map so the "Looks good" action can find the recording
    /// without re-deriving paths on click.
    private struct DoneEntry {
        let stem: String
        let recordingsDir: URL
        let pageURL: URL?
    }
    private var doneEntries: [String: DoneEntry] = [:]

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                Log.main.warning("Notification auth error: \(error.localizedDescription)")
            }
            Log.main.info("Notification auth granted: \(granted)")
        }
    }

    // MARK: Posting

    func notifyRecordingStarted(file: URL) {
        post(title: "Recording started", body: file.lastPathComponent)
    }

    func notifyProcessing(file: URL) {
        post(title: "Recording stopped", body: "Processing \(file.lastPathComponent)…")
    }

    /// Post the "meeting done" notification. When `stem` and
    /// `recordingsDir` are supplied AND a `<stem>.run.json` exists next
    /// to the recording, the notification surfaces a "Looks good" action
    /// that writes a verdict-good correction record inline. Without
    /// those, we fall back to the legacy behaviour (Open in Notion only,
    /// or a plain "Local Markdown ready" banner under regulated mode).
    func notifyDone(
        stem: String? = nil,
        recordingsDir: URL? = nil,
        pageURL: URL?
    ) {
        let canCorrect = Self.canCorrect(stem: stem, recordingsDir: recordingsDir)

        let content = UNMutableNotificationContent()
        content.sound = .default

        let id = "done-\(UUID().uuidString)"

        if let url = pageURL {
            content.title = "Meeting published"
            content.body = canCorrect ? "Open in Notion. How did this summary look?"
                                      : "Open in Notion"
            content.categoryIdentifier = canCorrect
                ? Self.doneCorrectableCategory
                : Self.doneCategory
            doneEntries[id] = DoneEntry(
                stem: stem ?? "",
                recordingsDir: recordingsDir ?? URL(fileURLWithPath: "/"),
                pageURL: url
            )
        } else if canCorrect, let stem = stem, let dir = recordingsDir {
            content.title = "Meeting processed"
            content.body = "Local Markdown ready. How did this summary look?"
            content.categoryIdentifier = Self.doneCorrectableLocalCategory
            doneEntries[id] = DoneEntry(stem: stem, recordingsDir: dir, pageURL: nil)
        } else {
            // No corrections, no Notion page: keep the legacy plain banner.
            post(title: "Meeting processed", body: "Local Markdown ready (regulated mode)")
            return
        }

        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// True when the run sidecar is present, i.e. the pipeline actually
    /// produced a summary the user can grade. Skipped paths (no_speech,
    /// byo, too_long) never reach the summarize stage and never write
    /// the run sidecar, so they correctly disable the correction action.
    private static func canCorrect(stem: String?, recordingsDir: URL?) -> Bool {
        guard let stem = stem, let dir = recordingsDir else { return false }
        let runURL = dir.appendingPathComponent("\(stem).run.json")
        return FileManager.default.fileExists(atPath: runURL.path)
    }

    func notifyError(_ message: String) {
        post(title: "MeetingPipe error", body: message)
    }

    /// Posted at startup when Screen Recording TCC is denied. The daemon
    /// keeps running, but every recording will be mic-only until the user
    /// grants the permission. The action button opens System Settings.
    func notifySystemAudioBlocked() {
        let content = UNMutableNotificationContent()
        content.title = "Screen Recording disabled"
        content.body = "MeetingPipe will record your microphone only. The other side of the call won't be captured."
        content.categoryIdentifier = Self.permCategory
        content.sound = .default
        let req = UNNotificationRequest(identifier: "perm-startup", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Posted after a recording stops if no system-audio samples were ever
    /// delivered. Stronger surface than the startup banner because the user
    /// has just lost half a meeting and may not have seen the startup one.
    ///
    /// `permissionState` shapes the message. Until this commit the warning
    /// only fired when the state was definitively `.denied`; an `.unknown`
    /// state (fresh daemon launch with no prewarm yet) silently produced
    /// mic-only recordings with no surface — that's the regression the
    /// May 5 18:30 recording hit.
    func notifyMicOnlyRecording(
        file: URL,
        permissionState: SystemAudioCapture.PermissionState
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Recording was mic-only"
        switch permissionState {
        case .denied:
            content.body = "Screen Recording permission is off, so only your voice was captured. Enable it in System Settings to record both sides."
            content.categoryIdentifier = Self.permCategory
        case .unknown:
            content.body = "Screen Recording wasn't available at recording start, so only your voice was captured. Open Settings to grant the permission for next time."
            content.categoryIdentifier = Self.permCategory
        case .granted:
            content.body = "Permission is granted but no system audio reached the recorder. Check ~/Library/Logs/MeetingPipe/recorder.log for SCStream errors."
            // No "Open Settings" action — it's not a permission problem.
        }
        content.sound = .default
        let req = UNNotificationRequest(identifier: "perm-stop-\(file.lastPathComponent)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: Categories

    private func registerCategories() {
        let open = UNNotificationAction(identifier: Self.actionOpen, title: "Open in Notion", options: [.foreground])
        let looksGood = UNNotificationAction(identifier: Self.actionLooksGood, title: "Looks good", options: [])
        let edit = UNNotificationAction(identifier: Self.actionEditSummary, title: "Edit summary", options: [.foreground])
        // Three categories:
        //   * MP_DONE             : pre-Phase-2 fallback (Open in Notion only)
        //   * MP_DONE_CORRECTABLE  : Notion + correction action
        //   * MP_DONE_CORRECTABLE_LOCAL: regulated/local-only + correction action
        let done = UNNotificationCategory(
            identifier: Self.doneCategory,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )
        let doneCorrectable = UNNotificationCategory(
            identifier: Self.doneCorrectableCategory,
            actions: [open, looksGood, edit],
            intentIdentifiers: [],
            options: []
        )
        let doneCorrectableLocal = UNNotificationCategory(
            identifier: Self.doneCorrectableLocalCategory,
            actions: [looksGood, edit],
            intentIdentifiers: [],
            options: []
        )
        let openSettings = UNNotificationAction(identifier: Self.actionOpenSettings, title: "Open Settings", options: [.foreground])
        let perm = UNNotificationCategory(
            identifier: Self.permCategory,
            actions: [openSettings],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories(
            [done, doneCorrectable, doneCorrectableLocal, perm]
        )
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        let isDefault = action == UNNotificationDefaultActionIdentifier

        if let entry = doneEntries[id] {
            switch action {
            case Self.actionLooksGood:
                if !entry.stem.isEmpty {
                    delegate?.notifier(
                        self,
                        didMarkLooksGoodFor: entry.stem,
                        recordingsDir: entry.recordingsDir
                    )
                }
                doneEntries.removeValue(forKey: id)
            case Self.actionEditSummary:
                if !entry.stem.isEmpty {
                    delegate?.notifier(
                        self,
                        didRequestEditSummaryFor: entry.stem,
                        recordingsDir: entry.recordingsDir
                    )
                }
                doneEntries.removeValue(forKey: id)
            case Self.actionOpen:
                if let url = entry.pageURL {
                    delegate?.notifier(self, didOpenPage: url)
                }
                doneEntries.removeValue(forKey: id)
            default:
                if isDefault, let url = entry.pageURL {
                    delegate?.notifier(self, didOpenPage: url)
                    doneEntries.removeValue(forKey: id)
                }
            }
        }

        // Permission notifications: any tap (action button or default) opens
        // System Settings. The id prefix is enough to disambiguate from the
        // "done" category, which is handled above and removed from the map.
        if id.hasPrefix("perm-"), action == Self.actionOpenSettings || isDefault {
            delegate?.notifierDidRequestScreenRecordingSettings(self)
        }
        completionHandler()
    }
}
