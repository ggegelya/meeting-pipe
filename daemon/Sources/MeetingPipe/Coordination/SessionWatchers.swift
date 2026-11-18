import Foundation
import MeetingPipeCore

/// A long-lived watcher `Coordinator.start()` brings up once per process (T7).
protocol Startable: AnyObject {
    func start()
}

extension MeetingDiscoveryWatcher: Startable {}
extension CallTeardownWatcher: Startable {}
extension ConfigRefreshCoordinator: Startable {}
extension MicHolderMonitor: Startable {}

/// The session-lifetime watchers, started together by `Coordinator.start()` (T7).
///
/// END9 shipped a teardown watcher that was constructed and never started, and the only fence
/// END10 could add was a grep over `Coordinator.start()`, because the real `Coordinator` does not
/// stand up headless. This is the seam that makes the wiring testable: the watchers live behind
/// one value, `SessionWatchersTests` builds it from fakes and checks every member starts, and the
/// source fence is down to the one `watchers.startAll()` line.
///
/// `production(...)` takes the concrete types, so dropping a watcher from the set is a compile
/// error rather than a silent omission. The designated init takes `Startable` so tests can pass
/// fakes in the same labelled slots.
final class SessionWatchers {
    let discovery: Startable
    let callTeardown: Startable
    let configRefresh: Startable
    /// END16: feeds the teardown watcher's cadence, so it starts after it (its first report ticks it).
    let teamsRunning: Startable
    /// DET23: the always-on 1 Hz record of which process holds audio input. Depends on none of the
    /// others, so it starts last.
    let micHolder: Startable
    /// END22: wake, unlock and display-change notifications for the session layer.
    let sleepWake: Startable
    /// OBS5: the hourly `main` / `heartbeat` row. Depends on nothing, so it starts last.
    let heartbeat: Startable

    /// In start order. Discovery and call-teardown kept the order they had inline in
    /// `Coordinator.start()`; config refresh used to start after hotkey registration, which none of
    /// the three depends on. The Teams-running observer follows the watcher it drives.
    var members: [Startable] { [discovery, callTeardown, teamsRunning, configRefresh, micHolder, sleepWake, heartbeat] }

    private(set) var hasStarted = false

    init(
        discovery: Startable, callTeardown: Startable, teamsRunning: Startable, configRefresh: Startable,
        micHolder: Startable, sleepWake: Startable, heartbeat: Startable
    ) {
        self.discovery = discovery
        self.callTeardown = callTeardown
        self.teamsRunning = teamsRunning
        self.configRefresh = configRefresh
        self.micHolder = micHolder
        self.sleepWake = sleepWake
        self.heartbeat = heartbeat
    }

    static func production(
        discovery: MeetingDiscoveryWatcher,
        callTeardown: CallTeardownWatcher,
        teamsRunning: TeamsRunningObserver,
        configRefresh: ConfigRefreshCoordinator,
        micHolder: MicHolderMonitor,
        sleepWake: SleepWakeObserver,
        heartbeat: HeartbeatTicker
    ) -> SessionWatchers {
        SessionWatchers(
            discovery: discovery, callTeardown: callTeardown,
            teamsRunning: teamsRunning, configRefresh: configRefresh, micHolder: micHolder,
            sleepWake: sleepWake, heartbeat: heartbeat
        )
    }

    /// Starts every member once. A second call is a no-op: `CallTeardownWatcher.start()` guards
    /// itself the same way, but `MeetingDiscoveryWatcher.start()` would add a second set of
    /// workspace observers and `ConfigRefreshCoordinator.start()` a second persistence sink, so the
    /// guard lives here once for all three.
    func startAll() {
        guard !hasStarted else { return }
        hasStarted = true
        for member in members { member.start() }
    }
}
