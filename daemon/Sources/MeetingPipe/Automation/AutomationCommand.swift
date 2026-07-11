import Foundation

/// A parsed `meetingpipe://` automation command (AUTO1).
///
/// Pure and host-agnostic so the parse is fully unit-testable without the app;
/// `Coordinator.handleAutomation` executes it against the live session, honouring
/// exactly the gates the global hotkey does (mic permission, no start while
/// recording). The URL scheme is the automation surface Shortcuts (via its
/// built-in "Open URL" action), Raycast, and Stream Deck drive; it needs no App
/// Intents metadata, so it works on the plain `swift build` bundle.
enum AutomationCommand: Equatable {
    /// Start a recording if idle. `byo` selects the paste-your-own-summary variant.
    case record(byo: Bool)
    /// Stop-only, like the force-stop hotkey. A no-op when not recording.
    case stop
    /// Start-or-stop, like the toggle hotkey.
    case toggle
    /// Open the Library, optionally at a rail (`scope`: "ask" / "digests" / "facts";
    /// nil or unknown opens the default All Meetings view). Raw string so the
    /// parser stays free of the `LibraryScope` type; the router maps it.
    case openLibrary(scope: String?)
    /// Open the Library's Ask rail with `question` prefilled and run it (AI3).
    case ask(question: String)
    /// Open the Library's Digests rail and generate the weekly digest (AI4).
    case digest

    /// The URL scheme this command layer answers to.
    static let scheme = "meetingpipe"

    /// A short stable name for the event log.
    var verb: String {
        switch self {
        case .record(let byo): return byo ? "record_byo" : "record"
        case .stop: return "stop"
        case .toggle: return "toggle"
        case .openLibrary: return "open_library"
        case .ask: return "ask"
        case .digest: return "digest"
        }
    }

    /// Parse a `meetingpipe://<verb>[?query]` URL, or nil for an unknown scheme or
    /// unrecognized verb, so a malformed deeplink is a safe no-op rather than a
    /// surprise action. The verb is the URL host (`meetingpipe://toggle`); a
    /// `meetingpipe:///toggle` first-path-component form is tolerated too.
    static func parse(_ url: URL) -> AutomationCommand? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let verb = (url.host ?? url.pathComponents.first { $0 != "/" } ?? "").lowercased()
        let query = queryItems(url)
        switch verb {
        case "record", "start":
            let byo = flagIsOn(query["byo"]) || url.pathComponents.contains(where: { $0.lowercased() == "byo" })
            return .record(byo: byo)
        case "byo":
            return .record(byo: true)
        case "stop":
            return .stop
        case "toggle":
            return .toggle
        case "library", "open":
            let scope = query["scope"]?.trimmingCharacters(in: .whitespaces).lowercased()
            return .openLibrary(scope: (scope?.isEmpty ?? true) ? nil : scope)
        case "ask":
            let q = (query["q"] ?? query["question"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return q.isEmpty ? nil : .ask(question: q)
        case "digest":
            return .digest
        default:
            return nil
        }
    }

    private static func queryItems(_ url: URL) -> [String: String] {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return [:] }
        var out: [String: String] = [:]
        for item in items {
            // Keep a valueless flag (`?byo`) as present-but-empty so it reads as on.
            out[item.name.lowercased()] = item.value ?? ""
        }
        return out
    }

    /// A query flag is on when present with a truthy value, or present bare
    /// (`?byo` / `?byo=`). Absent is off.
    private static func flagIsOn(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return value.isEmpty || value == "1" || value == "true" || value == "yes"
    }
}
