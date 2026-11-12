import AppKit
import XCTest
@testable import MeetingPipe

/// REC20 items 1 and 2: the byte rates a recording costs, the three-band decision over free-space
/// readings, and the watch that turns a reading into a stop through the ordinary path.
final class RecordingLowSpaceREC20Tests: XCTestCase {

    private let gb: Int64 = 1_000_000_000
    private let rate = RecordingSpaceBudget.nominalCaptureBytesPerSecond

    // MARK: - The rates (one home, read by the preflight and the growth copy)

    func test_the_final_rate_projects_an_hour_to_230_4_MB() {
        XCTAssertEqual(RecordingSpaceBudget.finalBytes(seconds: 3_600), 230_400_000)
        XCTAssertEqual(RecordingSpaceBudget.finalBytesPerSecond, 16_000 * 2 * 2, "16 kHz stereo s16")
    }

    func test_the_system_rate_is_the_capture_formats_own() {
        XCTAssertEqual(
            RecordingSpaceBudget.systemCaptureBytesPerSecond,
            MeetingRecorder.bytesPerSecond(SystemAudioCapture.captureFormat)
        )
        XCTAssertEqual(RecordingSpaceBudget.nominalCaptureBytesPerSecond, 576_000)
    }

    func test_the_wrong_rate_is_gone_from_the_retention_doc() throws {
        let workflow = try source("Sources/MeetingPipe/Workflow.swift")
        XCTAssertFalse(workflow.contains("0.7 GB"))
    }

    // MARK: - Hours covered

    func test_covered_seconds_counts_capture_plus_merge_per_second() {
        // 640,000 B/s for every further second, after the one-minute margin.
        let margin = RecordingLowSpace.marginBytes(captureBytesPerSecond: rate)
        XCTAssertEqual(margin, 38_400_000)
        let free = margin + 640_000 * 3_600
        XCTAssertEqual(RecordingLowSpace.coveredSeconds(freeBytes: free, elapsedSeconds: 0), 3_600, accuracy: 0.001)
    }

    func test_covered_seconds_reserves_the_merge_of_what_is_already_recorded() {
        let margin = RecordingLowSpace.marginBytes(captureBytesPerSecond: rate)
        let merge = RecordingSpaceBudget.finalBytes(seconds: 7_200)
        XCTAssertEqual(
            RecordingLowSpace.coveredSeconds(freeBytes: merge + margin, elapsedSeconds: 7_200), 0,
            "exactly the merge plus the margin covers nothing more"
        )
        XCTAssertEqual(
            RecordingLowSpace.coveredSeconds(freeBytes: merge + margin + 640_000 * 60, elapsedSeconds: 7_200),
            60, accuracy: 0.001
        )
        XCTAssertEqual(RecordingLowSpace.coveredSeconds(freeBytes: 0, elapsedSeconds: 7_200), 0)
    }

    // MARK: - Preflight (item 1)

    func test_preflight_is_silent_with_two_hours_covered_and_warns_below() {
        let twoHours = RecordingLowSpace.marginBytes(captureBytesPerSecond: rate) + 640_000 * 7_200
        XCTAssertNil(RecordingLowSpace.preflight(freeBytes: twoHours))
        let notice = RecordingLowSpace.preflight(freeBytes: twoHours - 640_000 * 1_800)
        XCTAssertEqual(notice?.hoursCovered ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(notice?.freeBytes, twoHours - 640_000 * 1_800)
    }

    func test_preflight_says_nothing_about_a_free_space_it_could_not_read() {
        XCTAssertNil(RecordingLowSpace.preflight(freeBytes: nil))
    }

    /// A meeting is never refused for space: the only use of the notice in `start()` is to arm
    /// the watch once the start has succeeded.
    func test_preflight_never_refuses_a_start() throws {
        let recorder = try source("Sources/MeetingPipe/MeetingRecorder.swift")
        let start = try XCTUnwrap(recorder.range(of: "let startNotice = RecordingLowSpace.preflight("))
        let armed = try XCTUnwrap(recorder.range(of: "armLowSpaceWatch(outputDir: outputDir, startNotice: startNotice)"))
        XCTAssertFalse(
            recorder[start.upperBound..<armed.lowerBound].contains("startNotice"),
            "nothing between the read and the arm may act on the notice, and so nothing can refuse on it"
        )
    }

    // MARK: - The three bands (item 2)

    private func free(coveringMinutes minutes: Double, elapsed: Double) -> Int64 {
        RecordingSpaceBudget.finalBytes(seconds: elapsed)
            + RecordingLowSpace.marginBytes(captureBytesPerSecond: rate)
            + Int64(minutes * 60 * 640_000)
    }

    func test_a_sequence_of_readings_warns_once_then_stops_once() {
        var policy = RecordingLowSpace.Policy(captureBytesPerSecond: rate)
        let readings: [(Int64?, Double)] = [
            (free(coveringMinutes: 600, elapsed: 60), 60),     // fine
            (free(coveringMinutes: 90, elapsed: 120), 120),    // under 2 h: label only
            (free(coveringMinutes: 14, elapsed: 180), 180),    // warn
            (free(coveringMinutes: 10, elapsed: 240), 240),    // still warn band: said once
            (nil, 300),                                        // unreadable: decides nothing
            (free(coveringMinutes: 0, elapsed: 360), 360),     // stop
            (free(coveringMinutes: 0, elapsed: 420), 420),     // after the stop: nothing
        ]
        let actions = readings.map { policy.evaluate(freeBytes: $0.0, elapsedSeconds: $0.1)?.action }
        XCTAssertEqual(actions, [.fine, .fine, .warn, .fine, nil, .stop, nil])
    }

    func test_the_label_counts_down_only_under_two_hours() {
        var policy = RecordingLowSpace.Policy(captureBytesPerSecond: rate)
        XCTAssertNil(policy.evaluate(freeBytes: free(coveringMinutes: 600, elapsed: 0), elapsedSeconds: 0)?.hudText)
        XCTAssertEqual(
            policy.evaluate(freeBytes: free(coveringMinutes: 85.5, elapsed: 0), elapsedSeconds: 0)?.hudText,
            "Disk: 1h 25m left"
        )
    }

    func test_a_start_already_told_it_is_short_is_not_warned_again() {
        var policy = RecordingLowSpace.Policy(captureBytesPerSecond: rate, startCovered: 10 * 60)
        XCTAssertEqual(
            policy.evaluate(freeBytes: free(coveringMinutes: 9, elapsed: 60), elapsedSeconds: 60)?.action, .fine
        )
        XCTAssertEqual(
            policy.evaluate(freeBytes: free(coveringMinutes: 0, elapsed: 120), elapsedSeconds: 120)?.action, .stop,
            "but it still stops"
        )
    }

    func test_the_first_reading_in_the_stop_band_stops_without_warning_first() {
        var policy = RecordingLowSpace.Policy(captureBytesPerSecond: rate)
        XCTAssertEqual(policy.evaluate(freeBytes: 1_000, elapsedSeconds: 3_600)?.action, .stop)
    }

    // MARK: - Copy

    func test_hud_text_forms() {
        XCTAssertEqual(RecordingLowSpace.hudText(coveredSeconds: 119 * 60 + 59), "Disk: 1h 59m left")
        XCTAssertEqual(RecordingLowSpace.hudText(coveredSeconds: 25 * 60), "Disk: 25m left")
        XCTAssertEqual(RecordingLowSpace.hudText(coveredSeconds: 0), "Disk: 0m left")
    }

    /// The countdown shares the pill with "Recording" and "Off the record", and the pill never
    /// resizes for a label (UX35). The longest form has to fit, measured the way the HUD lays it out.
    func test_the_longest_countdown_fits_the_pill() {
        let label = NSTextField(labelWithString: RecordingLowSpace.hudText(coveredSeconds: 119 * 60))
        label.font = .systemFont(ofSize: 10, weight: MPType.medium)
        XCTAssertGreaterThan(HUDPanelGeometry.pillWidth, 8 + 5 + label.intrinsicContentSize.width)
    }

    func test_the_messages_name_the_free_space_and_the_time() {
        let start = RecordingLowSpace.startMessage(.init(freeBytes: 3 * gb, coveredSeconds: 5_400))
        XCTAssertTrue(start.body.contains("3 GB"), start.body)
        XCTAssertTrue(start.body.contains("1 hour, 30 minutes") || start.body.contains("1 hour 30 minutes"), start.body)
        XCTAssertTrue(RecordingLowSpace.stopMessage(freeBytes: 2 * gb).hasPrefix("Recording stopped:"))
    }

    // MARK: - HUD label precedence

    func test_label_precedence_lost_mic_then_disk_then_off_record_then_confirming_end() {
        typealias L = HUDStateLabel
        XCTAssertEqual(L.resolve(micCaptureLost: true, lowSpace: "Disk: 5m left", offRecord: true, confirmingEnd: true).text, "Mic lost")
        XCTAssertEqual(L.resolve(micCaptureLost: false, lowSpace: "Disk: 5m left", offRecord: true, confirmingEnd: true).text, "Disk: 5m left")
        XCTAssertEqual(L.resolve(micCaptureLost: false, lowSpace: nil, offRecord: true, confirmingEnd: true).text, "Off the record")
        XCTAssertEqual(L.resolve(micCaptureLost: false, lowSpace: nil, offRecord: false, confirmingEnd: true).text, "Confirming end")
        XCTAssertEqual(L.resolve(micCaptureLost: false, lowSpace: nil, offRecord: false, confirmingEnd: false).text, "Recording")
        XCTAssertEqual(L.resolve(micCaptureLost: false, lowSpace: "x", offRecord: false, confirmingEnd: false).tone, .alert)
    }

    // MARK: - The watch

    private var events: [(action: String, attributes: [String: Any])] = []
    private var updates: [RecordingLowSpace.Update] = []
    private var nextFree: Int64? = 0
    private var clock: Double = 1_000

    private func makeWatch() -> LowSpaceWatch {
        let watch = LowSpaceWatch(
            startsTimer: false,
            freeSpace: { [unowned self] _ in (self.nextFree, "Test Volume") },
            mainHop: { $0() },
            uptime: { [unowned self] in self.clock },
            emit: { [unowned self] action, attributes in self.events.append((action, attributes)) }
        )
        watch.onUpdate = { [unowned self] update in self.updates.append(update) }
        return watch
    }

    private let dir = URL(fileURLWithPath: "/nonexistent/rec20")

    /// The acceptance's stop: the stop band emits `recording_stopped_low_space` and hands the
    /// session a `.stop`, which it routes through `forceStop` (pinned below), and it never touches
    /// `onWriteFailure`, the force-stop REC3 built for failed writes.
    func test_the_stop_band_hands_over_a_stop_and_never_a_write_failure() {
        let router = WriteFailureRouter(mainHop: { $0() }, freeSpace: { _ in (nil, nil) }, emit: { _, _ in })
        var writeFailures = 0
        router.onWriteFailure = { _ in writeFailures += 1 }
        router.beginRecording()

        let watch = makeWatch()
        watch.begin(directory: dir, captureBytesPerSecond: rate, start: nil)
        clock += 3_600
        nextFree = free(coveringMinutes: 0, elapsed: 3_600)
        watch.pollNow()

        XCTAssertEqual(events.map(\.action), ["recording_stopped_low_space"])
        XCTAssertEqual(events.first?.attributes["merge_bytes"] as? Int64, 230_400_000)
        XCTAssertEqual(events.first?.attributes["elapsed_sec"] as? Int, 3_600)
        guard case .stop(let message)? = updates.last else { return XCTFail("no stop: \(updates)") }
        XCTAssertTrue(message.hasPrefix("Recording stopped:"))
        XCTAssertEqual(writeFailures, 0)

        watch.pollNow()
        XCTAssertEqual(events.count, 1, "the stop is said once")
    }

    func test_the_warning_is_logged_once_and_the_label_is_pushed_only_when_it_changes() {
        let watch = makeWatch()
        watch.begin(directory: dir, captureBytesPerSecond: rate, start: nil)
        nextFree = free(coveringMinutes: 600, elapsed: 0)
        watch.pollNow()
        XCTAssertTrue(updates.isEmpty, "plenty of space: nothing to say")

        nextFree = free(coveringMinutes: 14.5, elapsed: 0)
        watch.pollNow()
        watch.pollNow()
        XCTAssertEqual(events.map(\.action), ["recording_low_space"])
        XCTAssertEqual(events.first?.attributes["minutes_covered"] as? Int, 14)
        guard case .warn(let hudText, let title, _)? = updates.first else { return XCTFail("\(updates)") }
        XCTAssertEqual(hudText, "Disk: 14m left")
        XCTAssertEqual(title, "Disk almost full")
        XCTAssertEqual(updates.count, 1, "an unchanged label is not pushed again")

        nextFree = free(coveringMinutes: 13.5, elapsed: 0)
        watch.pollNow()
        XCTAssertEqual(updates.last, .label("Disk: 13m left"))
    }

    func test_a_reading_for_an_ended_recording_does_nothing() {
        var held: (() -> Void)?
        let watch = LowSpaceWatch(
            startsTimer: false,
            freeSpace: { _ in (0, nil) },
            mainHop: { held = $0 },
            uptime: { 0 },
            emit: { [unowned self] action, attributes in self.events.append((action, attributes)) }
        )
        watch.onUpdate = { [unowned self] update in self.updates.append(update) }
        watch.begin(directory: dir, captureBytesPerSecond: rate, start: nil)
        watch.pollNow()          // read on the queue; the hop is still in flight
        watch.end()              // the recording stops
        watch.begin(directory: dir, captureBytesPerSecond: rate, start: nil)  // and the next starts
        held?()                  // the old reading lands
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(updates.isEmpty, "a stale reading must never stop the next recording")
    }

    func test_an_unreadable_free_space_never_stops() {
        let watch = makeWatch()
        watch.begin(directory: dir, captureBytesPerSecond: rate, start: nil)
        nextFree = nil
        watch.pollNow()
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(updates.isEmpty)
    }

    // MARK: - Fences: the watch is armed, stood down, and wired

    func test_the_recorder_arms_the_watch_on_start_and_stands_it_down_with_the_timers() throws {
        let recorder = try source("Sources/MeetingPipe/MeetingRecorder.swift")
        XCTAssertTrue(recorder.contains("armLowSpaceWatch(outputDir: outputDir, startNotice: startNotice)\n        started = true"))
        XCTAssertTrue(recorder.contains("lowSpaceWatch.begin("))
        let standDown = try XCTUnwrap(recorder.range(of: "private func standDownTimersAndHooks() {"))
        XCTAssertTrue(recorder[standDown.upperBound...].prefix(400).contains("lowSpaceWatch.end()"))
        // The preflight reads through REC19's reader off main, before any file is created.
        let preflight = try XCTUnwrap(recorder.range(of: "let startNotice = RecordingLowSpace.preflight("))
        let marker = try XCTUnwrap(recorder.range(of: "let modeMarkerURL = outputDir"))
        XCTAssertLessThan(preflight.lowerBound, marker.lowerBound)
        XCTAssertTrue(recorder.contains("runBlockingWithTimeout(seconds: 2) {\n            let free = RecordingWriteFailure.freeSpace(at: directory).freeBytes"))
    }

    func test_the_coordinator_routes_low_space_to_the_session_not_to_the_write_failure_path() throws {
        let coordinator = try source("Sources/MeetingPipe/Coordinator.swift")
        XCTAssertTrue(coordinator.contains("recorder.onLowSpace = { [weak self] update in\n            self?.session.handleLowSpace(update)"))
        let watch = try source("Sources/MeetingPipe/LowSpaceWatch.swift")
        XCTAssertFalse(watch.contains("onWriteFailure?("))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

/// REC20 at the session spine: the start notice reaches the HUD the start just presented, and the
/// watch's stop goes through `forceStop`, the ordinary stop that merges.
@MainActor
final class LowSpaceSessionREC20Tests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rec20-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", tempDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func waitUntil(_ predicate: () -> Bool, _ what: String) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 500_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func recording() -> (MeetingSessionController, FakeSessionHost) {
        let host = FakeSessionHost(tempDir: tempDir)
        let controller = MeetingSessionController(coordinator: host)
        host.stateMachine.setRecording(
            file: tempDir.appendingPathComponent("20260710-120000.wav"), source: nil, summaryMode: .auto
        )
        return (controller, host)
    }

    func test_a_short_start_shows_the_countdown_and_notifies_once() async {
        let host = FakeSessionHost(tempDir: tempDir)
        host.recorderSpy.lowSpaceAtStart = RecordingLowSpace.StartNotice(freeBytes: 3_000_000_000, coveredSeconds: 4_500)
        let controller = MeetingSessionController(coordinator: host)
        controller.beginRecording(source: nil, summaryMode: .auto)
        await waitUntil({ host.hudSpy.presentCount == 1 && !host.hudSpy.lowSpaceTexts.isEmpty }, "the HUD")

        XCTAssertEqual(host.hudSpy.lowSpaceTexts, ["Disk: 1h 15m left"])
        XCTAssertEqual(host.notifierSpy.lowSpace.count, 1)
        XCTAssertEqual(host.notifierSpy.lowSpace.first?.title, "Low disk space")
        XCTAssertEqual(host.recorderSpy.stopCallCount, 0, "a short start still records")
    }

    func test_a_start_with_room_says_nothing() async {
        let host = FakeSessionHost(tempDir: tempDir)
        let controller = MeetingSessionController(coordinator: host)
        controller.beginRecording(source: nil, summaryMode: .auto)
        await waitUntil({ host.hudSpy.presentCount == 1 }, "the HUD")
        XCTAssertTrue(host.hudSpy.lowSpaceTexts.isEmpty)
        XCTAssertTrue(host.notifierSpy.lowSpace.isEmpty)
    }

    func test_the_stop_band_takes_the_ordinary_stop_path() async {
        let (controller, host) = recording()
        controller.handleLowSpace(.stop(message: RecordingLowSpace.stopMessage(freeBytes: 100)))
        await waitUntil({ host.recorderSpy.stopCallCount == 1 }, "the recorder stop")
        XCTAssertEqual(host.statusBarSpy.stoppingCount, 1)
        XCTAssertEqual(host.recorderSpy.lastStopLimitSeconds, .some(nil), "an ordinary stop, nothing trimmed")
        XCTAssertEqual(host.notifierSpy.errors.count, 1)
        XCTAssertTrue(host.notifierSpy.errors[0].hasPrefix("Recording stopped:"))
    }

    func test_a_warning_sets_the_label_and_notifies() {
        let (controller, host) = recording()
        controller.handleLowSpace(.warn(hudText: "Disk: 12m left", title: "Disk almost full", body: "b"))
        controller.handleLowSpace(.label("Disk: 11m left"))
        XCTAssertEqual(host.hudSpy.lowSpaceTexts, ["Disk: 12m left", "Disk: 11m left"])
        XCTAssertEqual(host.notifierSpy.lowSpace.count, 1)
        XCTAssertEqual(host.recorderSpy.stopCallCount, 0)
    }

    func test_nothing_happens_when_no_recording_is_live() async {
        let host = FakeSessionHost(tempDir: tempDir)
        let controller = MeetingSessionController(coordinator: host)
        controller.handleLowSpace(.stop(message: "x"))
        controller.handleLowSpace(.label("Disk: 1m left"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(host.recorderSpy.stopCallCount, 0)
        XCTAssertTrue(host.hudSpy.lowSpaceTexts.isEmpty)
        XCTAssertTrue(host.notifierSpy.errors.isEmpty)
    }
}
