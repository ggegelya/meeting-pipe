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
