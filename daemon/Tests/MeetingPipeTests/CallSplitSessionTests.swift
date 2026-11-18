import ApplicationServices
import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// END28 at the session spine: a change of call ends the stem, then prompts for the new call (the
/// owner's decision of 2026-11-16), and the second stem names the first. The hand-built shape of
/// `20261112-172307`: the raw rows of that afternoon carry no Leave-window title (the extractor
/// drops titles by construction), so a raw replay cannot assert this.
@MainActor
final class CallSplitSessionTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("end28-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams", meetingTitle: "Standup")
    private let context = MeetingLifecycleContext(bundleID: "com.microsoft.teams2", kind: .native, pid: 635)

    /// A native adapter whose call-window read the test sets.
    final class WindowAdapter: LifecycleAdapter {
        let bundleIDs: Set<String> = ["com.microsoft.teams2"]
        let kind: MeetingLifecycleContext.Kind = .native
        var callWindow: CallWindowRead?
        func start(context: MeetingLifecycleContext, handle: LifecycleAdapterHandle, sink: @escaping (PrimarySignalEvent) -> Void) throws {}
        func stop() {}
    }

    private var serial: UInt64 = 0
    /// A fresh AX read, numbered as the Leave signal numbers them.
    private func read(_ window: UInt, _ title: String) -> CallWindowRead {
        serial += 1
        return CallWindowRead(windowID: window, title: title, subrole: "AXStandardWindow", serial: serial)
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

    private func meta(for file: URL) throws -> [String: Any] {
        let url = file.deletingPathExtension().appendingPathExtension("meta.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Record `file` for Teams with the call window reading `Standup`, already adopted.
    private func recording(_ file: URL) async throws -> (MeetingSessionController, FakeSessionHost, WindowAdapter) {
        let host = FakeSessionHost(tempDir: tempDir)
        host.recorderSpy.lastSystemFires = 1
        let adapter = WindowAdapter()
        host.lifecycleCoord = MeetingLifecycleCoordinator(adapters: [adapter])
        let controller = MeetingSessionController(coordinator: host)
        host.recorderSpy.fileToReturn = file
        controller.beginRecording(source: teams, summaryMode: .auto)
        await waitUntil({ isRecording(host) }, "the first call to record")
        if !host.lifecycleCoord.isEngaged {
            try host.lifecycleCoord.engage(context: context, handle: LifecycleAdapterHandle())
        }
        XCTAssertNotNil(controller.cancelCallIdentityTimer, "a native recording arms the watch at commit")
        adapter.callWindow = read(1, "Standup")
        controller.callIdentityTick(file: file, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(controller.callIdentity.identity?.title, "Standup")
        return (controller, host, adapter)
    }

    private func isRecording(_ host: FakeSessionHost) -> Bool {
        if case .recording = host.stateMachine.current { return true }
        return false
    }

    private func switchCall(_ controller: MeetingSessionController, _ adapter: WindowAdapter, file: URL) {
        adapter.callWindow = read(2, "SSO sync")
        controller.callIdentityTick(file: file, now: Date(timeIntervalSince1970: 10))
        adapter.callWindow = read(2, "SSO sync")
        controller.callIdentityTick(file: file, now: Date(timeIntervalSince1970: 14))
    }

    /// One cached read ticked over many times is one read: no split however long it is seen.
    func test_one_cached_read_never_splits_however_often_it_is_ticked() async throws {
        let file = tempDir.appendingPathComponent("20261112-140000.wav")
        let (controller, host, adapter) = try await recording(file)
        adapter.callWindow = read(2, "SSO sync")
        for t in stride(from: 10.0, through: 120, by: 2) {
            controller.callIdentityTick(file: file, now: Date(timeIntervalSince1970: t))
        }
        XCTAssertTrue(isRecording(host))
    }

    /// Ignored, a split's prompt becomes DET18's one-click offer even under
    /// `default_prompt_action = "record"`: the second call is recorded only on a yes.
    func test_an_ignored_split_prompt_offers_and_never_records_on_its_own() async throws {
        let logs = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }
        let file = tempDir.appendingPathComponent("20261112-200000.wav")
        let (controller, host, adapter) = try await recording(file)
        let config = tempDir.appendingPathComponent("config.toml")
        try "[detection]\ndefault_prompt_action = \"record\"\n".write(to: config, atomically: true, encoding: .utf8)
        host.configStore = ConfigStore(configURL: config)
        host.livePromptTimeoutSec = 0.01
        let startsBefore = host.recorderSpy.startCallCount

        switchCall(controller, adapter, file: file)
        await waitUntil({ host.promptSpy.presentCount == 1 }, "the split prompt")
        await waitUntil({ host.stateMachine.current == .idle }, "the timeout")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(host.recorderSpy.startCallCount, startsBefore, "nothing recorded without a click")
        let rows = ((try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        let timeout = rows.last { $0["action"] as? String == "prompt_timeout" }
        XCTAssertEqual(timeout?["effective_action"] as? String, "skip")
        XCTAssertEqual(timeout?["split"] as? Bool, true)
        XCTAssertTrue(rows.contains { $0["action"] as? String == "recording_split_on_call_change" })
    }

    func test_a_change_of_call_ends_the_stem_and_prompts_for_the_new_one() async throws {
        let first = tempDir.appendingPathComponent("20261112-172307.wav")
        let (controller, host, adapter) = try await recording(first)

        switchCall(controller, adapter, file: first)
        XCTAssertNil(controller.cancelCallIdentityTimer, "the stop disarmed the watch")
        await waitUntil({ if case .prompting = host.stateMachine.current { return true }; return false }, "the new call's prompt")
        XCTAssertEqual(host.promptSpy.presentCount, 1)
        guard case .prompting(let prompted) = host.stateMachine.current else { return XCTFail("expected a prompt") }
        XCTAssertEqual(prompted.meetingTitle, "SSO sync", "the prompt names call B, not call A")
        XCTAssertNil(try meta(for: first)[MeetingMetaSidecar.splitFromKey])

        let second = tempDir.appendingPathComponent("20261112-172912.wav")
        host.recorderSpy.fileToReturn = second
        controller.beginRecording(source: prompted, summaryMode: .auto)
        await waitUntil({ isRecording(host) }, "the second call to record")
        controller.stopRecording(file: second, source: prompted, summaryMode: .auto, cause: .lifecycleEnd)
        await waitUntil({ host.stateMachine.current == .idle }, "the second flush")
        let secondMeta = try meta(for: second)
        XCTAssertEqual(secondMeta[MeetingMetaSidecar.splitFromKey] as? String, "20261112-172307")
        XCTAssertNil(secondMeta[ResumeAfterEnd.metaKey], "a split is two meetings, not a resume to merge")
        XCTAssertEqual(secondMeta["meeting_title"] as? String, "SSO sync")
    }

    func test_the_same_call_or_an_unreadable_title_keeps_recording() async throws {
        let file = tempDir.appendingPathComponent("20261112-150000.wav")
        let (controller, host, adapter) = try await recording(file)
        for (t, value) in [(10.0, read(1, "Standup")), (20, read(5, "Standup")), (30, nil), (40, read(1, "Chat | Someone"))] as [(Double, CallWindowRead?)] {
            adapter.callWindow = value
            controller.callIdentityTick(file: file, now: Date(timeIntervalSince1970: t))
        }
        XCTAssertTrue(isRecording(host))
        XCTAssertNil(controller.pendingSplit)
    }

    /// A Stop pressed while the split's stop is still flushing is a Stop: no prompt follows it.
    func test_a_stop_during_the_split_drops_the_prompt() async throws {
        let file = tempDir.appendingPathComponent("20261112-160000.wav")
        let (controller, host, adapter) = try await recording(file)
        switchCall(controller, adapter, file: file)
        controller.forceStop(reason: "panic")
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
        await Task.yield()
        XCTAssertEqual(host.promptSpy.presentCount, 0)
    }

    /// A skipped split prompt takes its link with it, so the next start is not marked a split.
    func test_a_skipped_split_prompt_leaks_no_link() async throws {
        let file = tempDir.appendingPathComponent("20261112-170000.wav")
        let (controller, host, adapter) = try await recording(file)
        switchCall(controller, adapter, file: file)
        await waitUntil({ if case .prompting = host.stateMachine.current { return true }; return false }, "the prompt")
        controller.forceStop(reason: "panic")
        XCTAssertNil(controller.pendingSplitFrom)

        let next = tempDir.appendingPathComponent("20261112-171000.wav")
        host.recorderSpy.fileToReturn = next
        controller.beginRecording(source: AppSource(bundleID: teams.bundleID, displayName: teams.displayName, meetingTitle: "SSO sync"), summaryMode: .auto)
        await waitUntil({ isRecording(host) }, "the next recording")
        controller.stopRecording(file: next, source: teams, summaryMode: .auto, cause: .lifecycleEnd)
        await waitUntil({ host.stateMachine.current == .idle }, "its flush")
        XCTAssertNil(try meta(for: next)[MeetingMetaSidecar.splitFromKey])
    }

    /// Off the record is a span the owner opened on purpose; a split would close it.
    func test_no_split_while_off_the_record() async throws {
        let file = tempDir.appendingPathComponent("20261112-180000.wav")
        let (controller, host, adapter) = try await recording(file)
        controller.toggleOffTheRecord()
        switchCall(controller, adapter, file: file)
        XCTAssertTrue(isRecording(host))
    }

    /// A browser recording is not watched: it has no Leave control to read.
    func test_a_browser_recording_arms_no_watch() async {
        let host = FakeSessionHost(tempDir: tempDir)
        let controller = MeetingSessionController(coordinator: host)
        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20261112-190000.wav")
        controller.beginRecording(source: AppSource(bundleID: "com.google.Chrome", displayName: "Google Chrome", kind: .browser), summaryMode: .auto)
        await waitUntil({ isRecording(host) }, "the recording")
        XCTAssertNil(controller.cancelCallIdentityTimer)
        withExtendedLifetime(host) {}
    }
}
