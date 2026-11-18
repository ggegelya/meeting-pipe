import Foundation

/// UX93: what a failure notification carries in `userInfo`, so a click after a relaunch rebuilds the
/// same presentation the banner was posted with. Pure, so the round trip is assertable without a
/// notification center.
///
/// A stem-less notice used to keep its presentation only in `Notifier.failures`, in memory, so after a
/// relaunch the click opened an alert with the generic title, the retry line and an empty Details
/// pane. The operation, title and message ride in the notification now. The message is the banner's
/// own body, so nothing reaches Notification Center's store that the banner did not already show;
/// the full diagnostics and any traceback never do.
enum FailureNotificationPayload {
    static let stemKey = "failureStem"
    static let operationKey = "failureOperation"
    static let titleKey = "failureTitle"
    static let messageKey = "failureMessage"

    /// The banner body: the message itself for a stem-less notice, else a pointer to the Library row,
    /// which carries the full reason.
    static func body(failure: FailurePresentation, stem: String?, message: String?) -> String {
        if stem != nil { return "Review in Library." }
        return message ?? failure.explanation
    }

    static func userInfo(failure: FailurePresentation, stem: String?, message: String?) -> [String: String] {
        if let stem { return [stemKey: stem] }
        return [
            operationKey: failure.metadata.operation.rawValue,
            titleKey: failure.title,
            messageKey: body(failure: failure, stem: nil, message: message),
        ]
    }

    /// The presentation a stem-less click shows when the in-memory entry is gone (a relaunch), or nil
    /// when the notification carries none (one posted by an older build).
    static func rebuild(userInfo: [AnyHashable: Any]) -> FailurePresentation? {
        guard let raw = userInfo[operationKey] as? String,
              let operation = FailureMetadata.Operation(rawValue: raw),
              let message = userInfo[messageKey] as? String else { return nil }
        return FailurePresentation(diagnostics: message, operation: operation, title: userInfo[titleKey] as? String)
    }
}

/// UX93: a done banner's state is its stem, in `userInfo`. The recordings directory comes from the
/// current config and the page URL from `<stem>.publish.json` at click time, the same file
/// `notifyDone` read, so no map outlives the banner and a click after a relaunch still routes. The
/// in-memory map this replaces lost an entry only when its banner was acted on, so it grew for
/// the life of the process, and after a relaunch Looks good, Edit and Open silently did nothing.
enum DoneNotificationPayload {
    static let stemKey = "doneStem"

    static func userInfo(stem: String) -> [String: String] { [stemKey: stem] }

    /// What a click on a done banner needs: the router's entry and the page to open.
    struct Resolved: Equatable {
        var entry: NotificationRouter.DoneEntry
        var recordingsDir: URL
        var pageURL: URL?
    }

    static func resolve(userInfo: [AnyHashable: Any], recordingsDir: URL?) -> Resolved? {
        guard let stem = userInfo[stemKey] as? String, !stem.isEmpty, let recordingsDir else { return nil }
        let pageURL = PublishResult.load(stem: stem, in: recordingsDir)?.pageURL
        return Resolved(
            entry: NotificationRouter.DoneEntry(stem: stem, hasPageURL: pageURL != nil),
            recordingsDir: recordingsDir,
            pageURL: pageURL
        )
    }
}

/// UX93: the in-memory failure presentations, evicted oldest first. It used to drop
/// `keys.sorted().first`, which is random UUID order, not age.
struct InsertionOrderedStore<Value> {
    let capacity: Int
    private(set) var order: [String] = []
    private var values: [String: Value] = [:]

    init(capacity: Int) { self.capacity = capacity }

    var count: Int { values.count }

    mutating func insert(_ value: Value, for key: String) {
        if values[key] == nil {
            if order.count >= capacity, let oldest = order.first {
                order.removeFirst()
                values.removeValue(forKey: oldest)
            }
            order.append(key)
        }
        values[key] = value
    }

    mutating func remove(_ key: String) -> Value? {
        guard let value = values.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        return value
    }

    subscript(key: String) -> Value? { values[key] }
}
