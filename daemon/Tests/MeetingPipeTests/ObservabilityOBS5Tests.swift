import Combine
import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// OBS5: the rows that say why a recording stopped, why the daemon exited, what a permission did,
/// which backend a run expects, what a save changed (names only), and what the registry loaded.
@MainActor
final class ObservabilityOBS5Tests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("obs5-\(UUID().uuidString)", isDirectory: true)
        logs = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private let zoom = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")

    private func rows(_ action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    private func waitUntil(_ predicate: () -> Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// Record, stop through `stop`, and return the `recording_stopped` row.
    private func stoppedRow(_ stop: (MeetingSessionController) -> Void) async throws -> [String: Any] {
        let host = FakeSessionHost(tempDir: tempDir)
        host.recorderSpy.lastSystemFires = 1
        let file = tempDir.appendingPathComponent("\(UUID().uuidString).wav")
        host.recorderSpy.fileToReturn = file
        let controller = MeetingSessionController(coordinator: host)
        controller.beginRecording(source: zoom, summaryMode: .auto)
        await waitUntil({ if case .recording = host.stateMachine.current { return true }; return false }, "the recording")
        stop(controller)
        await waitUntil({ host.stateMachine.current == .idle }, "the stop")
        return try XCTUnwrap(rows("recording_stopped").first { $0["file"] as? String == file.lastPathComponent })
    }

    // MARK: - stop_cause

    func test_a_user_stop_names_its_surface() async throws {
        for surface in [StopSurface.menu, .hotkey, .hud, .notification, .automation] {
            let row = try await stoppedRow { $0.toggleManual(surface: surface) }
            XCTAssertEqual(row["stop_cause"] as? String, "user_stop", surface.rawValue)
            XCTAssertEqual(row["stop_surface"] as? String, surface.rawValue)
        }
    }

    func test_a_force_stop_names_its_reason_and_the_disk_and_writer_routes_their_own_cause() async throws {
        let cases: [(String, String, String?, String?)] = [
            ("hotkey", "force_stop", "force_reason", "hotkey"),
            ("url_scheme", "force_stop", "force_reason", "url_scheme"),
            ("low_space", "low_space", nil, nil),
            ("write_failure_mic", "writer_stalled", "channel", "mic"),
        ]
        for (reason, cause, key, value) in cases {
            let row = try await stoppedRow { $0.forceStop(reason: reason) }
            XCTAssertEqual(row["stop_cause"] as? String, cause, reason)
            if let key { XCTAssertEqual(row[key] as? String, value, reason) }
        }
    }

    func test_the_idle_backstop_and_a_lifecycle_end_are_named() async throws {
        let idle = try await stoppedRow { $0.handleIdleAutoStop() }
        XCTAssertEqual(idle["stop_cause"] as? String, "idle_backstop")
        let host = FakeSessionHost(tempDir: tempDir)
        let file = tempDir.appendingPathComponent("lifecycle.wav")
        host.stateMachine.setRecording(file: file, source: zoom, summaryMode: .auto)
        let controller = MeetingSessionController(coordinator: host)
        controller.stopRecording(file: file, source: zoom, summaryMode: .auto, cause: .lifecycleEnd)
        await waitUntil({ host.stateMachine.current == .idle }, "the stop")
        XCTAssertEqual(rows("recording_stopped").first { $0["file"] as? String == "lifecycle.wav" }?["stop_cause"] as? String, "lifecycle_end")
    }

    func test_every_cause_keeps_end21s_stop_route_and_one_detail() {
        XCTAssertEqual(StopCause.userStop(surface: .hud, duringHold: true).name, "user_stop_during_hold")
        XCTAssertEqual(StopCause.userStop(surface: .hud, duringHold: true).stopRoute, "toggle")
        XCTAssertEqual(StopCause.forced(reason: "write_failure_system"), .writerStalled(channel: "system"))
        XCTAssertEqual(StopCause.forced(reason: "write_failure_system").stopRoute, "write_failure_system")
        XCTAssertEqual(StopCause.forced(reason: "low_space"), .lowSpace)
        XCTAssertEqual(StopCause.micRelease.stopRoute, "mic_released")
        XCTAssertEqual(StopCause.lifecycleEnd.stopRoute, "lifecycle_end")
        XCTAssertEqual(StopCause.cancelledDuringStart(by: "toggle").attributes["cancelled_by"] as? String, "toggle")
        XCTAssertEqual(StopCause.callChanged.name, "call_changed")
    }

    // MARK: - terminating

    func test_termination_writes_its_reason_relaunch_uptime_and_an_open_recording() throws {
        AppDelegate.recordTermination(reason: .sigterm, relaunch: true, uptimeSec: 42, recordingOpen: true)
        let row = try XCTUnwrap(rows("terminating").first)
        XCTAssertEqual(row["category"] as? String, "daemon")
        XCTAssertEqual(row["reason"] as? String, "sigterm")
        XCTAssertEqual(row["relaunch"] as? Bool, true)
        XCTAssertEqual(row["uptime_sec"] as? Int, 42)
        XCTAssertEqual(row["recording_open"] as? Bool, true)
    }

    /// `flushAndExit` exits, so the order is pinned on its source: REC13's ceiling first, then the
    /// row, then the shutdown, so a wedged teardown still leaves the row and cannot hold the exit.
    func test_the_terminating_row_is_written_before_anything_that_can_block() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe/App.swift")
        let text = try String(contentsOf: app, encoding: .utf8)
        let body = try XCTUnwrap(text.range(of: "private func flushAndExit(reason: TerminationReason) -> Never {"))
        let rest = String(text[body.upperBound...])
        let record = try XCTUnwrap(rest.range(of: "AppDelegate.recordTermination("))
        let ceiling = try XCTUnwrap(rest.range(of: "armTerminationCeiling()"))
        let shutdown = try XCTUnwrap(rest.range(of: "coordinator?.shutdown()"))
        XCTAssertLessThan(ceiling.lowerBound, record.lowerBound)
        XCTAssertLessThan(record.lowerBound, shutdown.lowerBound)
    }

    // MARK: - permission_changed

    func test_permission_transitions_are_logged_and_an_unchanged_status_publishes_nothing() {
        let center = PermissionsCenter()
        var changes = 0
        let cancel = center.objectWillChange.sink { _ in changes += 1 }
        var granted: [PermissionsCenter.Kind] = []
        let grants = center.permissionGranted.sink { granted.append($0) }

        center.simulateStatusForTesting(.granted, kind: .screenRecording)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(granted, [.screenRecording], "the first grant still re-evaluates detection")
        center.simulateStatusForTesting(.granted, kind: .screenRecording)
        XCTAssertEqual(changes, 1, "an unchanged status fires no objectWillChange")
        center.simulateStatusForTesting(.denied, kind: .screenRecording)
        cancel.cancel()
        grants.cancel()

        let rowsSeen = rows("permission_changed").filter { $0["kind"] as? String == "screenRecording" }
        XCTAssertEqual(rowsSeen.count, 2, "unknown to granted, granted to denied; the repeat writes nothing")
        XCTAssertEqual(rowsSeen.first?["from"] as? String, "unknown")
        XCTAssertEqual(rowsSeen.first?["at_launch"] as? Bool, true)
        XCTAssertEqual(rowsSeen.last?["from"] as? String, "granted")
        XCTAssertEqual(rowsSeen.last?["to"] as? String, "denied")
        XCTAssertNil(rowsSeen.last?["at_launch"])
    }

    // MARK: - expectedBackend

    private func config(_ body: String) throws -> URL {
        let url = tempDir.appendingPathComponent("config-\(UUID().uuidString).toml")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func meeting(_ meta: [String: Any]?) throws -> URL {
        let stem = "20260101-\(String(format: "%06d", Int.random(in: 0..<999_999)))"
        let wav = tempDir.appendingPathComponent("\(stem).wav")
        if let meta {
            try JSONSerialization.data(withJSONObject: meta).write(to: tempDir.appendingPathComponent("\(stem).meta.json"))
        }
        return wav
    }

    func test_expected_backend_names_the_setting_that_chose_it() throws {
        let cloud = try config("[summarization]\nbackend = \"anthropic\"\n")
        let regulated = try config("[modes]\nregulated_mode = true\n[summarization]\nbackend = \"anthropic\"\n")
        let pinned = try meeting(["workflow_backend": "apple_intelligence"])
        let nda = try meeting(["workflow_nda_mode": true, "workflow_backend": "anthropic"])

        let table: [(URL?, String?, URL, String, String)] = [
            (nil, nil, regulated, "local", "regulated"),
            (pinned, "anthropic", regulated, "local", "regulated"),
            (nda, nil, cloud, "local", "nda"),
            (pinned, "local", cloud, "local", "override"),
            (pinned, nil, cloud, "apple_intelligence", "sidecar"),
            (nil, nil, cloud, "anthropic", "global"),
        ]
        for (meeting, override, configURL, backend, source) in table {
            let expected = PipelineLauncher.expectedBackend(for: meeting, backendOverride: override, configURL: configURL)
            XCTAssertEqual(expected.backend, backend, source)
            XCTAssertEqual(expected.source, source)
        }
        // cloudSecretPolicy reads the same resolution: unchanged for each.
        XCTAssertTrue(PipelineLauncher.cloudSecretPolicy(for: nil, configURL: regulated).zeroEgress)
        XCTAssertTrue(PipelineLauncher.cloudSecretPolicy(for: nda, configURL: cloud).zeroEgress)
        XCTAssertTrue(PipelineLauncher.cloudSecretPolicy(for: pinned, configURL: cloud).stripAnthropic)
        XCTAssertFalse(PipelineLauncher.cloudSecretPolicy(for: pinned, configURL: cloud).zeroEgress)
        XCTAssertFalse(PipelineLauncher.cloudSecretPolicy(for: nil, configURL: cloud).stripAnthropic)
    }

    // MARK: - saves, names only

    func test_config_saved_names_only_the_changed_key() throws {
        let url = try config("[summarization]\nbackend = \"anthropic\"\n")
        let store = ConfigStore(configURL: url)
        store.summarizationBackend = "local"
        try store.saveNow()
        let row = try XCTUnwrap(rows("config_saved").last)
        XCTAssertEqual(row["keys"] as? [String], ["summarization.backend"])
        let raw = try String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)
        XCTAssertFalse(raw.contains("\"local\""), "no value reaches the log")
    }

    func test_workflow_saved_names_changed_fields_and_no_values() throws {
        let store = WorkflowStore(directory: tempDir.appendingPathComponent("workflows", isDirectory: true))
        var workflow = Workflow(name: "Avery sync")
        try store.upsert(workflow)
        workflow.contextPrompt = "Placeholder context"
        try store.upsert(workflow)
        let saved = rows("workflow_saved")
        XCTAssertEqual(saved.first?["created"] as? Bool, true)
        XCTAssertEqual(saved.last?["fields"] as? [String], ["contextPrompt"])
        let raw = try String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)
        XCTAssertFalse(raw.contains("Placeholder context"))
    }

    // MARK: - registry_loaded

    func test_registry_loaded_reports_the_overlay() throws {
        _ = MeetingAppRegistry.load(overlayURL: tempDir.appendingPathComponent("absent.toml"))
        let valid = tempDir.appendingPathComponent("valid.toml")
        try "[native]\nbundle_ids = [\"com.example.meet\"]\n".write(to: valid, atomically: true, encoding: .utf8)
        let registry = MeetingAppRegistry.load(overlayURL: valid)
        let malformed = tempDir.appendingPathComponent("malformed.toml")
        try "[native\nbundle_ids = ".write(to: malformed, atomically: true, encoding: .utf8)
        _ = MeetingAppRegistry.load(overlayURL: malformed)

        XCTAssertTrue(registry.nativeBundles.contains("com.example.meet"))
        XCTAssertEqual(rows("registry_loaded").map { $0["overlay"] as? String }, ["absent", "applied", "rejected"])
        XCTAssertEqual(rows("registry_overlay_rejected").first?["file"] as? String, "malformed.toml")
        XCTAssertNotNil(rows("registry_loaded").first?["native"] as? Int)
    }
}
