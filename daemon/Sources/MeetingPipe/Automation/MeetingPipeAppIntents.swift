import AppIntents
import AppKit
import Foundation

// Native App Intents (AUTO1), the no-URL-typing sibling of the `meetingpipe://`
// scheme: these are what Shortcuts, Spotlight, and Siri discover as first-class
// actions. Each one executes by opening the matching `meetingpipe://` URL, so the
// shipped and unit-tested `Coordinator+Automation` router stays the single gate
// path (mic permission, no start while recording) rather than growing a parallel
// one.
//
// This file is deliberately dependency-free: it references no other type in the
// module. `scripts/install.sh` compiles it STANDALONE with `swift-frontend` to
// emit the const-values that `appintentsmetadataprocessor` reads, and a
// standalone compile cannot resolve cross-file references. That is why the verbs
// are string literals here instead of reusing `AutomationCommand`.
// `MeetingPipeAppIntentsTests` parses every URL built here back through
// `AutomationCommand.parse`, so the two cannot drift apart silently.

/// Builds the `meetingpipe://` URLs the intents open. Kept tiny and pure so the
/// tests can pin each intent's URL without running `perform()`.
enum AutomationIntentURL {
    static let scheme = "meetingpipe"

    static func build(_ verb: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = verb
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    /// Hand the deeplink to Launch Services, which delivers it to the running
    /// daemon's `application(_:open:)`. Same path a Shortcuts "Open URL" action
    /// already takes, so a native action and a URL action behave identically.
    @MainActor
    static func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Which Library rail an `Open Library` action lands on. Mirrors the `?scope=`
/// tokens the URL parser accepts; `allMeetings` sends no scope at all.
enum LibraryRailAppEnum: String, AppEnum {
    case allMeetings
    case ask
    case digests
    case facts

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Library Rail" }

    static var caseDisplayRepresentations: [LibraryRailAppEnum: DisplayRepresentation] {
        [
            .allMeetings: "All Meetings",
            .ask: "Ask",
            .digests: "Digests",
            .facts: "Facts"
        ]
    }

    /// nil means "no `?scope=`", which the router maps to the default view.
    var scopeToken: String? {
        self == .allMeetings ? nil : rawValue
    }
}

struct ToggleRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Meeting Recording"
    static var description = IntentDescription(
        "Start a recording, or stop the one in progress. Same as the toggle hotkey."
    )
    static var openAppWhenRun: Bool = false

    static var url: URL? { AutomationIntentURL.build("toggle") }

    func perform() async throws -> some IntentResult {
        await AutomationIntentURL.open(Self.url)
        return .result()
    }
}

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Meeting Recording"
    static var description = IntentDescription(
        "Start a recording if none is running. Never stacks a second recording."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Bring your own summary", default: false)
    var byo: Bool

    static func url(byo: Bool) -> URL? {
        AutomationIntentURL.build("record", query: byo ? [URLQueryItem(name: "byo", value: "1")] : [])
    }

    func perform() async throws -> some IntentResult {
        await AutomationIntentURL.open(Self.url(byo: byo))
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Meeting Recording"
    static var description = IntentDescription(
        "Stop the recording in progress. Does nothing when idle, like the force-stop hotkey."
    )
    static var openAppWhenRun: Bool = false

    static var url: URL? { AutomationIntentURL.build("stop") }

    func perform() async throws -> some IntentResult {
        await AutomationIntentURL.open(Self.url)
        return .result()
    }
}

struct OpenLibraryIntent: AppIntent {
    static var title: LocalizedStringResource = "Open MeetingPipe Library"
    static var description = IntentDescription("Open the Library, optionally at a rail.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Rail", default: .allMeetings)
    var rail: LibraryRailAppEnum

    static func url(rail: LibraryRailAppEnum) -> URL? {
        guard let token = rail.scopeToken else { return AutomationIntentURL.build("library") }
        return AutomationIntentURL.build("library", query: [URLQueryItem(name: "scope", value: token)])
    }

    func perform() async throws -> some IntentResult {
        await AutomationIntentURL.open(Self.url(rail: rail))
        return .result()
    }
}

struct AskLibraryIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask MeetingPipe"
    static var description = IntentDescription(
        "Open the Ask rail with a question prefilled, and run it against your meeting library."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Question")
    var question: String

    static func url(question: String) -> URL? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AutomationIntentURL.build("ask", query: [URLQueryItem(name: "q", value: trimmed)])
    }

    func perform() async throws -> some IntentResult {
        await AutomationIntentURL.open(Self.url(question: question))
        return .result()
    }
}

struct GenerateDigestIntent: AppIntent {
    static var title: LocalizedStringResource = "Generate MeetingPipe Digest"
    static var description = IntentDescription("Open the Digests rail and generate the weekly digest.")
    static var openAppWhenRun: Bool = false

    static var url: URL? { AutomationIntentURL.build("digest") }

    func perform() async throws -> some IntentResult {
        await AutomationIntentURL.open(Self.url)
        return .result()
    }
}

/// The zero-configuration actions Shortcuts surfaces without the user building
/// anything. Only the parameter-free verbs get a phrase; the parameterized ones
/// (Open Library, Ask) are still available as actions to drag into a Shortcut.
struct MeetingPipeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: ["Toggle recording in \(.applicationName)"],
            shortTitle: "Toggle Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["Stop recording in \(.applicationName)"],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: GenerateDigestIntent(),
            phrases: ["Generate my \(.applicationName) digest"],
            shortTitle: "Generate Digest",
            systemImageName: "calendar"
        )
    }
}
