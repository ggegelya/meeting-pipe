import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// MIC21 at the session spine: every committed recording stopped through `stopRecording` writes
/// exactly one `speech_evidence` row naming the five sources, for an app's recording and for one
/// with no source (the manual path). Neither engages the gate (`liveHonorAppMute` is off here),
/// which is the case that matters: the row is scoped to the recording, not to the gate's start.
@MainActor
final class SpeechEvidenceSessionTests: XCTestCase {

    private var tempDir: URL!
    private var hosts: [FakeSessionHost] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mic21-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")

    private func rows(_ host: FakeSessionHost) -> [[String: String]] {
        host.micGateLog.entries.filter { $0.action == "speech_evidence" }.map(\.attributes)
    }

    private func waitUntil(_ predicate: () -> Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func recordAndStop(source: AppSource?, stem: String) async -> [String: String]? {
        let host = FakeSessionHost(tempDir: tempDir)
        hosts.append(host)
        host.recorderSpy.lastSystemFires = 1
        let controller = MeetingSessionController(coordinator: host)
        let file = tempDir.appendingPathComponent("\(stem).wav")
        host.recorderSpy.fileToReturn = file
        controller.beginRecording(source: source, summaryMode: .auto)
        await waitUntil({ if case .recording = host.stateMachine.current { return true } else { return false } }, "the recording")
        // A little wall time on the gate's clock, so the row's seconds are real.
        host.micGate.ingest(rmsDb: -70)
        try? await Task.sleep(nanoseconds: 250_000_000)
        controller.stopRecording(file: file, source: source, summaryMode: .auto, cause: .lifecycleEnd)
        await waitUntil({ host.stateMachine.current == .idle }, "the stop")
        await waitUntil({ self.rows(host).count == 1 }, "the evidence row")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rows(host).count, 1, "exactly one row per stop")
        return rows(host).last
    }

    private func assertFiveSources(_ row: [String: String]?, file: StaticString = #filePath, line: UInt = #line) {
        guard let row else { return XCTFail("no row", file: file, line: line) }
        for source in ["app_mute_ax", "app_mute_log", "hal_vad", "rms_gate", "speech_detector"] {
            XCTAssertNotNil(row["\(source)_available"], source, file: file, line: line)
            XCTAssertNotNil(row["\(source)_sec"], source, file: file, line: line)
        }
        XCTAssertGreaterThan(Double(row["total_sec"] ?? "") ?? 0, 0, file: file, line: line)
    }

    func test_anAppsRecording_writesOneRow() async {
        let row = await recordAndStop(source: teams, stem: "20261117-170000")
        assertFiveSources(row)
        XCTAssertEqual(row?["bundle_id"], teams.bundleID)
    }

    /// No source, and so no MicGate engage at all: the level still publishes verdicts, and the row
    /// is still written, once.
    func test_aRecordingWithNoSource_writesOneRow() async {
        let row = await recordAndStop(source: nil, stem: "20261117-171000")
        assertFiveSources(row)
        XCTAssertEqual(row?["bundle_id"], "manual")
    }
}
