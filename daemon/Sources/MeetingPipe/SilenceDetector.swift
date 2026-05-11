import Foundation

/// Watches mic + system audio levels during a recording so the daemon
/// can stop a meeting the regular detector missed-end (TECH-C2).
///
/// Failure mode this exists to cover: browser-tab meetings — the
/// detector's window-title probe can keep firing `started` long after
/// the call ended (a leftover "Meet" tab in the background, Slack
/// huddle threads named "huddle"). Until now the user noticed the
/// recording was still running hours later by checking the menu bar.
///
/// Behaviour:
///   - When BOTH the latest mic and the latest system level fall below
///     `thresholdDb`, a silence streak begins.
///   - After `notifyAfterSec` seconds of unbroken silence, fire
///     `onNotifySilence` exactly once. The Coordinator surfaces this
///     as a "Still meeting?" notification with a stop action — the
///     user can stop immediately or ignore.
///   - After `autoStopAfterSec` seconds, fire `onAutoStopSilence`
///     exactly once. The Coordinator emits `auto_stop_silence` and
///     stops the recorder.
///   - Any single non-silent sample resets the streak (and re-arms
///     the notification path).
///
/// Pure timing logic: the detector never owns a Timer. The Coordinator
/// drives `observeMic` / `observeSystem` from the Recorder's level
/// callbacks (already ~1×/sec), and tests inject the clock through the
/// `at:` parameter. That's why this file has no `import AVFoundation`.
///
/// One asymmetry worth flagging: if the user denies Screen Recording,
/// the system stream never delivers a sample and `latestSystemDb`
/// stays at `-.infinity`. The gate then reduces to "mic alone is
/// silent" — which is the correct call for a mic-only recording (no
/// other channel exists), so the 5-minute fallback still works.
final class SilenceDetector {
    static let defaultThresholdDb: Double = -50.0
    static let defaultNotifyAfterSec: TimeInterval = 90
    static let defaultAutoStopAfterSec: TimeInterval = 300

    private let thresholdDb: Double
    private let notifyAfterSec: TimeInterval
    private let autoStopAfterSec: TimeInterval
    private let onNotifySilence: () -> Void
    private let onAutoStopSilence: () -> Void

    private var latestMicDb: Double = -.infinity
    private var latestSystemDb: Double = -.infinity
    private var silenceStartedAt: Date?
    private var didNotify: Bool = false
    private var didAutoStop: Bool = false

    init(
        thresholdDb: Double = SilenceDetector.defaultThresholdDb,
        notifyAfterSec: TimeInterval = SilenceDetector.defaultNotifyAfterSec,
        autoStopAfterSec: TimeInterval = SilenceDetector.defaultAutoStopAfterSec,
        onNotifySilence: @escaping () -> Void,
        onAutoStopSilence: @escaping () -> Void
    ) {
        self.thresholdDb = thresholdDb
        self.notifyAfterSec = notifyAfterSec
        self.autoStopAfterSec = autoStopAfterSec
        self.onNotifySilence = onNotifySilence
        self.onAutoStopSilence = onAutoStopSilence
    }

    /// Wipe streak state so the detector can be reused across recordings.
    /// Cached level values reset to `-.infinity` deliberately: without a
    /// sample to prove otherwise, "unknown" is treated as silent so the
    /// auto-stop path still arms (matches the no-system-audio case).
    func reset() {
        latestMicDb = -.infinity
        latestSystemDb = -.infinity
        silenceStartedAt = nil
        didNotify = false
        didAutoStop = false
    }

    func observeMic(db: Double, at time: Date = Date()) {
        latestMicDb = db
        evaluate(at: time)
    }

    func observeSystem(db: Double, at time: Date = Date()) {
        latestSystemDb = db
        evaluate(at: time)
    }

    private func evaluate(at time: Date) {
        // Once auto-stop has fired, the recorder is being torn down by
        // the Coordinator. Subsequent stale ticks must not fire again.
        if didAutoStop { return }

        let silent = latestMicDb < thresholdDb && latestSystemDb < thresholdDb
        if !silent {
            silenceStartedAt = nil
            didNotify = false
            return
        }

        let start = silenceStartedAt ?? time
        silenceStartedAt = start
        let elapsed = time.timeIntervalSince(start)

        if elapsed >= autoStopAfterSec {
            didAutoStop = true
            onAutoStopSilence()
            return
        }
        if elapsed >= notifyAfterSec && !didNotify {
            didNotify = true
            onNotifySilence()
        }
    }
}
