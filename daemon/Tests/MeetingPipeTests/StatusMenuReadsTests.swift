import AppKit
import os
import XCTest
@testable import MeetingPipe

/// PERF24: the status menu used to spawn `launchctl print-disabled` and list the whole of
/// `raw/` on the main thread at every open, and to rebuild (and discard, unseen) a whole menu on
/// every state, queue, permission and 2 s download tick, paying the listing each time.
///
/// These drive a real `StatusBarController` over a real status item with the two expensive reads
/// replaced: a counting `raw/` listing and a fake `launchctl` runner, each recording which thread
/// it was called on. Nothing here touches launchd or a recordings folder. The controller's two
/// read queues are the test's own, so a test can drain them, or hold one suspended to look at the
/// window between an open and its read landing.
final class StatusMenuReadsTests: XCTestCase {

    // MARK: - Fakes

    /// One expensive read's call log. Locked rather than `@unchecked Sendable` (`daemon/CLAUDE.md`
    /// caps those), since the reads run on the controller's queues.
    private final class CallLog: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (calls: 0, onMain: 0))
        func record() { state.withLock { $0.calls += 1; if Thread.isMainThread { $0.onMain += 1 } } }
        var calls: Int { state.withLock { $0.calls } }
        var onMain: Int { state.withLock { $0.onMain } }
    }

    /// The `raw/` listing: what it answers, and who asked.
    private final class FailedCounter: Sendable {
        let log = CallLog()
        private let answer = OSAllocatedUnfairLock(initialState: 0)
        func set(_ n: Int) { answer.withLock { $0 = n } }
        func count(_ dir: URL) -> Int { log.record(); return answer.withLock { $0 } }
    }

    /// `launchctl`, answering `print-disabled` with the agent disabled or not.
    private final class FakeLaunchctl: LaunchctlRunning {
        let printDisabled = CallLog()
        private let disabled = OSAllocatedUnfairLock(initialState: false)
        func setDisabled(_ on: Bool) { disabled.withLock { $0 = on } }
        func run(_ arguments: [String]) -> LaunchctlResult {
            guard arguments.first == "print-disabled" else { return LaunchctlResult(status: 0, output: "") }
            printDisabled.record()
            let state = disabled.withLock { $0 } ? "disabled" : "enabled"
            return LaunchctlResult(status: 0, output: "disabled services = {\n\t\t\"com.meetingpipe.daemon\" => \(state)\n}\n")
        }
    }

    private func service(_ runner: FakeLaunchctl) -> LaunchAtLoginService {
        LaunchAtLoginService(runner: runner, uid: 501, plistPath: "/tmp/perf24/agent.plist", plistExists: { _ in true })
    }

    // MARK: - Fixture

    private var item: NSStatusItem!
    private var controller: StatusBarController!
    private var counter: FailedCounter!
    private var launchctl: FakeLaunchctl!
    private var countQueue: DispatchQueue!
    private var launchAgentQueue: DispatchQueue!

    override func setUp() {
        super.setUp()
        counter = FailedCounter()
        launchctl = FakeLaunchctl()
        countQueue = DispatchQueue(label: "perf24.test.count")
        launchAgentQueue = DispatchQueue(label: "perf24.test.launchAgent")
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let counter = self.counter!
        controller = StatusBarController(
            item: item,
            launchAtLogin: service(launchctl),
            countFailedMeetings: { counter.count($0) },
            countQueue: countQueue,
            launchAgentQueue: launchAgentQueue
        )
        // Never resolved through a Coordinator here, and never listed for real.
        controller.recordingsDir = { URL(fileURLWithPath: "/nonexistent/perf24/raw") }
    }

    override func tearDown() {
        NSStatusBar.system.removeStatusItem(item)
        controller = nil
        item = nil
        super.tearDown()
    }

    private var menu: NSMenu { item.menu! }

    private func open() {
        menu.delegate?.menuNeedsUpdate?(menu)
    }

    private func close() {
        menu.delegate?.menuDidClose?(menu)
    }

    /// Let both read queues finish, then let main run every hop they queued (the main queue is
    /// FIFO, so a block queued after them runs after them).
    private func drain() {
        countQueue.sync {}
        launchAgentQueue.sync {}
        let landed = expectation(description: "main hops ran")
        DispatchQueue.main.async { landed.fulfill() }
        wait(for: [landed], timeout: 5)
    }

    private var titles: [String] { menu.items.map(\.title) }

    private func failedRow(_ count: Int) -> String {
        StatusBarModel.failedMeetingsTitle(count: count)!
    }

    // MARK: - Item 1: rebuilds stop building

    /// The headline acceptance: ten queue and download ticks with the menu closed cost no listing,
    /// no subprocess and no populate. Against `main` each of them built a menu and listed `raw/`.
    func test_ten_ticks_with_the_menu_closed_read_nothing_and_populate_nothing() {
        let assigned = item.menu
        let before = menu.items
        for i in 0..<5 {
            controller.setQueueActivity(QueueActivity(depth: i + 1, isRunning: true))
            controller.setModelDownload(.downloading(
                modelId: "m", progress: Double(i) / 5, downloadedBytes: Int64(i), totalBytes: 5
            ))
        }
        drain()

        XCTAssertEqual(counter.log.calls, 0, "a tick must not list the recordings folder")
        XCTAssertEqual(launchctl.printDisabled.calls, 0, "a tick must not spawn launchctl")
        XCTAssertEqual(menu.items, before, "a tick must not populate a menu nobody has opened")
        XCTAssertTrue(item.menu === assigned, "the one menu stays assigned; nothing replaces it")
    }

    /// One open populates once, in place, and starts both reads off main.
    func test_an_open_populates_once_and_reads_only_off_main() {
        let assigned = item.menu
        open()

        XCTAssertEqual(titles.filter { $0 == "MeetingPipe: Idle" }.count, 1, "one populate, one header")
        XCTAssertTrue(item.menu === assigned, "repopulated in place, not replaced")
        drain()

        XCTAssertEqual(counter.log.calls, 1)
        XCTAssertEqual(counter.log.onMain, 0, "the raw/ listing must not run on main")
        XCTAssertEqual(launchctl.printDisabled.calls, 1)
        XCTAssertEqual(launchctl.printDisabled.onMain, 0, "launchctl must not run on main")
    }

    /// UX79's contract, which now reaches the next open: the header agrees with the title.
    func test_setStopping_reaches_the_next_open() {
        controller.setStopping(
            file: URL(fileURLWithPath: "/tmp/recordings/20260814-163455.wav"),
            source: AppSource(bundleID: "com.microsoft.teams2", displayName: "Teams"),
            summaryMode: .auto
        )
        open()
        XCTAssertTrue(titles.contains("MeetingPipe: Stopping…"), "\(titles)")
    }

    // MARK: - Item 2: the failed count

    /// A job settling recounts off main, and the next open shows the count it found.
    func test_a_recount_off_main_is_what_the_next_open_shows() {
        counter.set(3)
        controller.refreshFailedMeetingCount()   // what the dispatcher's onJobSettled calls
        drain()
        XCTAssertEqual(counter.log.calls, 1)
        XCTAssertEqual(counter.log.onMain, 0)

        open()
        XCTAssertTrue(titles.contains(failedRow(3)), "\(titles)")
    }

    /// The open shows the cached count and its own recount, landing while the menu is up,
    /// updates the row in place.
    func test_a_count_that_moves_while_the_menu_is_open_updates_it_in_place() {
        open()
        drain()
        XCTAssertFalse(titles.contains { $0.contains("failed") }, "\(titles)")

        counter.set(2)
        controller.refreshFailedMeetingCount()
        drain()
        XCTAssertTrue(titles.contains(failedRow(2)), "the open menu shows the new count: \(titles)")
    }

    /// Once closed, a moved count waits for the next open rather than populating unseen.
    func test_a_count_that_moves_while_closed_populates_nothing() {
        open()
        drain()
        close()
        let before = menu.items

        counter.set(4)
        controller.refreshFailedMeetingCount()
        drain()
        XCTAssertEqual(menu.items, before)

        open()
        XCTAssertTrue(titles.contains(failedRow(4)))
    }

    // MARK: - Item 3: the launch agent

    /// Preferences' write reaches the menu with no read of the menu's own.
    @MainActor
    func test_a_preferences_write_updates_the_menu_without_a_launchctl_read() async {
        let prefsRunner = FakeLaunchctl()
        let controller = self.controller!
        let model = LaunchAtLoginModel(
            service: service(prefsRunner),
            onStatus: { controller.noteLaunchAtLoginStatus($0) }
        )
        XCTAssertTrue(controller.launchAgentEnabled)

        await model.set(enabled: false)?.value

        XCTAssertFalse(controller.launchAgentEnabled, "the write's answer reached the menu")
        XCTAssertEqual(launchctl.printDisabled.calls, 0, "and the menu read nothing to learn it")
    }

    /// An open shows the cached value; its off-main read finds the agent disabled (a terminal
    /// `launchctl disable`, say) and repopulates the open menu, so the quit rows are decided
    /// against what launchd now says within the same open.
    func test_a_read_that_finds_a_change_repopulates_the_open_menu() {
        launchctl.setDisabled(true)
        let assigned = item.menu
        open()
        let header = menu.items.first
        XCTAssertTrue(controller.launchAgentEnabled, "the open shows the cached value at once")

        drain()
        XCTAssertFalse(controller.launchAgentEnabled)
        XCTAssertFalse(menu.items.first === header, "the open menu was repopulated")
        XCTAssertTrue(item.menu === assigned, "in place, not replaced")
    }

    /// A push is newer than a read already out, so the read must not land over it.
    func test_a_push_wins_over_a_read_that_was_already_in_flight() {
        launchctl.setDisabled(true)
        launchAgentQueue.suspend()
        open()
        controller.noteLaunchAtLoginStatus(LaunchAtLoginStatus(state: .enabled, error: nil))
        launchAgentQueue.resume()
        drain()

        XCTAssertEqual(launchctl.printDisabled.calls, 1)
        XCTAssertTrue(controller.launchAgentEnabled, "the older read was dropped")
    }

    /// One read at a time: a wedged launchctl holds its read for up to 5 s, and reopening the menu
    /// meanwhile must not queue another subprocess behind it.
    func test_reopening_while_a_read_is_out_does_not_stack_another() {
        launchAgentQueue.suspend()
        open(); close(); open(); close(); open()
        launchAgentQueue.resume()
        drain()
        XCTAssertEqual(launchctl.printDisabled.calls, 1)
    }

    /// Launch primes both reads, so the first open shows launchd's answer and a real count.
    func test_launch_primes_both_reads_off_main() {
        counter.set(1)
        launchctl.setDisabled(true)
        controller.primeCachedReads()
        drain()
        XCTAssertEqual(counter.log.onMain, 0)
        XCTAssertEqual(launchctl.printDisabled.onMain, 0)
        XCTAssertFalse(controller.launchAgentEnabled)

        open()
        XCTAssertTrue(titles.contains(failedRow(1)))
    }

    // MARK: - The calling (END9: a seam nobody calls ships green)

    /// Every trigger above is a call the Coordinator makes through a `?.` or a no-op default, so
    /// deleting one leaves this suite green while the menu goes stale. Pinned in source because the
    /// Coordinator cannot be built headless.
    func test_the_coordinator_wires_every_trigger() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
            .deletingLastPathComponent()   // repo root
        let coordinator = try String(
            contentsOf: root.appendingPathComponent("daemon/Sources/MeetingPipe/Coordinator.swift"),
            encoding: .utf8
        )
        for wiring in [
            "statusBar.primeCachedReads()",
            "onJobSettled: { [weak self] in\n                self?.statusBar.refreshFailedMeetingCount()",
            "failedSetMayHaveChanged: { [weak self] in self?.statusBar.refreshFailedMeetingCount() }",
            "preferencesWindow?.onLaunchAtLoginStatus = { [weak self] status in\n            self?.statusBar.noteLaunchAtLoginStatus(status)",
            "preferencesWindow?.onLibraryRestored = { [weak self] in\n            self?.statusBar.refreshFailedMeetingCount()",
        ] {
            XCTAssertTrue(coordinator.contains(wiring), "Coordinator no longer wires: \(wiring)")
        }
        let window = try String(
            contentsOf: root.appendingPathComponent("daemon/Sources/MeetingPipe/PreferencesWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(window.contains("onLaunchAtLoginStatus: onLaunchAtLoginStatus"))
        XCTAssertTrue(window.contains("onLibraryRestored: onLibraryRestored"))
        let prefs = try String(
            contentsOf: root.appendingPathComponent("daemon/Sources/MeetingPipe/Preferences/PreferencesView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(prefs.contains("GeneralSectionView(store: store, onLaunchAtLoginStatus: onLaunchAtLoginStatus)"))
        XCTAssertTrue(prefs.contains("onRestored: onLibraryRestored"))
    }
}
