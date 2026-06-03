import Foundation

/// Decides whether the 5-minute mic+system silence backstop (TECH-C2) should
/// actually stop the recording, or stand down because the silence is a wait,
/// not a meeting end.
///
/// The backstop exists for browser / stale-window meetings where end-detection
/// is blind and a finished call can leave the title probe firing. For a native
/// meeting that the lifecycle subsystem still tracks as live (window + Leave
/// button present), prolonged silence is someone waiting for a participant to
/// join, not an abandoned call. Stopping there throws away an active meeting,
/// which is the bug this guards against.
///
/// Pure decision, no I/O: the Coordinator forwards the recording's source kind
/// and the current lifecycle liveness in.
enum SilenceAutoStopPolicy {
    /// `true` to let the silence backstop stop the recording; `false` to stand
    /// down (keep recording and re-nudge).
    ///
    /// Stands down only for a native meeting that is still lifecycle-live. A
    /// browser meeting, a manual recording (`sourceKind == nil`), or a native
    /// meeting whose lifecycle is no longer live all keep today's stop, so a
    /// genuinely ended or untrackable meeting is not left recording forever.
    static func shouldAutoStop(sourceKind: AppSourceKind?, lifecycleIsLive: Bool) -> Bool {
        if sourceKind == .native, lifecycleIsLive {
            return false
        }
        return true
    }
}
