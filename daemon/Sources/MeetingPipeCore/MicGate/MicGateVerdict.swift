import Foundation

/// Per-buffer verdict from `MicGate`. Determines whether the writer emits live mic samples or zero-amplitude frames. Reasons are written to events.jsonl for post-hoc gate-flip analysis.
public enum MicGateVerdict: Equatable {
    /// Live samples pass through. Reason names the primary probe (VAD vs RMS-above-open-threshold).
    case hot(reason: Reason)

    /// Meeting app reports mute via AX; audit attribute records the matched localised label.
    case mutedByApp(axLabel: String, locale: String)

    /// HAL system-input mute (Control Center / hardware key / per-device property). Highest precedence.
    case mutedByHardware

    /// RMS gate closed; no other primary signal active.
    case silentByRMS(dwellMillis: Int)

    /// No probe gave a confident verdict. Writer emits zero-amp frames (safer than ambient capture); audit log lists per-probe gaps.
    case uncertain(reasons: [String])

    public enum Reason: String, Equatable {
        case voiceActivityDetected = "vad_active"
        case rmsAboveOpenThreshold = "rms_above_open_threshold"
    }

    /// True only for `.hot`; all other verdicts zero the mic.
    public var passesLiveAudio: Bool {
        if case .hot = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .hot: return "hot"
        case .mutedByApp: return "muted_by_app"
        case .mutedByHardware: return "muted_by_hardware"
        case .silentByRMS: return "silent_by_rms"
        case .uncertain: return "uncertain"
        }
    }
}
