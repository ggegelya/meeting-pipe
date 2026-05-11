import XCTest
@testable import MeetingPipe

/// Unit tests for `Detector.effectiveDebounceEnd` (TECH-C4).
///
/// The lookup is precedence-sensitive — per-bundle override beats the
/// browser default beats the global. Each precedence rung is locked in
/// with a dedicated case so a future refactor that flips the order can't
/// silently downgrade browser meetings back to the 5 s global.
final class EffectiveDebounceTests: XCTestCase {

    private let nativeZoom = AppSource(
        bundleID: "us.zoom.xos",
        displayName: "Zoom",
        kind: .native
    )
    private let browserChrome = AppSource(
        bundleID: "com.google.Chrome",
        displayName: "Google Chrome",
        kind: .browser
    )

    func test_nil_source_returns_global() {
        let interval = Detector.effectiveDebounceEnd(
            for: nil,
            globalEndSec: 5,
            perBundle: [:]
        )
        XCTAssertEqual(interval, 5)
    }

    func test_native_app_with_no_override_returns_global() {
        let interval = Detector.effectiveDebounceEnd(
            for: nativeZoom,
            globalEndSec: 5,
            perBundle: [:]
        )
        XCTAssertEqual(interval, 5)
    }

    func test_browser_with_no_override_returns_browser_default() {
        // 12 s, per TECH-C4 — browser meeting state flickers more than
        // native, so the global 5 s would produce premature stops.
        let interval = Detector.effectiveDebounceEnd(
            for: browserChrome,
            globalEndSec: 5,
            perBundle: [:]
        )
        XCTAssertEqual(interval, Detector.browserDebounceEndDefault)
        XCTAssertEqual(Detector.browserDebounceEndDefault, 12.0)
    }

    func test_explicit_override_wins_over_browser_default() {
        let interval = Detector.effectiveDebounceEnd(
            for: browserChrome,
            globalEndSec: 5,
            perBundle: ["com.google.Chrome": 20]
        )
        XCTAssertEqual(interval, 20)
    }

    func test_explicit_override_wins_for_native_too() {
        let interval = Detector.effectiveDebounceEnd(
            for: nativeZoom,
            globalEndSec: 5,
            perBundle: ["us.zoom.xos": 8]
        )
        XCTAssertEqual(interval, 8)
    }

    func test_override_for_other_bundle_does_not_apply() {
        // Override exists, but for a different bundle. The native source
        // must still fall through to the global.
        let interval = Detector.effectiveDebounceEnd(
            for: nativeZoom,
            globalEndSec: 5,
            perBundle: ["com.microsoft.teams2": 7]
        )
        XCTAssertEqual(interval, 5)
    }

    func test_browser_default_can_be_injected() {
        // Lets future code (or a test) plug in a different default
        // without touching the static constant.
        let interval = Detector.effectiveDebounceEnd(
            for: browserChrome,
            globalEndSec: 5,
            perBundle: [:],
            browserDefault: 15
        )
        XCTAssertEqual(interval, 15)
    }
}
