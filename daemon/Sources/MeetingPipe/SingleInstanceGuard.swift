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

        init(_ app: NSRunningApplication) {
            self.init(
                pid: app.processIdentifier,
                launchDate: app.launchDate,
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

    /// Pure. `peers` is every running copy carrying this bundle identifier, this process
    /// included; `current` is this process.
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
    /// line below is the whole of what it writes.
    static func standDownIfPeerIsRunning() {
        // No bundle identifier means a bare SPM binary rather than the installed .app. Launch
        // Services does not list such a process either, so it can neither see peers nor be seen
        // as one: fail open rather than guess. A guard that cannot identify itself must not be
        // the thing that kills a daemon.
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let current = Peer(NSRunningApplication.current)
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(Peer.init)
        guard case .standDown(let peerPID) = decide(current: current, peers: peers) else { return }

        Log.main.info("Another MeetingPipe is already running (pid \(peerPID)); standing down")
        Log.event(
            category: "main",
            action: "second_instance_stood_down",
            attributes: ["peer_pid": Int(peerPID), "self_pid": Int(current.pid)]
        )
        // Answer the launch the user just made rather than vanishing silently. An accessory app
        // has no window to raise, so this only makes the incumbent frontmost, and a refusal
        // (cooperative activation can decline) must not hold up the exit.
        _ = NSRunningApplication(processIdentifier: peerPID)?.activate(options: [])
        exit(standDownExitStatus)
    }
}
