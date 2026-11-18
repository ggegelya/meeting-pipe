import XCTest
@testable import MeetingPipeCore

final class MicGateAdaptersStep6Tests: XCTestCase {

    /// T13: loaded per test and thrown, not force-tried in a static initialiser: a trap there killed the
    /// xctest process, so one broken resource bundle read as a crash with every later test unrun.
    private var catalogue: MuteLabels!

    override func setUpWithError() throws {
        try super.setUpWithError()
        catalogue = try MuteLabelsLoader.loadDefault()
    }

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2", kind: .native, pid: 1234
    )

    func test_webex_mute_adapter_routes_both_bundle_ids() {
        let adapter = NativeMuteAdapter(config: .webex, axBus: AXObserverBus(), catalogue: catalogue)
        XCTAssertEqual(adapter.app, "webex")
        XCTAssertTrue(adapter.bundleIDs.contains("com.cisco.webexmeetingsapp"))
        XCTAssertTrue(adapter.bundleIDs.contains("com.cisco.spark"))
    }

    func test_meet_mute_adapter_covers_browser_bundles() {
        let adapter = NoOpMuteAdapter(config: .meet)
        XCTAssertEqual(adapter.app, "meet")
        XCTAssertTrue(adapter.bundleIDs.contains("com.google.Chrome"))
    }

    func test_browser_mute_adapter_distinct_from_meet() {
        let meet = NoOpMuteAdapter(config: .meet)
        let browser = NoOpMuteAdapter(config: .browser)
        XCTAssertEqual(meet.bundleIDs, browser.bundleIDs)
        XCTAssertNotEqual(meet.app, browser.app)
    }

    func test_meet_adapter_emits_no_signal_log_on_start() throws {
        let log = RecordingEventLog()
        let adapter = NoOpMuteAdapter(config: .meet, eventLog: log)
        try adapter.start(
            context: MeetingLifecycleContext(bundleID: "com.google.Chrome", kind: .browser, pid: 99),
            handle: MicGateAdapterHandle(),
            sink: { _ in }
        )
        XCTAssertTrue(log.entries.contains { $0.action == "meet_adapter_no_ax_signal" })
    }
}

final class MuteLabelsLocaleCoverageTests: XCTestCase {

    /// T13: loaded per test and thrown, not force-tried in a static initialiser: a trap there killed the
    /// xctest process, so one broken resource bundle read as a crash with every later test unrun.
    private var catalogue: MuteLabels!

    override func setUpWithError() throws {
        try super.setUpWithError()
        catalogue = try MuteLabelsLoader.loadDefault()
    }

    private static let apps = ["teams", "zoom", "slack", "webex"]
    private static let locales = ["en", "de", "es", "fr", "ja", "pt", "ru"]

    func test_every_app_has_every_required_locale() {
        for app in Self.apps {
            for locale in Self.locales {
                XCTAssertNotNil(
                    catalogue.entry(app: app, locale: locale),
                    "Missing TOML entry for \(app).\(locale)"
                )
            }
        }
    }

    func test_each_locale_has_at_least_one_label() {
        for app in Self.apps {
            for locale in Self.locales {
                guard let entry = catalogue.entry(app: app, locale: locale) else { continue }
                XCTAssertFalse(
                    entry.isEmpty,
                    "Catalogue entry \(app).\(locale) has no labels"
                )
            }
        }
    }

    func test_japanese_label_recognises_unmute_action() {
        let state = catalogue.recognize(
            app: "teams", locale: "ja",
            title: "ミュート解除", help: nil, description: nil
        )
        XCTAssertEqual(state, .muted)
    }
}
