import AppKit
import XCTest
@testable import MeetingPipe

/// One ordered log for everything the manager does, so a test can pin *when* each call happens and
/// not just that it happened. The two defects UX39 fixed are both ordering or identity defects that
/// a "was it called" assertion would have passed: the app asked to be frontmost before it asked to
/// be regular (Cmd+Tab MRU tail), and a miniaturized re-show counted twice (stuck `.regular`). The
/// log is what pins UX56's answer to the first one too, which is a retry on the turn after the
/// policy raise rather than a window made to wait for it.
private final class ActivationRecorder {
    private(set) var calls: [String] = []
    private var pending: [() -> Void] = []

    func note(_ call: String) { calls.append(call) }

    var effects: WindowActivationManager.Effects {
        WindowActivationManager.Effects(
            setPolicy: { [weak self] policy in self?.note("policy:\(Self.name(policy))") },
            activateApp: { [weak self] in self?.note("activate") },
            handOffActivation: { [weak self] in self?.note("handoff") },
            installMainMenu: { [weak self] in self?.note("menu:install") },
            removeMainMenu: { [weak self] in self?.note("menu:remove") },
            onNextRunLoopTurn: { [weak self] work in self?.pending.append(work) }
        )
    }

    /// Drain the deferred work the way the main run loop would on its next turn.
    func runNextRunLoopTurn() {
        let due = pending
        pending = []
        for work in due { work() }
    }

    private static func name(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }
}

/// Stands in for an `NSWindow` so the counting rules run without a window server. The real
/// `NSWindow` satisfies `ActivatableWindow` unchanged, which is what the three participating
/// windows hand over.
private final class FakeWindow: ActivatableWindow {
    let name: String
    var isMiniaturized: Bool
    private let recorder: ActivationRecorder

    init(_ name: String, recorder: ActivationRecorder, miniaturized: Bool = false) {
        self.name = name
        self.recorder = recorder
        self.isMiniaturized = miniaturized
    }

    func makeKeyAndOrderFront(_ sender: Any?) { recorder.note("front:\(name)") }

    func deminiaturize(_ sender: Any?) {
        isMiniaturized = false
        recorder.note("deminiaturize:\(name)")
    }
}

final class WindowActivationManagerTests: XCTestCase {

    private var recorder = ActivationRecorder()

    override func setUp() {
        super.setUp()
        recorder = ActivationRecorder()
    }

    private func makeManager() -> WindowActivationManager {
        WindowActivationManager(effects: recorder.effects)
    }

    // MARK: - Ordering

    /// UX39's first defect and UX56's answer to it in one sequence. The policy flip is issued before
    /// anything asks to be frontmost, which is the half that was always load-bearing: the call sites
    /// used to front and activate *before* handing over, so the app asked to be frontmost while it
    /// was still an accessory and macOS appended it to the Cmd+Tab MRU tail. The window itself no
    /// longer waits for the transition, because the wait was measured costing focus and buying no
    /// MRU position; the activation is re-issued on the next turn instead, when the raise has
    /// certainly landed.
    func test_first_show_flips_policy_then_fronts_in_the_same_turn() {
        let manager = makeManager()
        let window = FakeWindow("library", recorder: recorder)

        manager.showWindow(window)
        XCTAssertEqual(
            recorder.calls, ["policy:regular", "menu:install", "front:library", "activate"],
            "The raise precedes the activation, and the window the user asked for goes up now."
        )

        recorder.runNextRunLoopTurn()
        XCTAssertEqual(
            recorder.calls,
            ["policy:regular", "menu:install", "front:library", "activate", "activate"],
            "The follow-up activation is the retry for an attempt evaluated against the accessory app."
        )
    }

    /// A window that is not miniaturized is never sent a spurious deminiaturize.
    func test_show_of_a_normal_window_does_not_deminiaturize() {
        let manager = makeManager()
        let window = FakeWindow("prefs", recorder: recorder)

        manager.showWindow(window)
        recorder.runNextRunLoopTurn()

        XCTAssertFalse(recorder.calls.contains("deminiaturize:prefs"))
    }

    // MARK: - Counting by identity

    /// Re-showing the same window brings it forward again but is not a second open, so the policy
    /// is flipped once and one close is enough to drop it.
    func test_showing_the_same_window_twice_counts_once() {
        let manager = makeManager()
        let window = FakeWindow("library", recorder: recorder)

        manager.showWindow(window)
        recorder.runNextRunLoopTurn()
        manager.showWindow(window)
        recorder.runNextRunLoopTurn()

        XCTAssertEqual(
            recorder.calls,
            [
                "policy:regular", "menu:install", "front:library", "activate", "activate",
                "front:library", "activate"
            ]
        )

        manager.didCloseWindow(window)
        XCTAssertEqual(recorder.calls.suffix(3), ["policy:accessory", "menu:remove", "handoff"])
    }

    /// The regression the owner hit: `NSWindow.isVisible` is false while a window is miniaturized,
    /// so the old per-call-site `if !w.isVisible` guard counted every reopen-from-the-Dock as a
    /// fresh open while only one `windowWillClose` ever arrived. Five reopens then left the count
    /// at five, and closing the window left the app `.regular` with nothing on screen.
    func test_reopening_a_miniaturized_window_deminiaturizes_without_double_counting() {
        let manager = makeManager()
        let window = FakeWindow("library", recorder: recorder)

        manager.showWindow(window)
        recorder.runNextRunLoopTurn()

        for _ in 0..<5 {
            window.isMiniaturized = true
            manager.showWindow(window)
            recorder.runNextRunLoopTurn()
        }

        XCTAssertEqual(recorder.calls.filter { $0 == "policy:regular" }.count, 1)
        XCTAssertEqual(recorder.calls.filter { $0 == "deminiaturize:library" }.count, 5)

        manager.didCloseWindow(window)
        XCTAssertEqual(
            recorder.calls.suffix(3), ["policy:accessory", "menu:remove", "handoff"],
            "One close has to undo any number of reopens, or the Dock icon never goes away."
        )
    }

    func test_two_windows_open_and_one_closed_stays_regular() {
        let manager = makeManager()
        let library = FakeWindow("library", recorder: recorder)
        let prefs = FakeWindow("prefs", recorder: recorder)

        manager.showWindow(library)
        manager.showWindow(prefs)
        recorder.runNextRunLoopTurn()
        XCTAssertEqual(recorder.calls.filter { $0.hasPrefix("policy:") }, ["policy:regular"])

        manager.didCloseWindow(prefs)
        XCTAssertFalse(recorder.calls.contains("policy:accessory"))
        XCTAssertFalse(
            recorder.calls.contains("menu:remove"),
            "Closing one of two windows must not take the menu bar down under the other."
        )

        manager.didCloseWindow(library)
        XCTAssertEqual(recorder.calls.suffix(3), ["policy:accessory", "menu:remove", "handoff"])
    }

    /// A window that was never counted (or a second `windowWillClose` for one already gone) must
    /// not drop the policy out from under a window that is still up.
    func test_closing_an_untracked_window_is_ignored() {
        let manager = makeManager()
        let library = FakeWindow("library", recorder: recorder)
        let stranger = FakeWindow("stranger", recorder: recorder)

        manager.showWindow(library)
        recorder.runNextRunLoopTurn()

        manager.didCloseWindow(stranger)
        manager.didCloseWindow(library)
        manager.didCloseWindow(library)

        XCTAssertEqual(recorder.calls.filter { $0 == "policy:accessory" }.count, 1)
        XCTAssertEqual(recorder.calls.filter { $0 == "handoff" }.count, 1)
        XCTAssertEqual(recorder.calls.filter { $0 == "menu:remove" }.count, 1)
    }

    // MARK: - Close and reopen

    /// The full round trip: the app drops to `.accessory` on the last close, hands activation on,
    /// and comes back to `.regular` the next time a window opens.
    func test_close_all_then_show_again_raises_the_policy_again() {
        let manager = makeManager()
        let window = FakeWindow("library", recorder: recorder)

        manager.showWindow(window)
        recorder.runNextRunLoopTurn()
        manager.didCloseWindow(window)
        manager.showWindow(window)
        recorder.runNextRunLoopTurn()

        XCTAssertEqual(
            recorder.calls,
            [
                "policy:regular", "menu:install", "front:library", "activate", "activate",
                "policy:accessory", "menu:remove", "handoff",
                "policy:regular", "menu:install", "front:library", "activate", "activate"
            ]
        )
    }

    /// The handoff is issued after the policy drop, not before: dropping to `.accessory` while
    /// still the active app is what leaves this app owning the menu bar with no window, and the
    /// Dock icon outliving the flip.
    func test_close_hands_activation_off_after_dropping_the_policy() {
        let manager = makeManager()
        let window = FakeWindow("diagnostics", recorder: recorder)

        manager.showWindow(window)
        recorder.runNextRunLoopTurn()
        manager.didCloseWindow(window)

        guard let drop = recorder.calls.firstIndex(of: "policy:accessory"),
              let handoff = recorder.calls.firstIndex(of: "handoff") else {
            return XCTFail("Expected both the policy drop and the handoff: \(recorder.calls)")
        }
        XCTAssertLessThan(drop, handoff)
    }

    // MARK: - Main menu (UX48)

    /// The menu bar exists exactly while the app is `.regular`, so it is installed in the same step
    /// that raises the policy rather than a run-loop turn later with the fronting. macOS matches a
    /// command-key event against `NSApp.mainMenu` before anything else, and an event that arrives
    /// between the flip and a deferred install would still beep.
    func test_first_show_installs_the_menu_in_the_same_step_as_the_policy_flip() {
        let manager = makeManager()
        let window = FakeWindow("library", recorder: recorder)

        manager.showWindow(window)

        XCTAssertEqual(
            Array(recorder.calls.prefix(2)), ["policy:regular", "menu:install"],
            "The menu goes up with the policy, ahead of anything this window does for itself."
        )
    }

    /// A second window is not a second menu bar. `NSApp.mainMenu` is one slot, so a re-install would
    /// be harmless here, but the count is what says the transition is owned rather than sprayed.
    func test_second_window_opening_does_not_reinstall_the_menu() {
        let manager = makeManager()
        let library = FakeWindow("library", recorder: recorder)
        let prefs = FakeWindow("prefs", recorder: recorder)

        manager.showWindow(library)
        manager.showWindow(prefs)
        recorder.runNextRunLoopTurn()

        XCTAssertEqual(recorder.calls.filter { $0 == "menu:install" }.count, 1)
        XCTAssertFalse(recorder.calls.contains("menu:remove"))
    }

    /// Re-showing a window already counted (the Dock-icon reopen path) is not a fresh open, so it
    /// must not touch the menu any more than it touches the policy.
    func test_reshowing_a_counted_window_does_not_reinstall_the_menu() {
        let manager = makeManager()
        let window = FakeWindow("library", recorder: recorder)

        manager.showWindow(window)
        recorder.runNextRunLoopTurn()
        window.isMiniaturized = true
        manager.showWindow(window)
        recorder.runNextRunLoopTurn()

        XCTAssertEqual(recorder.calls.filter { $0 == "menu:install" }.count, 1)
    }

    // MARK: - Fronting in the turn that asked, with the raise retried after it (UX56)

    /// The first half of UX56, and the half the owner confirmed on 2026-08-04. With the app already
    /// `.regular` there is no asynchronous policy transition to outlive, so the window is fronted in
    /// the turn that asked for it rather than a turn later. The turn was not free: it is one in
    /// which the app the user came from can keep or reclaim focus, and the report was a Preferences
    /// window landing behind the Library that opened it.
    func test_show_while_the_app_is_already_regular_fronts_in_the_same_turn() {
        let manager = makeManager()
        let library = FakeWindow("library", recorder: recorder)
        let prefs = FakeWindow("prefs", recorder: recorder)

        manager.showWindow(library)
        recorder.runNextRunLoopTurn()

        manager.showWindow(prefs)

        XCTAssertEqual(
            recorder.calls.suffix(2), ["front:prefs", "activate"],
            "A second window has no policy transition to wait for, so waiting only costs."
        )
        XCTAssertEqual(
            recorder.calls.filter { $0.hasPrefix("policy:") }, ["policy:regular"],
            "Fronting in the same turn must not have re-raised a policy that was already up."
        )
    }

    /// The same rule on the re-show path: a window already counted cannot have raised the policy,
    /// so the Dock-icon and menu-bar reopens come forward immediately too.
    func test_reshowing_a_counted_window_fronts_in_the_same_turn() {
        let manager = makeManager()
        let window = FakeWindow("library", recorder: recorder)

        manager.showWindow(window)
        recorder.runNextRunLoopTurn()
        window.isMiniaturized = true
        manager.showWindow(window)

        XCTAssertEqual(recorder.calls.suffix(3), ["deminiaturize:library", "front:library", "activate"])
    }

    /// Two windows opened in the same turn are **one** transition, so they front in the order they
    /// were asked for (the second ends up on top) and share the single follow-up activation. Queuing
    /// the retry per window instead would issue one `activate` per open for a transition that
    /// happened once.
    func test_two_windows_shown_in_one_turn_share_one_follow_up_activation() {
        let manager = makeManager()
        let library = FakeWindow("library", recorder: recorder)
        let prefs = FakeWindow("prefs", recorder: recorder)

        manager.showWindow(library)
        manager.showWindow(prefs)

        XCTAssertEqual(
            recorder.calls,
            [
                "policy:regular", "menu:install",
                "front:library", "activate", "front:prefs", "activate"
            ],
            "Order follows the asks, so the window opened second ends up on top."
        )

        recorder.runNextRunLoopTurn()
        XCTAssertEqual(
            recorder.calls.suffix(1), ["activate"],
            "One transition, one retry, however many windows rode it."
        )
        XCTAssertEqual(recorder.calls.filter { $0 == "activate" }.count, 3)
    }

    /// The reported path, and the one this pass exists for: the last close drops the policy, so
    /// every open of Preferences from the status-bar menu with no other window up raises it again.
    /// That open used to wait a run-loop turn, and the owner measured the wait landing the window
    /// behind the frontmost app **and** the app at the Cmd+Tab tail, which is the position the wait
    /// existed to buy. It fronts in the turn that asked now, and the raise is retried after it.
    func test_show_after_the_last_close_raises_again_and_still_fronts_in_the_same_turn() {
        let manager = makeManager()
        let window = FakeWindow("prefs", recorder: recorder)

        manager.showWindow(window)
        recorder.runNextRunLoopTurn()
        manager.didCloseWindow(window)
        manager.showWindow(window)

        XCTAssertEqual(
            recorder.calls.suffix(4),
            ["policy:regular", "menu:install", "front:prefs", "activate"],
            "A re-raised policy must not put the window the user just asked for a turn behind."
        )

        recorder.runNextRunLoopTurn()
        XCTAssertEqual(recorder.calls.suffix(1), ["activate"])
    }

    /// The retry belongs to the transition, so a show with no raise behind it queues nothing at all.
    /// Without this, every re-front of an already-`.regular` app would trail an activation into the
    /// next turn, which is the shape whose cost this task measured.
    func test_a_show_with_no_policy_raise_queues_nothing_for_the_next_turn() {
        let manager = makeManager()
        let library = FakeWindow("library", recorder: recorder)
        let prefs = FakeWindow("prefs", recorder: recorder)

        manager.showWindow(library)
        recorder.runNextRunLoopTurn()

        manager.showWindow(prefs)
        let afterShow = recorder.calls
        recorder.runNextRunLoopTurn()

        XCTAssertEqual(recorder.calls, afterShow, "Nothing was pending, so draining the turn is a no-op.")
    }

    /// The way back: the menu comes down with the policy, before the handoff, so this app is never
    /// the one whose menu bar is drawn once another app is frontmost.
    func test_last_close_removes_the_menu_before_handing_activation_off() {
        let manager = makeManager()
        let window = FakeWindow("library", recorder: recorder)

        manager.showWindow(window)
        recorder.runNextRunLoopTurn()
        manager.didCloseWindow(window)

        guard let drop = recorder.calls.firstIndex(of: "policy:accessory"),
              let remove = recorder.calls.firstIndex(of: "menu:remove"),
              let handoff = recorder.calls.firstIndex(of: "handoff") else {
            return XCTFail("Expected the drop, the removal and the handoff: \(recorder.calls)")
        }
        XCTAssertLessThan(drop, remove)
        XCTAssertLessThan(remove, handoff)
    }
}
