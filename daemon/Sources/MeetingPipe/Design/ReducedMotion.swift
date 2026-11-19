import Foundation

/// What the continuously moving status indicators draw at a moment, under Reduce Motion or not
/// (UX102). PRODUCT.md's accessibility floor says the recording-dot loop and the row pulse degrade
/// to a still state when reduced motion is on; the three Library indicators (`PulseDot`,
/// `MPSteadyPulseDot`, `MPRingSpinner`) free-ran regardless. Pure so a test can pin the envelopes
/// without rendering. Under reduced motion the views draw one still frame and no `TimelineView`
/// at all, so the redraws stop as well as the movement.
enum PulseEnvelope {
    /// One full opacity cycle for both recording dots, the legacy `easeInOut(duration: 1.6)` shape.
    static let periodSec: Double = 1.6
    /// One full turn of the processing ring.
    static let ringPeriodSec: Double = 1.0

    private static func phase(at time: TimeInterval, period: Double) -> Double {
        time.truncatingRemainder(dividingBy: period) / period
    }

    /// The toolbar recording dot's aura, 0...1 (scaled by the view's aura alpha). Reduced: the aura
    /// held at its peak, so the dot still reads as live without moving.
    static func toolbarAura(at time: TimeInterval, reduceMotion: Bool) -> Double {
        if reduceMotion { return 1 }
        return 0.5 + 0.5 * cos(phase(at: time, period: periodSec) * 2 * .pi)
    }

    /// The row pill's recording dot, 0.35...1 ("steady, not urgent"). Reduced: full opacity.
    static func steadyDot(at time: TimeInterval, reduceMotion: Bool) -> Double {
        if reduceMotion { return 1 }
        return 0.675 + 0.325 * cos(phase(at: time, period: periodSec) * 2 * .pi)
    }

    /// The processing ring's rotation in degrees. Reduced: a still, partial ring.
    static func ringDegrees(at time: TimeInterval, reduceMotion: Bool) -> Double {
        if reduceMotion { return 0 }
        return 360 * phase(at: time, period: ringPeriodSec)
    }
}

/// The floating panels' motion decisions (UX102), shared by `RecordingHUDWindow` and
/// `MeetingPromptWindow` the way `HUDFlagAcknowledgement.decide(count:reduceMotion:)` carries the
/// flag's. The fades used `MPMotion.durBase` in and `durFast + 0.03` out whatever the setting, and
/// the HUD dot pulsed forever; only the prompt's "Last time" fade read `MPMotion.reduceMotion`.
/// The callers pass `MPMotion.reduceMotion`, read at call time, so a setting changed mid-recording
/// applies from the next panel.
struct PanelMotion: Equatable {
    let fadeIn: TimeInterval
    let fadeOut: TimeInterval
    /// Whether the HUD's recording dot runs its opacity loop. Off, it stays at full opacity.
    let pulses: Bool

    static func decide(reduceMotion: Bool) -> PanelMotion {
        reduceMotion
            ? PanelMotion(fadeIn: 0, fadeOut: 0, pulses: false)
            : PanelMotion(fadeIn: MPMotion.durBase, fadeOut: MPMotion.durFast + 0.03, pulses: true)
    }
}

/// The Audio tab waveform's keyboard and VoiceOver seek (UX102): a fixed step, clamped to the
/// recording. The waveform otherwise seeks by pointer only.
enum WaveformSeek {
    static let stepSec: TimeInterval = 5

    static func step(from current: TimeInterval, forward: Bool, durationSec: TimeInterval) -> TimeInterval {
        let target = current + (forward ? stepSec : -stepSec)
        return min(max(target, 0), max(durationSec, 0))
    }

    /// The accessibility value: where the playhead is, of how long.
    static func value(current: TimeInterval, durationSec: TimeInterval) -> String {
        "\(WaveformTimecode.format(current)) of \(WaveformTimecode.format(durationSec))"
    }
}
