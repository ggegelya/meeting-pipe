import Foundation
import UserNotifications

/// UX92: what a notice is for, in the post record. A fixed vocabulary, never the title or body
/// (a body can carry a meeting name).
enum NotificationKind: String, Sendable {
    case done
    case failure
    case stillMeeting = "still_meeting"
    case skipLate = "skip_late"
    case mic
    case capture
    case accessibility
    case info
}

/// UX92: the row a post leaves, pure so a test asserts what ships. Every `add` used to be
/// fire-and-forget, so on 2026-10-16 four `pipeline_failed` rows each implied a failure banner and
/// nothing said whether one was posted.
enum NotificationPostRecord {
    static func attributes(kind: NotificationKind, stem: String?, error: Error?) -> [String: Any] {
        var attributes: [String: Any] = ["kind": kind.rawValue]
        if let stem, !stem.isEmpty { attributes["stem"] = stem }
        if let error {
            let ns = error as NSError
            attributes["error_domain"] = ns.domain
            attributes["error_code"] = ns.code
        }
        return attributes
    }

    /// The `daemon.log` line a failed post writes; nil for a post the system took.
    static func failureLine(kind: NotificationKind, error: Error?) -> String? {
        guard let error else { return nil }
        let ns = error as NSError
        return "notification not posted (kind=\(kind.rawValue)) [\(ns.domain) \(ns.code)]"
    }

    static func record(
        kind: NotificationKind, stem: String?, error: Error?,
        emit: ([String: Any]) -> Void = { Log.event(category: "daemon", action: "notification_posted", attributes: $0) },
        writeLine: (String) -> Void = { Log.writeLine("daemon", $0) }
    ) {
        emit(attributes(kind: kind, stem: stem, error: error))
        if let line = failureLine(kind: kind, error: error) { writeLine(line) }
    }
}

/// The center seam, so a test can fail an `add` without a notification center.
protocol NotificationCenterPosting: AnyObject {
    func add(_ request: UNNotificationRequest, completion: @escaping @Sendable (Error?) -> Void)
}

extension UNUserNotificationCenter: NotificationCenterPosting {
    func add(_ request: UNNotificationRequest, completion: @escaping @Sendable (Error?) -> Void) {
        add(request, withCompletionHandler: completion)
    }
}

/// UX92: the one post path. Each request goes to the center with a completion handler, and the
/// outcome becomes a `daemon/notification_posted` row (`kind`, `stem` when known, and the error's
/// domain and code when the system refused it). A refused post also writes a `daemon.log` line.
final class NotificationPoster {
    private let center: NotificationCenterPosting
    private let record: @Sendable (NotificationKind, String?, Error?) -> Void

    init(
        center: NotificationCenterPosting,
        record: @escaping @Sendable (NotificationKind, String?, Error?) -> Void = { kind, stem, error in
            NotificationPostRecord.record(kind: kind, stem: stem, error: error)
        }
    ) {
        self.center = center
        self.record = record
    }

    func post(_ request: UNNotificationRequest, kind: NotificationKind, stem: String? = nil) {
        let record = self.record
        center.add(request) { error in record(kind, stem, error) }
    }
}
