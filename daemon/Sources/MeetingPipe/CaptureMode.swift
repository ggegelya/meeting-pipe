import Foundation

/// How a recording treats the microphone, resolved once at `beginRecording` and
/// threaded into `MeetingRecorder.start` with no default so every call site must
/// choose (TECH-MIC4, ratified by ADR 0016).
///
/// The architectural root cause of the "talking unmuted, recorded nothing"
/// failure was a real-time destructive gate that depended on a mute reading that
/// does not exist for most tools and is fragile where it does. The cure is to
/// stop deciding destructively in real time: capture losslessly and keep the
/// full recording. Offline muted-span redaction is an opt-in privacy layer on
/// top of lossless capture, off by default (TECH-MIC9: a confidently-wrong mute
/// oracle, e.g. Teams' new mini window, made it destroy the consumed artifact of
/// a normal meeting). The only path that still gates in real time is regulated /
/// NDA, where no audio at rest is permitted and the data-loss risk is accepted.
enum CaptureMode: Equatable {
    /// Capture the mic losslessly; never zero it at capture and never redact. The
    /// full recording IS the consumed artifact. The default for normal meetings
    /// (TECH-MIC9): retention-based privacy, no dependency on any mute oracle.
    case captureFirst

    /// Capture the mic losslessly, then redact the muted spans from the consumed
    /// artifact offline (TECH-MIC5), keeping the full recording aside for
    /// recovery. Opt-in per workflow (`flags.redactMutedSpans`) for users who
    /// want muted asides kept out of the notes. The offline redaction is
    /// audio-grounded (`MuteRedactor` withholds a runaway whole-meeting redaction
    /// over a live mic) so a wrong timeline degrades rather than destroys.
    case captureFirstRedact

    /// Real-time destructive gate: muted spans are zeroed in place at capture so
    /// no muted audio is ever written to disk. Used under regulated (global) or
    /// NDA (per-workflow) where no audio at rest is permitted. Carries the
    /// residual data-loss risk ADR 0016 documents; its only lever is the oracle
    /// hardening in TECH-MIC6.
    case regulatedGate

    /// Resolve the mode for a recording. Regulated or NDA forces the
    /// no-audio-at-rest gate; otherwise lossless capture, with offline redaction
    /// only when the workflow opted in (`redactMuted`). This is the only
    /// resolution rule, so an ambiguous caller that cannot read the flags should
    /// pass `.regulatedGate` explicitly (the privacy-safe path), per ADR 0016.
    static func resolve(regulated: Bool, nda: Bool, redactMuted: Bool) -> CaptureMode {
        if regulated || nda { return .regulatedGate }
        return redactMuted ? .captureFirstRedact : .captureFirst
    }

    /// True when the mic is captured losslessly (no real-time zeroing): both
    /// capture-first variants. Only `.regulatedGate` zeroes at capture.
    var capturesLosslessly: Bool { self != .regulatedGate }

    /// Stable on-disk token written at recording start (`<stem>.capturemode`) so
    /// orphan recovery, after a crash where `stop()` never wrote the mute
    /// timeline, can still apply the right privacy posture (TECH-MIC5 review).
    var marker: String {
        switch self {
        case .captureFirst: return "capture_first"
        case .captureFirstRedact: return "capture_first_redact"
        case .regulatedGate: return "regulated_gate"
        }
    }

    init?(marker: String) {
        switch marker.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "capture_first": self = .captureFirst
        case "capture_first_redact": self = .captureFirstRedact
        case "regulated_gate": self = .regulatedGate
        default: return nil
        }
    }
}
