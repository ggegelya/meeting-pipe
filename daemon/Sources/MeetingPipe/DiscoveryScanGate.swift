import Foundation

/// Single-flight gate for `MeetingDiscoveryWatcher`'s scans (PERF17), lifted beside
/// `DiscoveryScanCadence` because the watcher itself has no harness (it needs `NSWorkspace` and
/// AVFoundation).
///
/// Two rules, both decided here:
///
/// - **One scan in flight, at most one pending.** Every poll, every meeting-app workspace event and
///   every mic KVO edge asks for a scan. Before this each one enqueued a full scan on the serial
///   `scanQueue`, so scans slower than their triggers (a large Teams tree, a hung client waiting out
///   the 2 s AX messaging timeout per read) queued up and each delivered its winner late. Now a
///   request while a scan runs only marks pending, and that scan's completion starts one follow-up
///   however many requests arrived meanwhile. The follow-up exists so a trigger that arrived
///   mid-scan is still answered by a scan that began after it.
/// - **No scans while the session does not accept prompts.** Outside `.idle` the only consumers of
///   a scan (`handleDiscovery`, and the mic-in-use tier through `handleMeetingStarted`) return at
///   their `isAcceptingPrompts` guard, so a scan there is AX walks for log lines. A request is
///   refused, and a pending follow-up is dropped rather than carried: the return to `.idle`
///   requests a fresh scan through `refreshNow()`, so nothing is lost by dropping it.
///
/// Threading: main queue only, like `DiscoveryScanCadence`. The watcher consults it on main before
/// dispatching to `scanQueue`, and the scan's existing main hop calls `complete`, so the two flags
/// need no lock.
struct DiscoveryScanGate {

    private(set) var scanInFlight = false
    private(set) var scanPending = false

    /// A coalesced scan request. Returns true when the caller should dispatch a scan now, in which
    /// case the gate counts it as in flight until `complete`.
    mutating func request(acceptingPrompts: Bool) -> Bool {
        guard acceptingPrompts else { return false }
        if scanInFlight {
            scanPending = true
            return false
        }
        scanInFlight = true
        return true
    }

    /// The in-flight scan's main hop finished. Returns true when exactly one follow-up scan should be
    /// dispatched now (a request arrived while it ran and the session still accepts prompts), in
    /// which case that follow-up is the new in-flight scan.
    mutating func complete(acceptingPrompts: Bool) -> Bool {
        let follow = scanPending && acceptingPrompts
        scanPending = false
        scanInFlight = follow
        return follow
    }
}
