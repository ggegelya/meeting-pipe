import Foundation

/// Browser-hosted meeting adapter. Covers Google Meet, Teams web,
/// Webex web, Slack huddles, and Chromium PWAs (Meet / Teams / etc.
/// installed as desktop apps).
///
/// Browsers expose tab content as a single AX window per browser, so
/// `AXLeaveButton` is unavailable, and they expose no per-tab mic
/// state via any public Apple API as of macOS 14-15. The adapter
/// fuses up to three PRIMARY signals: `ShareableContentSignal` (a
/// meeting-titled window owned by the bundle), `WorkspaceSignal` (the
/// meeting-app process terminating), and - for PWA contexts only -
/// `WindowTitleSignal` (an AX title transition off the meeting
/// pattern). A regular browser is left on the first two: an AX title
/// change on a shared tabbed window is usually a tab switch.
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

    /// Bundle-ID prefixes for Chromium "installed PWA" apps. A PWA
    /// installed from Chrome / Edge / Brave runs as its own process
    /// under `<browser-bundle-id>.app.<hash>`, where the hash is
    /// assigned per install and so cannot be listed as a fixed
    /// bundle ID (TECH-I5). Detection is by prefix instead. Firefox
    /// has no PWA mechanism; Safari "Add to Dock" web apps use a
    /// different scheme and are left for a verified follow-up.
    public static let pwaBundleIDPrefixes: [String] = [
        "com.google.Chrome.app.",
        "com.microsoft.edgemac.app.",
        "com.brave.Browser.app."
    ]

    /// True when `bundleID` is a Chromium-installed PWA (see
    /// `pwaBundleIDPrefixes`).
    public static func isPWABundleID(_ bundleID: String) -> Bool {
        pwaBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Recognise a Chromium-installed PWA by the localised name macOS
    /// reports for `NSRunningApplication`. The name is set by the PWA's
    /// web manifest at install time (Google Meet, Microsoft Teams,
    /// etc.) and is durable across the meeting lifecycle, unlike the
    /// window title which goes through "Meet", "Meeting details",
    /// "Google Meet" before settling on "Meet - <code>". The scanner
    /// uses this as a fallback when the title-matcher rejects a real
    /// meeting because its hyphen-bearing code is not yet in the title
    /// (typical when starting a meeting solo via the PWA).
    public static func matchesKnownMeetingPWA(localizedName: String?) -> Bool {
        guard let lowered = localizedName?.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !lowered.isEmpty else {
            return false
        }
        return pwaLocalizedNameRecognizers.contains { $0(lowered) }
    }

    /// Lowercased-name predicates that identify the localised name of a
    /// known meeting PWA. Add new entries here when expanding to a new
    /// meeting app's PWA. The list is intentionally tight; matching a
    /// generic substring would over-admit casual web apps the user
    /// installed for other reasons.
    private static let pwaLocalizedNameRecognizers: [(String) -> Bool] = [
        { $0.contains("google meet") || $0 == "meet" },
        { $0.contains("microsoft teams") || $0 == "teams" },
        { $0.contains("webex") },
        { $0.contains("zoom") },
        { $0.contains("slack") }
    ]

    /// Accepts the advertised browsers plus any Chromium PWA bundle
    /// ID. The coordinator dispatches `.browser`-kind contexts here.
    public func handles(bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
            || BrowserMeetingLifecycleAdapter.isPWABundleID(bundleID)
    }

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
    private let workspace: WorkspaceSignal
    private let windowTitle: WindowTitleSignal
    private let titleMatchers: [(String?) -> Bool]
    private let eventLog: EventLog

    public convenience init(
        axBus: AXObserverBus = AXObserverBus(),
        eventLog: EventLog = NoopEventLog(),
        titleMatchers: [(String?) -> Bool] = BrowserMeetingLifecycleAdapter.defaultTitleMatchers
    ) {
        self.init(
            shareableContent: ShareableContentSignal(eventLog: eventLog),
            workspace: WorkspaceSignal(eventLog: eventLog),
            windowTitle: WindowTitleSignal(axBus: axBus, eventLog: eventLog),
            titleMatchers: titleMatchers,
            eventLog: eventLog
        )
    }

    /// Designated initializer with injectable signals. Production goes
    /// through the convenience init above; tests supply fakes.
    init(
        shareableContent: ShareableContentSignal,
        workspace: WorkspaceSignal,
        windowTitle: WindowTitleSignal,
        titleMatchers: [(String?) -> Bool],
        eventLog: EventLog
    ) {
        self.shareableContent = shareableContent
        self.workspace = workspace
        self.windowTitle = windowTitle
        self.titleMatchers = titleMatchers
        self.eventLog = eventLog
    }

    public func start(
        context: MeetingLifecycleContext,
        handle: LifecycleAdapterHandle,
        sink: @escaping (PrimarySignalEvent) -> Void
    ) throws {
        let matchers = titleMatchers

        // A Chromium meeting PWA (Google Meet / Teams / etc. installed as
        // a standalone app) that the discovery scanner admitted on its
        // localised name rather than a title match: its window title sits
        // on a non-hyphenated string ("Meet", "Google Meet", "Meeting
        // details") for the first seconds of a solo "New Meeting" before
        // the in-call code appears, so the title matchers reject it. For
        // such a context the PWA simply owning an on-screen window is the
        // live signal; the scanner already vetted it as a meeting source
        // and only ever engages PWA bundles through that gate. Regular
        // tabbed browsers keep the strict title gate so a non-meeting tab
        // never reads as live.
        let isMeetingPWA = BrowserMeetingLifecycleAdapter.isPWABundleID(context.bundleID)

        // PRIMARY: a window owned by this bundle still matches a
        // meeting-title pattern in the shareable-content snapshot.
        shareableContent.onChange = { present in
            sink(PrimarySignalEvent(
                kind: .browserTabTitle,
                state: present ? .live : .ended,
                timestamp: Date(),
                context: context
            ))
        }
        shareableContent.start(context: context) { title in
            isMeetingPWA || matchers.contains { $0(title) }
        }

        // PRIMARY: meeting-app process termination. For a PWA, closing
        // the meeting window quits its process - a definitive end that
        // needs no TCC permission and is the only signal left if Screen
        // Recording is denied. A tab-in-browser meeting outlives a tab
        // close, so this rarely fires there.
        workspace.onTerminated = { endedContext in
            sink(PrimarySignalEvent(
                kind: .workspaceAppTerminated,
                state: .ended,
                timestamp: Date(),
                context: endedContext
            ))
        }
        workspace.start(context: context)

        // PRIMARY: AX window-title transition off the meeting pattern.
        // Wired only when the handle carries a meeting window, which
        // MeetingAXHandleBuilder resolves for PWA contexts only. A
        // WindowTitleSignal failure degrades to the two signals above
        // rather than failing the engage.
        if let window = handle.meetingWindow {
            // Suppress an "ended" before the in-call title has ever
            // matched. During a PWA's solo bootstrap the title sits on a
            // non-meeting string ("Google Meet") before the hyphenated
            // code appears; emitting "ended" then would close the meeting
            // the instant shareable-content opened it. Once the in-call
            // pattern has been seen, a transition off it still ends the
            // recording promptly (the user left but kept the window open).
            var hasMatchedMeetingTitle = false
            windowTitle.onChange = { title in
                let live = matchers.contains { $0(title) }
                if live { hasMatchedMeetingTitle = true }
                guard live || hasMatchedMeetingTitle else { return }
                sink(PrimarySignalEvent(
                    kind: .windowTitleLeftPattern,
                    state: live ? .live : .ended,
                    timestamp: Date(),
                    context: context
                ))
            }
            do {
                try windowTitle.start(context: context, window: window)
            } catch {
                eventLog.emit(category: "signal", action: "window_title_signal_unavailable", attributes: [
                    "bundle_id": context.bundleID,
                    "error": "\(error)"
                ])
            }
        }
    }

    public func stop() {
        shareableContent.stop()
        workspace.stop()
        windowTitle.stop()
    }
}
