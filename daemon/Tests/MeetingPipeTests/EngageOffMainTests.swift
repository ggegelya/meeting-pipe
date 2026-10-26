import ApplicationServices
import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// PERF15: engaging, arming and disengaging a meeting ran full AX walks on the main thread. A
/// discovery winner built its handles synchronously in `handleDiscovery` (about 547 ms for a healthy
/// Teams, unbounded against a hung one), and a record start built up to three more times, two of
/// them on main. These drive the real controller with the build behind `EngageSeams`, gated on a
/// semaphore, so "main did not wait" is something a test can observe rather than infer.
@MainActor
final class EngageOffMainTests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!
    private var hosts: [FakeSessionHost] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("perf15-\(UUID().uuidString)", isDirectory: true)
        logs = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")

    // MARK: - Fixtures

    /// A build that counts its calls, can park on a gate, and hands back handles whose pid names
    /// which call produced them (4001 for the first, 4002 for the second, ...). The gate wait is
    /// bounded so a failing test cannot wedge the shared `axWalkQueue` for the tests after it.
    final class GatedBuild: @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
        let gated: Bool
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)

        init(gated: Bool) { self.gated = gated }

        var calls: Int { lock.withLock { callCount } }

        func build(_ source: AppSource) -> MeetingAXHandleBuilder.Handles? {
            let call: Int = lock.withLock { callCount += 1; return callCount }
            entered.signal()
            if gated { _ = gate.wait(timeout: .now() + 5) }
            let pid = pid_t(4000 + call)
            return MeetingAXHandleBuilder.Handles(
                lifecycle: LifecycleAdapterHandle(leaveButton: AXUIElementCreateApplication(pid)),
                micGate: MicGateAdapterHandle(muteButton: AXUIElementCreateApplication(pid)),
                context: MeetingLifecycleContext(bundleID: source.bundleID, kind: .native, pid: pid)
            )
        }
    }

    /// Records every start and arm, and on which thread the start ran.
    final class CountingAdapter: LifecycleAdapter {
        let bundleIDs: Set<String> = ["com.microsoft.teams2"]
        let kind: MeetingLifecycleContext.Kind = .native
        private(set) var starts: [(pid: pid_t, onMain: Bool)] = []
        private(set) var armedCount = 0
        private(set) var sink: ((PrimarySignalEvent) -> Void)?

        func start(
            context: MeetingLifecycleContext,
            handle: LifecycleAdapterHandle,
            sink: @escaping (PrimarySignalEvent) -> Void
        ) throws {
            starts.append((pid: context.pid, onMain: Thread.isMainThread))
            self.sink = sink
        }

        func stop() {}

        func armLeaveButton(_ element: AXUIElement) { armedCount += 1 }
    }

    private func makeController(build: GatedBuild) -> (MeetingSessionController, FakeSessionHost, CountingAdapter) {
        let host = FakeSessionHost(tempDir: tempDir)
        // The controller holds its host `unowned`, and a test that only needs the controller would
        // otherwise free the host the moment this returns.
        hosts.append(host)
        let adapter = CountingAdapter()
        host.lifecycleCoord = MeetingLifecycleCoordinator(adapters: [adapter])
        let controller = MeetingSessionController(coordinator: host)
        controller.engageSeams.buildHandles = { source, _ in build.build(source) }
        return (controller, host, adapter)
    }

    private func waitUntil(
        _ predicate: () -> Bool,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func eventRows(action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    private func skipReasons() -> [String] {
        eventRows(action: "lifecycle_engage_skipped").compactMap { $0["reason"] as? String }
    }

    // MARK: - Item 1: discovery builds off main

    func test_handleDiscovery_returnsBeforeABlockedBuild_andEngagesOnMainOnceItLands() async {
        let build = GatedBuild(gated: true)
        let (controller, _, adapter) = makeController(build: build)

        controller.handleDiscovery(teams)

        // Main is here, so `handleDiscovery` has returned, and the build is still parked.
        XCTAssertEqual(build.entered.wait(timeout: .now() + 2), .success, "the build is running off main")
        XCTAssertTrue(adapter.starts.isEmpty, "nothing engages until the build lands")

        build.gate.signal()
        await waitUntil({ adapter.starts.count == 1 }, "the engage to land")
        XCTAssertEqual(adapter.starts.first?.onMain, true, "the engage itself still runs on main")
        XCTAssertEqual(adapter.starts.first?.pid, 4001)
    }

    func test_aBuildThatLandsAfterTheStateLeftIdle_doesNotEngage() async {
        let build = GatedBuild(gated: true)
        let (controller, host, adapter) = makeController(build: build)

        controller.handleDiscovery(teams)
        XCTAssertEqual(build.entered.wait(timeout: .now() + 2), .success)
        host.stateMachine.setPrompting(source: teams)
        build.gate.signal()

        await waitUntil({ self.skipReasons().contains("state_changed") }, "the stale landing to be dropped")
        XCTAssertTrue(adapter.starts.isEmpty, "a prompt is up, so this landing must not reset the engine")
    }

    func test_aBuildSupersededByANewerOneForTheSameBundle_doesNotEngage() async {
        let build = GatedBuild(gated: true)
        let (controller, _, adapter) = makeController(build: build)

        controller.handleDiscovery(teams)
        XCTAssertEqual(build.entered.wait(timeout: .now() + 2), .success)
        controller.handleDiscovery(teams)  // the next 3 s poll, the first build still walking
        XCTAssertEqual(build.calls, 1, "a build in flight for this bundle absorbs the request")

        controller.disengageLifecycle()    // e.g. an idle transition: the in-flight build is now stale
        controller.handleDiscovery(teams)  // so this one is the newest request
        build.gate.signal()                // first build lands, superseded
        XCTAssertEqual(build.entered.wait(timeout: .now() + 2), .success, "the second build runs")
        build.gate.signal()

        await waitUntil({ adapter.starts.count == 1 }, "the newer build to engage")
        XCTAssertEqual(adapter.starts.map(\.pid), [4002], "only the newest build engages")
        XCTAssertEqual(build.calls, 2)
        XCTAssertTrue(skipReasons().contains("superseded_build"))
    }

    /// Pins the behaviour PERF15 kept: a discovery of a bundle already engaged re-engages. This path
    /// only runs while `.idle`, where the engine has nothing worth keeping, and the re-engage is what
    /// picks up a relaunched app's pid and a Leave button the earlier build was too early to see.
    func test_aRepeatDiscoveryOfAnEngagedBundleStillReEngages() async {
        let build = GatedBuild(gated: false)
        let (controller, host, adapter) = makeController(build: build)

        controller.handleDiscovery(teams)
        await waitUntil({ adapter.starts.count == 1 }, "the first engage")
        XCTAssertTrue(host.lifecycleCoord.isEngaged)

        controller.handleDiscovery(teams)
        await waitUntil({ adapter.starts.count == 2 }, "the repeat engage")
        XCTAssertEqual(adapter.starts.map(\.pid), [4001, 4002])
    }

    // MARK: - Item 2: one build per recording start

    func test_recordStart_runsOneBuildOffMain_andAttachesEverythingFromIt() async {
        let build = GatedBuild(gated: true)
        let (controller, host, adapter) = makeController(build: build)
        host.liveHonorAppMute = true
        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20261026-150000.wav")
        controller.recordStartBuildDeadlineSec = 30  // this test is about the build, not its deadline
        var micGateStarts: [MicGateAdapterHandle] = []
        controller.engageSeams.startMicGate = { _, handle in micGateStarts.append(handle) }

        controller.beginRecording(source: teams, summaryMode: .auto)
        XCTAssertEqual(build.entered.wait(timeout: .now() + 2), .success, "the build starts when the start commits")

        // The continuation past the recorder start does not wait for the walk.
        await waitUntil({ host.hudSpy.presentCount == 1 }, "the HUD, with the build still blocked")
        XCTAssertEqual(host.statusBarSpy.recordings.count, 1)
        XCTAssertTrue(micGateStarts.isEmpty, "MicGate waits for the build")
        XCTAssertTrue(
            host.recorderSpy.verdicts.isEmpty,
            "no verdict reaches the recorder before MicGate engages, so it stays on .uncertain(not_started)"
        )
        XCTAssertTrue(adapter.starts.isEmpty)

        build.gate.signal()
        await waitUntil({ micGateStarts.count == 1 && adapter.armedCount == 1 }, "the attach")
        XCTAssertNotNil(micGateStarts.first?.muteButton, "MicGate got the build's mute button")
        XCTAssertEqual(adapter.starts.map(\.pid), [4001], "END11's explicit-start engage used the same build")
        XCTAssertEqual(build.calls, 1, "one build replaces the three a start used to run")
        XCTAssertEqual(eventRows(action: "micgate_attached").first?["via"] as? String, "build")

        controller.stopRecording(file: host.recorderSpy.fileToReturn, source: teams, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current == .idle }, "the stop to finish")
    }

    func test_recordStart_pastTheDeadline_engagesMicGateWithEmptyHandles() async {
        let build = GatedBuild(gated: true)
        let (controller, host, adapter) = makeController(build: build)
        host.liveHonorAppMute = true
        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20261026-160000.wav")
        controller.recordStartBuildDeadlineSec = 0.05
        controller.engageSeams.resolveContext = { source in
            MeetingLifecycleContext(bundleID: source.bundleID, kind: .native, pid: 9999)
        }
        var micGateStarts: [(pid: pid_t, handle: MicGateAdapterHandle)] = []
        controller.engageSeams.startMicGate = { context, handle in micGateStarts.append((context.pid, handle)) }

        controller.beginRecording(source: teams, summaryMode: .auto)
        XCTAssertEqual(build.entered.wait(timeout: .now() + 2), .success)

        await waitUntil({ micGateStarts.count == 1 }, "the deadline to engage MicGate")
        XCTAssertNil(micGateStarts.first?.handle.muteButton, "no AX mute button: HAL VAD plus RMS")
        XCTAssertEqual(micGateStarts.first?.pid, 9999)
        XCTAssertEqual(eventRows(action: "micgate_attached").first?["via"] as? String, "deadline")
        XCTAssertTrue(adapter.starts.isEmpty, "end detection keeps waiting for the build")

        build.gate.signal()
        await waitUntil({ adapter.starts.count == 1 }, "the late build to engage the lifecycle")
        XCTAssertEqual(micGateStarts.count, 1, "the late build does not engage MicGate a second time")

        controller.stopRecording(file: host.recorderSpy.fileToReturn, source: teams, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current == .idle }, "the stop to finish")
    }

    // MARK: - The late `.starting` an off-main engage produces

    /// An explicit start's engine reaches `.starting` after `beginRecording`'s `confirmRecording`
    /// now, so the lifecycle consumer has to promote it or the recording runs with an engine that
    /// never reaches `.inMeeting` (and so never holds a weak end).
    func test_aStartingForTheAppBeingRecorded_isConfirmedRatherThanPrompted() async throws {
        let build = GatedBuild(gated: false)
        let (controller, host, adapter) = makeController(build: build)
        let context = MeetingLifecycleContext(bundleID: teams.bundleID, kind: .native, pid: 4321)
        host.stateMachine.setRecording(
            file: tempDir.appendingPathComponent("rec.wav"), source: teams, summaryMode: .auto
        )
        controller.startConsumers()
        defer { controller.shutdownConsumers() }

        try host.lifecycleCoord.engage(context: context, handle: LifecycleAdapterHandle())
        adapter.sink?(PrimarySignalEvent(
            kind: .shareableContentWindow, state: .live, timestamp: Date(), context: context
        ))

        await waitUntil({ host.lifecycleCoord.current == .inMeeting(context: context) }, "the late promotion")
        XCTAssertEqual(host.promptSpy.presentCount, 0)
        XCTAssertEqual(eventRows(action: "lifecycle_late_start_confirmed").count, 1)
    }
}
