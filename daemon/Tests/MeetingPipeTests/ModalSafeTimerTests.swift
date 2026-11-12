import AppKit
import XCTest
import MeetingPipeCore
@testable import MeetingPipe

/// CONC10: AppKit runs the main run loop in the modal-panel mode for the whole of an app-modal
/// session and in the event-tracking mode while a menu is open, and a `Timer.scheduledTimer` is in
/// the default mode only, so one alert left up behind Teams stalled the discovery backstop, the
/// prompt timeout, END17's provisional-end tick, the teardown-hold oracle and the HUD clock until
/// it was dismissed. And the prompt's buttons and the HUD's Stop were dead meanwhile, because
/// neither panel set `worksWhenModal`.
///
/// The run-loop cases drive the real main run loop in exactly one mode at a time. AppKit registers
/// both modes as common modes when `NSApplication` comes up, and the test host has no guarantee
/// it ever did, so `registerAppKitCommonModes()` does the same registration with
/// `CFRunLoopAddCommonMode` first; it is idempotent, so a host where AppKit already did it is
/// unchanged.
@MainActor
final class ModalSafeTimerTests: XCTestCase {

    // MARK: - Item 1: the helpers fire while an alert or a menu holds the run loop

    func test_theRepeatingHelperFiresWhileOnlyTheModalPanelModeRuns() {
        assertRepeatingHelperFires(in: .modalPanel)
    }

    func test_theRepeatingHelperFiresWhileOnlyTheEventTrackingModeRuns() {
        assertRepeatingHelperFires(in: .eventTracking)
    }

    func test_theOneShotHelperFiresWhileOnlyTheModalPanelModeRuns() {
        assertOneShotHelperFires(in: .modalPanel)
    }

    func test_theOneShotHelperFiresWhileOnlyTheEventTrackingModeRuns() {
        assertOneShotHelperFires(in: .eventTracking)
    }

    /// The cancel closure is what every site now holds instead of a `Timer`, so it has to stop the
    /// repeat for real, or a dismissed HUD keeps ticking into a released panel.
    func test_cancellingTheRepeatingHelperStopsIt() {
        registerAppKitCommonModes()
        let box = FireCount()
        let cancel = Schedulers.mainRunLoopRepeating(0.01) { box.helper += 1 }
        spin(.modalPanel, for: 2) { box.helper >= 1 }
        XCTAssertGreaterThanOrEqual(box.helper, 1, "the repeat never started, so cancelling it proves nothing")
        cancel()
        let seen = box.helper
        spin(.modalPanel, for: 0.15) { false }
        XCTAssertEqual(box.helper, seen, "a cancelled repeat must not fire again")
    }

    private func assertRepeatingHelperFires(in mode: RunLoop.Mode, file: StaticString = #filePath, line: UInt = #line) {
        registerAppKitCommonModes()
        let box = FireCount()
        let control = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in box.control += 1 }
        let cancel = Schedulers.mainRunLoopRepeating(0.02) { box.helper += 1 }
        defer { cancel(); control.invalidate() }

        spin(mode, for: 2) { box.helper >= 2 }
        XCTAssertGreaterThanOrEqual(box.helper, 2, "the repeating helper stalled in \(mode.rawValue)", file: file, line: line)
        XCTAssertEqual(
            box.control, 0,
            "a default-mode Timer fired in \(mode.rawValue), so this test cannot tell the two apart",
            file: file, line: line
        )
    }

    private func assertOneShotHelperFires(in mode: RunLoop.Mode, file: StaticString = #filePath, line: UInt = #line) {
        registerAppKitCommonModes()
        let box = FireCount()
        let control = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in box.control += 1 }
        let cancel = Schedulers.mainRunLoopOnce(0.02) { box.helper += 1 }
        defer { cancel(); control.invalidate() }

        spin(mode, for: 2) { box.helper >= 1 }
        // Hold the mode a little longer than both intervals, so the control had its chance.
        spin(mode, for: 0.15) { false }
        XCTAssertEqual(box.helper, 1, "the one-shot helper has to fire exactly once in \(mode.rawValue)", file: file, line: line)
        XCTAssertEqual(
            box.control, 0,
            "a default-mode Timer fired in \(mode.rawValue), so this test cannot tell the two apart",
            file: file, line: line
        )
    }

    // MARK: - Item 3: both passive panels take clicks during a modal session

    /// Built headless: an `NSPanel` needs no window server to be constructed and read back, which
    /// `FailureLayoutTests` already relies on for `NSWindow`. The other three assertions pin what
    /// `worksWhenModal` must not cost: both panels stay nonactivating and never become key.
    func test_bothPassivePanelsWorkWhenModalAndStillNeverTakeFocus() {
        let source = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .native)
        let panels: [(String, NSPanel)] = [
            ("prompt", MeetingPromptWindow().makePanel(source: source, timeoutSec: 30)),
            ("HUD", RecordingHUDWindow().makePanel(source: source, workflow: nil)),
        ]
        for (name, panel) in panels {
            XCTAssertTrue(panel.worksWhenModal, "the \(name) panel's controls are dead while an alert is up")
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "the \(name) panel must not activate the app")
            XCTAssertTrue(panel.becomesKeyOnlyIfNeeded, "the \(name) panel must not take key on a click")
            XCTAssertFalse(panel.canBecomeKey, "the \(name) panel must never be key")
        }
    }

    // MARK: - Item 4: no new default-mode timer

    /// Every `scheduledTimer(` left under `daemon/Sources`, per file, with why it may stay in the
    /// default mode. A new site fails (add it here with a reason, or use `Schedulers`), and so does a
    /// listed one that is gone (drop the entry), the `CLAUDE_ALLOWLIST` stale-entry contract. The
    /// token is `scheduledTimer(` rather than `Timer.scheduledTimer(` so a spacing or a `Timer.self`
    /// spelling cannot walk around it.
    static let defaultModeTimers: [String: (count: Int, reason: String)] = [
        "MeetingPipe/ConfigStore.swift": (1, "debounced save; firing after the alert closes is harmless (CONC8 is reshaping it)"),
        "MeetingPipe/SecretsStore.swift": (1, "debounced save; firing after the alert closes is harmless (CONC8 is reshaping it)"),
        "MeetingPipe/GlossaryStore.swift": (1, "debounced save; firing after the alert closes is harmless (CONC8 is reshaping it)"),
        "MeetingPipe/StatusBarController.swift": (2, "the Suppressed and Downloaded labels; a late collapse is cosmetic, and touching the title while the menu is open is what default mode avoids"),
        "MeetingPipe/Coordination/SinkDispatcher.swift": (1, "startStallTracking is an elapsed-time check, so a late fire still reports the stall correctly"),
        "MeetingPipe/AudioPlaybackController.swift": (1, "already re-added with RunLoop.main.add(_, forMode: .common) on the next line"),
        "MeetingPipe/PermissionsCenter.swift": (1, "already re-added with RunLoop.main.add(_, forMode: .common) on the next line"),
    ]

    func test_everyDefaultModeTimerIsListedWithItsReason() throws {
        var found: [String: Int] = [:]
        for (path, text) in try daemonSourceFiles() where text.contains("scheduledTimer(") {
            let count = SwiftSourceScan.occurrences(of: "scheduledTimer(", in: SwiftSourceScan.codeOnly(text)).count
            if count > 0 { found[path] = count }
        }
        var unlisted: [String] = []
        for (path, count) in found where count > (Self.defaultModeTimers[path]?.count ?? 0) {
            unlisted.append("\(path) (\(count))")
        }
        var stale: [String] = []
        for (path, entry) in Self.defaultModeTimers where (found[path] ?? 0) < entry.count {
            stale.append("\(path) (listed \(entry.count), found \(found[path] ?? 0))")
        }
        unlisted.sort()
        stale.sort()
        XCTAssertEqual(
            unlisted, [],
            "a new default-mode Timer stalls while any alert or menu is open (CONC10). Use "
                + "Schedulers.mainRunLoopOnce / mainRunLoopRepeating, or list it here with the reason it may stall."
        )
        XCTAssertEqual(stale, [], "these entries outlived their timer; drop or recount them")
        XCTAssertFalse(found.isEmpty, "the scan found no Sources at all, so it is not looking where it thinks")
    }

    // MARK: - Helpers

    private final class FireCount {
        var helper = 0
        var control = 0
    }

    private func registerAppKitCommonModes() {
        for mode in [RunLoop.Mode.modalPanel, .eventTracking] {
            CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(mode.rawValue as CFString))
        }
    }

    /// Run the main run loop in `mode` only, until `done` or `seconds` pass. A mode with nothing
    /// attached returns at once, so that case sleeps briefly instead of spinning.
    private func spin(_ mode: RunLoop.Mode, for seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            if !RunLoop.main.run(mode: mode, before: min(deadline, Date().addingTimeInterval(0.01))) {
                usleep(2_000)
            }
        }
    }

    private func daemonSourceFiles() throws -> [(String, String)] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
            .appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: sources.path) else { return [] }
        var found: [(String, String)] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            found.append((relative, try String(contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)))
        }
        return found
    }
}
