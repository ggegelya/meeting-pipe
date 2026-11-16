import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// DET17 guards 1 and 2: a browser source is never recorded without a click, and a skipped or
/// timed-out browser prompt is remembered per tab rather than per browser.
@MainActor
final class BrowserPromptGuardTests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!
    /// The controller holds its host `unowned`, and a discovery's AX build lands after the test body.
    private var hosts: [FakeSessionHost] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("det17-\(UUID().uuidString)", isDirectory: true)
        logs = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func chrome(_ title: String) -> AppSource {
        AppSource(
            bundleID: "com.google.Chrome", displayName: "Google Chrome", kind: .browser,
            tabKey: AppSource.browserTabKey(bundleID: "com.google.Chrome", title: title)
        )
    }
    private let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")

    private func makeController(defaultAction: String = "skip") throws -> (MeetingSessionController, FakeSessionHost) {
        let host = FakeSessionHost(tempDir: tempDir)
        hosts.append(host)
        let config = tempDir.appendingPathComponent("config-\(UUID().uuidString).toml")
        try "[detection]\ndefault_prompt_action = \"\(defaultAction)\"\n".write(to: config, atomically: true, encoding: .utf8)
        host.configStore = ConfigStore(configURL: config)
        return (MeetingSessionController(coordinator: host), host)
    }

    private func waitUntil(_ predicate: () -> Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 500_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func rows(_ action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    // MARK: - Guard 1

    func test_aBrowserTimeoutUnderRecord_recordsNothing_andLogsTheEffectiveSkip() async throws {
        let (controller, host) = try makeController(defaultAction: "record")
        XCTAssertEqual(host.configStore?.defaultPromptAction, "record")
        host.livePromptTimeoutSec = 0.01
        let tab = chrome("Meet: \"Placeholder sync\"")
        controller.handleDiscovery(tab)
        controller.handleMeetingStarted(source: tab)
        await waitUntil({ host.stateMachine.current == .idle }, "the timeout")

        XCTAssertEqual(host.recorderSpy.startCallCount, 0)
        XCTAssertEqual(rows("prompt_timeout").last?["default_action"] as? String, "record")
        XCTAssertEqual(rows("prompt_timeout").last?["effective_action"] as? String, "skip")
    }

    func test_aNativeTimeoutUnderRecord_stillRecords() async throws {
        let (controller, host) = try makeController(defaultAction: "record")
        host.livePromptTimeoutSec = 0.01
        controller.handleMeetingStarted(source: teams)
        await waitUntil({ host.recorderSpy.startCallCount == 1 }, "the auto-record")
        XCTAssertEqual(rows("prompt_timeout").last?["effective_action"] as? String, "record")
    }

    func test_anAutoConsentedBrowser_prompts() throws {
        let (controller, host) = try makeController()
        let tab = chrome("Meet: \"Placeholder sync\"")
        host.consent.setAutoConsented(bundleID: tab.bundleID, value: true)
        controller.handleMeetingStarted(source: tab)
        XCTAssertEqual(host.promptSpy.presentCount, 1)
        XCTAssertEqual(host.recorderSpy.startCallCount, 0)
    }

    func test_theEffectiveActionTable() {
        typealias C = MeetingSessionController
        XCTAssertEqual(C.effectiveTimeoutAction(configured: "record", kind: .browser), "skip")
        XCTAssertEqual(C.effectiveTimeoutAction(configured: "byo", kind: .browser), "skip")
        XCTAssertEqual(C.effectiveTimeoutAction(configured: "skip", kind: .browser), "skip")
        XCTAssertEqual(C.effectiveTimeoutAction(configured: "record", kind: .native), "record")
    }

    // MARK: - Guard 2

    func test_aTimedOutBrowserPrompt_isRememberedForThatTabOnly() async throws {
        let (controller, host) = try makeController()
        host.livePromptTimeoutSec = 0.01
        let first = chrome("Meet: \"Placeholder sync\"")
        controller.handleDiscovery(first)
        controller.handleMeetingStarted(source: AppSource(bundleID: first.bundleID, displayName: first.displayName, kind: .browser))
        await waitUntil({ host.stateMachine.current == .idle }, "the timeout")

        XCTAssertFalse(host.stateMachine.isCoolingDown(bundleID: first.bundleID, cooldownSec: 60))
        XCTAssertFalse(host.stateMachine.isSkipLatched(bundleID: first.bundleID))
        XCTAssertTrue(host.stateMachine.isPromptHeld(bundleID: first.bundleID, tabKey: first.tabKey), "the same tab is held")

        let second = chrome("Meet: \"Placeholder review\"")
        XCTAssertFalse(host.stateMachine.isPromptHeld(bundleID: second.bundleID, tabKey: second.tabKey))
        controller.handleDiscovery(second)
        controller.handleMeetingStarted(source: AppSource(bundleID: second.bundleID, displayName: second.displayName, kind: .browser))
        XCTAssertEqual(host.promptSpy.presentCount, 2, "a second Meet title in the same browser prompts")
    }

    func test_aSkippedBrowserPrompt_armsNoBundleCooldown_andHoldsOnlyItsTab() throws {
        let (controller, host) = try makeController()
        let first = chrome("Meet: \"Placeholder sync\"")
        controller.handleDiscovery(first)
        let prompted = AppSource(bundleID: first.bundleID, displayName: first.displayName, kind: .browser)
        controller.handleMeetingStarted(source: prompted)
        controller.resolvePromptPick(.skip, source: prompted)

        XCTAssertFalse(host.stateMachine.isCoolingDown(bundleID: first.bundleID, cooldownSec: 60))
        XCTAssertTrue(host.stateMachine.isSkipLatched(bundleID: first.bundleID))
        controller.handleMeetingStarted(source: prompted)
        XCTAssertEqual(host.promptSpy.presentCount, 1, "the same tab stays skipped")
        XCTAssertEqual(host.stateMachine.liveSuppressedCandidate(), prompted, "the way back stays offered")

        let second = chrome("Meet: \"Placeholder review\"")
        controller.handleDiscovery(second)
        controller.handleMeetingStarted(source: prompted)
        XCTAssertEqual(host.promptSpy.presentCount, 2)
    }

    /// A native hold is still bundle-wide.
    func test_aNativeSkip_stillHoldsTheWholeBundle() throws {
        let (controller, host) = try makeController()
        controller.handleMeetingStarted(source: teams)
        controller.resolvePromptPick(.skip, source: teams)
        XCTAssertTrue(host.stateMachine.isCoolingDown(bundleID: teams.bundleID, cooldownSec: 60))
        XCTAssertTrue(host.stateMachine.isPromptHeld(bundleID: teams.bundleID, tabKey: 42))
    }

    /// Review fix: Chrome's speaker glyph comes and goes on a Meet tab mid-call, and the held tab
    /// must stay held through it.
    func test_theSpeakerGlyphDoesNotChangeTheTab() {
        XCTAssertEqual(
            AppSource.browserTabKey(bundleID: "com.google.Chrome", title: "Meet: \"Placeholder sync\""),
            AppSource.browserTabKey(bundleID: "com.google.Chrome", title: "Meet: \"Placeholder sync\" 🔊")
        )
        XCTAssertNotEqual(
            AppSource.browserTabKey(bundleID: "com.google.Chrome", title: "Meet: \"Placeholder sync\""),
            AppSource.browserTabKey(bundleID: "com.google.Chrome", title: "Meet: \"Placeholder review\"")
        )
    }

    /// Re-sighting the same tab after a timeout, through discovery and the lifecycle start, does not
    /// prompt again, even with the glyph now showing.
    func test_theSameTabResighted_isNotPromptedAgain() async throws {
        let (controller, host) = try makeController()
        host.livePromptTimeoutSec = 0.01
        let tab = chrome("Meet: \"Placeholder sync\"")
        let prompted = AppSource(bundleID: tab.bundleID, displayName: tab.displayName, kind: .browser)
        controller.handleDiscovery(tab)
        controller.handleMeetingStarted(source: prompted)
        await waitUntil({ host.stateMachine.current == .idle }, "the timeout")

        controller.handleDiscovery(chrome("Meet: \"Placeholder sync\" 🔊"))
        controller.handleMeetingStarted(source: prompted)
        XCTAssertEqual(host.promptSpy.presentCount, 1)
    }

    /// A skip with no tab key (a Meet PWA) stays bundle-wide, cooldown included.
    func test_aKeylessBrowserSkip_staysBundleWide() throws {
        let (controller, host) = try makeController()
        let pwa = AppSource(bundleID: "com.google.Chrome.app.fake", displayName: "Google Meet", kind: .browser)
        controller.handleMeetingStarted(source: pwa)
        controller.resolvePromptPick(.skip, source: pwa)
        XCTAssertTrue(host.stateMachine.isCoolingDown(bundleID: pwa.bundleID, cooldownSec: 60))
    }
}
