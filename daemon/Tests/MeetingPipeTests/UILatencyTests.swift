import AppKit
import XCTest
@testable import MeetingPipe

/// OBS7: the click/feedback/first-paint/window rows. The clock and the "next main turn" are
/// injected, so a latency is asserted against a number the test chose and "the work after the
/// setter counts" needs no sleep.
final class UILatencyTests: XCTestCase {

    private final class Rig: @unchecked Sendable {
        var now: TimeInterval = 1000
        var rows: [(String, [String: Any])] = []
        var queued: [@Sendable () -> Void] = []
        var removed = 0
        lazy var latency = UILatency(
            uptime: { [unowned self] in self.now },
            emit: { [unowned self] a, attrs in self.rows.append((a, attrs)) },
            nextTurn: { [unowned self] block in self.queued.append(block) }
        )
        func drain() { let q = queued; queued = []; q.forEach { $0() } }
        func rows(_ action: String) -> [[String: Any]] { rows.filter { $0.0 == action }.map { $0.1 } }
    }

    func test_sequence_numbers_increase_per_action() {
        let rig = Rig()
        let a = rig.latency.action("hud_stop", surface: "hud")
        let b = rig.latency.action("menu_start", surface: "menu")
        XCTAssertEqual(b, a + 1)
        XCTAssertEqual(rig.rows("ui_action").map { $0["seq"] as? Int }, [a, b])
        XCTAssertEqual(rig.rows("ui_action").first?["surface"] as? String, "hud")
        XCTAssertEqual(rig.rows("ui_action").first?["name"] as? String, "hud_stop")
    }

    func test_feedback_measures_from_the_injected_uptime_on_the_next_turn_and_counts_work_after_the_setter() {
        let rig = Rig()
        let seq = rig.latency.action("hud_stop", surface: "hud")
        rig.now += 0.010
        rig.latency.feedback(seq: seq)
        XCTAssertTrue(rig.rows("ui_feedback").isEmpty, "emitted at the setter, not on the next turn")
        rig.now += 0.208  // the synchronous tail after the setter (P005/P047's HAL teardown)
        rig.drain()
        XCTAssertEqual(rig.rows("ui_feedback").first?["ms"] as? Int, 218)
        XCTAssertEqual(rig.rows("ui_feedback").first?["seq"] as? Int, seq)
    }

    func test_feedback_for_an_unknown_or_answered_sequence_emits_nothing() {
        let rig = Rig()
        rig.latency.feedback(seq: 99)
        let seq = rig.latency.action("menu_start", surface: "menu")
        rig.latency.feedback(seq: seq)
        rig.drain()
        rig.latency.feedback(seq: seq)
        rig.drain()
        XCTAssertEqual(rig.rows("ui_feedback").count, 1)
    }

    func test_two_feedback_calls_before_the_turn_runs_answer_once() {
        let rig = Rig()
        let seq = rig.latency.action("menu_start", surface: "menu")
        rig.latency.feedback(seq: seq)
        rig.latency.feedback(seq: seq)
        rig.drain()
        XCTAssertEqual(rig.rows("ui_feedback").count, 1)
    }

    func test_feedbackForLatest_answers_the_newest_recent_click_of_the_right_kind_and_returns_its_seq() {
        let rig = Rig()
        let old = rig.latency.action("menu_start", surface: "menu")
        rig.now += UILatency.staleActionSeconds + 1
        XCTAssertNil(rig.latency.feedbackForLatest(.start), "an automatic start must not be answered by seq \(old)")
        let start = rig.latency.action("hotkey_toggle", surface: "hotkey")
        let skip = rig.latency.action("prompt_skip", surface: "prompt")
        XCTAssertEqual(rig.latency.feedbackForLatest(.start), start, "a Skip can never cause a HUD")
        XCTAssertNil(rig.latency.feedbackForLatest(.start), "answered once")
        let open = rig.latency.action("open_window", surface: "guide")
        XCTAssertNil(rig.latency.feedbackForLatest(.stop), "a window open does not stop a recording")
        let stop = rig.latency.action("hud_stop", surface: "hud")
        XCTAssertEqual(rig.latency.feedbackForLatest(.stop), stop)
        rig.drain()
        XCTAssertEqual(Set(rig.rows("ui_feedback").compactMap { $0["seq"] as? Int }), [start, stop])
        _ = (skip, open)
    }

    func test_a_discarded_click_stops_waiting_and_discardPending_clears_them_all() {
        let rig = Rig()
        let a = rig.latency.action("menu_start", surface: "menu")
        rig.latency.discard(seq: a)
        XCTAssertNil(rig.latency.feedbackForLatest(.start))
        rig.latency.action("hotkey_toggle", surface: "hotkey")
        rig.latency.action("hud_stop", surface: "hud")
        rig.latency.discardPending()
        XCTAssertNil(rig.latency.feedbackForLatest(.start))
        XCTAssertNil(rig.latency.feedbackForLatest(.stop))
    }

    func test_recentActionSeq_finds_an_answered_click_of_the_phase_for_the_first_paint_row() {
        let rig = Rig()
        let start = rig.latency.action("hotkey_toggle", surface: "hotkey")
        rig.latency.feedback(seq: start); rig.drain()
        rig.latency.action("open_window", surface: "library")
        XCTAssertEqual(rig.latency.recentActionSeq(.start), start, "a later window open must not take the HUD's paint")
        rig.now += UILatency.staleActionSeconds + 1
        XCTAssertNil(rig.latency.recentActionSeq(.start))
    }

    func test_the_pending_table_is_bounded() {
        let rig = Rig()
        for _ in 0..<(UILatency.maxPending + 20) { rig.latency.action("menu_start", surface: "menu") }
        rig.latency.feedback(seq: 1)  // evicted
        rig.drain()
        XCTAssertTrue(rig.rows("ui_feedback").isEmpty)
    }

    func test_lastAction_reports_the_sequence_and_the_age() {
        let rig = Rig()
        XCTAssertNil(rig.latency.lastAction())
        let seq = rig.latency.action("hotkey_toggle", surface: "hotkey")
        rig.now += 0.120
        XCTAssertEqual(rig.latency.lastAction()?.seq, seq)
        XCTAssertEqual(rig.latency.lastAction()?.sinceMs, 120)
    }

    func test_first_paint_carries_the_triggering_seq_and_click_to_paint_ms() {
        let rig = Rig()
        let seq = rig.latency.action("prompt_record", surface: "prompt")
        rig.now += 0.050
        rig.latency.firstPaint(surface: "hud", phase: "present", seq: seq)
        rig.latency.firstPaint(surface: "prompt", phase: "order_out", seq: nil)
        let rows = rig.rows("first_paint")
        XCTAssertEqual(rows[0]["ms"] as? Int, 50)
        XCTAssertEqual(rows[0]["seq"] as? Int, seq)
        XCTAssertNil(rows[1]["seq"])
        XCTAssertNil(rows[1]["ms"])
    }

    func test_window_opened_waits_for_key_and_reports_cold() {
        let rig = Rig()
        let seq = rig.latency.action("open_window", surface: "guide")
        var becameKey: (@Sendable () -> Void)?
        rig.now += 0.120  // the cold build, between the click and the observer
        rig.latency.windowOpened(
            window: "guide", cold: true, seq: seq, alreadyKey: false,
            observeKey: { becameKey = $0; return { rig.removed += 1 } }, afterTimeout: { _ in }
        )
        XCTAssertTrue(rig.rows("window_opened").isEmpty)
        rig.now += 0.060
        becameKey?()
        becameKey?()
        let rows = rig.rows("window_opened")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["cold"] as? Bool, true)
        XCTAssertEqual(rows[0]["ms_to_key"] as? Int, 180, "counted from the click, so the build is inside it")
        XCTAssertEqual(rig.removed, 1, "the observer is removed once the row is out")
        XCTAssertEqual(rows[0]["window"] as? String, "guide")
    }

    func test_window_opened_for_an_already_key_window_reports_the_build_cost_and_a_timeout_removes_the_observer() {
        let rig = Rig()
        let seq = rig.latency.action("open_window", surface: "library")
        rig.now += 0.300  // a cold build that left the window key before the observer existed
        rig.latency.windowOpened(
            window: "library", cold: true, seq: seq, alreadyKey: true,
            observeKey: { _ in XCTFail(); return {} }, afterTimeout: { _ in XCTFail() }
        )
        XCTAssertEqual(rig.rows("window_opened").first?["ms_to_key"] as? Int, 300)
        var timeout: (@Sendable () -> Void)?
        let seq2 = rig.latency.action("open_window", surface: "prefs")
        rig.latency.windowOpened(
            window: "prefs", cold: true, seq: seq2, alreadyKey: false,
            observeKey: { _ in { rig.removed += 1 } }, afterTimeout: { timeout = $0 }
        )
        timeout?()
        XCTAssertTrue(rig.rows("window_opened").last?["ms_to_key"] is NSNull)
        XCTAssertEqual(rig.removed, 1, "a timed-out open must not leave its observer registered")
    }

    func test_rows_carry_no_free_text() {
        let rig = Rig()
        let seq = rig.latency.action("prompt_record", surface: "prompt")
        rig.latency.feedback(seq: seq); rig.drain()
        for (_, attrs) in rig.rows {
            XCTAssertTrue(Set(attrs.keys).isSubset(of: ["name", "surface", "seq", "ms", "phase", "window", "cold", "ms_to_key"]))
        }
    }
}
