import AppKit
import UserNotifications

/// UX82 item 2: what a tripped `CrashLoopBreaker` starts instead of the app. A status item and a
/// three-row menu, and nothing else: no `Coordinator`, so no detection, no recorder, no preloader
/// and no pipeline, which are where a start-time crash would come from. Staying up is the point,
/// since launchd does not respawn a job that is running.
@MainActor
final class SafeModeController: NSObject {
    /// The copy, in one place so the test and the menu read the same strings.
    enum Copy {
        static let header = "MeetingPipe stopped after crashing repeatedly"
        static let tryNormalStart = "Try a Normal Start"
        static let openLogs = "Open Logs Folder"
        static let quit = "Quit MeetingPipe"
        static let notificationTitle = "MeetingPipe stopped after crashing repeatedly"
        static let notificationBody = "It crashed several times within a minute of starting, so it is waiting in the menu bar instead of restarting again. Pick Try a Normal Start from its menu when you are ready, or open the logs folder to see why."
    }

    private let statusItem: NSStatusItem
    private let logsDir: URL
    private let launchCount: Int

    init(launchCount: Int, logsDir: URL = Log.logsDir) {
        self.launchCount = launchCount
        self.logsDir = logsDir
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    func start() {
        Log.writeLine("daemon", "crash loop: \(launchCount) unclean launches inside \(Int(CrashLoopBreaker.window)) s - started in safe mode")
        Log.event(category: "daemon", action: "crash_loop_tripped", attributes: [
            "launch_count": launchCount,
            "window_sec": Int(CrashLoopBreaker.window),
        ])
        statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: Copy.header)
        statusItem.menu = makeMenu()
        postNotification()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: Copy.header, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(row(Copy.tryNormalStart, #selector(tryNormalStart)))
        menu.addItem(row(Copy.openLogs, #selector(openLogs)))
        menu.addItem(.separator())
        menu.addItem(row(Copy.quit, #selector(quit), key: "q"))
        return menu
    }

    private func row(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// Forget the crash history and ask the agent for a requested relaunch, which the next launch
    /// reads as clean, so it starts normally (and counts again only if it crashes again).
    @objc func tryNormalStart() {
        CrashLoopBreaker.reset(logsDir: logsDir)
        AppDelegate.pendingRelaunchOverride = true
        NSApp.terminate(nil)
    }

    @objc func openLogs() {
        NSWorkspace.shared.open(logsDir)
    }

    @objc func quit() {
        AppDelegate.pendingRelaunchOverride = false
        NSApp.terminate(nil)
    }

    private func postNotification() {
        let content = UNMutableNotificationContent()
        content.title = Copy.notificationTitle
        content.body = Copy.notificationBody
        let request = UNNotificationRequest(identifier: "crash-loop-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.failure(category: "daemon", action: "crash_loop_notice_failed", error: error)
            }
        }
    }
}
