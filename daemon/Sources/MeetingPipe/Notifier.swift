import AppKit
import UserNotifications

/// Outcomes the Coordinator cares about. Both the on-screen prompt panel
/// (`MeetingPromptWindow`) and the "Done — open in Notion" notification
/// route into this delegate, so the state machine has one entry point per
/// outcome regardless of the surface that produced it.
protocol NotifierDelegate: AnyObject {
    func notifier(_ notifier: Notifier, didChooseRecord source: AppSource)
    func notifier(_ notifier: Notifier, didChooseSkip source: AppSource)
    func notifier(_ notifier: Notifier, didChooseAlways source: AppSource)
    func notifier(_ notifier: Notifier, didOpenPage url: URL)
    /// User clicked "Open Settings" on a Screen-Recording permission warning.
    func notifierDidRequestScreenRecordingSettings(_ notifier: Notifier)
}

/// Wraps UNUserNotificationCenter for the informational banner notifications
/// (recording started / processing / done / error). The "Record this
/// meeting?" prompt itself lives in `MeetingPromptWindow` — banners get
/// silenced under Focus modes and are easy to miss; the floating panel
/// is the primary surface.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    weak var delegate: NotifierDelegate?

    private static let doneCategory = "MP_DONE"
    private static let actionOpen = "MP_OPEN_PAGE"
    private static let permCategory = "MP_PERM"
    private static let actionOpenSettings = "MP_OPEN_SETTINGS"

    /// Map id → URL so we can resolve which Notion page the user clicked.
    private var donePages: [String: URL] = [:]

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

    func notifyDone(pageURL: URL?) {
        let content = UNMutableNotificationContent()
        if let url = pageURL {
            content.title = "Meeting published"
            content.body = "Open in Notion"
            content.categoryIdentifier = Self.doneCategory
            let id = "done-\(UUID().uuidString)"
            donePages[id] = url
            content.sound = .default
            let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        } else {
            post(title: "Meeting processed", body: "Local Markdown ready (regulated mode)")
        }
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
        let done = UNNotificationCategory(
            identifier: Self.doneCategory,
            actions: [open],
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
        UNUserNotificationCenter.current().setNotificationCategories([done, perm])
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

        if let url = donePages.removeValue(forKey: id) {
            if action == Self.actionOpen || isDefault {
                delegate?.notifier(self, didOpenPage: url)
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
