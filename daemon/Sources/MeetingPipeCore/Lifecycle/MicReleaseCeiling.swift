import Foundation

/// END23: one independent stop for a Teams-sourced recording. Once the Teams family has read
/// released for `ceilingSeconds` of DET23's monitor samples, the recording stops whatever the end
/// engine believes (in a meeting, holding, already ended, or never engaged), cut at the release.
///
/// Why it exists: three Teams recordings ran 562 s, 63 s and about 380 s past a mic release that was
/// in the log, and since END17 retired END13's 7200 s ceiling nothing bounds a recording whose engine
/// stays live, reverts a hold, or has gone terminal (stem 20261112-174606). The engine's own
/// process-audio voter cannot be the bound: it runs only while an adapter is engaged and backs off
/// to 5 s. This reads the always-on monitor instead.
///
/// Why 120 s: the longest same-call gaps on record are 23.1 s and 23.5 s, sampled through a poll that
/// adds up to 5 s, so the true bound is about 28.5 s; 120 s is four times that.
///
/// Why regardless of the Leave button, unlike END29's lone-dwell refusal: END29 guards a return the
/// engagement-bound signal can miss on a stale object. The monitor re-enumerates the list every
/// second, so a re-registered holder reads held on the next tick, and the audit measured in-app mute
/// never releasing the flag (178 s false in 38,845 s of app-muted Teams time, all after the call's
/// final release). Both era A overruns had the Leave button reading live.
///
/// Pure: the host feeds one snapshot a second. The cut is the monitor's `leftHeldAt`, the first
/// non-held sample, and the later of the two Teams families' (classic Teams usually reads released
/// from launch). Released samples add time, capped per sample so a stalled host never credits an
/// unobserved gap; unknown samples (stale, list failed, a vanished holder) pause without clearing;
/// a held sample clears; a `leftHeldAt` that moved (a hold too short for the host to see) restarts.
/// A release that began before the recording does not arm it (owner question open, see END23).
public struct MicReleaseCeiling {

    /// The Teams family, as the monitor's registry defines it.
    public static let teamsFamilies: Set<String> = ["com.microsoft.teams2", "com.microsoft.teams"]
    public static let ceilingSeconds: Double = 120
    /// At most this much released time is credited per sample.
    public static let maxCreditPerSample: Double = 2

    public enum Decision: Equatable {
        case none
        /// A release this recording owns was first seen; `cut` is its start on the monitor clock.
        case releaseStarted(cut: TimeInterval)
        /// Released for the ceiling: stop, cut at `cut`. Returned once.
        case stop(cut: TimeInterval, releasedSeconds: Double)
    }

    /// Whether a recording from `bundleID` gets the ceiling: a native Teams source only. Zoom waits on
    /// DET24's bar Z1, Webex and Slack on a measured call each, browsers on DET24's B bars, and a
    /// source-less recording's end is END11's.
    public static func applies(toBundleID bundleID: String?, isNative: Bool) -> Bool {
        guard isNative, let bundleID else { return false }
        return MicHolderMonitor.family(forBundleID: bundleID, in: Array(teamsFamilies)) != nil
    }

    private let recordingStartedAt: TimeInterval
    public private(set) var cut: TimeInterval?
    public private(set) var releasedSeconds: Double = 0
    private var lastReleasedAt: TimeInterval?
    private var stopped = false

    /// `recordingStartedAt` on the monitor's clock.
    public init(recordingStartedAt: TimeInterval) {
        self.recordingStartedAt = recordingStartedAt
    }

    public mutating func observe(_ snapshot: MicHolderMonitor.Snapshot) -> Decision {
        guard !stopped else { return .none }
        let readings = Self.teamsFamilies.map { snapshot.readings[$0] }
        let levels = readings.map { $0?.level ?? .unknown }
        if levels.contains(.held) {
            cut = nil
            releasedSeconds = 0
            lastReleasedAt = nil
            return .none
        }
        if levels.contains(.unknown) {
            lastReleasedAt = nil
            return .none
        }
        // Every Teams family reads released. The release this recording owns began at the latest
        // family's first non-held sample; a family that never held has none.
        guard let start = readings.compactMap({ $0?.leftHeldAt }).max(), start >= recordingStartedAt else {
            return .none
        }
        let at = snapshot.at
        if cut != start {
            cut = start
            releasedSeconds = 0
            lastReleasedAt = at
            return .releaseStarted(cut: start)
        }
        if let last = lastReleasedAt, at > last {
            releasedSeconds += min(at - last, Self.maxCreditPerSample)
        }
        lastReleasedAt = at
        guard releasedSeconds >= Self.ceilingSeconds else { return .none }
        stopped = true
        return .stop(cut: start, releasedSeconds: releasedSeconds)
    }
}
