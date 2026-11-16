import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// SEC18: the pure decision is tested in `LibrarySyncStartWarningTests`; this fences the *calling*
/// (daemon/CLAUDE.md, END9): a start through `MeetingSessionController` has to reach the notifier
/// with the resolved capture mode and the directory the recorder is writing to.
@MainActor
final class LibrarySyncStartCallSiteTests: XCTestCase {

    private var tempDir: URL!
    /// The controller holds its host `unowned` and a parked start outlives the test body, so both are
    /// kept for the whole test (the shape `StartInFlightTests` uses).
    private var hosts: [FakeSessionHost] = []
    private var controllers: [MeetingSessionController] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sec18-start-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", tempDir.appendingPathComponent("logs").path, 1)
    }

    override func tearDownWithError() throws {
        controllers.removeAll()
        hosts.removeAll()
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")

    private func start(regulated: Bool) async throws -> FakeSessionHost {
        let host = FakeSessionHost(tempDir: tempDir)
        let cfg = tempDir.appendingPathComponent("config-\(regulated).toml")
        try "[modes]\nregulated_mode = \(regulated)\n".write(to: cfg, atomically: true, encoding: .utf8)
        host.configStore = ConfigStore(configURL: cfg)
        host.recorderSpy.lastSystemFires = 1
        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20261117-120000.wav")
        host.recorderSpy.startBehaviour = .park
        hosts.append(host)
        let controller = MeetingSessionController(coordinator: host)
        controllers.append(controller)
        controller.engageSeams.buildHandles = { _, _ in nil }
        controller.handleMeetingStarted(source: teams)
        controller.beginRecording(source: teams, summaryMode: .auto)
        let deadline = Date().addingTimeInterval(5)
        while host.recorderSpy.startCallCount < 1, Date() < deadline {
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        host.recorderSpy.releasePark()
        try await Task.sleep(nanoseconds: 100_000_000)
        return host
    }

    func test_a_regulated_start_reaches_the_notifier_with_the_gate_and_the_live_output_dir() async throws {
        let host = try await start(regulated: true)
        let checks = host.notifierSpy.librarySyncedChecks
        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(checks.first?.mode, .regulatedGate)
        XCTAssertEqual(checks.first?.root, host.liveOutputDir)
    }

    func test_an_ordinary_start_reaches_it_with_a_capture_first_mode_so_it_never_warns() async throws {
        let host = try await start(regulated: false)
        XCTAssertEqual(host.notifierSpy.librarySyncedChecks.first?.mode, .captureFirst)
    }
}
