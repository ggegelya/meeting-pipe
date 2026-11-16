import AppKit
import Foundation
import MeetingPipeCore

/// END16: tells `CallTeardownWatcher` whether Teams is running, so its tail polls at 1 Hz only
/// while a Teams call is possible and every `CallTeardownWatcher.idlePollInterval` otherwise.
///
/// Teams' running state rather than its log folder, because the Group Container outlives the app
/// (130 entries and no SlimCore generation on a Mac without Teams, 2026-10-25), and rather than a
/// lazy start on the first consult, because END10 needs the tail warm before that consult. The
/// watcher defaults to "running", so if this observer were dropped the oracle would keep today's
/// 1 Hz instead of going slow; `SessionWatchers` holds it so dropping it is a compile error.
final class TeamsRunningObserver: Startable {

    private let bundleIDs: Set<String>
    private let center: NotificationCenter
    private let runningBundleIDs: () -> [String?]
    private let onChange: (Bool) -> Void
    private var observers: [NSObjectProtocol] = []
    private var lastReported: Bool?

    init(
        bundleIDs: Set<String> = NativeLifecycleConfig.teams.bundleIDs,
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        runningBundleIDs: @escaping () -> [String?] = { NSWorkspace.shared.runningApplications.map(\.bundleIdentifier) },
        onChange: @escaping (Bool) -> Void
    ) {
        self.bundleIDs = bundleIDs
        self.center = center
        self.runningBundleIDs = runningBundleIDs
        self.onChange = onChange
    }

    /// Registers for launches and quits BEFORE the first read, so a launch landing between the two
    /// is not lost. Each delivery re-reads the running set rather than trusting the payload.
    func start() {
        guard observers.isEmpty else { return }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(addMainQueueObserver(on: center, forName: name, object: nil) { [weak self] in
                self?.refresh()
            })
        }
        refresh()
    }

    func refresh() {
        let running = runningBundleIDs().contains { $0.map(bundleIDs.contains) ?? false }
        guard running != lastReported else { return }
        lastReported = running
        onChange(running)
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }
}
