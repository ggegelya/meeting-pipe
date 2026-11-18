import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// UX97: an "Always for <app>" pick lands on the list Preferences renders (`ConfigStore.autoConsentApps`,
/// with its remove tag), and removing it there makes the next sighting prompt, with no restart. The
/// host reads `liveAutoConsentApps` through a real temp-file `ConfigStore`, as `Coordinator` does.
@MainActor
final class AlwaysAllowlistTests: XCTestCase {
    private var tempDir: URL!
    private var hosts: [FakeSessionHost] = []
    private let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ux97-\(UUID().uuidString)", isDirectory: true)
        let logs = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func makeController() -> (MeetingSessionController, FakeSessionHost, ConfigStore) {
        let host = FakeSessionHost(tempDir: tempDir)
        hosts.append(host)
        let store = ConfigStore(configURL: tempDir.appendingPathComponent("config.toml"))
        host.configStore = store
        host.recorderSpy.lastSystemFires = 1
        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20261118-120000.wav")
        host.recorderSpy.startBehaviour = .succeed
        let controller = MeetingSessionController(coordinator: host)
        controller.engageSeams.buildHandles = { _, _ in nil }
        return (controller, host, store)
    }

    private func waitUntil(_ predicate: () -> Bool, _ what: String) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    func test_anAlwaysPick_appearsInTheAllowlistPreferencesRenders() async {
        let (controller, host, store) = makeController()
        XCTAssertTrue(store.everyMeetingPrompts)
        controller.handleMeetingStarted(source: teams)
        XCTAssertEqual(host.stateMachine.current, .prompting(source: teams))

        controller.chooseAlways(source: teams)

        XCTAssertEqual(store.autoConsentApps, [teams.bundleID])
        XCTAssertFalse(store.everyMeetingPrompts)
        await waitUntil({ host.recorderSpy.startCallCount == 1 }, "the recording")
        controller.forceStop(reason: "test")
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
    }

    func test_anAllowlistedApp_recordsWithoutAPrompt() async {
        let (controller, host, store) = makeController()
        store.addAutoConsentApp(teams.bundleID)
        controller.handleMeetingStarted(source: teams)
        await waitUntil({ host.recorderSpy.startCallCount == 1 }, "the auto-consent start")
        XCTAssertEqual(host.promptSpy.presentCount, 0)
        controller.forceStop(reason: "test")
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
    }

    func test_removingIt_makesTheNextSightingPrompt() {
        let (controller, host, store) = makeController()
        store.addAutoConsentApp(teams.bundleID)
        store.removeAutoConsentApp(teams.bundleID)
        XCTAssertTrue(store.everyMeetingPrompts)

        controller.handleMeetingStarted(source: teams)

        XCTAssertEqual(host.stateMachine.current, .prompting(source: teams))
        XCTAssertEqual(host.promptSpy.presentCount, 1)
        XCTAssertEqual(host.recorderSpy.startCallCount, 0)
    }

    func test_theAllowlistHelpers_trimAndDoNotDuplicate() {
        let store = ConfigStore(configURL: tempDir.appendingPathComponent("helpers.toml"))
        XCTAssertTrue(store.addAutoConsentApp(" us.zoom.xos "))
        XCTAssertFalse(store.addAutoConsentApp("us.zoom.xos"))
        XCTAssertFalse(store.addAutoConsentApp("   "))
        XCTAssertEqual(store.autoConsentApps, ["us.zoom.xos"])
    }
}
