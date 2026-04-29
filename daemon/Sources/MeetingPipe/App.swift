import AppKit
import UserNotifications

@main
final class App {
    static func main() {
        Secrets.loadIfPresent()
        let app = NSApplication.shared
        // Accessory: we live in the menu bar with no Dock icon, no main window.
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusBar: StatusBarController!
    private var coordinator: Coordinator!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.main.info("MeetingPipe starting")

        // First thing: undo any audio-routing state left by a previous crashed
        // run. If we crashed mid-recording, the user's system output would
        // still be pointed at our transient device — this restores it before
        // we do anything else.
        AudioRouter.cleanupStale()

        let config: Config
        do {
            config = try Config.load()
            Log.main.info("Loaded config from \(Config.defaultPath.path)")
        } catch {
            Log.main.warning("No config at \(Config.defaultPath.path) — using defaults: \(String(describing: error))")
            config = Config.defaultFallback()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusBar = StatusBarController(item: statusItem)
        statusBar.setIdle()

        coordinator = Coordinator(config: config, statusBar: statusBar)
        statusBar.coordinator = coordinator
        coordinator.start()

        // Best-effort notification authorization. Doesn't block startup if denied.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                Log.main.warning("Notification auth error: \(error.localizedDescription)")
            }
            Log.main.info("Notification auth granted: \(granted)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.shutdown()
    }
}
