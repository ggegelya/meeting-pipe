import Foundation

extension Coordinator {
    /// Execute a parsed `meetingpipe://` automation command (AUTO1). Called on the
    /// main thread from `AppDelegate.application(_:open:)`. Recording commands go
    /// through exactly the paths the global hotkey uses, so the same gates apply:
    /// a denied mic routes to the Permissions tab (via `beginRecording`), and
    /// `record` never stacks a second start on a live recording.
    func handleAutomation(_ command: AutomationCommand) {
        Log.event(category: "automation", action: "command", attributes: ["verb": command.verb])
        switch command {
        case .toggle:
            session.toggleManual()
        case .record(let byo):
            startRecordingViaAutomation(byo: byo)
        case .stop:
            session.forceStop(reason: "url_scheme")
        case .openLibrary(let scope):
            openLibraryViaAutomation(scope: scope)
        case .ask(let question):
            openLibraryViaAutomation(scope: "ask")
            libraryModel.pendingAskQuestion = question
        case .digest:
            openLibraryViaAutomation(scope: "digests")
            Task { @MainActor in _ = await libraryModel.generateDigest() }
        }
    }

    /// Start a fresh manual recording only from idle, so an external trigger can
    /// never stack a second `recorder.start()` on a live meeting (a guard
    /// `beginRecording` itself does not enforce, since its usual callers already
    /// checked state). `toggle` stays the command that also stops.
    private func startRecordingViaAutomation(byo: Bool) {
        guard case .idle = stateMachine.current else {
            Log.event(category: "automation", action: "record_ignored", attributes: ["reason": "not_idle"])
            return
        }
        session.beginRecording(source: nil, summaryMode: byo ? .byo : .auto)
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
        default: return nil
        }
    }
}
