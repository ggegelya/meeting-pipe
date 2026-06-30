import Foundation

/// Browser-hosted meeting adapter (Google Meet, Teams web, Webex web, Slack huddles, Chromium PWAs).
/// Browsers expose no per-tab AX Leave button and no per-tab mic state via public Apple APIs (macOS 14-15),
/// so the adapter fuses `ShareableContentSignal` + `WorkspaceSignal` for regular browsers, adding
/// `WindowTitleSignal` for PWA contexts only (an AX title change on a shared tabbed window is usually a tab switch, not a meeting end).
/// "Teams in Chrome/Edge/Arc" is handled here through the same title patterns as the native adapter.
public final class BrowserMeetingLifecycleAdapter: LifecycleAdapter {

    public let bundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.apple.Safari",
        "org.mozilla.firefox"
    ]
    public let kind: MeetingLifecycleContext.Kind = .browser

    /// Prefixes for Chromium PWA bundle IDs. A PWA runs as `<browser-bundle>.app.<hash>` where the hash is
    /// per-install and can't be enumerated (TECH-I5), so detection is by prefix. Firefox has no PWA mechanism;
    /// Safari "Add to Dock" uses a different scheme and is deferred.
    public static let pwaBundleIDPrefixes: [String] = [
        "com.google.Chrome.app.",
        "com.microsoft.edgemac.app.",
        "com.brave.Browser.app."
    ]

    /// True when `bundleID` matches a known Chromium PWA prefix.
    public static func isPWABundleID(_ bundleID: String) -> Bool {
        pwaBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Match a Chromium PWA by `NSRunningApplication.localizedName`. The manifest name (e.g. "Google Meet", "Microsoft Teams")
    /// is durable across the meeting lifecycle; the window title is not - it cycles through "Meet", "Meeting details",
    /// "Google Meet" before the hyphenated in-call code appears. The scanner uses this as a fallback when the title-matcher
    /// rejects a real meeting because the code is not yet in the title (solo "New Meeting" bootstrap).
    public static func matchesKnownMeetingPWA(localizedName: String?) -> Bool {
        guard let lowered = localizedName?.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !lowered.isEmpty else {
            return false
        }
        return pwaLocalizedNameRecognizers.contains { $0(lowered) }
    }

    /// Lowercased-name predicates for known meeting PWAs. Intentionally tight - broad substrings over-admit unrelated apps.
    private static let pwaLocalizedNameRecognizers: [(String) -> Bool] = [
        { $0.contains("google meet") || $0 == "meet" },
        { $0.contains("microsoft teams") || $0 == "teams" },
        { $0.contains("webex") },
        { $0.contains("zoom") },
        { $0.contains("slack") }
    ]

    /// Accepts the advertised browser bundle IDs plus any Chromium PWA bundle ID.
    public func handles(bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
            || BrowserMeetingLifecycleAdapter.isPWABundleID(bundleID)
    }

    /// Ordered title matchers. First match wins; no match reads as `.ended`, which correctly handles the Meet "left the call" title transition.
    /// Browser-scoped variants: a browser title-match stands alone in `MeetingSourceScorer` (no per-tab Leave/mute to
    /// corroborate), so these key off vendor brand/structure (`browserTeams`, `browserWebex`, the Meet code) rather than
    /// the bare localized "meeting" stem the native matchers allow. Without this, any page titled "...Meeting..." (a Jira
    /// board, a "Meeting notes" doc) raised an uncorroborated Record prompt (the 2026-06-30 false positive).
    public static let defaultTitleMatchers: [(String?) -> Bool] = [
        MeetingTitlePatterns.googleMeet,
        MeetingTitlePatterns.browserTeams,
        MeetingTitlePatterns.browserWebex,
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

    /// Designated initializer with injectable signals for testing.
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

        // PRIMARY: a meeting-titled window owned by this bundle exists in the shareable-content snapshot.
        // START3/AUD-4: PWAs use the SAME strict title gate as plain browsers. The old `isMeetingPWA`
        // bypass treated any on-screen PWA window as live, so a meeting-named PWA idling on its landing
        // page ("Google Meet") read live forever and the false prompt persisted until a timeout-skip.
        // A genuine in-room call always carries a hyphenated title ("Meet - abc-defg-hij") that the
        // matchers accept, and dropping the bypass gives the PWA a real end signal (the landing-page
        // title now reads not-live) it previously never had.
        shareableContent.onChange = { present in
            sink(PrimarySignalEvent(
                kind: .browserTabTitle,
                state: present ? .live : .ended,
                timestamp: Date(),
                context: context
            ))
        }
        shareableContent.start(context: context) { title in
            matchers.contains { $0(title) }
        }

        // PRIMARY: process termination. For a PWA, closing the meeting window quits the process - definitive
        // end, no TCC needed, and the only signal left when Screen Recording is denied.
        workspace.onTerminated = { endedContext in
            sink(PrimarySignalEvent(
                kind: .workspaceAppTerminated,
                state: .ended,
                timestamp: Date(),
                context: endedContext
            ))
        }
        workspace.start(context: context)

        // PRIMARY: AX title transition. Wired for PWA contexts only (MeetingAXHandleBuilder resolves a
        // window only there). Failure degrades to the two signals above rather than failing engage.
        if let window = handle.meetingWindow {
            // Gate "ended" on having seen the in-call title at least once. During PWA solo bootstrap
            // the title is "Google Meet" before the hyphenated code appears; emitting "ended" immediately
            // would close the meeting the instant shareable-content opened it.
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
