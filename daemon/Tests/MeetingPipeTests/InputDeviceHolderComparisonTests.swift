import CoreAudio
import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// MIC22 leg 1 at the session spine: a recording's start and a mid-recording input change each
/// write one `input_device_holder_compared` row, from the mic-holder monitor's published devices,
/// with the device reads behind seams so nothing reaches the HAL.
@MainActor
final class InputDeviceHolderComparisonTests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!
    private var hosts: [FakeSessionHost] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mic22-\(UUID().uuidString)", isDirectory: true)
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
    private let builtIn = InputDeviceIdentity(name: "Built-in", uid: "builtin", transport: .builtIn, sampleRate: 48000)
    private let headset = InputDeviceIdentity(name: "Headset", uid: "headset", transport: .bluetooth, sampleRate: 16000)

    private func rows() -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == "input_device_holder_compared" }
    }

    private func waitUntil(_ predicate: () -> Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func holding(_ devices: [AudioObjectID]) -> MicHolderMonitor.Snapshot {
        MicHolderMonitor.Snapshot(at: 0, readings: [
            "com.microsoft.teams2": .init(level: .held, since: 0, readAt: 0, inputDevices: devices),
            "us.zoom.xos": .init(level: .released, since: 0, readAt: 0),
        ])
    }

    private func makeController(
        captured: @escaping () -> InputDeviceIdentity?
    ) -> (MeetingSessionController, FakeSessionHost) {
        let host = FakeSessionHost(tempDir: tempDir)
        hosts.append(host)
        host.recorderSpy.lastSystemFires = 1
        let controller = MeetingSessionController(coordinator: host)
        let devices: [AudioObjectID: InputDeviceIdentity] = [10: builtIn, 11: headset]
        controller.inputHolderSeams = .init(
            captured: captured,
            holderIdentities: { [devices[$0] ?? InputDeviceIdentity(name: nil, uid: nil, transport: .unknown, sampleRate: 0)] },
            run: { $0() }
        )
        controller.inputHolderChangeSettleSec = 0.05
        return (controller, host)
    }

    private func record(_ controller: MeetingSessionController, _ host: FakeSessionHost, _ stem: String) async -> URL {
        let file = tempDir.appendingPathComponent("\(stem).wav")
        host.recorderSpy.fileToReturn = file
        controller.beginRecording(source: teams, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current.isRecordingState }, "the recording")
        return file
    }

    func test_aStartAClientSwitchAndARecorderReconfigure_eachWriteOneRow() async {
        var captured = builtIn
        let (controller, host) = makeController(captured: { captured })
        host.micHolderSpy.snapshot = holding([10])
        let file = await record(controller, host, "20261117-150000")
        await waitUntil({ self.rows().count == 1 }, "the start's row")
        XCTAssertEqual(rows().first?["trigger"] as? String, "start")
        XCTAssertEqual(rows().first?["match"] as? String, "true")

        // Nothing moved: the 1 Hz tick writes nothing.
        controller.noteHolderDevicesTick()
        XCTAssertEqual(rows().count, 1)

        // The owner switches Teams to a headset; the system default stays the built-in mic, so our
        // engine never reconfigures. The tick sees the client's devices move.
        host.micHolderSpy.snapshot = holding([11])
        controller.noteHolderDevicesTick()
        controller.noteHolderDevicesTick()
        XCTAssertEqual(rows().count, 2, "one row per switch, not per tick")
        XCTAssertEqual(rows().last?["trigger"] as? String, "holder_change")
        XCTAssertEqual(rows().last?["match"] as? String, "false")
        XCTAssertEqual(rows().last?["holder_uids"] as? [String], ["headset"])

        // The default follows and the recorder reconfigures, twice in one burst: one row, after the
        // settle, matching again.
        captured = headset
        controller.noteInputDeviceChanged(recovered: true)
        controller.noteInputDeviceChanged(recovered: true)
        XCTAssertEqual(rows().count, 2, "the reconfigure row waits out the settle")
        await waitUntil({ self.rows().count == 3 }, "the settled row")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(rows().count, 3, "a burst writes one row")
        XCTAssertEqual(rows().last?["trigger"] as? String, "recorder_reconfigured")
        XCTAssertEqual(rows().last?["match"] as? String, "true")

        controller.stopRecording(file: file, source: teams, summaryMode: .auto, cause: .lifecycleEnd)
        await waitUntil({ host.stateMachine.current == .idle }, "the stop")
    }

    /// A stop inside the settle window: the pending comparison belongs to a recording that is gone.
    func test_aReconfigureRightBeforeAStop_writesNoRow() async {
        let (controller, host) = makeController(captured: { self.builtIn })
        host.micHolderSpy.snapshot = holding([10])
        let file = await record(controller, host, "20261117-160000")
        await waitUntil({ self.rows().count == 1 }, "the start's row")
        controller.noteInputDeviceChanged(recovered: false)
        controller.stopRecording(file: file, source: teams, summaryMode: .auto, cause: .lifecycleEnd)
        await waitUntil({ host.stateMachine.current == .idle }, "the stop")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(rows().count, 1)
        controller.noteInputDeviceChanged(recovered: true)
        XCTAssertEqual(rows().count, 1, "no row once the recording has stopped")
    }

    /// The client not holding the mic (or no source at all) is unknown, never a mismatch.
    func test_aClientNotHoldingTheMic_readsUnknown() async {
        let host = FakeSessionHost(tempDir: tempDir)
        hosts.append(host)
        let controller = MeetingSessionController(coordinator: host)
        controller.inputHolderSeams = .init(captured: { self.builtIn }, holderIdentities: { _ in [self.headset] }, run: { $0() })
        host.micHolderSpy.snapshot = MicHolderMonitor.Snapshot(at: 0, readings: [
            "com.microsoft.teams2": .init(level: .released, since: 0, readAt: 0),
        ])
        controller.compareInputDeviceHolder(trigger: "start", source: teams)
        controller.compareInputDeviceHolder(trigger: "start", source: nil)
        XCTAssertEqual(rows().map { $0["match"] as? String }, ["unknown", "unknown"])
        XCTAssertEqual(rows().map { $0["holder_read"] as? String }, ["unavailable", "unavailable"])
    }
}

private extension AppState {
    var isRecordingState: Bool {
        if case .recording = self { return true }
        return false
    }
}
