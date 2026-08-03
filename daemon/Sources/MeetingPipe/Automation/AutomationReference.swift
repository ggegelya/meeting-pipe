import AppKit
import Foundation

/// AUTO4: the read-only list of `meetingpipe://` verbs that Preferences renders
/// under Advanced, for the owner who does not keep the README open.
///
/// It is a value list rather than rows written straight into the SwiftUI view,
/// because the only real risk in shipping a reference is that it goes stale
/// quietly: a row naming a verb the parser stopped accepting teaches a URL that
/// does nothing, which is worse than the README-only state it replaces. So the
/// list is pinned to `AutomationCommand.parse` in both directions by
/// `AutomationReferenceTests` (every template lands on the command its row
/// claims; every case of the enum has a row). That is the
/// `MeetingPipeAppIntentsTests` idiom applied one layer up: there, six intents'
/// hand-written URLs are parsed back through the router's own parser so the two
/// vocabularies cannot diverge.
///
/// The templates use the README's `<placeholder>` spelling so a reader moving
/// between the two lists is not re-learning a notation. That costs nothing here:
/// `URL(string:)` percent-encodes the angle brackets instead of refusing them, so
/// the exact string the owner copies is the string the fence parses, and there is
/// no separate "example" that could drift from what is displayed.
struct AutomationReference: Identifiable {
    /// The URL, as shown and as copied. Unique across the list, so it is the id.
    let template: String
    /// What `AutomationCommand.parse` makes of `template`. The fence key: it is
    /// what stops a row from describing one verb while spelling another.
    let command: AutomationCommand
    /// One line for the owner. What happens, in the words someone who has never
    /// read the parser would use.
    let purpose: String

    var id: String { template }

    /// Put this row's template on the pasteboard, which is the whole of what the
    /// row's Copy button does. It takes the pasteboard rather than reaching for
    /// `.general` inside, so the behaviour can be pinned against a scratch one
    /// instead of stomping the owner's real clipboard on every test run.
    func copyTemplate(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(template, forType: .string)
    }

    /// Ordered like the README's table, so the two read alike.
    static let rows: [AutomationReference] = [
        AutomationReference(
            template: "meetingpipe://toggle",
            command: .toggle,
            purpose: "Start recording, or stop the recording that is running. Same as the record hotkey."
        ),
        AutomationReference(
            template: "meetingpipe://record",
            command: .record(byo: false),
            purpose: "Start recording. Does nothing if a recording is already running."
        ),
        AutomationReference(
            template: "meetingpipe://record?byo=1",
            command: .record(byo: true),
            purpose: "Start recording, without writing the summary for you. You paste your own notes after it stops."
        ),
        AutomationReference(
            template: "meetingpipe://stop",
            command: .stop,
            purpose: "Stop the recording that is running. Does nothing when nothing is recording."
        ),
        AutomationReference(
            template: "meetingpipe://library",
            command: .openLibrary(scope: nil),
            purpose: "Open the Library. Add ?scope=facts, people, time, ask, or digests to land on that rail."
        ),
        AutomationReference(
            template: "meetingpipe://open?stem=<stem>&t=<seconds>",
            command: .openMeeting(stem: "<stem>", seek: nil),
            purpose: "Open one meeting's transcript at that second. The value for stem comes from Copy meeting ID in a meeting's menu."
        ),
        AutomationReference(
            template: "meetingpipe://ask?q=<question>",
            command: .ask(question: "<question>"),
            purpose: "Ask a question across every meeting, and open the answer as it arrives."
        ),
        AutomationReference(
            template: "meetingpipe://digest",
            command: .digest,
            purpose: "Build this week's review of open actions and recent decisions, and open it."
        ),
    ]
}
