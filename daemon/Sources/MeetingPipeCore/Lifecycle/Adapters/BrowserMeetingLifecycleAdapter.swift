import Foundation

/// Browser-hosted meeting adapter. Covers Google Meet, Teams web,
/// Webex web, and Slack huddles (PWA).
///
/// Browsers expose tab content as a single AX window per browser, so
/// `AXLeaveButton` is unavailable. Browsers also do not expose
/// per-tab mic state via any public Apple API as of macOS 14-15.
/// The PRIMARY signal is therefore `ShareableContent` only, keyed
/// on the browser bundle ID with a host-specific title regex.
///
/// `TeamsLifecycleAdapter` covers the Teams native app; the browser
/// adapter handles "Teams in Chrome / Edge / Arc" through the same
/// title patterns since both surfaces show "Meeting | ..." in their
/// window title.
public final class BrowserMeetingLifecycleAdapter: LifecycleAdapter {

    public let bundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.apple.Safari",
        "org.mozilla.firefox"
    ]
    public let kind: MeetingLifecycleContext.Kind = .browser

    /// Title-match patterns the adapter cycles through. The first
    /// matching pattern wins; a tab title that matches none reads as
    /// `.ended`, which is exactly what we want for the Meet "left
    /// the call" page transition.
    public static let defaultTitleMatchers: [(String?) -> Bool] = [
        MeetingTitlePatterns.googleMeet,
        MeetingTitlePatterns.teams,
        MeetingTitlePatterns.webex,
        MeetingTitlePatterns.slackHuddle
    ]

    private let shareableContent: ShareableContentSignal
    private let titleMatchers: [(String?) -> Bool]

    public init(
        eventLog: EventLog = NoopEventLog(),
        titleMatchers: [(String?) -> Bool] = BrowserMeetingLifecycleAdapter.defaultTitleMatchers
    ) {
        self.shareableContent = ShareableContentSignal(eventLog: eventLog)
        self.titleMatchers = titleMatchers
    }

    public func start(
        context: MeetingLifecycleContext,
        handle: LifecycleAdapterHandle,
        sink: @escaping (PrimarySignalEvent) -> Void
    ) throws {
        shareableContent.onChange = { present in
            sink(PrimarySignalEvent(
                kind: .browserTabTitle,
                state: present ? .live : .ended,
                timestamp: Date(),
                context: context
            ))
        }
        let matchers = titleMatchers
        shareableContent.start(context: context) { title in
            matchers.contains { $0(title) }
        }
    }

    public func stop() {
        shareableContent.stop()
    }
}
