import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// END21 at the session spine: every stop route inside an open hold concludes it under the owner's
/// rule of 2026-11-16, and a lifecycle end cuts at the mic release rather than the first doubt. The
/// hold is a real one: a hand-driven adapter feeds the real coordinator and engine, so the evidence
/// the controller reads is the engine's own.
@MainActor
final class HeldEndStopRouteTests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!
    private var hosts: [FakeSessionHost] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("end21-\(UUID().uuidString)", isDirectory: true)
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
    private let context = MeetingLifecycleContext(bundleID: "com.microsoft.teams2", kind: .native, pid: 4321)

    private func waitUntil(_ predicate: () -> Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func rows(_ action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    private func meta(for file: URL) throws -> [String: Any] {
        let url = file.deletingPathExtension().appendingPathExtension("meta.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private struct Rig {
        let controller: MeetingSessionController
        let host: FakeSessionHost
        let adapter: StartInFlightTests.MicAdapter
        let file: URL
    }

    /// Record a Teams call whose engine is in `.inMeeting` with the Leave button, the mic and the
    /// window all live; then `opener` (the Leave button by default) goes ended and opens a hold.
    private func recordIntoAHold(
        workflows: [Workflow] = [], override: UUID? = nil, opener: PrimarySignalKind = .axLeaveButton
    ) async throws -> Rig {
        let host = FakeSessionHost(tempDir: tempDir, workflows: workflows)
        hosts.append(host)
        host.recorderSpy.lastSystemFires = 1
        let file = tempDir.appendingPathComponent("20261116-150000.wav")
        host.recorderSpy.fileToReturn = file
        let adapter = StartInFlightTests.MicAdapter()
        host.lifecycleCoord = MeetingLifecycleCoordinator(adapters: [adapter])
        let controller = MeetingSessionController(coordinator: host)
        controller.engageSeams.buildHandles = { _, _ in nil }
        controller.pendingWorkflowOverride = override.map { (source: teams, workflowID: $0) }
        controller.startConsumers()
        controller.beginRecording(source: teams, summaryMode: .auto)
        await waitUntil({ if case .recording = host.stateMachine.current { return true }; return false }, "the recording")
        try host.lifecycleCoord.engage(context: context, handle: LifecycleAdapterHandle())
        adapter.emit(.axLeaveButton, .live, context)
        adapter.emit(.processAudioIsRunningInput, .live, context)
        adapter.emit(.shareableContentWindow, .live, context)
        await waitUntil({ host.lifecycleCoord.current == .inMeeting(context: context) }, "in meeting")
        try? await Task.sleep(nanoseconds: 20_000_000)
        adapter.emit(opener, .ended, context)
        await waitUntil({ controller.holdPolicy.isOpen }, "the hold")
        // The hold must be at least `minimumTrimmedHoldSec` old before anything can be cut.
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        return Rig(controller: controller, host: host, adapter: adapter, file: file)
    }

    /// The real end, then a stop route: the mic releases and the window goes after it.
    private func theCallEnds(_ rig: Rig) async {
        rig.adapter.emit(.processAudioIsRunningInput, .ended, context)
        try? await Task.sleep(nanoseconds: 20_000_000)
        rig.adapter.emit(.shareableContentWindow, .ended, context)
        await waitUntil({ rig.host.lifecycleCoord.holdEvidence?.callWindowBacksRelease == true }, "the evidence")
    }

    private func finish(_ rig: Rig) async {
        await waitUntil({ rig.host.stateMachine.current == .idle }, "the flush")
        rig.controller.shutdownConsumers()
    }

    func test_aHandStopAfterTheRealEnd_cutsAtTheRelease_andSaysSo() async throws {
        let rig = try await recordIntoAHold()
        await theCallEnds(rig)
        let release = try XCTUnwrap(rig.host.lifecycleCoord.holdEvidence?.releasedAt)
        let startedAt = try XCTUnwrap(rig.host.recorderSpy.startedAt)
        rig.controller.toggleManual(surface: .menu)
        await finish(rig)

        let row = try XCTUnwrap(rows("held_end_trimmed").first)
        XCTAssertEqual(row["stop_route"] as? String, "toggle")
        // OBS5: a hand Stop inside an open hold is told apart from a plain one.
        XCTAssertEqual(rows("recording_stopped").first?["stop_cause"] as? String, "user_stop_during_hold")
        XCTAssertEqual(row["mode"] as? String, "suggested")
        XCTAssertEqual(row["limit_sec"] as? Double ?? .nan, release.timeIntervalSince(startedAt), accuracy: 0.01)
        XCTAssertNil(rig.host.recorderSpy.lastStopLimitSeconds ?? nil, "lossless: kept on disk, suggested")
        XCTAssertNotNil(try meta(for: rig.file)[HeldEndTrim.metaKey])
    }

    /// The owner's case (a): a headphone switch drops only the mic, so a Stop inside it cuts nothing.
    func test_aStopDuringAHeadphoneSwitch_cutsNothing() async throws {
        // A switch takes only the mic: the hold opens on its release, the Leave button and window stay live.
        let rig = try await recordIntoAHold(opener: .processAudioIsRunningInput)
        await waitUntil({ rig.host.lifecycleCoord.holdEvidence?.processAudio == .ended }, "the release")
        XCTAssertEqual(rig.host.lifecycleCoord.holdEvidence?.callWindowBacksRelease, false)
        rig.controller.toggleManual(surface: .menu)
        await finish(rig)
        XCTAssertTrue(rows("held_end_trimmed").isEmpty)
        XCTAssertNil(try meta(for: rig.file)[HeldEndTrim.metaKey])
    }

    /// A stop while Teams still holds the mic cuts nothing: the call was up.
    func test_aStopWhileTheMicIsLive_cutsNothing() async throws {
        let rig = try await recordIntoAHold()
        rig.controller.forceStop(reason: "hotkey")
        await finish(rig)
        XCTAssertTrue(rows("held_end_trimmed").isEmpty)
    }

    /// The low-space stop under NDA: same rule, and the regulated gate still truncates at stop.
    func test_theLowSpaceStop_underNDA_truncatesAtTheRelease() async throws {
        var nda = Workflow(name: "Client NDA")
        nda.flags.ndaMode = true
        let rig = try await recordIntoAHold(workflows: [nda], override: nda.id)
        await theCallEnds(rig)
        let release = try XCTUnwrap(rig.host.lifecycleCoord.holdEvidence?.releasedAt)
        let startedAt = try XCTUnwrap(rig.host.recorderSpy.startedAt)
        rig.controller.forceStop(reason: "low_space")
        await finish(rig)
        let row = try XCTUnwrap(rows("held_end_trimmed").first)
        XCTAssertEqual(row["limit_sec"] as? Double ?? .nan, release.timeIntervalSince(startedAt), accuracy: 0.01, "cut at the release")
        XCTAssertEqual(row["stop_route"] as? String, "low_space")
        XCTAssertEqual(row["mode"] as? String, "truncated")
        XCTAssertNotNil(rig.host.recorderSpy.lastStopLimitSeconds ?? nil, "cut at stop under the regulated gate")
    }

    /// The idle backstop inside a hold applies the same rule.
    func test_theIdleBackstop_insideAHold_cutsAtTheRelease() async throws {
        let rig = try await recordIntoAHold()
        await theCallEnds(rig)
        let release = try XCTUnwrap(rig.host.lifecycleCoord.holdEvidence?.releasedAt)
        let startedAt = try XCTUnwrap(rig.host.recorderSpy.startedAt)
        rig.controller.handleIdleAutoStop()
        await finish(rig)
        let row = try XCTUnwrap(rows("held_end_trimmed").first)
        XCTAssertEqual(row["stop_route"] as? String, "idle_backstop")
        XCTAssertEqual(row["limit_sec"] as? Double ?? .nan, release.timeIntervalSince(startedAt), accuracy: 0.01, "cut at the release")
    }

    /// The other real-end order: the Leave button (which opened the hold) and the window go before the
    /// mic releases, the order of `zoom_native_lifecycle_pair_dwell_trim` and of the window gone 50 to
    /// 400 ms ahead of the mic on a Teams leave (END14). Under the owner's amendment a second signal
    /// up to `secondSignalLeadSec` before the release counts, so a Stop here cuts at the release.
    func test_aStopAfterTheWindowWentBeforeTheMic_cutsAtTheRelease() async throws {
        let rig = try await recordIntoAHold()
        rig.adapter.emit(.shareableContentWindow, .ended, context)
        try? await Task.sleep(nanoseconds: 20_000_000)
        rig.adapter.emit(.processAudioIsRunningInput, .ended, context)
        await waitUntil({ rig.host.lifecycleCoord.holdEvidence?.callWindowBacksRelease == true }, "the evidence")
        let release = try XCTUnwrap(rig.host.lifecycleCoord.holdEvidence?.releasedAt)
        let startedAt = try XCTUnwrap(rig.host.recorderSpy.startedAt)
        rig.controller.toggleManual(surface: .menu)
        await finish(rig)
        let row = try XCTUnwrap(rows("held_end_trimmed").first)
        XCTAssertEqual(row["limit_sec"] as? Double ?? .nan, release.timeIntervalSince(startedAt), accuracy: 0.01)
    }

    /// The accepted edge (owner, 2026-11-16): the window minimised moments before a headphone switch
    /// backs the switch's mic release, so a Stop during the switch cuts the seconds since it. They
    /// stay on disk under a lossless capture and Restore brings them back.
    func test_aStopDuringASwitchJustAfterMinimising_cutsTheSecondsSinceTheSwitch_asAccepted() async throws {
        let rig = try await recordIntoAHold()
        rig.adapter.emit(.shareableContentWindow, .ended, context)   // minimised: the window reads gone
        try? await Task.sleep(nanoseconds: 50_000_000)
        rig.adapter.emit(.processAudioIsRunningInput, .ended, context)   // the headphone switch
        await waitUntil({ rig.host.lifecycleCoord.holdEvidence?.callWindowBacksRelease == true }, "the evidence")
        rig.controller.toggleManual(surface: .menu)
        await finish(rig)
        XCTAssertEqual(rows("held_end_trimmed").first?["mode"] as? String, "suggested", "restorable")
    }
}
