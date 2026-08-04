import AppKit

/// UX54: refuses to be a second MeetingPipe.
///
/// Two live daemons is not a cosmetic duplicate menu-bar icon. It is two detectors polling the
/// same AX trees, two recorders that can both answer the same meeting, and a second process
/// outside the one job lane PIPE11 built so that same-stem runs serialize. The owner hit it twice
/// during UX42's walkthrough and there was no guard of any shape, so two copies started by any
/// means both installed a status item, both detected, and both recorded.
///
/// **The newcomer is always the one that loses.** The incumbent may be mid-recording, and losing a
/// meeting is strictly worse than the duplicate icon this fixes. Every copy this process can see
/// has by construction been running at least as long as it has, so ordering by launch date is the
/// same rule stated in a form that survives the one case a bare "is anyone else there?" gets
/// wrong: two copies launching at the same instant would each see the other and both stand down,
/// leaving none. Launch date (kernel-supplied, so both processes read the same value for the same
/// copy) with the lower pid as tie-break is a total order, so exactly one survives either way.
///
/// `decide` is pure so the ordering is drivable from a test. The AppKit half is not testable and
/// is kept to the few lines that cannot be anything else.
///
/// Deliberately **not** a second login-start mechanism (UX42 settled that the LaunchAgent is the
/// single owner of login-start and relaunch-after-quit). This guards against duplicates however
/// they arise, including a Finder or Spotlight open of a build-product bundle carrying the same
/// identifier as the installed one.
///
/// ## Why the first version of this never fired once
///
/// It shipped reading this process's own identity off `NSRunningApplication.current`, and at the
/// point in `App.main()` where the guard has to run that object is a **placeholder**: measured
/// 2026-08-04 in a three-instance probe, it answers `processIdentifier` **-1**, a nil
/// `bundleIdentifier`, a nil `launchDate`, and `isTerminated` **true**. `decide` over a current
/// with pid -1 can never stand down, because `startedBefore(peer, current)` reduces to
/// `peer.pid < -1`, which is false for every real pid, so the incumbent list is empty whoever else
/// is running. The guard was working perfectly on an input that described no process at all, which
/// is why `second_instance_stood_down` was never once emitted while two and three daemons ran.
///
/// The peer *query* was never the broken half, which the same probe settled: at `main()` entry,
/// 3 to 12 ms in and before `NSApplication` exists, `runningApplications(withBundleIdentifier:)`
/// listed 0, then 1, then 2 peers with the right pids as the instances came up. So this process's
/// identity comes from the kernel (`ProcessInfo` for the pid, `sysctl` for the start time), which
/// needs no Launch Services connection, and the guard stays exactly where it was. Moving it later
/// to warm something up is the one fix this task forbids: a rejected instance must not install a
/// status item or start a subsystem first.
enum SingleInstanceGuard {

    /// One running copy as the decision sees it, snapshotted from `NSRunningApplication` so
    /// `decide` never touches AppKit.
    struct Peer: Equatable {
        let pid: pid_t
        /// Process start time. Nil is documented as possible, and falls back to the pid rather
        /// than being treated as "started at the beginning of time".
        let launchDate: Date?
        /// A copy that has already exited is not an incumbent: `NSRunningApplication` can hand
        /// back an object for a process that quit just before the snapshot was taken.
        let isTerminated: Bool

        init(pid: pid_t, launchDate: Date? = nil, isTerminated: Bool = false) {
            self.pid = pid
            self.launchDate = launchDate
            self.isTerminated = isTerminated
        }

        /// A peer as Launch Services describes it. Its `launchDate` is nil for a copy started
        /// directly from `Contents/MacOS/...` rather than through Launch Services, which is
        /// precisely the route the owner reproduced the duplicate on, so the kernel start time
        /// stands in rather than letting the order fall back to a pid comparison: pids wrap at
        /// ~99998 and the real duplicate pair was 87918 and 89520, close enough to that ceiling
        /// that "higher pid means younger" is not a safe read.
        init(_ app: NSRunningApplication) {
            let pid = app.processIdentifier
            self.init(
                pid: pid,
                launchDate: app.launchDate ?? SingleInstanceGuard.kernelStartTime(of: pid),
                isTerminated: app.isTerminated
            )
        }
    }

    enum Outcome: Equatable {
        /// No one else holds the identity: boot normally.
        case start
        /// Someone else got here first. Bring them forward and quit; `peerPID` names the copy
        /// that keeps running, which is the oldest one when several are somehow alive.
        case standDown(peerPID: pid_t)
    }

    /// Pure. `peers` is every running copy carrying this bundle identifier and `current` is this
    /// process, which may or may not be in that list: Launch Services registers a process around
    /// the time `NSApplication` boots, which is *after* the guard runs, so at the real call site
    /// the list holds the other copies and not this one (measured 2026-08-04). Both shapes are
    /// handled, since the same list read a moment later does contain it.
    static func decide(current: Peer, peers: [Peer]) -> Outcome {
        let incumbents = peers.filter {
            $0.pid != current.pid && !$0.isTerminated && startedBefore($0, current)
        }
        guard let oldest = incumbents.min(by: startedBefore) else { return .start }
        return .standDown(peerPID: oldest.pid)
    }

    /// Total order over running copies. Earlier launch date wins; an equal or unknown launch
    /// date falls back to the lower pid. Nothing here reads which process is asking, which is
    /// what makes two copies asking at the same moment reach opposite answers rather than the
    /// same one.
    static func startedBefore(_ a: Peer, _ b: Peer) -> Bool {
        if let x = a.launchDate, let y = b.launchDate, x != y { return x < y }
        return a.pid < b.pid
    }

    /// This process, as `decide` sees it. Read from the kernel rather than from
    /// `NSRunningApplication.current`, which is a placeholder describing pid -1 as terminated
    /// until AppKit is up (see the type comment); the guard has to answer before that, and this
    /// pair of reads needs no framework connection at all.
    static func currentPeer() -> Peer {
        let pid = ProcessInfo.processInfo.processIdentifier
        return Peer(pid: pid, launchDate: kernelStartTime(of: pid), isTerminated: false)
    }

    /// Kernel-supplied process start time, which is the same quantity Launch Services reports as
    /// a peer's `launchDate`. Reading it directly is what lets this process date itself in the
    /// first milliseconds of `main()`, and it keeps the order over a mixed list honest, since a
    /// value invented here would not be the one another copy reads for the same process.
    static func kernelStartTime(of pid: pid_t) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        // A dead or never-existing pid leaves `size` at 0 with rc 0, so both need checking.
        guard rc == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        guard started.tv_sec > 0 else { return nil }
        return Date(
            timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        )
    }

    /// Exit status a stand-down uses. **Must stay 0.** The LaunchAgent runs
    /// `KeepAlive = { SuccessfulExit = false }` (TECH-UX7), so a non-zero exit is this app's
    /// "bring me back" signal; a launchd-started newcomer using one would respawn against a
    /// healthy incumbent every `ThrottleInterval` seconds and never get anywhere.
    static let standDownExitStatus: Int32 = EXIT_SUCCESS

    /// Wired into `App.main()` before `NSApplication` exists, and after the one-shot CLI
    /// subcommands intercept (`doctor` and `prefetch-models` are diagnostics that must keep
    /// running alongside a live daemon). A rejected instance therefore never migrates secrets,
    /// never sets an activation policy, never installs a status item or a main menu, never
    /// constructs the `Coordinator`, and never touches the recorder or launchd. The single event
    /// line below is the whole of what it writes to the event log; the two `Log.main` lines go to
    /// the unified log only, so `mp logs` still sees exactly one row per stand-down.
    static func standDownIfPeerIsRunning() {
        // No bundle identifier means a bare SPM binary rather than the installed .app. Launch
        // Services does not list such a process either, so it can neither see peers nor be seen
        // as one: fail open rather than guess. A guard that cannot identify itself must not be
        // the thing that kills a daemon.
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let current = currentPeer()
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(Peer.init)
        guard case .standDown(let peerPID) = decide(current: current, peers: peers) else {
            // One unified-log line per launch, no event row. A guard whose failure mode is
            // "decided not to act" is silent by construction, and that silence is what made the
            // first version's defect cost a walkthrough plus two probes: nobody could see either
            // the peer count or the identity it compared them against. Both are here now.
            Log.main.info(
                "Single-instance guard: \(peers.count) copy/copies of \(bundleID) visible, starting as pid \(current.pid)"
            )
            return
        }

        Log.main.info("Another MeetingPipe is already running (pid \(peerPID)); standing down")
        Log.event(
            category: "main",
            action: "second_instance_stood_down",
            attributes: [
                "peer_pid": Int(peerPID),
                "self_pid": Int(current.pid),
                "peer_count": peers.count
            ]
        )
        // Answer the launch the user just made rather than vanishing silently. An accessory app
        // has no window to raise, so this only makes the incumbent frontmost, and a refusal
        // (cooperative activation can decline) must not hold up the exit.
        _ = NSRunningApplication(processIdentifier: peerPID)?.activate(options: [])
        exit(standDownExitStatus)
    }
}
