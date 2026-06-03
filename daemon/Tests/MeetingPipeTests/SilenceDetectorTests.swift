import XCTest
@testable import MeetingPipe

/// Unit tests for `SilenceDetector` (TECH-C2). The detector takes an
/// explicit `at:` time parameter on every observe call so these tests
/// run in microseconds — no Timer to wait on, no real wall clock.
final class SilenceDetectorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDetector(
        notifyAfter: TimeInterval = 90,
        autoStopAfter: TimeInterval = 300,
        thresholdDb: Double = -50,
        onNotify: @escaping () -> Void = {},
        onAutoStop: @escaping () -> Void = {}
    ) -> SilenceDetector {
        SilenceDetector(
            thresholdDb: thresholdDb,
            notifyAfterSec: notifyAfter,
            autoStopAfterSec: autoStopAfter,
            onNotifySilence: onNotify,
            onAutoStopSilence: onAutoStop
        )
    }

    // MARK: - Silence streak gating

    func test_does_not_notify_before_threshold() {
        var notifyCount = 0
        let det = makeDetector(onNotify: { notifyCount += 1 })
        det.observeMic(db: -80, at: t0)
        det.observeSystem(db: -80, at: t0)
        det.observeMic(db: -80, at: t0.addingTimeInterval(89))
        XCTAssertEqual(notifyCount, 0)
    }

    func test_fires_notify_at_threshold_exactly() {
        var notifyCount = 0
        let det = makeDetector(onNotify: { notifyCount += 1 })
        det.observeMic(db: -80, at: t0)
        det.observeSystem(db: -80, at: t0)
        det.observeMic(db: -80, at: t0.addingTimeInterval(90))
        XCTAssertEqual(notifyCount, 1)
    }

    func test_notify_fires_only_once_per_streak() {
        var notifyCount = 0
        let det = makeDetector(onNotify: { notifyCount += 1 })
        det.observeMic(db: -80, at: t0)
        det.observeSystem(db: -80, at: t0)
        det.observeMic(db: -80, at: t0.addingTimeInterval(91))
        det.observeMic(db: -80, at: t0.addingTimeInterval(120))
        det.observeMic(db: -80, at: t0.addingTimeInterval(180))
        XCTAssertEqual(notifyCount, 1)
    }

    // MARK: - Auto-stop

    func test_fires_auto_stop_at_5_minutes() {
        var stopCount = 0
        let det = makeDetector(onAutoStop: { stopCount += 1 })
        det.observeMic(db: -80, at: t0)
        det.observeSystem(db: -80, at: t0)
        det.observeMic(db: -80, at: t0.addingTimeInterval(300))
        XCTAssertEqual(stopCount, 1)
    }

    func test_auto_stop_fires_only_once_even_with_trailing_samples() {
        var stopCount = 0
        let det = makeDetector(onAutoStop: { stopCount += 1 })
        det.observeMic(db: -80, at: t0)
        det.observeSystem(db: -80, at: t0)
        det.observeMic(db: -80, at: t0.addingTimeInterval(300))
        // Recorder is async — taps may still fire after the Coordinator
        // requested stop. Subsequent samples must not re-trigger.
        det.observeMic(db: -80, at: t0.addingTimeInterval(305))
        det.observeMic(db: -80, at: t0.addingTimeInterval(400))
        XCTAssertEqual(stopCount, 1)
    }

    // MARK: - Speech resets streak

    func test_any_loud_sample_resets_streak() {
        var notifyCount = 0
        var stopCount = 0
        let det = makeDetector(
            onNotify: { notifyCount += 1 },
            onAutoStop: { stopCount += 1 }
        )
        det.observeMic(db: -80, at: t0)
        det.observeSystem(db: -80, at: t0)
        // 80 s of silence, then a loud sample — streak resets.
        det.observeMic(db: -10, at: t0.addingTimeInterval(80))
        // Another silent run — the new streak's clock starts at the
        // first silent sample after the loud reset (t0+140), not at
        // the loud point itself. With 1 Hz sampling in production
        // these are within a second of each other; the synthetic gap
        // here makes the model explicit.
        det.observeMic(db: -80, at: t0.addingTimeInterval(140))
        XCTAssertEqual(notifyCount, 0)
        XCTAssertEqual(stopCount, 0)
        // 90 s after the new streak start (t0+140) → notify fires.
        det.observeMic(db: -80, at: t0.addingTimeInterval(230))
        XCTAssertEqual(notifyCount, 1)
    }

    func test_only_mic_loud_holds_streak_open() {
        // System silent, mic talking. Not silence — user is still in a
        // call where the other side has muted (common Zoom pattern).
        var notifyCount = 0
        let det = makeDetector(onNotify: { notifyCount += 1 })
        det.observeMic(db: -10, at: t0)
        det.observeSystem(db: -80, at: t0)
        det.observeMic(db: -10, at: t0.addingTimeInterval(100))
        XCTAssertEqual(notifyCount, 0)
    }

    func test_only_system_loud_holds_streak_open() {
        // Mic muted, other side talking. Same situation, mirrored — also
        // not silence. Common when the user has muted themselves.
        var notifyCount = 0
        let det = makeDetector(onNotify: { notifyCount += 1 })
        det.observeMic(db: -80, at: t0)
        det.observeSystem(db: -10, at: t0)
        det.observeSystem(db: -10, at: t0.addingTimeInterval(100))
        XCTAssertEqual(notifyCount, 0)
    }

    // MARK: - No-system-audio fallback

    func test_silence_detected_from_mic_alone_when_system_unavailable() {
        // Screen Recording denied → system stream never delivers. The
        // detector should still trip on mic-only silence so a forgotten
        // recording auto-stops after 5 min.
        var stopCount = 0
        let det = makeDetector(onAutoStop: { stopCount += 1 })
        det.observeMic(db: -80, at: t0)
        det.observeMic(db: -80, at: t0.addingTimeInterval(300))
        XCTAssertEqual(stopCount, 1)
    }

    // MARK: - Reset

    func test_reset_re_arms_detector_for_reuse() {
        var notifyCount = 0
        var stopCount = 0
        let det = makeDetector(
            onNotify: { notifyCount += 1 },
            onAutoStop: { stopCount += 1 }
        )
        // Drive past auto-stop on the first session.
        det.observeMic(db: -80, at: t0)
        det.observeSystem(db: -80, at: t0)
        det.observeMic(db: -80, at: t0.addingTimeInterval(300))
        XCTAssertEqual(stopCount, 1)

        det.reset()

        // Fresh session — must rearm cleanly. Pretend we get loud samples
        // first (recorder just started), then silence again.
        det.observeMic(db: -10, at: t0.addingTimeInterval(1000))
        det.observeSystem(db: -10, at: t0.addingTimeInterval(1000))
        det.observeMic(db: -80, at: t0.addingTimeInterval(1100))
        det.observeSystem(db: -80, at: t0.addingTimeInterval(1100))
        det.observeMic(db: -80, at: t0.addingTimeInterval(1190))
        XCTAssertEqual(notifyCount, 1)
        // Auto-stop hasn't fired again — only 90 s elapsed in the new session.
        XCTAssertEqual(stopCount, 1)
    }

    // MARK: - Threshold edge

    func test_value_exactly_at_threshold_is_not_silent() {
        // `< thresholdDb` is the gate, so the threshold itself counts as
        // non-silent. Makes -50.0 readings from a flat-noisy room safe
        // from over-triggering.
        var notifyCount = 0
        let det = makeDetector(thresholdDb: -50, onNotify: { notifyCount += 1 })
        det.observeMic(db: -50, at: t0)
        det.observeSystem(db: -50, at: t0)
        det.observeMic(db: -50, at: t0.addingTimeInterval(120))
        XCTAssertEqual(notifyCount, 0)
    }

    // MARK: - keepAlive (TECH-C2 false-positive fix)

    func test_keep_alive_restarts_the_auto_stop_countdown() {
        var stopCount = 0
        let det = makeDetector(onAutoStop: { stopCount += 1 })
        det.observeMic(db: -80, at: t0)
        det.observeSystem(db: -80, at: t0)
        det.observeMic(db: -80, at: t0.addingTimeInterval(290))  // 290 s, no stop yet
        XCTAssertEqual(stopCount, 0)

        det.keepAlive()  // native gate stood down, or user tapped "Keep recording"

        // The countdown restarts from the next sample, not from t0.
        det.observeMic(db: -80, at: t0.addingTimeInterval(295))
        det.observeMic(db: -80, at: t0.addingTimeInterval(594))  // 299 s into the new streak
        XCTAssertEqual(stopCount, 0, "the old streak must not carry over")
        det.observeMic(db: -80, at: t0.addingTimeInterval(595))  // 300 s into the new streak
        XCTAssertEqual(stopCount, 1)
    }

    func test_keep_alive_lets_the_notify_fire_again() {
        var notifyCount = 0
        let det = makeDetector(onNotify: { notifyCount += 1 })
        det.observeMic(db: -80, at: t0)
        det.observeSystem(db: -80, at: t0)
        det.observeMic(db: -80, at: t0.addingTimeInterval(90))   // notify #1
        XCTAssertEqual(notifyCount, 1)
        det.keepAlive()
        det.observeMic(db: -80, at: t0.addingTimeInterval(100))  // restart streak
        det.observeMic(db: -80, at: t0.addingTimeInterval(190))  // 90 s into new streak
        XCTAssertEqual(notifyCount, 2)
    }

    func test_keep_alive_re_arms_after_a_fired_auto_stop() {
        // The native-gate path: the detector fired the auto-stop, the gate
        // chose to keep recording, keepAlive must clear didAutoStop so a later
        // genuine silence can still fire.
        var stopCount = 0
        let det = makeDetector(onAutoStop: { stopCount += 1 })
        det.observeMic(db: -80, at: t0)
        det.observeSystem(db: -80, at: t0)
        det.observeMic(db: -80, at: t0.addingTimeInterval(300))  // auto-stop #1
        XCTAssertEqual(stopCount, 1)

        det.keepAlive()
        det.observeMic(db: -80, at: t0.addingTimeInterval(305))  // restart streak
        det.observeMic(db: -80, at: t0.addingTimeInterval(605))  // 300 s later
        XCTAssertEqual(stopCount, 2)
    }
}
