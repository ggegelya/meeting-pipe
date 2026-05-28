import ApplicationServices
import XCTest
@testable import MeetingPipeCore

final class LifecycleAdapterTests: XCTestCase {

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2", kind: .native, pid: 1234
    )

    private let zoomContext = MeetingLifecycleContext(
        bundleID: "us.zoom.xos", kind: .native, pid: 5678
    )

    private let webexContext = MeetingLifecycleContext(
        bundleID: "com.cisco.spark", kind: .native, pid: 9012
    )

    private let chromeContext = MeetingLifecycleContext(
        bundleID: "com.google.Chrome", kind: .browser, pid: 3456
    )

    private let meetPWAContext = MeetingLifecycleContext(
        bundleID: "com.google.Chrome.app.fmgjjmmmlfnkbppncabfkddbjimcfncm",
        kind: .browser, pid: 7890
    )

    func test_teams_adapter_advertises_teams_bundle_ids() {
        let adapter = NativeLifecycleAdapter(
            config: .teams, halBus: CoreAudioHALBus(), axBus: AXObserverBus()
        )
        XCTAssertEqual(adapter.kind, .native)
        XCTAssertTrue(adapter.bundleIDs.contains("com.microsoft.teams2"))
        XCTAssertTrue(adapter.bundleIDs.contains("com.microsoft.teams"))
    }

    func test_zoom_adapter_advertises_zoom_bundle_id() {
        let adapter = NativeLifecycleAdapter(
            config: .zoom, halBus: CoreAudioHALBus(), axBus: AXObserverBus()
        )
        XCTAssertEqual(adapter.kind, .native)
        XCTAssertEqual(adapter.bundleIDs, ["us.zoom.xos"])
    }

    func test_webex_adapter_covers_legacy_and_unified_bundles() {
        let adapter = NativeLifecycleAdapter(config: .webex, axBus: AXObserverBus())
        XCTAssertEqual(adapter.kind, .native)
        XCTAssertTrue(adapter.bundleIDs.contains("com.cisco.webexmeetingsapp"))
        XCTAssertTrue(adapter.bundleIDs.contains("com.cisco.spark"))
    }

    func test_browser_adapter_advertises_browser_kind() {
        let adapter = BrowserMeetingLifecycleAdapter()
        XCTAssertEqual(adapter.kind, .browser)
        XCTAssertTrue(adapter.bundleIDs.contains("com.google.Chrome"))
        XCTAssertTrue(adapter.bundleIDs.contains("com.apple.Safari"))
    }

    func test_browser_adapter_handles_known_browsers_and_chromium_pwas() {
        let adapter = BrowserMeetingLifecycleAdapter()
        // Advertised browsers.
        XCTAssertTrue(adapter.handles(bundleID: "com.google.Chrome"))
        XCTAssertTrue(adapter.handles(bundleID: "com.apple.Safari"))
        // Chromium PWAs (Google Meet installed as a desktop app, etc.):
        // the `<browser>.app.<hash>` hash is assigned per install.
        XCTAssertTrue(adapter.handles(bundleID: "com.google.Chrome.app.fmgjjmmmlfnkbppncabfkddbjimcfncm"))
        XCTAssertTrue(adapter.handles(bundleID: "com.microsoft.edgemac.app.aaaabbbbccccdddd"))
        XCTAssertTrue(adapter.handles(bundleID: "com.brave.Browser.app.zzzz"))
        // Not a browser, not a PWA. The Chrome helper shares the
        // browser prefix but is not an installed PWA.
        XCTAssertFalse(adapter.handles(bundleID: "com.acme.Notes"))
        XCTAssertFalse(adapter.handles(bundleID: "com.google.Chrome.helper"))
    }

    func test_isPWABundleID_matches_only_chromium_app_prefixes() {
        XCTAssertTrue(BrowserMeetingLifecycleAdapter.isPWABundleID("com.google.Chrome.app.hash"))
        XCTAssertTrue(BrowserMeetingLifecycleAdapter.isPWABundleID("com.microsoft.edgemac.app.hash"))
        XCTAssertFalse(BrowserMeetingLifecycleAdapter.isPWABundleID("com.google.Chrome"))
        XCTAssertFalse(BrowserMeetingLifecycleAdapter.isPWABundleID("org.mozilla.firefox"))
        XCTAssertFalse(BrowserMeetingLifecycleAdapter.isPWABundleID(""))
    }

    func test_matchesKnownMeetingPWA_admits_meeting_app_names() {
        XCTAssertTrue(BrowserMeetingLifecycleAdapter.matchesKnownMeetingPWA(localizedName: "Google Meet"))
        XCTAssertTrue(BrowserMeetingLifecycleAdapter.matchesKnownMeetingPWA(localizedName: "Meet"))
        XCTAssertTrue(BrowserMeetingLifecycleAdapter.matchesKnownMeetingPWA(localizedName: "Microsoft Teams"))
        XCTAssertTrue(BrowserMeetingLifecycleAdapter.matchesKnownMeetingPWA(localizedName: "Webex"))
        XCTAssertTrue(BrowserMeetingLifecycleAdapter.matchesKnownMeetingPWA(localizedName: "Zoom"))
        XCTAssertTrue(BrowserMeetingLifecycleAdapter.matchesKnownMeetingPWA(localizedName: "Slack"))
        // Case-insensitive + whitespace tolerant.
        XCTAssertTrue(BrowserMeetingLifecycleAdapter.matchesKnownMeetingPWA(localizedName: "  google meet  "))
    }

    func test_matchesKnownMeetingPWA_rejects_unrelated_names() {
        XCTAssertFalse(BrowserMeetingLifecycleAdapter.matchesKnownMeetingPWA(localizedName: "Notion"))
        XCTAssertFalse(BrowserMeetingLifecycleAdapter.matchesKnownMeetingPWA(localizedName: "Photopea"))
        XCTAssertFalse(BrowserMeetingLifecycleAdapter.matchesKnownMeetingPWA(localizedName: nil))
        XCTAssertFalse(BrowserMeetingLifecycleAdapter.matchesKnownMeetingPWA(localizedName: ""))
        XCTAssertFalse(BrowserMeetingLifecycleAdapter.matchesKnownMeetingPWA(localizedName: "   "))
        // "meet" as a bare token matches; "meets the eye" should not -
        // we only treat exact "meet" or "google meet" as a Google Meet
        // PWA, not arbitrary substrings.
        XCTAssertFalse(BrowserMeetingLifecycleAdapter.matchesKnownMeetingPWA(localizedName: "Meets The Eye"))
    }

    func test_native_adapter_handles_is_exact_match() {
        let teams = NativeLifecycleAdapter(config: .teams, halBus: CoreAudioHALBus(), axBus: AXObserverBus())
        XCTAssertTrue(teams.handles(bundleID: "com.microsoft.teams2"))
        // The default (native) dispatch is exact: a PWA-shaped id never
        // leaks into a native adapter.
        XCTAssertFalse(teams.handles(bundleID: "com.microsoft.teams2.app.hash"))
        XCTAssertFalse(teams.handles(bundleID: "us.zoom.xos"))
    }

    func test_teams_title_pattern_recognises_localised_meeting_token() {
        XCTAssertTrue(MeetingTitlePatterns.teams("Microsoft Teams Meeting | Standup"))
        XCTAssertTrue(MeetingTitlePatterns.teams("Besprechung in Microsoft Teams"))
        XCTAssertFalse(MeetingTitlePatterns.teams("Chat | Acme"))
    }

    func test_teams_title_pattern_matches_subject_titled_meeting_window() {
        // New-Teams meeting windows are "<subject> | Microsoft Teams" with no literal "meeting" token (the 8m47s false-stop regression).
        XCTAssertTrue(MeetingTitlePatterns.teams("Architecture priorities - Weekly sync | Microsoft Teams"))
    }

    func test_zoom_title_pattern_matches_zoom_meeting_strings() {
        XCTAssertTrue(MeetingTitlePatterns.zoom("Zoom Meeting"))
        XCTAssertTrue(MeetingTitlePatterns.zoom("Zoom - Standup"))
        XCTAssertFalse(MeetingTitlePatterns.zoom("Slack | Standup"))
    }

    func test_google_meet_pattern_requires_meet_substring() {
        XCTAssertTrue(MeetingTitlePatterns.googleMeet("Meet - abc-defg-hij"))
        XCTAssertFalse(MeetingTitlePatterns.googleMeet("Acme Inc - Mail"))
    }

    func test_browser_adapter_default_matchers_recognise_known_meeting_titles() {
        let matchers = BrowserMeetingLifecycleAdapter.defaultTitleMatchers
        let meet = "Meet - abc-defg-hij"
        let teams = "Microsoft Teams Meeting | Standup"
        let huddle = "Huddle - #engineering"
        let chat = "Slack - #general"

        XCTAssertTrue(matchers.contains { $0(meet) })
        XCTAssertTrue(matchers.contains { $0(teams) })
        XCTAssertTrue(matchers.contains { $0(huddle) })
        XCTAssertFalse(matchers.contains { $0(chat) })
    }

    func test_adapter_routing_picks_correct_adapter_per_bundle() {
        let teams = NativeLifecycleAdapter(config: .teams, halBus: CoreAudioHALBus(), axBus: AXObserverBus())
        let zoom = NativeLifecycleAdapter(config: .zoom, halBus: CoreAudioHALBus(), axBus: AXObserverBus())
        let webex = NativeLifecycleAdapter(config: .webex, axBus: AXObserverBus())
        let browser = BrowserMeetingLifecycleAdapter()
        let adapters: [LifecycleAdapter] = [teams, zoom, webex, browser]

        // Mirrors MeetingLifecycleCoordinator.engage's dispatch.
        func adapter(for context: MeetingLifecycleContext) -> LifecycleAdapter? {
            adapters.first { $0.kind == context.kind && $0.handles(bundleID: context.bundleID) }
        }

        XCTAssertTrue(adapter(for: teamsContext) === teams)
        XCTAssertTrue(adapter(for: zoomContext) === zoom)
        XCTAssertTrue(adapter(for: webexContext) === webex)
        XCTAssertTrue(adapter(for: chromeContext) === browser)
        // A Chromium PWA routes to the browser adapter even though its
        // per-install bundle ID is in no fixed list (TECH-I5).
        XCTAssertTrue(adapter(for: meetPWAContext) === browser)
    }

    // MARK: - Leave-button late-arm

    func test_native_adapters_armLeaveButton_before_start_is_a_safe_noop() {
        // The orchestrator calls armLeaveButton at recording-start;
        // before start() there is no captured context, so each native
        // adapter must absorb the late-arm rather than crash.
        let element = AXUIElementCreateSystemWide()
        let adapters: [LifecycleAdapter] = [
            NativeLifecycleAdapter(config: .teams, halBus: CoreAudioHALBus(), axBus: AXObserverBus()),
            NativeLifecycleAdapter(config: .zoom, halBus: CoreAudioHALBus(), axBus: AXObserverBus()),
            NativeLifecycleAdapter(config: .webex, axBus: AXObserverBus()),
            NativeLifecycleAdapter(config: .slack, axBus: AXObserverBus()),
        ]
        for adapter in adapters {
            adapter.armLeaveButton(element)
        }
    }

    func test_browser_adapter_armLeaveButton_is_a_noop() {
        // The browser adapter has no AX Leave-button signal; it relies
        // on the protocol's default no-op.
        BrowserMeetingLifecycleAdapter().armLeaveButton(AXUIElementCreateSystemWide())
    }

    // MARK: - Browser adapter signal wiring (GAP 2)

    /// A browser adapter with an inert shareable-content signal so a
    /// test can drive the workspace / window-title signals in isolation.
    private func makeBrowserAdapter(
        workspace: WorkspaceSignal,
        windowTitle: WindowTitleSignal
    ) -> BrowserMeetingLifecycleAdapter {
        BrowserMeetingLifecycleAdapter(
            shareableContent: ShareableContentSignal(probe: { nil }, scheduler: { _, _ in {} }),
            workspace: workspace,
            windowTitle: windowTitle,
            titleMatchers: BrowserMeetingLifecycleAdapter.defaultTitleMatchers,
            eventLog: NoopEventLog()
        )
    }

    func test_browser_adapter_emits_ended_on_meeting_app_termination() throws {
        let workspace = WorkspaceSignal(probe: { _ in nil })
        let adapter = makeBrowserAdapter(
            workspace: workspace,
            windowTitle: WindowTitleSignal(axBus: AXObserverBus(), probe: { _ in nil })
        )
        var events: [PrimarySignalEvent] = []
        try adapter.start(context: meetPWAContext, handle: LifecycleAdapterHandle()) {
            events.append($0)
        }
        defer { adapter.stop() }

        workspace.handleTerminated(reason: "test")

        let terminated = events.first { $0.kind == .workspaceAppTerminated }
        XCTAssertEqual(terminated?.state, .ended)
        XCTAssertEqual(terminated?.context.bundleID, meetPWAContext.bundleID)
    }

    func test_browser_adapter_skips_window_title_without_a_meeting_window() throws {
        // No meeting window in the handle (a regular tabbed browser):
        // the window-title signal stays dormant, so no title events.
        let adapter = makeBrowserAdapter(
            workspace: WorkspaceSignal(probe: { _ in nil }),
            windowTitle: WindowTitleSignal(axBus: AXObserverBus(), probe: { _ in "Meet - abc-defg" })
        )
        var events: [PrimarySignalEvent] = []
        try adapter.start(context: meetPWAContext, handle: LifecycleAdapterHandle()) {
            events.append($0)
        }
        defer { adapter.stop() }
        XCTAssertFalse(events.contains { $0.kind == .windowTitleLeftPattern })
    }

    func test_browser_adapter_window_title_maps_meeting_pattern_to_live_then_ended() throws {
        // PWA context: the handle carries a meeting window, so the
        // window-title signal is wired. A title matching the meeting
        // pattern is .live; a title that left the pattern is .ended.
        var currentTitle: String? = "Meet - abc-defg-hij"
        let windowTitle = WindowTitleSignal(axBus: AXObserverBus(), probe: { _ in currentTitle })
        let adapter = makeBrowserAdapter(
            workspace: WorkspaceSignal(probe: { _ in nil }),
            windowTitle: windowTitle
        )
        var events: [PrimarySignalEvent] = []
        try adapter.start(
            context: meetPWAContext,
            handle: LifecycleAdapterHandle(meetingWindow: AXUIElementCreateSystemWide())
        ) { events.append($0) }
        defer { adapter.stop() }

        currentTitle = "Google Meet"
        windowTitle.evaluate(reason: "test")

        let titleStates = events
            .filter { $0.kind == .windowTitleLeftPattern }
            .map(\.state)
        XCTAssertEqual(titleStates, [.live, .ended])
    }

    func test_browser_adapter_meeting_pwa_reads_live_from_identity_without_hyphen_title() throws {
        // Solo "New Meeting" via the Google Meet PWA: the window title is
        // still "Google Meet" (no hyphenated code), so the title matchers
        // reject it. The adapter must read .live from the PWA identity so
        // the prompt fires, and must NOT emit a premature .ended from the
        // bootstrap title (which would close the meeting the instant it
        // opened).
        let shareable = ShareableContentSignal(
            probe: {
                [ShareableContentSignal.ShareableWindowSummary(
                    bundleIdentifier: self.meetPWAContext.bundleID,
                    title: "Google Meet"
                )]
            },
            scheduler: { _, _ in {} }
        )
        let adapter = BrowserMeetingLifecycleAdapter(
            shareableContent: shareable,
            workspace: WorkspaceSignal(probe: { _ in nil }),
            windowTitle: WindowTitleSignal(axBus: AXObserverBus(), probe: { _ in "Google Meet" }),
            titleMatchers: BrowserMeetingLifecycleAdapter.defaultTitleMatchers,
            eventLog: NoopEventLog()
        )
        var events: [PrimarySignalEvent] = []
        try adapter.start(
            context: meetPWAContext,
            handle: LifecycleAdapterHandle(meetingWindow: AXUIElementCreateSystemWide())
        ) { events.append($0) }
        defer { adapter.stop() }

        XCTAssertEqual(events.first { $0.kind == .browserTabTitle }?.state, .live)
        XCTAssertFalse(events.contains { $0.kind == .windowTitleLeftPattern && $0.state == .ended })
    }

    func test_browser_adapter_regular_browser_does_not_read_live_from_identity() throws {
        // The identity shortcut is scoped to PWAs. A plain browser with a
        // non-meeting tab title must not read as live, or every open
        // browser would raise the prompt.
        let shareable = ShareableContentSignal(
            probe: {
                [ShareableContentSignal.ShareableWindowSummary(
                    bundleIdentifier: self.chromeContext.bundleID,
                    title: "Inbox - Gmail"
                )]
            },
            scheduler: { _, _ in {} }
        )
        let adapter = BrowserMeetingLifecycleAdapter(
            shareableContent: shareable,
            workspace: WorkspaceSignal(probe: { _ in nil }),
            windowTitle: WindowTitleSignal(axBus: AXObserverBus(), probe: { _ in nil }),
            titleMatchers: BrowserMeetingLifecycleAdapter.defaultTitleMatchers,
            eventLog: NoopEventLog()
        )
        var events: [PrimarySignalEvent] = []
        try adapter.start(context: chromeContext, handle: LifecycleAdapterHandle()) {
            events.append($0)
        }
        defer { adapter.stop() }

        XCTAssertFalse(events.contains { $0.kind == .browserTabTitle && $0.state == .live })
    }
}
