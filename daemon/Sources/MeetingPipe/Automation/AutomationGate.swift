import AppKit

/// AUTO7: what a `meetingpipe://` link may do without the owner's click.
///
/// macOS gives a URL handler no caller identity, so a web page, a chat message, a calendar invite
/// or any local app can open one. The verbs that change state or may cost an engine call (`toggle`,
/// `record`, `record_byo`, `stop`, `digest`) therefore ask first when they arrive by URL; the action
/// is the default button, so a Stream Deck or Raycast user pays one click or one Return. Showing UI
/// (`library`, `open`) never asks, and `ask` from a URL prefills without running (the router's
/// perform half). In-app callers (Quick Find) are trusted and never ask. Pure.
struct AutomationConfirmation: Equatable {
    /// `AutomationCommand.verb`, for the event log.
    let verb: String
    /// One sentence naming the action and its origin.
    let message: String
    /// The default button's title.
    let actionTitle: String
    /// `toggle` only: whether it was decided as a stop (true) or a start (false) when the link
    /// arrived. The panel has no timeout, so the router re-reads the state at accept and performs
    /// nothing if a toggle would now do the other thing (the 2026-11-21 amendment). Nil for verbs
    /// whose perform re-checks the state itself: `record` refuses anything but idle, `stop` is
    /// stop-only, `digest` does not depend on it.
    var expectsRecording: Bool? = nil
}

enum AutomationGate {
    /// The `source` a URL open carries (`AppDelegate.application(_:open:)`).
    static let urlSource = "url_scheme"

    /// The confirm a command needs before it runs, or nil to run it at once.
    static func confirmation(
        for command: AutomationCommand, source: String, isRecording: Bool
    ) -> AutomationConfirmation? {
        guard source == urlSource else { return nil }
        let verb = command.verb
        switch command {
        case .toggle:
            return isRecording
                ? .init(verb: verb, message: "A link asked MeetingPipe to stop the current recording.",
                        actionTitle: "Stop Recording", expectsRecording: true)
                : .init(verb: verb, message: "A link asked MeetingPipe to start recording.",
                        actionTitle: "Start Recording", expectsRecording: false)
        case .record(let byo):
            return .init(
                verb: verb,
                message: byo
                    ? "A link asked MeetingPipe to start recording, without writing the summary for you."
                    : "A link asked MeetingPipe to start recording.",
                actionTitle: "Start Recording"
            )
        case .stop:
            return .init(verb: verb, message: "A link asked MeetingPipe to stop the current recording.", actionTitle: "Stop Recording")
        case .digest:
            return .init(
                verb: verb,
                message: "A link asked MeetingPipe to build this week's digest, which runs your summarizing engine.",
                actionTitle: "Build Digest"
            )
        case .openLibrary, .openMeeting, .ask:
            return nil
        }
    }

    /// What `MeetingSessionController.toggleManual` would do right now: true when it stops (a
    /// recording, a stop already flushing, or a start in flight, which the toggle cancels), false
    /// when it starts (idle, or a prompt or skipped meeting, which it records attached). The
    /// router's `isRecording` read, at arrival and again at accept. Idle-or-not used to stand in
    /// for this, which titled a toggle that would start from a prompt "Stop Recording".
    static func toggleStops(_ state: AppState, startInFlight: Bool) -> Bool {
        if startInFlight { return true }
        switch state {
        case .recording, .stopping: return true
        case .idle, .prompting, .suppressed: return false
        }
    }

    /// Whether a URL `ask` runs its question or only prefills it. Only an in-app source runs.
    static func asksRun(source: String) -> Bool { source != urlSource }
}

/// Holds the gate's one piece of state: a confirm on screen. A second gated link arriving while one
/// is up (a modal alert still delivers Apple Events) is dropped and logged, never stacked. Main
/// queue only, like `handleAutomation`.
final class AutomationRouter {
    typealias Confirm = (AutomationConfirmation, @escaping (Bool) -> Void) -> Void

    private let confirm: Confirm
    private(set) var isConfirming = false

    init(confirm: @escaping Confirm = AutomationRouter.confirmWithAlert) {
        self.confirm = confirm
    }

    /// `isRecording` is a live read (`AutomationGate.toggleStops`), taken when the link arrives and
    /// again when the confirm is accepted, since the panel can sit open across a meeting starting
    /// or ending.
    func route(_ command: AutomationCommand, source: String, isRecording: @escaping () -> Bool, perform: @escaping () -> Void) {
        guard let request = AutomationGate.confirmation(for: command, source: source, isRecording: isRecording()) else {
            perform()
            return
        }
        guard !isConfirming else {
            Log.event(category: "automation", action: "command_dropped",
                      attributes: ["verb": request.verb, "source": source, "reason": "confirm_open"])
            return
        }
        isConfirming = true
        confirm(request) { [weak self] accepted in
            self?.isConfirming = false
            if accepted, let expected = request.expectsRecording, isRecording() != expected {
                Log.event(category: "automation", action: "command_stale",
                          attributes: ["verb": request.verb, "source": source, "decided": expected ? "stop" : "start"])
                return
            }
            Log.event(category: "automation", action: accepted ? "command_confirmed" : "command_declined",
                      attributes: ["verb": request.verb, "source": source])
            if accepted { perform() }
        }
    }

    /// The real panel. Brought to the front first: this is a menu-bar app, so a link opened from
    /// another app would otherwise raise the alert behind it.
    static func confirmWithAlert(_ request: AutomationConfirmation, completion: @escaping (Bool) -> Void) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Allow this link?"
        alert.informativeText = request.message + " Links can come from any app or web page."
        alert.addButton(withTitle: request.actionTitle)
        alert.addButton(withTitle: "Cancel")
        completion(alert.runModal() == .alertFirstButtonReturn)
    }
}
