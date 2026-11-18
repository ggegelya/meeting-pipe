import ApplicationServices
import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// END19: the bound on a discovery engage that discovery stopped sighting, and what a source-less
/// recording does with an end from such an engage.
final class StaleEngageBoundTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)

    func test_anIdleEngage_isTornDownAfterItsLifeOfWinnerlessScans() {
        var bound = StaleEngageBound()
        bound.sighted(bundleID: "com.google.Chrome", at: t0)
        for scan in 1..<StaleEngageBound.scansWithoutSighting {
            XCTAssertEqual(bound.scanWithoutWinner(engineIdle: true, at: t0.addingTimeInterval(Double(scan) * 12)), .keep)
        }
        XCTAssertEqual(
            bound.scanWithoutWinner(engineIdle: true, at: t0.addingTimeInterval(60)),
            .disengage(bundleID: "com.google.Chrome", engagedSec: 60, scansWithoutSighting: StaleEngageBound.scansWithoutSighting)
        )
        XCTAssertNil(bound.engage, "torn down once")
    }

    func test_aSightingInsideTheLife_restartsIt_andKeepsTheFirstEngageTime() {
        var bound = StaleEngageBound()
        bound.sighted(bundleID: "com.google.Chrome", at: t0)
        for _ in 1..<StaleEngageBound.scansWithoutSighting {
            _ = bound.scanWithoutWinner(engineIdle: true, at: t0)
        }
        bound.sighted(bundleID: "com.google.Chrome", at: t0.addingTimeInterval(50))
        XCTAssertEqual(bound.scanWithoutWinner(engineIdle: true, at: t0.addingTimeInterval(62)), .keep)
        XCTAssertEqual(bound.engage?.engagedAt, t0)
    }

    func test_anEngageThatReachedStarting_isNeverTornDown() {
        var bound = StaleEngageBound()
        bound.sighted(bundleID: "com.microsoft.teams2", at: t0)
        for _ in 0..<(StaleEngageBound.scansWithoutSighting * 3) {
            XCTAssertEqual(bound.scanWithoutWinner(engineIdle: false, at: t0), .keep)
        }
    }

    /// The life is DET9's skip-latch grace in polls, not a guess of its own.
    func test_theLife_isTheSkipLatchGraceInPolls() {
        XCTAssertEqual(StaleEngageBound.scansWithoutSighting, Int(DetectionStateMachine.skipLatchGracePolls))
    }

    /// Item 2's predicate half: the scanner admits a plain browser tab only on a strong title, and
    /// every strong title is one the browser adapter's window signal reads as live, so discovery
    /// cannot engage a tab the end side could never see as a meeting. Shape classes only.
    func test_everyTitleTheScannerAdmits_isOneTheAdapterReadsLive() {
        let shapes = [
            "Meet - abc-defg-hij", "abc-defg-hij - Google Meet", "meet.google.com/abc-defg-hij",
            "Weekly sync | Microsoft Teams", "Webex meeting", "Huddle in #general", "Level 10 Meeting - Jira",
            "one-more-day", "Google Meet", "Inbox (3) - Gmail", "",
        ]
        for title in shapes where MeetingSourceScanner.browserWindowIndicatesStrongMeeting(title: title) {
            XCTAssertTrue(
                BrowserMeetingLifecycleAdapter.defaultTitleMatchers.contains { $0(title) },
                "the scanner admits \"\(title)\" but the window signal would never read it live"
            )
        }
        XCTAssertTrue(shapes.contains { MeetingSourceScanner.browserWindowIndicatesStrongMeeting(title: $0) }, "the fixture exercises an admission")
    }
}

@MainActor
final class StaleEngageSessionTests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!
    private var hosts: [FakeSessionHost] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("end19-\(UUID().uuidString)", isDirectory: true)
        logs = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    /// A browser lifecycle adapter for Chrome, driven by hand.
    final class ChromeAdapter: LifecycleAdapter {
        let bundleIDs: Set<String> = ["com.google.Chrome"]
        let kind: MeetingLifecycleContext.Kind = .browser
        private(set) var starts = 0
        private(set) var sink: ((PrimarySignalEvent) -> Void)?
        func start(context: MeetingLifecycleContext, handle: LifecycleAdapterHandle, sink: @escaping (PrimarySignalEvent) -> Void) throws {
            starts += 1
            self.sink = sink
        }
        func stop() {}
        func emit(_ kind: PrimarySignalKind, _ state: PrimarySignalState, _ context: MeetingLifecycleContext) {
            sink?(PrimarySignalEvent(kind: kind, state: state, timestamp: Date(), context: context))
        }
    }

    private let chrome = AppSource(bundleID: "com.google.Chrome", displayName: "Google Chrome", kind: .browser)
    private let chromeContext = MeetingLifecycleContext(bundleID: "com.google.Chrome", kind: .browser, pid: 5151)

    private func makeController() -> (MeetingSessionController, FakeSessionHost, ChromeAdapter) {
        let host = FakeSessionHost(tempDir: tempDir)
        hosts.append(host)
        host.recorderSpy.lastSystemFires = 1
        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20261111-155951.wav")
        let adapter = ChromeAdapter()
        host.lifecycleCoord = MeetingLifecycleCoordinator(adapters: [adapter])
        let controller = MeetingSessionController(coordinator: host)
        let context = chromeContext
        controller.engageSeams.buildHandles = { _, _ in
            MeetingAXHandleBuilder.Handles(lifecycle: LifecycleAdapterHandle(), micGate: MicGateAdapterHandle(), context: context)
        }
        return (controller, host, adapter)
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

    private func rows(_ action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    private var isRecording: (FakeSessionHost) -> Bool = { host in
        if case .recording = host.stateMachine.current { return true }
        return false
    }

    // MARK: - Item 1

    func test_anEngageDiscoveryStopsSighting_isDisengagedAfterItsLife() async {
        let (controller, host, _) = makeController()
        controller.handleDiscovery(chrome)
        await waitUntil({ host.lifecycleCoord.isEngaged }, "the discovery engage")
        for _ in 0..<StaleEngageBound.scansWithoutSighting {
            controller.handleScanWithoutWinner()
        }
        XCTAssertFalse(host.lifecycleCoord.isEngaged)
        let row = rows("lifecycle_disengaged_stale").first
        XCTAssertEqual(row?["bundle_id"] as? String, chrome.bundleID)
        XCTAssertEqual(row?["scans_without_sighting"] as? Int, StaleEngageBound.scansWithoutSighting)
    }

    func test_anEngageReSightedInsideItsLife_isKept() async {
        let (controller, host, _) = makeController()
        controller.handleDiscovery(chrome)
        await waitUntil({ host.lifecycleCoord.isEngaged }, "the discovery engage")
        for _ in 1..<StaleEngageBound.scansWithoutSighting { controller.handleScanWithoutWinner() }
        controller.handleDiscovery(chrome)
        for _ in 1..<StaleEngageBound.scansWithoutSighting { controller.handleScanWithoutWinner() }
        XCTAssertTrue(host.lifecycleCoord.isEngaged)
        XCTAssertTrue(rows("lifecycle_disengaged_stale").isEmpty)
    }

    // MARK: - Item 3 (owner's decision 2026-11-16)

    /// The 2026-11-11 shape: a browser engage left `.idle`, a hand start with no source, then the
    /// tab title matches (`.starting`) and leaves its pattern (`.ended`, unconfirmed) mid-recording.
    func test_aStaleBrowserEngagesEnd_doesNotStopAHandStartedRecording() async throws {
        let (controller, host, adapter) = makeController()
        controller.startConsumers()
        defer { controller.shutdownConsumers() }
        controller.handleDiscovery(chrome)
        await waitUntil({ host.lifecycleCoord.isEngaged }, "the stale engage")

        controller.toggleManual(surface: .menu)
        await waitUntil({ self.isRecording(host) }, "the hand start")
        adapter.emit(.browserTabTitle, .live, chromeContext)
        await waitUntil({ host.lifecycleCoord.current == .starting(context: chromeContext) }, "the late starting")
        adapter.emit(.browserTabTitle, .ended, chromeContext)
        await waitUntil({ !self.rows("meeting_end_ignored_sourceless").isEmpty }, "the ignored end")

        XCTAssertTrue(isRecording(host), "the hand-started recording keeps running")
        XCTAssertEqual(host.recorderSpy.stopCallCount, 0)
        let rows = rows("meeting_end_ignored_sourceless")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["ended_bundle_id"] as? String, chrome.bundleID)
        XCTAssertEqual(rows.first?["engaged_before_recording"] as? Bool, true)
        XCTAssertEqual(host.promptSpy.presentCount, 0)
        controller.forceStop(reason: "test")
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
    }

    /// END21 amendment (2026-11-17): a hold the stale engage opened and then concluded leaves a cut
    /// behind, armed by `resolveTeardownHold` before `handleMeetingEnded` ignores the end. The
    /// recording keeps running on a terminal engine, so nothing else would clear it, and the hand
    /// Stop much later consumed it: under NDA it truncated the audio at the foreign hold's stamp.
    /// The verdicts are published straight to the coordinator; the engine route to this shape needs
    /// the foreign engage promoted without an `.inMeeting` under the recording, which END19's
    /// review traced only through M2 (a skipped engage), and the controller's handling is the same.
    private func recordOverAForeignHeldEnd(workflows: [Workflow]) async throws -> (MeetingSessionController, FakeSessionHost) {
        let host = FakeSessionHost(tempDir: tempDir, workflows: workflows)
        host.recorderSpy.lastSystemFires = 1
        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20261117-100000.wav")
        let adapter = ChromeAdapter()
        host.lifecycleCoord = MeetingLifecycleCoordinator(adapters: [adapter])
        let controller = MeetingSessionController(coordinator: host)
        let context = chromeContext
        controller.engageSeams.buildHandles = { _, _ in
            MeetingAXHandleBuilder.Handles(lifecycle: LifecycleAdapterHandle(), micGate: MicGateAdapterHandle(), context: context)
        }
        controller.startConsumers()
        controller.handleDiscovery(chrome)
        await waitUntil({ host.lifecycleCoord.isEngaged }, "the stale engage")
        controller.toggleManual(surface: .menu)
        await waitUntil({ self.isRecording(host) }, "the hand start")

        let reason = EndingReason(
            leadingSignal: PrimarySignalKind.browserTabTitle.rawValue,
            confirmedBy: [PrimarySignalKind.shareableContentWindow.rawValue]
        )
        host.lifecycleCoord.publish(.endingProvisional(context: context, reason: reason))
        await waitUntil({ controller.holdPolicy.isOpen }, "the foreign hold")
        // Old enough that concluding it arms a cut (`minimumTrimmedHoldSec`).
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        host.lifecycleCoord.publish(.ended(context: context, reason: reason))
        await waitUntil({ !self.rows("meeting_end_ignored_sourceless").isEmpty }, "the ignored end")
        await waitUntil({ !self.rows("lifecycle_recording_on_terminal_engine").isEmpty }, "the terminal-engine row")
        XCTAssertTrue(isRecording(host), "the hand-started recording keeps running")
        XCTAssertEqual(rows("lifecycle_recording_on_terminal_engine").first?["trim_dropped"] as? Bool, true)
        return (controller, host)
    }

    func test_aForeignHeldEndTheRecordingIgnored_leavesNoCutForALaterStop_underNDA() async throws {
        var nda = Workflow(name: "Client NDA")
        nda.flags.ndaMode = true
        nda.isDefault = true
        let (controller, host) = try await recordOverAForeignHeldEnd(workflows: [nda])
        controller.toggleManual(surface: .menu)
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
        controller.shutdownConsumers()

        XCTAssertEqual(host.recorderSpy.stopCallCount, 1)
        XCTAssertTrue(rows("held_end_trimmed").isEmpty, "no cut from the hold the recording ignored")
        XCTAssertNil(host.recorderSpy.lastStopLimitSeconds ?? nil, "the audio is not truncated at stop")
    }

    func test_aForeignHeldEndTheRecordingIgnored_leavesNoSuggestedTrim() async throws {
        // A default workflow so the sidecar is written at all (an empty one is skipped).
        var plain = Workflow(name: "Default")
        plain.isDefault = true
        let (controller, host) = try await recordOverAForeignHeldEnd(workflows: [plain])
        controller.toggleManual(surface: .menu)
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
        controller.shutdownConsumers()

        XCTAssertTrue(rows("held_end_trimmed").isEmpty)
        let meta = tempDir.appendingPathComponent("20261117-100000.meta.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: meta)) as? [String: Any])
        XCTAssertNil(json[HeldEndTrim.metaKey], "no held_end_trim_sec in the sidecar")
    }

    /// An engage the hand start promoted is the recording's own, so its end is honoured, and the
    /// same browser sighted again inside the window is offered back (item 4). Owner's decision
    /// 2026-11-16 (DET17): a browser resume prompts rather than recording without a click.
    func test_anEngageTheHandStartPromoted_endsIt_andTheCallResumes() async throws {
        let (controller, host, adapter) = makeController()
        controller.handleDiscovery(chrome)
        await waitUntil({ host.lifecycleCoord.isEngaged }, "the engage")
        adapter.emit(.browserTabTitle, .live, chromeContext)
        await waitUntil({ host.lifecycleCoord.current == .starting(context: chromeContext) }, "starting")

        controller.toggleManual(surface: .menu)
        await waitUntil({ host.lifecycleCoord.current == .inMeeting(context: chromeContext) }, "the start's promotion")
        controller.startConsumers()
        defer { controller.shutdownConsumers() }
        await waitUntil({ self.isRecording(host) }, "the recording")
        // The buffered verdicts reach the consumer; give the `.inMeeting` a moment to be noted.
        try? await Task.sleep(nanoseconds: 50_000_000)

        adapter.emit(.workspaceAppTerminated, .ended, chromeContext)
        await waitUntil({ host.recorderSpy.stopCallCount == 1 }, "the honoured end")
        XCTAssertTrue(rows("meeting_end_ignored_sourceless").isEmpty)
        XCTAssertEqual(controller.resumeCandidate?.bundleID, chrome.bundleID, "keyed to the app that ended it")
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")

        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20261111-161500.wav")
        controller.handleMeetingStarted(source: chrome)
        XCTAssertEqual(host.promptSpy.presentCount, 1, "prompted, inside the cooldown the end armed")
        XCTAssertEqual(host.recorderSpy.startCallCount, 1, "no recording without a click")
        XCTAssertEqual(rows("browser_resume_prompted").count, 1)
        controller.resolvePromptPick(.record, source: chrome)
        await waitUntil({ self.isRecording(host) }, "the clicked resume")
        controller.forceStop(reason: "test")
        await waitUntil({ host.stateMachine.current == .idle }, "the second flush")
    }
}

/// END19's wiring fence, in END10's shape: the no-winner scan only bounds anything if the watcher
/// reports it and the coordinator hands it to the session.
final class StaleEngageWiringFenceTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func test_theWatcherReportsWinnerlessScans_andTheCoordinatorForwardsThem() throws {
        let watcher = try source("daemon/Sources/MeetingPipe/MeetingDiscoveryWatcher.swift")
        XCTAssertTrue(watcher.contains("self.onScanWithoutWinner?()"), "the watcher no longer reports a no-winner scan")
        let coordinator = try source("daemon/Sources/MeetingPipe/Coordinator.swift")
        XCTAssertTrue(
            coordinator.contains("discoveryWatcher.onScanWithoutWinner = {")
                && coordinator.contains("self?.session.handleScanWithoutWinner()"),
            "the coordinator no longer forwards no-winner scans, so a stale engage is never bounded"
        )
    }
}

/// END19 amendment (2026-11-17, M2 of the post-audit review): a record start for one app that finds
/// another app's engine engaged replaces it instead of keeping it as `already_engaged`. The
/// review's route: a Teams call on offer, a named Meet tab wins a scan and discovery engages Chrome,
/// the owner clicks the Teams offer. Real controller, real coordinator and engine, two hand-driven
/// adapters, and `EngageOffMainTests`' build.
@MainActor
final class ForeignEngageAtStartTests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("end19m2-\(UUID().uuidString)", isDirectory: true)
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
    private let chromeContext = MeetingLifecycleContext(bundleID: "com.google.Chrome", kind: .browser, pid: 5151)

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

    private func emit(_ adapter: EngageOffMainTests.CountingAdapter, _ kind: PrimarySignalKind, _ state: PrimarySignalState, _ context: MeetingLifecycleContext) {
        adapter.sink?(PrimarySignalEvent(kind: kind, state: state, timestamp: Date(), context: context))
    }

    func test_aRecordStartOverAnotherAppsEngine_engagesItsOwn_andItsEndIsHonoured() async throws {
        let host = FakeSessionHost(tempDir: tempDir)
        host.recorderSpy.lastSystemFires = 1
        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20261117-110000.wav")
        let chromeAdapter = StaleEngageSessionTests.ChromeAdapter()
        let teamsAdapter = EngageOffMainTests.CountingAdapter()
        host.lifecycleCoord = MeetingLifecycleCoordinator(adapters: [chromeAdapter, teamsAdapter])
        let controller = MeetingSessionController(coordinator: host)
        // Gated, so the commit runs before the record start's build lands, as it does when the AX
        // walk is slow: the commit's promotion is then the only thing between Chrome's engine and
        // the recording.
        let build = EngageOffMainTests.GatedBuild(gated: true)
        controller.engageSeams.buildHandles = { source, _ in build.build(source) }
        controller.engageSeams.resolveStartingSource = { context in
            AppSource(bundleID: context.bundleID, displayName: "Google Chrome", kind: .browser)
        }

        // Discovery engaged Chrome and its tab reads live: the engine is `.starting` for Chrome.
        try host.lifecycleCoord.engage(context: chromeContext, handle: LifecycleAdapterHandle())
        chromeAdapter.emit(.browserTabTitle, .live, chromeContext)
        await waitUntil({ host.lifecycleCoord.current == .starting(context: self.chromeContext) }, "Chrome's starting")

        // The click on the Teams offer.
        controller.recordAttached(to: teams, trigger: "test")
        await waitUntil({ !self.rows("lifecycle_promotion_skipped").isEmpty }, "the commit")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(host.lifecycleCoord.current, .starting(context: chromeContext), "Chrome's engine is not promoted for the Teams recording")
        build.gate.signal()
        await waitUntil({ teamsAdapter.starts.count == 1 }, "the Teams engage")
        if case .recording(_, let src?, _) = host.stateMachine.current {
            XCTAssertEqual(src.bundleID, teams.bundleID)
        } else {
            XCTFail("recording the Teams call")
        }
        XCTAssertEqual(host.lifecycleCoord.engagedBundleID, teams.bundleID, "the recording's own adapter is engaged")
        XCTAssertEqual(rows("lifecycle_promotion_skipped").first?["engaged_bundle_id"] as? String, chromeContext.bundleID)
        let reengaged = try XCTUnwrap(rows("lifecycle_reengaged").first)
        XCTAssertEqual(reengaged["reason"] as? String, "other_app_at_start")
        XCTAssertEqual(reengaged["engaged_bundle_id"] as? String, chromeContext.bundleID)
        XCTAssertTrue(rows("lifecycle_engage_skipped").allSatisfy { $0["reason"] as? String != "already_engaged" })

        // The Teams engine follows the call and its end stops the recording.
        controller.startConsumers()
        defer { controller.shutdownConsumers() }
        let recorded = try XCTUnwrap(teamsAdapter.starts.last.map {
            MeetingLifecycleContext(bundleID: teams.bundleID, kind: .native, pid: $0.pid)
        })
        emit(teamsAdapter, .axLeaveButton, .live, recorded)
        await waitUntil({ host.lifecycleCoord.current == .inMeeting(context: recorded) }, "the Teams promotion")
        emit(teamsAdapter, .workspaceAppTerminated, .ended, recorded)
        await waitUntil({ host.recorderSpy.stopCallCount == 1 }, "the honoured end")
        XCTAssertTrue(rows("meeting_end_ignored_other_app").isEmpty)
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
    }
}
