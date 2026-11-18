import AppKit
import XCTest
@testable import MeetingPipe

/// OBS7: the stamps are wired where the audit could not measure. The controller half is behavioural
/// (a real `MeetingSessionController` over `FakeSessionHost`); the entry points that live on
/// `Coordinator` and the windows cannot be built headless, so a source fence pins that each opens
/// with its stamp, the way `CoordinatorWiringFenceTests` pins its seams.
@MainActor
final class UILatencyWiringTests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("obs7-\(UUID().uuidString)", isDirectory: true)
        logs = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func rows(_ action: String) -> [[String: Any]] {
        Log.drainAsyncWrites()
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    private func waitUntil(_ what: String, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    private let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")

    // MARK: Controller: the first visible state answers the click

    func test_a_start_and_a_stop_each_answer_their_click_with_one_ui_feedback_on_the_same_seq() async {
        let host = FakeSessionHost(tempDir: tempDir)
        host.recorderSpy.lastSystemFires = 1
        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20261117-120000.wav")
        let controller = MeetingSessionController(coordinator: host)
        controller.engageSeams.buildHandles = { _, _ in nil }

        let startSeq = UILatency.shared.action("hotkey_toggle", surface: "hotkey")
        controller.toggleManual(surface: .menu)
        await waitUntil("the HUD to present") { host.hudSpy.presentCount == 1 }
        await waitUntil("the start's feedback") { self.rows("ui_feedback").contains { $0["seq"] as? Int == startSeq } }

        let stopSeq = UILatency.shared.action("hud_stop", surface: "hud")
        controller.toggleManual(surface: .menu)
        await waitUntil("the stop's feedback") { self.rows("ui_feedback").contains { $0["seq"] as? Int == stopSeq } }

        for seq in [startSeq, stopSeq] {
            let answers = rows("ui_feedback").filter { $0["seq"] as? Int == seq }
            XCTAssertEqual(answers.count, 1, "seq \(seq) answered exactly once")
            XCTAssertNotNil(answers.first?["ms"] as? Int)
        }
        let click = rows("ui_action").filter { $0["seq"] as? Int == startSeq }
        XCTAssertEqual(click.count, 1)
        XCTAssertEqual(click.first?["name"] as? String, "hotkey_toggle", "the click name must survive Log.event, which owns the `action` key")
    }

    // MARK: Entry points open with their stamp

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe")
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The first statement after the opening line of `signature`'s body.
    private func firstStatement(in src: String, after signature: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let r = src.range(of: signature) else {
            XCTFail("no `\(signature)`", file: file, line: line); return ""
        }
        let rest = src[r.upperBound...]
        return rest.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.hasPrefix("//") && !$0.isEmpty } ?? ""
    }

    func test_each_click_entry_point_opens_with_its_ui_action() throws {
        let prompt = try source("MeetingPromptWindow.swift")
        for (fn, act) in [("handleRecord", "prompt_record"), ("handleSkip", "prompt_skip"),
                          ("handleAlways", "prompt_always"), ("handleRecordBYO", "prompt_record_byo")] {
            XCTAssertTrue(firstStatement(in: prompt, after: "fileprivate func \(fn)() {").contains("UILatency.shared.action(\"\(act)\", surface: \"prompt\")"), fn)
        }
        XCTAssertTrue(firstStatement(in: try source("RecordingHUDWindow.swift"), after: "fileprivate func handleStop() {")
            .contains("UILatency.shared.action(\"hud_stop\", surface: \"hud\")"))
        let menu = try source("Coordinator+MenuActions.swift")
        XCTAssertTrue(firstStatement(in: menu, after: "@objc func menuStart() {").contains("action(\"menu_start\""))
        XCTAssertTrue(firstStatement(in: menu, after: "@objc func menuStop() {").contains("action(\"menu_stop\""))
        XCTAssertTrue(firstStatement(in: try source("Coordinator+Delegates.swift"), after: "func notifierDidRequestStopRecording(_ notifier: Notifier) {")
            .contains("action(\"notification_stop\""))
        // The hotkey stamps before the main-queue hop, so the hop is inside the measurement.
        let coordinator = try source("Coordinator.swift")
        let stamp = coordinator.range(of: "UILatency.shared.action(\"hotkey_toggle\"")
        let hop = coordinator.range(of: "DispatchQueue.main.async { self?.session.toggleManual(surface: .hotkey) }")
        XCTAssertNotNil(stamp); XCTAssertNotNil(hop)
        if let stamp, let hop { XCTAssertLessThan(stamp.lowerBound, hop.lowerBound) }
        XCTAssertTrue(coordinator.contains("UILatency.shared.action(\"hotkey_force_stop\""))
        XCTAssertTrue(try source("Coordinator+Delegates.swift").contains("UILatency.shared.action(\"notification_record\""))
        let auto = try source("Automation/Coordinator+Automation.swift")
        for (arm, act) in [("case .toggle:", "automation_toggle"), ("case .record(let byo):", "automation_record"), ("case .stop:", "automation_stop")] {
            XCTAssertTrue(firstStatement(in: auto, after: arm).contains("action(\"\(act)\""), arm)
        }
    }

    func test_each_window_opener_stamps_first_and_tracks_both_the_cold_and_the_warm_path() throws {
        for (file, name) in [("LibraryWindow.swift", "library"), ("PreferencesWindow.swift", "preferences"),
                             ("GuideWindow.swift", "guide"), ("DiagnosticsWindow.swift", "diagnostics"),
                             ("QuickFindWindow.swift", "quick_find")] {
            let src = try source(file)
            XCTAssertTrue(src.contains("UILatency.shared.action(\"open_window\", surface: \"\(name)\")"), file)
            XCTAssertTrue(src.contains("trackWindowOpen(\"\(name)\", cold: true"), "\(file) cold path")
            XCTAssertTrue(src.contains("trackWindowOpen(\"\(name)\", cold: false"), "\(file) warm path")
        }
    }

    // MARK: A real window: cold, then warm

    func test_a_guide_window_reports_cold_on_the_first_show_and_warm_on_the_second() async {
        let guide = GuideWindow()
        guide.show()
        guard let w = NSApp.windows.first(where: { $0.title == "MeetingPipe Guide" }) else {
            return XCTFail("the guide window was not built")
        }
        defer { w.close() }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w)
        await waitUntil("the cold row") { self.rows("window_opened").count == 1 }
        guide.show()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w)
        await waitUntil("the warm row") { self.rows("window_opened").count == 2 }
        let opened = rows("window_opened")
        XCTAssertEqual(opened.map { $0["cold"] as? Bool }, [true, false])
        XCTAssertEqual(opened.map { $0["window"] as? String }, ["guide", "guide"])
        XCTAssertEqual(rows("ui_action").filter { $0["surface"] as? String == "guide" }.count, 2)
    }
}
