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

    /// Google Meet: title contains "meet" + "-" (handles non-ASCII separators across locales). Signal flips on transition off this pattern.
    public static let googleMeet: (String?) -> Bool = { title in
        guard let lowered = title?.lowercased() else { return false }
        return lowered.contains("meet") && lowered.contains("-")
    }

    /// Slack huddles: title contains "huddle".
    public static let slackHuddle: (String?) -> Bool = { title in
        guard let lowered = title?.lowercased() else { return false }
        return lowered.contains("huddle")
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
