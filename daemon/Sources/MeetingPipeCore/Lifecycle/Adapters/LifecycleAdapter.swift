import ApplicationServices
import Foundation

/// AX references handed from the executable's AX walk into per-app adapters. `MeetingPipeCore` avoids
/// AX-tree traversal itself so it stays testable without accessibility-trust.
/// `leaveButton` is nil for browser adapters (browsers expose tab content as a single window; per-tab AX is unavailable).
public struct LifecycleAdapterHandle {
    public let leaveButton: AXUIElement?
    public let meetingWindow: AXUIElement?
    /// Fresh-tree-walk resolver for the live Leave button, injected by the daemon
    /// (it owns the AX walk). `AXLeaveButtonSignal` calls it before treating a stale
    /// `.invalid` read as a meeting end, so a Teams call-UI re-render recovers a live
    /// control instead of false-ending the call (TECH-END2, mirrors the MIC6 mute seam).
    public let resolveLeaveButton: (() -> AXUIElement?)?

    public init(
        leaveButton: AXUIElement? = nil,
        meetingWindow: AXUIElement? = nil,
        resolveLeaveButton: (() -> AXUIElement?)? = nil
    ) {
        self.leaveButton = leaveButton
        self.meetingWindow = meetingWindow
        self.resolveLeaveButton = resolveLeaveButton
    }
}

/// Per-app lifecycle adapter. Translates PRIMARY signal state changes into `PrimarySignalEvent`s for the coordinator's engine.
public protocol LifecycleAdapter: AnyObject {
    /// Bundle IDs served by this adapter. The coordinator dispatches to the first matching adapter.
    var bundleIDs: Set<String> { get }

    /// `.native` or `.browser`. Used by the coordinator to route contexts.
    var kind: MeetingLifecycleContext.Kind { get }

    /// Whether this adapter handles `bundleID`. Default is exact match; browser adapter overrides to also accept
    /// Chromium PWA IDs whose `<browser>.app.<hash>` form can't be enumerated.
    func handles(bundleID: String) -> Bool

    /// Start observing. The adapter retains `sink` and calls it on every PRIMARY signal flip.
    func start(
        context: MeetingLifecycleContext,
        handle: LifecycleAdapterHandle,
        sink: @escaping (PrimarySignalEvent) -> Void
    ) throws

    func stop()

    /// Late-arm the Leave-button signal with a button re-walked at recording-start.
    /// Discovery-time walk usually misses the button because the call UI hasn't rendered yet.
    /// No-op when already armed; browser adapter's default is a no-op.
    func armLeaveButton(_ element: AXUIElement)
}

public extension LifecycleAdapter {
    func handles(bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    func armLeaveButton(_ element: AXUIElement) {}
}

/// Locale-tolerant title matchers for all meeting vendors. Single source of truth; adapters compose these per platform.
public enum MeetingTitlePatterns {

    /// Teams: localised "meeting" stem or the universal " | Microsoft Teams" window-title suffix.
    public static let teams: (String?) -> Bool = { title in
        guard let lowered = title?.lowercased() else { return false }
        for token in teamsTokens where lowered.contains(token) {
            return true
        }
        return false
    }

    /// Zoom: "Zoom Meeting", "Zoom -", localised "Reunion Zoom", or plain "Zoom" (older builds).
    public static let zoom: (String?) -> Bool = { title in
        guard let lowered = title?.lowercased() else { return false }
        return zoomTokens.contains { lowered.contains($0) }
    }

    /// Webex: "Webex Meetings" (classic) or the unified Webex App "Meeting"/"Reunion" stems shared with Teams.
    public static let webex: (String?) -> Bool = { title in
        guard let lowered = title?.lowercased() else { return false }
        for token in webexTokens where lowered.contains(token) {
            return true
        }
        for token in teamsTokens where lowered.contains(token) {
            return true
        }
        return false
    }

    /// Google Meet (browser tab): a live call tab carries the meeting code (`abc-defg-hij`: three-four-three
    /// lowercase letters) or the `meet.google.com` host. The earlier "meet" + "-" heuristic over-admitted any
    /// page title containing the word, e.g. "Level 10 Meeting - Jira" (the 2026-06-30 false prompt). The code is
    /// the distinctive in-room marker; the idle "Google Meet" lobby (no code) correctly reads not-live. Signal
    /// flips on transition off this pattern. Browser-only matcher (no native Meet adapter consumes it).
    public static let googleMeet: (String?) -> Bool = { title in
        guard let lowered = title?.lowercased() else { return false }
        if lowered.contains("meet.google.com") { return true }
        return lowered.range(
            of: #"(?<![a-z])[a-z]{3}-[a-z]{4}-[a-z]{3}(?![a-z])"#,
            options: .regularExpression
        ) != nil
    }

    /// Slack huddles: title contains "huddle" as a whole word, so a "team-huddles" channel name
    /// does not match (the trailing `s` is alphanumeric and fails the boundary). DET5 made this
    /// word-boundary to match the scanner's start-side recognizer, which now routes through this
    /// matcher, so discovery and end-detection cannot diverge.
    public static let slackHuddle: (String?) -> Bool = { title in
        guard let title, !title.isEmpty else { return false }
        return title.range(of: #"\bhuddle\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Browser-tab Teams: keys off the "Microsoft Teams" brand suffix ("<subject> | Microsoft Teams").
    /// Unlike the native `teams` matcher it deliberately omits the bare localized "meeting" stem, which
    /// matches any page whose title merely contains the word (a Jira board named "Level 10 Meeting", a
    /// "Meeting notes" doc). Native Teams can afford the permissive stem because the scorer requires an
    /// in-call corroborator for natives; a browser title-match stands alone, so it must be brand-specific.
    public static let browserTeams: (String?) -> Bool = { title in
        guard let lowered = title?.lowercased() else { return false }
        return lowered.contains("microsoft teams")
    }

    /// Browser-tab Webex: keys off the "webex" brand, never the shared "meeting" stem (see `browserTeams`).
    public static let browserWebex: (String?) -> Bool = { title in
        guard let lowered = title?.lowercased() else { return false }
        return lowered.contains("webex")
    }

    private static let teamsTokens: [String] = [
        "meeting", "besprechung", "reunion", "reuniao", "encuentro",
        "встреча", "kokous", "spotkanie", "moot",
        // Universal " | Microsoft Teams" suffix: matches meeting windows whose subject lacks a meeting stem.
        "microsoft teams"
    ]

    private static let zoomTokens: [String] = [
        "zoom meeting", "zoom -", "reunion zoom", "zoom"
    ]

    private static let webexTokens: [String] = [
        "webex meetings", "webex meeting", "webex"
    ]
}
