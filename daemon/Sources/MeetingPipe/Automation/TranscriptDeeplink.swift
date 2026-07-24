import Foundation

/// AUTO2: where a `meetingpipe://open?stem=&t=` deeplink lands, decided against
/// the Library's meeting list.
///
/// Pure and host-agnostic like `AutomationCommand`, so the rule is unit-testable
/// without a window. The reason it is a rule at all rather than a lookup: the
/// deeplink usually arrives at a *cold* Library (a note is clicked while the app
/// sits in the menu bar), and `MeetingStore` scans asynchronously from the
/// window's `onAppear`, so "no such meeting" and "not scanned yet" look identical
/// at the moment the URL is handled. Collapsing them would send every valid link
/// to the quiet no-match open.
enum TranscriptDeeplink {

    enum Outcome: Equatable {
        /// The list has not finished its first scan; ask again on the next store
        /// revision rather than deciding on an empty list.
        case wait
        /// Select this meeting and reveal `seek` in its Transcript tab. A nil
        /// `seek` still opens the transcript, just without scrolling to a row.
        case openMeeting(stem: String, seek: Double?)
        /// A stale note or a renamed recording. The window is already coming up,
        /// so drop the request and leave the Library where it is: an alert about
        /// a link the reader cannot fix would be noise, and a note legitimately
        /// outlives the recording it cites.
        case libraryOnly
    }

    static func resolve(
        stem: String,
        seek: Double?,
        knownStems: Set<String>,
        hasLoadedOnce: Bool
    ) -> Outcome {
        if knownStems.contains(stem) { return .openMeeting(stem: stem, seek: seek) }
        return hasLoadedOnce ? .libraryOnly : .wait
    }
}
