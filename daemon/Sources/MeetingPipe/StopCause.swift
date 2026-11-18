import Foundation

/// OBS5: the surface a person stopped a recording from. Every route into `toggleManual` names one,
/// so a `recording_stopped` row says which control was pressed.
enum StopSurface: String, Equatable {
    case menu, hotkey, hud, notification, automation
}

/// OBS5: why a recording stopped, written as `stop_cause` on `recording_stopped` and in its
/// `daemon.log` line. Before it, "why" was answered by elimination from whichever row came first
/// (`force_stop`, `auto_stop_silence`, a lifecycle `ended`), and one lost row left a stop with no
/// cause: 10 of 74 field stops had none. Every caller of `stopRecording` passes one, so no stop
/// can be written without it.
enum StopCause: Equatable {
    /// A person pressed Stop. `duringHold` when it landed while an end was held (Confirming end).
    case userStop(surface: StopSurface, duringHold: Bool)
    /// The lifecycle engine confirmed the meeting ended.
    case lifecycleEnd
    /// END20: the meeting ended while the recording was still coming up.
    case endedDuringStart
    /// END20: a Stop or toggle overtook the start; `by` is the latch's own name for it.
    case cancelledDuringStart(by: String)
    /// The silence backstop's horizon.
    case idleBackstop
    /// DET1: the app that held the mic released it.
    case micRelease
    /// END23: Teams has not held the mic for its ceiling.
    case micReleaseCeiling
    /// END28: the call's window changed to another call; the stem splits.
    case callChanged
    /// The force-stop hotkey or the URL scheme's stop verb.
    case forceStop(reason: String)
    /// REC20: the disk is nearly full.
    case lowSpace
    /// REC3 / REC25: a capture channel's writes failed or stalled.
    case writerStalled(channel: String)

    /// The cause a `forceStop(reason:)` names, from the reasons its callers pass.
    static func forced(reason: String) -> StopCause {
        if reason == "low_space" { return .lowSpace }
        let writeFailure = "write_failure_"
        if reason.hasPrefix(writeFailure) { return .writerStalled(channel: String(reason.dropFirst(writeFailure.count))) }
        return .forceStop(reason: reason)
    }

    /// The `stop_cause` value.
    var name: String {
        switch self {
        case .userStop(_, let duringHold): return duringHold ? "user_stop_during_hold" : "user_stop"
        case .lifecycleEnd: return "lifecycle_end"
        case .endedDuringStart: return "ended_during_start"
        case .cancelledDuringStart: return "cancelled_during_start"
        case .idleBackstop: return "idle_backstop"
        case .micRelease: return "mic_release"
        case .micReleaseCeiling: return "mic_release_ceiling"
        case .callChanged: return "call_changed"
        case .forceStop: return "force_stop"
        case .lowSpace: return "low_space"
        case .writerStalled: return "writer_stalled"
        }
    }

    /// `stop_cause` plus the one detail that goes with it (`stop_surface`, `force_reason`,
    /// `channel`, `cancelled_by`).
    var attributes: [String: Any] {
        var out: [String: Any] = ["stop_cause": name]
        switch self {
        case .userStop(let surface, _): out["stop_surface"] = surface.rawValue
        case .forceStop(let reason): out["force_reason"] = reason
        case .writerStalled(let channel): out["channel"] = channel
        case .cancelledDuringStart(let by): out["cancelled_by"] = by
        default: break
        }
        return out
    }

    /// END21's `held_end_trimmed` `stop_route`, kept byte-for-byte so rows before OBS5 and after
    /// read the same.
    var stopRoute: String {
        switch self {
        case .userStop: return "toggle"
        case .lifecycleEnd, .endedDuringStart, .cancelledDuringStart: return "lifecycle_end"
        case .idleBackstop: return "idle_backstop"
        case .micRelease: return "mic_released"
        case .micReleaseCeiling: return "mic_release_ceiling"
        case .callChanged: return "call_changed"
        case .forceStop(let reason): return reason
        case .lowSpace: return "low_space"
        case .writerStalled(let channel): return "write_failure_\(channel)"
        }
    }
}

extension StopCause {
    /// OBS5: the stop notification's title, naming the route that stopped the recording, so a
    /// wrong automatic end is visible the moment it happens instead of in the log afterwards.
    /// Every route used to post the same "Recording stopped". `docs/GUIDE.md` quotes these; change
    /// both together.
    var notificationTitle: String {
        switch self {
        case .userStop, .forceStop: return "You stopped the recording"
        case .lifecycleEnd, .endedDuringStart: return "Recording stopped: the call ended"
        case .cancelledDuringStart: return "Recording stopped as it started"
        case .micRelease, .micReleaseCeiling: return "Recording stopped: the meeting app let go of the mic"
        case .callChanged: return "Recording split: a new call started"
        case .idleBackstop: return "Recording stopped: the meeting went quiet"
        case .lowSpace: return "Recording stopped: the disk was almost full"
        case .writerStalled: return "Recording stopped: the audio could not keep being saved"
        }
    }
}
