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
        UNUserNotificationCenter.current().setNotificationCategories([done])
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
        completionHandler()
    }
}
