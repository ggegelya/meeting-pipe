import AppKit
import Foundation
import MeetingPipeCore

/// END22: tells the session layer the Mac woke, the screens woke, the session was unlocked or the
/// display configuration changed. Before it, only `MeetingRecorder` heard a wake (REC8), so the
/// engine's dwells ran across a sleep on the wall clock and a hold confirmed on the first tick after
/// waking, before any signal had re-read.
///
/// The lifecycle coordinator measures the sleep itself from the gap between its wall clock and
/// `systemUptime` (its first tick after a wake can beat this notification to its queue), so what
/// this adds is the reason, the screen-wake and unlock cases with no system sleep behind them, the
/// display change, and the idle backstop's reset. Unlock is the distributed
/// `com.apple.screenIsUnlocked`: `NSWorkspace.sessionDidBecomeActiveNotification` is fast user
/// switching, not the lock screen.
final class SleepWakeObserver: Startable {

    enum Wake: String {
        case system = "system_wake"
        case screens = "screens_wake"
        case unlock = "unlock"
    }

    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    private let workspaceCenter: NotificationCenter
    private let defaultCenter: NotificationCenter
    private let distributedCenter: NotificationCenter
    private let onWake: (Wake) -> Void
    private let onDisplayChange: () -> Void
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        defaultCenter: NotificationCenter = .default,
        distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
        onWake: @escaping (Wake) -> Void,
        onDisplayChange: @escaping () -> Void
    ) {
        self.workspaceCenter = workspaceCenter
        self.defaultCenter = defaultCenter
        self.distributedCenter = distributedCenter
        self.onWake = onWake
        self.onDisplayChange = onDisplayChange
    }

    func start() {
        guard observers.isEmpty else { return }
        observe(workspaceCenter, NSWorkspace.didWakeNotification) { [weak self] in self?.onWake(.system) }
        observe(workspaceCenter, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.onWake(.screens) }
        observe(distributedCenter, Self.screenUnlocked) { [weak self] in self?.onWake(.unlock) }
        observe(defaultCenter, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.onDisplayChange()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @Sendable () -> Void) {
        observers.append((center, addMainQueueObserver(on: center, forName: name, object: nil, handler: handler)))
    }

    deinit {
        for (center, observer) in observers { center.removeObserver(observer) }
    }
}
