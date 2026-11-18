import Foundation

extension Coordinator {
    /// Execute a parsed `meetingpipe://` automation command (AUTO1). Called on the
    /// main thread from `AppDelegate.application(_:open:)`. Recording commands go
    /// through exactly the paths the global hotkey uses, so the same gates apply:
    /// a denied mic routes to the Permissions tab (via `beginRecording`), and
    /// `record` never stacks a second start on a live recording.
    ///
    /// `source` names who triggered it, so an in-app caller reusing this router
    /// (UX25's Quick Find handoff) is distinguishable in the event log from a real
    /// deeplink instead of inflating the URL-scheme's usage trail.
    ///
    /// AUTO7: a URL's state-changing verbs pass `AutomationGate`'s one-click confirm first, and a URL
    /// `ask` prefills without running. macOS gives a URL open no caller identity to check.
    func handleAutomation(_ command: AutomationCommand, source: String = AutomationGate.urlSource) {
        Log.event(category: "automation", action: "command", attributes: ["verb": command.verb, "source": source])
        let isRecording: Bool
        if case .idle = stateMachine.current { isRecording = false } else { isRecording = true }
        automationRouter.route(command, source: source, isRecording: isRecording) { [weak self] in
            self?.performAutomation(command, source: source)
        }
    }

    private func performAutomation(_ command: AutomationCommand, source: String) {
        switch command {
        case .toggle:
            UILatency.shared.action("automation_toggle", surface: "automation")
            session.toggleManual(surface: .automation)
        case .record(let byo):
            UILatency.shared.action("automation_record", surface: "automation")
            startRecordingViaAutomation(byo: byo)
        case .stop:
            UILatency.shared.action("automation_stop", surface: "automation")
            session.forceStop(reason: "url_scheme")
        case .openLibrary(let scope):
            openLibraryViaAutomation(scope: scope)
        case .openMeeting(let stem, let seek):
            openMeetingViaAutomation(stem: stem, seek: seek)
        case .ask(let question):
            openLibraryViaAutomation(scope: "ask")
            libraryModel.pendingAsk = .init(question: question, run: AutomationGate.asksRun(source: source))
        case .digest:
            openLibraryViaAutomation(scope: "digests")
            Task { @MainActor in _ = await libraryModel.generateDigest() }
        }
    }

    /// Start a fresh manual recording only from idle, so an external trigger can
    /// never stack a second `recorder.start()` on a live meeting (a guard
    /// `beginRecording` itself does not enforce, since its usual callers already
    /// checked state). `toggle` stays the command that also stops.
    ///
    /// DET7: a Raycast / Stream Deck start fired *during* a meeting the user skipped
    /// attaches to it, like the menu row and the hotkey. Without the candidate this was
    /// unconditionally `source: nil`, so the most common way to trigger it (mid-call,
    /// having just dismissed the prompt) was also the one that lost the attribution.
    private func startRecordingViaAutomation(byo: Bool) {
        guard case .idle = stateMachine.current else {
            Log.event(category: "automation", action: "record_ignored", attributes: ["reason": "not_idle"])
            UILatency.shared.discardPending()
            return
        }
        session.startManual(summaryMode: byo ? .byo : .auto, trigger: "automation")
    }

    /// AUTO2: a citation link clicked in a published note. The request is handed
    /// to the Library rather than resolved here, because the meeting list scans
    /// asynchronously and is usually empty at this instant (the window is only
    /// now coming up); `LibraryRootView` applies `TranscriptDeeplink.resolve` as
    /// soon as the list is real, and `MeetingDetailView` carries the seek into
    /// the Transcript tab. An unknown stem lands on a plain Library, quietly.
    private func openMeetingViaAutomation(stem: String, seek: Double?) {
        libraryModel.pendingTranscriptJump = .init(stem: stem, seek: seek)
        libraryWindow.show()
    }

    private func openLibraryViaAutomation(scope: String?) {
        if let mapped = Self.libraryScope(for: scope) {
            libraryModel.pendingScope = mapped
        }
        libraryWindow.show()
    }

    /// Map a URL scope token to a Library rail. Unknown or nil opens the default
    /// All Meetings view (no `pendingScope`), so a typo lands somewhere sensible.
    private static func libraryScope(for raw: String?) -> LibraryScope? {
        switch raw {
        case "ask": return .ask
        case "digest", "digests": return .digests
        case "facts": return .facts
        case "people": return .people
        case "time", "stats": return .stats
        default: return nil
        }
    }
}
