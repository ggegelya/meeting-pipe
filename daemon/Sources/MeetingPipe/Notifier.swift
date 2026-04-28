import AppKit
import UserNotifications

protocol NotifierDelegate: AnyObject {
    func notifier(_ notifier: Notifier, didChooseRecord source: AppSource)
    func notifier(_ notifier: Notifier, didChooseSkip source: AppSource)
    func notifier(_ notifier: Notifier, didChooseAlways source: AppSource)
    func notifier(_ notifier: Notifier, didOpenPage url: URL)
}

/// Wraps UNUserNotificationCenter. Action identifiers and category IDs match
/// what the system delivery callback dispatches on.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    weak var delegate: NotifierDelegate?

    // Category & action IDs must match between registration and userInfo lookups.
    private static let promptCategory = "MP_MEETING_DETECTED"
    private static let actionRecord = "MP_RECORD"
    private static let actionSkip = "MP_SKIP"
    private static let actionAlways = "MP_ALWAYS"

    private static let doneCategory = "MP_DONE"
    private static let actionOpen = "MP_OPEN_PAGE"

    /// Maps notification request identifiers → AppSource so we can resolve
    /// which meeting the user clicked Record on.
    private var pendingSources: [String: AppSource] = [:]
    private var donePages: [String: URL] = [:]

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Posting

    func notifyMeetingDetected(source: AppSource) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting detected: \(source.displayName)"
        content.body = "Record this meeting?"
        content.categoryIdentifier = Self.promptCategory
        content.sound = .default

        let id = "prompt-\(UUID().uuidString)"
        pendingSources[id] = source
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

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
        let record = UNNotificationAction(identifier: Self.actionRecord, title: "Record", options: [.foreground])
        let skip = UNNotificationAction(identifier: Self.actionSkip, title: "Skip", options: [])
        let always = UNNotificationAction(identifier: Self.actionAlways, title: "Always for this app", options: [])
        let prompt = UNNotificationCategory(
            identifier: Self.promptCategory,
            actions: [record, skip, always],
            intentIdentifiers: [],
            options: []
        )

        let open = UNNotificationAction(identifier: Self.actionOpen, title: "Open in Notion", options: [.foreground])
        let done = UNNotificationCategory(
            identifier: Self.doneCategory,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([prompt, done])
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

        // Default tap (no action button) on a prompt = treat as Record.
        let isDefault = action == UNNotificationDefaultActionIdentifier

        if let source = pendingSources.removeValue(forKey: id) {
            switch action {
            case Self.actionRecord:
                delegate?.notifier(self, didChooseRecord: source)
            case Self.actionSkip:
                delegate?.notifier(self, didChooseSkip: source)
            case Self.actionAlways:
                delegate?.notifier(self, didChooseAlways: source)
            default:
                if isDefault {
                    delegate?.notifier(self, didChooseRecord: source)
                }
            }
        } else if let url = donePages.removeValue(forKey: id) {
            if action == Self.actionOpen || isDefault {
                delegate?.notifier(self, didOpenPage: url)
            }
        }
        completionHandler()
    }
}
