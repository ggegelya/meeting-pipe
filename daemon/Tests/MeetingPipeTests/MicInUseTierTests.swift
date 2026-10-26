import XCTest
@testable import MeetingPipe

/// DET1: the pure mic-in-use catch-all decision. The host supplies the dwell, the scan outcome,
/// and the resolved bundle sets; these pin when a quiet generic prompt should (and must not) fire.
final class MicInUseTierTests: XCTestCase {

    private let chrome = "com.google.Chrome"
    private let facetime = "com.apple.FaceTime"
    private let textedit = "com.apple.TextEdit"
    private let zoom = "us.zoom.xos"

    /// browsers + mic-plausible, exactly as the watcher composes DET1's plausible set. Native
    /// whitelist apps (Zoom) and non-meeting apps (TextEdit) are deliberately absent - discovery
    /// owns natives, and DET1 catches only what the whitelist structurally cannot see.
    private let plausible: Set<String> = [
        "com.google.Chrome", "com.apple.Safari",
        "com.apple.FaceTime", "com.hnc.Discord",
    ]

    private func decide(
        dwell: TimeInterval = 45,
        threshold: TimeInterval = 30,
        hasWinner: Bool = false,
        bundle: String?,
        name: String? = "App",
        kind: AppSourceKind = .browser
    ) -> AppSource? {
        MicInUseTier.decide(
            dwellSec: dwell, threshold: threshold, hasScannerWinner: hasWinner,
            bundleID: bundle, displayName: name, kind: kind, plausibleBundles: plausible
        )
    }

    func test_prompts_for_a_browser_on_an_unlisted_domain() {
        // The headline acceptance: a WebRTC call in Chrome on a domain the whitelist never listed.
        // No scanner winner (no meeting-title match), mic held past the dwell -> a browser prompt.
        let source = decide(bundle: chrome, name: "Google Chrome", kind: .browser)
        XCTAssertEqual(source?.bundleID, chrome)
        XCTAssertEqual(source?.displayName, "Google Chrome")  // names the app
        XCTAssertEqual(source?.kind, .browser)
    }

    func test_prompts_for_a_mic_plausible_native() {
        let source = decide(bundle: facetime, name: "FaceTime", kind: .native)
        XCTAssertEqual(source?.bundleID, facetime)
        XCTAssertEqual(source?.kind, .native)
    }

    func test_no_prompt_below_the_dwell_threshold() {
        // A brief mic grab (a notification capture, a dictation burst) is under the dwell.
        XCTAssertNil(decide(dwell: 12, bundle: chrome))
    }

    func test_no_prompt_when_the_scanner_already_has_a_winner() {
        // Guardrail: the whitelist path owns a detected meeting; the tier must not double-prompt.
        XCTAssertNil(decide(hasWinner: true, bundle: chrome))
    }

    func test_no_prompt_for_an_implausible_app() {
        // Dictation into TextEdit holds the mic with TextEdit frontmost, but TextEdit is not a
        // meeting-capable app, so it is not named - the quiet register, no brittle denylist needed.
        XCTAssertNil(decide(bundle: textedit, name: "TextEdit", kind: .native))
    }

    func test_no_prompt_for_a_native_whitelist_app() {
        // Zoom (a native whitelist app) is NOT in DET1's plausible set: discovery owns it, and a
        // native pre-join holding the mic before its window appears must not have DET1 pre-empt the
        // real detection and its lifecycle end-detection.
        XCTAssertNil(decide(bundle: zoom, name: "Zoom", kind: .native))
    }

    func test_no_prompt_for_a_nil_bundle() {
        XCTAssertNil(decide(bundle: nil))
    }

    func test_dwell_exactly_at_threshold_prompts() {
        XCTAssertNotNil(decide(dwell: 30, threshold: 30, bundle: chrome))
    }
}

/// PERF17 item 3: the tier's once-per-span latch. Outside `.idle` the watcher runs no scans, so the
/// tier is not evaluated there; a span that opened during a recording must be latched as handled,
/// or it would raise a generic prompt the moment the recording ended. These drive the real
/// `MicBusySpanTracker` and `MicInUseTier.SpanLatch` in the order the watcher calls them:
/// `sampleMicBusy` latches while not idle, and each scan's main hop calls `evaluate`.
final class MicInUseTierSpanLatchTests: XCTestCase {

    private let chrome = "com.google.Chrome"
    private let plausible: Set<String> = ["com.google.Chrome", "com.apple.FaceTime"]
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func busy(_ tracker: inout MicBusySpanTracker, at offset: TimeInterval) {
        _ = tracker.update(busy: true, at: t0 + offset, frontmostBundle: chrome, frontmostName: "Google Chrome")
    }

    private func release(_ tracker: inout MicBusySpanTracker, at offset: TimeInterval) {
        // Two idle samples straddling the release debounce close the span.
        _ = tracker.update(busy: false, at: t0 + offset, frontmostBundle: nil, frontmostName: nil)
        _ = tracker.update(busy: false, at: t0 + offset + 10, frontmostBundle: nil, frontmostName: nil)
    }

    private func evaluate(
        _ latch: inout MicInUseTier.SpanLatch,
        _ tracker: MicBusySpanTracker,
        accepting: Bool,
        at offset: TimeInterval
    ) -> AppSource? {
        latch.evaluate(
            openSpan: tracker.open, acceptingPrompts: accepting, now: t0 + offset,
            hasScannerWinner: false, kind: .browser, plausibleBundles: plausible
        )
    }

    func test_an_idle_span_past_the_dwell_prompts_once() {
        var tracker = MicBusySpanTracker()
        var latch = MicInUseTier.SpanLatch()
        busy(&tracker, at: 0)
        XCTAssertNil(evaluate(&latch, tracker, accepting: true, at: 10), "under the dwell")
        XCTAssertEqual(evaluate(&latch, tracker, accepting: true, at: 40)?.bundleID, chrome)
        XCTAssertNil(evaluate(&latch, tracker, accepting: true, at: 50), "once per span")
    }

    /// The acceptance case: a span seen while not idle is latched, raises no prompt after the
    /// return to idle, and a new span afterwards still can.
    func test_a_span_seen_while_not_idle_never_prompts_but_a_later_span_can() {
        var tracker = MicBusySpanTracker()
        var latch = MicInUseTier.SpanLatch()
        busy(&tracker, at: 0)                                  // the call grabs the mic
        latch.noteNotAcceptingPrompts(openSpan: tracker.open)  // sampleMicBusy during the recording
        XCTAssertEqual(latch.firedForSpanSince, t0, "the open span is latched as handled")

        // Back to idle with the same span still open, well past the dwell: no prompt.
        XCTAssertNil(evaluate(&latch, tracker, accepting: true, at: 600))
        XCTAssertNil(evaluate(&latch, tracker, accepting: true, at: 700))

        // That span closes; a new one opens in idle and runs past the dwell: it prompts.
        release(&tracker, at: 800)
        XCTAssertNil(tracker.open)
        XCTAssertNil(evaluate(&latch, tracker, accepting: true, at: 820))  // mic idle resets
        busy(&tracker, at: 900)
        XCTAssertEqual(evaluate(&latch, tracker, accepting: true, at: 940)?.bundleID, chrome)
    }

    /// A scan already in flight when the session left idle still hops to main and evaluates; it
    /// latches rather than prompting, so the call's span cannot prompt from that late hop either.
    func test_an_evaluation_while_not_idle_latches_instead_of_prompting() {
        var tracker = MicBusySpanTracker()
        var latch = MicInUseTier.SpanLatch()
        busy(&tracker, at: 0)
        XCTAssertNil(evaluate(&latch, tracker, accepting: false, at: 40))
        XCTAssertEqual(latch.firedForSpanSince, t0)
        XCTAssertNil(evaluate(&latch, tracker, accepting: true, at: 600))
    }

    func test_noting_not_idle_with_the_mic_idle_latches_nothing() {
        var latch = MicInUseTier.SpanLatch()
        latch.noteNotAcceptingPrompts(openSpan: nil)
        XCTAssertNil(latch.firedForSpanSince)
    }
}
