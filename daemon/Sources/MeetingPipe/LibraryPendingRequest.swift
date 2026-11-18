import Foundation

/// UX100: what the Library root does with the requests a caller left on `LibraryWindowModel`
/// before it called `LibraryWindow.show()`.
///
/// Quick Find, a failure-notification click and the `meetingpipe://library`, `ask` and
/// `digest` links all set `pendingSelection` or `pendingScope` and then show the window. The
/// window is built on its first show, so for the first request after a launch the value is
/// already set when `LibraryRootView` appears, and `onChange` never fires for an initial value.
/// The root used to consume these only in `onChange`, so that request was lost, and because the
/// stale value was never cleared a repeat of it was not a change either. The root now applies
/// this on appear and on either change, and clears both values on every attempt.
///
/// Pure, so the cold-open path can be tested without hosting the window.
struct LibraryPendingRequest: Equatable {
    /// The rail to show.
    let scope: LibraryScope
    /// The meeting to select, or nil to leave the selection to the scope switch.
    let selection: String?
    /// True when a pending Ask question would otherwise be left behind: the rail it was meant
    /// for is not the one this request lands on, so the next manual visit to Ask would run a
    /// question nobody is waiting for.
    let dropsPendingAsk: Bool

    /// Nil when nothing is pending, so a plain appear changes nothing.
    ///
    /// Scope first, then selection: a selection forces All meetings, so a meeting picked after a
    /// scope request still lands on a list that shows it.
    static func decide(
        pendingScope: LibraryScope?,
        pendingSelection: String?,
        hasPendingAsk: Bool
    ) -> LibraryPendingRequest? {
        if let stem = pendingSelection {
            return LibraryPendingRequest(
                scope: .allMeetings, selection: stem, dropsPendingAsk: hasPendingAsk
            )
        }
        if let scope = pendingScope {
            return LibraryPendingRequest(
                scope: scope, selection: nil, dropsPendingAsk: hasPendingAsk && scope != .ask
            )
        }
        return nil
    }
}
