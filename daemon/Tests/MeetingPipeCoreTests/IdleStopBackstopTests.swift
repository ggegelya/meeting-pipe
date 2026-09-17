import XCTest
@testable import MeetingPipeCore

/// TECH-END3: the single VAD-gated idle backstop that replaced the RMS
/// `SilenceDetector` and `MicOnlySilenceBackstop`. Verdict-driven so the timer
/// runs in microseconds with an injected clock, no Timer to wait on.
final class IdleStopBackstopTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func backstop(
        notify: TimeInterval = 480,
        autoStop: TimeInterval = 900
    ) -> IdleStopBackstop {
        IdleStopBackstop(notifySeconds: notify, autoStopSeconds: autoStop)
    }

    private func silent(_ ms: Int = 0) -> MicGateVerdict { .silentByRMS(dwellMillis: ms) }

    // MARK: - Auto-stop horizon

    func test_does_not_auto_stop_below_window() {
        let b = backstop()
        var stopped = false
        b.onAutoStop = { _ in stopped = true }
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0)
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(800))
        XCTAssertFalse(stopped)
        XCTAssertFalse(b.triggered)
    }

    func test_auto_stops_after_window_elapses() {
        let b = backstop()
        var firedAt: Date?
        b.onAutoStop = { firedAt = $0 }
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0)
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(900))
        XCTAssertEqual(firedAt, t0.addingTimeInterval(900))
        XCTAssertTrue(b.triggered)
    }

    func test_auto_stop_is_sticky_across_trailing_samples() {
        // Recorder teardown is async; trailing ticks must not re-fire.
        let b = backstop()
        var stopCount = 0
        b.onAutoStop = { _ in stopCount += 1 }
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0)
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(900))
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(905))
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(1500))
        XCTAssertEqual(stopCount, 1)
    }

    // MARK: - Nudge horizon

    func test_nudge_fires_once_before_the_auto_stop() {
        let b = backstop(notify: 480, autoStop: 900)
        var notifyCount = 0
        var stopCount = 0
        b.onNotify = { _ in notifyCount += 1 }
        b.onAutoStop = { _ in stopCount += 1 }
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0)
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(480))  // nudge
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(600))  // still silent
        XCTAssertEqual(notifyCount, 1, "Nudge fires once per streak, not every tick")
        XCTAssertEqual(stopCount, 0)
    }

    // MARK: - Clock-feed without verdict changes (TECH-END7)

    func test_re_ingesting_the_same_silent_verdict_fires_both_horizons() {
        // TECH-END7: the verdict stream is deduped, so after a call goes silent the
        // host re-feeds the SAME verdict at ~1 Hz (off the mic-level callback). The
        // backstop must advance off the clock and fire both horizons in turn, with
        // no new verdict transition. This is the forgotten-recording scenario the
        // auto-stop exists for, which the change-only feed could never reach.
        let b = backstop(notify: 480, autoStop: 900)
        var notified = false
        var stopped = false
        b.onNotify = { _ in notified = true }
        b.onAutoStop = { _ in stopped = true }
        let v = silent()

        b.ingest(verdict: v, systemChannel: .live(hasAudio: false), at: t0)                          // streak starts
        XCTAssertFalse(notified)
        XCTAssertFalse(stopped)
        b.ingest(verdict: v, systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(480))  // re-fed, nudge
        XCTAssertTrue(notified, "the nudge fires from the clock on re-ingestion")
        XCTAssertFalse(stopped)
        b.ingest(verdict: v, systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(900))  // re-fed, stop
        XCTAssertTrue(stopped, "the auto-stop fires from the clock on re-ingestion")
    }

    // MARK: - Nudge stays below a configurable auto-stop

    func test_safe_notify_always_precedes_the_auto_stop() {
        // The auto-stop horizon is user-configurable (60...1800 s). The nudge must
        // land before it, otherwise the auto-stop fires with no warning (ingest
        // checks the auto-stop first). safeNotifySeconds guarantees notify < autoStop.
        XCTAssertEqual(IdleStopBackstop.safeNotifySeconds(forAutoStop: 900), 450)   // default 15 min
        XCTAssertEqual(IdleStopBackstop.safeNotifySeconds(forAutoStop: 1800), 480)  // capped at the default
        XCTAssertEqual(IdleStopBackstop.safeNotifySeconds(forAutoStop: 120), 60)    // low config still warns first
        for autoStop in stride(from: 60.0, through: 1800.0, by: 30.0) {
            XCTAssertLessThan(
                IdleStopBackstop.safeNotifySeconds(forAutoStop: autoStop), autoStop,
                "nudge must strictly precede the auto-stop for every slider value"
            )
        }
    }

    func test_low_auto_stop_still_fires_the_nudge_first() {
        // Regression for the review finding: a 120 s auto-stop with a fixed 480 s nudge
        // would never warn. With the derived nudge (60 s) the warning lands first.
        let b = IdleStopBackstop(
            notifySeconds: IdleStopBackstop.safeNotifySeconds(forAutoStop: 120),
            autoStopSeconds: 120
        )
        var notifyAt: Date?
        var stopAt: Date?
        b.onNotify = { notifyAt = $0 }
        b.onAutoStop = { stopAt = $0 }
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0)
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(60))
        XCTAssertEqual(notifyAt, t0.addingTimeInterval(60))
        XCTAssertNil(stopAt, "nudge fires before the auto-stop, not together")
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(120))
        XCTAssertEqual(stopAt, t0.addingTimeInterval(120))
    }

    // MARK: - VAD gating (the END3 point: speech, not raw level, resets)

    func test_voice_activity_resets_the_streak() {
        let b = backstop()
        var stopped = false
        b.onAutoStop = { _ in stopped = true }
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0)
        b.ingest(verdict: .hot(reason: .voiceActivityDetected), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(100))
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(950))
        XCTAssertFalse(stopped, "User speaking mid-window resets the idle streak")
    }

    func test_system_audio_resets_the_streak() {
        let b = backstop()
        var stopped = false
        b.onAutoStop = { _ in stopped = true }
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0)
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: true), at: t0.addingTimeInterval(100))
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(950))
        XCTAssertFalse(stopped, "Other participants' audio resets the idle streak")
    }

    func test_confidently_unmuted_floor_still_counts_as_silence() {
        // TECH-MIC5: the unmuted-but-quiet floor reports .hot to keep audio, but a
        // forgotten recording in that state must still auto-stop.
        let b = backstop()
        var firedAt: Date?
        b.onAutoStop = { firedAt = $0 }
        b.ingest(verdict: .hot(reason: .confidentlyUnmuted), systemChannel: .live(hasAudio: false), at: t0)
        b.ingest(verdict: .hot(reason: .confidentlyUnmuted), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(900))
        XCTAssertEqual(firedAt, t0.addingTimeInterval(900))
    }

    func test_muted_by_app_counts_as_silence() {
        let b = backstop()
        var stopped = false
        b.onAutoStop = { _ in stopped = true }
        b.ingest(verdict: .mutedByApp(axLabel: "Unmute", locale: "en"), systemChannel: .live(hasAudio: false), at: t0)
        b.ingest(verdict: .mutedByApp(axLabel: "Unmute", locale: "en"), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(900))
        XCTAssertTrue(stopped, "An app-muted user with no system audio is still a forgotten recording")
    }

    // MARK: - reset / keepAlive

    func test_reset_re_arms_the_backstop() {
        let b = backstop()
        var stopCount = 0
        b.onAutoStop = { _ in stopCount += 1 }
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0)
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(900))
        XCTAssertEqual(stopCount, 1)
        b.reset()
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(1000))
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(1900))
        XCTAssertEqual(stopCount, 2)
    }

    func test_keep_alive_restarts_the_countdown() {
        // The native stand-down (or "Keep recording") path: re-arm without carrying
        // the old streak, and let a later genuine idle still fire.
        let b = backstop()
        var stopCount = 0
        b.onAutoStop = { _ in stopCount += 1 }
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0)
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(890))  // no stop yet
        XCTAssertEqual(stopCount, 0)
        b.keepAlive()
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(895))  // restart
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(1794))  // 899s into new streak
        XCTAssertEqual(stopCount, 0, "the old streak must not carry over")
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(1795))  // 900s
        XCTAssertEqual(stopCount, 1)
    }

    func test_keep_alive_re_arms_after_a_fired_auto_stop() {
        let b = backstop()
        var stopCount = 0
        b.onAutoStop = { _ in stopCount += 1 }
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0)
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(900))
        XCTAssertEqual(stopCount, 1)
        b.keepAlive()
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(905))
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(1805))
        XCTAssertEqual(stopCount, 2)
    }

    func test_keep_alive_lets_the_nudge_fire_again() {
        let b = backstop(notify: 480, autoStop: 900)
        var notifyCount = 0
        b.onNotify = { _ in notifyCount += 1 }
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0)
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(480))  // nudge #1
        XCTAssertEqual(notifyCount, 1)
        b.keepAlive()
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(500))  // restart
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(980))  // 480s into new streak
        XCTAssertEqual(notifyCount, 2)
    }

    // MARK: - A down system channel holds the streak (REC17)

    /// The 2026-09-17 shape: the SCStream start hung for 64 minutes, the owner muted in
    /// Teams at +23 min, and the backstop nudged "Still in a meeting?" at +4 min and again
    /// at +8 min because a channel that never delivered read as a silent one. Red against
    /// `main`, where the host's one `hasSystemAudio` bit could not say "down".
    func test_a_down_system_channel_advances_neither_horizon() {
        let b = backstop(notify: 240, autoStop: 480)
        var notifyCount = 0
        var stopCount = 0
        b.onNotify = { _ in notifyCount += 1 }
        b.onAutoStop = { _ in stopCount += 1 }
        let muted = MicGateVerdict.mutedByApp(axLabel: "Unmute", locale: "en")
        for seconds in stride(from: 0.0, through: 3900.0, by: 60.0) {
            b.ingest(verdict: muted, systemChannel: .down, at: t0.addingTimeInterval(seconds))
        }
        XCTAssertEqual(notifyCount, 0, "mic silence against a channel that cannot be heard is not evidence of an empty call")
        XCTAssertEqual(stopCount, 0)
        XCTAssertFalse(b.triggered)
    }

    /// When the channel comes back and is quiet, the streak starts from that tick, not from
    /// engage and not from where a hold interrupted it.
    func test_the_channel_coming_back_quiet_starts_the_streak_from_that_moment() {
        let b = backstop(notify: 480, autoStop: 900)
        var notifyAt: Date?
        var stopAt: Date?
        b.onNotify = { notifyAt = $0 }
        b.onAutoStop = { stopAt = $0 }
        b.ingest(verdict: silent(), systemChannel: .down, at: t0)
        b.ingest(verdict: silent(), systemChannel: .down, at: t0.addingTimeInterval(600))
        let back = t0.addingTimeInterval(600)
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: back)
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: back.addingTimeInterval(479))
        XCTAssertNil(notifyAt, "479 s into the new streak is not yet the nudge")
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: back.addingTimeInterval(480))
        XCTAssertEqual(notifyAt, back.addingTimeInterval(480), "the nudge counts from when the channel came back")
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: back.addingTimeInterval(900))
        XCTAssertEqual(stopAt, back.addingTimeInterval(900))
    }

    /// A hold in the middle of a streak restarts it: the ticks before the outage are not
    /// carried across it, because nothing about the far side was known during it.
    func test_a_hold_mid_streak_restarts_it() {
        let b = backstop(notify: 480, autoStop: 900)
        var notifyAt: Date?
        b.onNotify = { notifyAt = $0 }
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0)
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(300))
        b.ingest(verdict: silent(), systemChannel: .down, at: t0.addingTimeInterval(310))
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(400))
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(480))
        XCTAssertNil(notifyAt, "480 s after engage is only 80 s into the streak that survived the hold")
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(880))
        XCTAssertEqual(notifyAt, t0.addingTimeInterval(880))
    }

    /// Live far-side audio after a hold still resets, exactly as it always did.
    func test_live_audio_after_a_hold_still_resets() {
        let b = backstop()
        var stopped = false
        b.onAutoStop = { _ in stopped = true }
        b.ingest(verdict: silent(), systemChannel: .down, at: t0)
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(10))
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: true), at: t0.addingTimeInterval(500))
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(1300))
        XCTAssertFalse(stopped, "the far side spoke at +500, so +1300 is 800 s into a streak, not 1290")
    }

    /// A nudge that fired before the hold can fire again after it: the hold is a fresh
    /// start, not a continuation with the nudge already spent.
    func test_the_nudge_can_fire_again_after_a_hold() {
        let b = backstop(notify: 480, autoStop: 900)
        var notifyCount = 0
        b.onNotify = { _ in notifyCount += 1 }
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0)
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(480))
        XCTAssertEqual(notifyCount, 1)
        b.ingest(verdict: silent(), systemChannel: .down, at: t0.addingTimeInterval(500))
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(600))
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(1080))
        XCTAssertEqual(notifyCount, 2)
    }

    /// The carve-out: Screen Recording denied is a chosen mic-only state, and the backstop was
    /// built for it (TECH-C7, `mic_only_silence_seconds`). `.micOnly` is `.live(hasAudio: false)`
    /// by another name, so both horizons fire on schedule.
    func test_mic_only_by_permission_counts_as_silence() {
        let b = backstop(notify: 480, autoStop: 900)
        var notifyAt: Date?
        var stopAt: Date?
        b.onNotify = { notifyAt = $0 }
        b.onAutoStop = { stopAt = $0 }
        b.ingest(verdict: silent(), systemChannel: .micOnly, at: t0)
        b.ingest(verdict: silent(), systemChannel: .micOnly, at: t0.addingTimeInterval(480))
        XCTAssertEqual(notifyAt, t0.addingTimeInterval(480))
        b.ingest(verdict: silent(), systemChannel: .micOnly, at: t0.addingTimeInterval(900))
        XCTAssertEqual(stopAt, t0.addingTimeInterval(900))
    }

    /// Speech on the mic against a down channel is still speech: the hold is about what the
    /// far side means, not a suspension of the mic verdict, and a live mic resets exactly as
    /// it would with the channel up.
    func test_a_down_channel_does_not_outrank_a_hot_mic() {
        let b = backstop()
        var stopped = false
        b.onAutoStop = { _ in stopped = true }
        b.ingest(verdict: .hot(reason: .voiceActivityDetected), systemChannel: .down, at: t0)
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(10))
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(905))
        XCTAssertFalse(stopped, "895 s into the streak that began when the channel came back")
        b.ingest(verdict: silent(), systemChannel: .live(hasAudio: false), at: t0.addingTimeInterval(910))
        XCTAssertTrue(stopped)
    }
}
