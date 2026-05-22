import ApplicationServices
import Foundation

/// Bundle of AX references the per-app adapter needs to wire its
/// PRIMARY signals. The executable's AX-walk code produces one of
/// these (or returns nil when the walk fails); `MeetingPipeCore`
/// stays out of AX-tree traversal so it remains testable without
/// accessibility-trust.
///
/// The Leave button is always required: every adapter that uses
/// `AXLeaveButtonSignal` needs it. The meeting window is optional
/// because the browser adapter doesn't track an AX window at all
/// (browsers expose `WKWebView` content as a single window with the
/// tab title baked into the window title).
public struct LifecycleAdapterHandle {
    public let leaveButton: AXUIElement?
    public let meetingWindow: AXUIElement?

    public init(leaveButton: AXUIElement? = nil, meetingWindow: AXUIElement? = nil) {
        self.leaveButton = leaveButton
        self.meetingWindow = meetingWindow
    }
}

/// Per-app lifecycle adapter. Owns the PRIMARY signals for its
/// platform and translates their state changes into
/// `PrimarySignalEvent`s feeding the `MeetingLifecycleCoordinator`'s
/// engine.
public protocol LifecycleAdapter: AnyObject {
    /// Bundle IDs this adapter knows how to handle. The coordinator
    /// dispatches to the first adapter whose set contains the
    /// active context's bundle ID.
    var bundleIDs: Set<String> { get }

    /// Source kind (native or browser). Used by the coordinator to
    /// route browser-hosted contexts to the browser adapter.
    var kind: MeetingLifecycleContext.Kind { get }

    /// Whether this adapter handles `bundleID`. The default
    /// implementation is an exact match against `bundleIDs`; the
    /// browser adapter overrides it to also accept Chromium PWA
    /// bundle IDs, whose `<browser>.app.<hash>` form is per-install
    /// and so cannot be enumerated as a fixed set.
    func handles(bundleID: String) -> Bool

    /// Start observing the given meeting. The sink is called whenever
    /// a PRIMARY signal flips. The adapter retains the sink for the
    /// duration of `start ... stop`.
    func start(
        context: MeetingLifecycleContext,
        handle: LifecycleAdapterHandle,
        sink: @escaping (PrimarySignalEvent) -> Void
    ) throws

    func stop()

    /// Late-arm the AX Leave-button signal with a button the executable
    /// re-walked at recording-start. The discovery-time AX walk usually
    /// misses the Leave button because the call UI has not rendered yet
    /// (`MeetingAXHandleBuilder.build` returns `leaveButton: nil`).
    /// Idempotent: a no-op when the signal already armed at engage
    /// time, and for adapters with no AX Leave-button signal.
    func armLeaveButton(_ element: AXUIElement)
}

public extension LifecycleAdapter {
    /// Default dispatch: exact match against the advertised set.
    func handles(bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    /// Default: adapters with no AX Leave-button signal ignore the
    /// late-arm. The browser adapter relies on this.
    func armLeaveButton(_ element: AXUIElement) {}
}

/// Locale-tolerant title-match callbacks used by adapters when they
/// wire `ShareableContentSignal`. The regex catalogue lives here so a
/// single source of truth covers the strings shipped by the meeting
/// vendors. Adapters compose these per-platform.
public enum MeetingTitlePatterns {

    /// Teams native + web: a localised "meeting" stem, or the universal " | Microsoft Teams" window-title suffix.
    public static let teams: (String?) -> Bool = { title in
        guard let lowered = title?.lowercased() else { return false }
        for token in teamsTokens where lowered.contains(token) {
            return true
        }
        return false
    }

    /// Zoom titles either contain "Zoom Meeting", "Zoom -", the
    /// localised "Reunion Zoom" variant, or just "Zoom" plus a
    /// participant count (older builds).
    public static let zoom: (String?) -> Bool = { title in
        guard let lowered = title?.lowercased() else { return false }
        return zoomTokens.contains { lowered.contains($0) }
    }

    /// Webex native windows expose "Webex Meetings" plus the meeting
    /// topic. The unified Webex App is "Meeting" / "Reunion" / etc.
    /// in the same localisations as Teams.
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

    /// Google Meet tab titles follow `Meet ... <code>` with non-ASCII
    /// separators across locales. The PRIMARY signal flips on the
    /// transition off of this pattern.
    public static let googleMeet: (String?) -> Bool = { title in
        guard let lowered = title?.lowercased() else { return false }
        return lowered.contains("meet") && lowered.contains("-")
    }

    /// Slack huddles: tab / window title contains "huddle" in any
    /// supported locale.
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
