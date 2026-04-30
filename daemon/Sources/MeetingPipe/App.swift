import AppKit

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
    private var configStore: ConfigStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.main.info("MeetingPipe starting")

        let config: Config
        do {
            config = try Config.load()
            Log.main.info("Loaded config from \(Config.defaultPath.path)")
        } catch {
            Log.main.warning("No config at \(Config.defaultPath.path) — using defaults: \(String(describing: error))")
            config = Config.defaultFallback()
        }

        // ConfigStore powers the Preferences UI. Failure to read isn't
        // fatal — the daemon keeps running with the in-memory `config`,
        // and the user just sees a less-friendly menu.
        let store: ConfigStore?
        do {
            store = try ConfigStore()
        } catch {
            Log.main.warning("ConfigStore disabled: \(String(describing: error))")
            store = nil
        }
        self.configStore = store

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusBar = StatusBarController(item: statusItem)

        // Wire the coordinator into the status bar BEFORE setIdle() so the
        // initial menu build sees a non-nil target. NSMenu auto-disables
        // items whose target is nil (Cocoa menu validation), which would
        // otherwise leave Start Recording / Open … greyed out until the
        // next state change rebuilt the menu.
        coordinator = Coordinator(config: config, statusBar: statusBar, configStore: store)
        statusBar.coordinator = coordinator
        statusBar.setIdle()
        coordinator.start()  // requests notification authorization via Notifier

        // Pre-warm the Screen Recording TCC check ONCE at startup, not on
        // every Start Recording click. Without this prewarm, each recording
        // start would call SCShareableContent again, which re-prompts on
        // any binary whose signature TCC hasn't seen before.
        Task.detached {
            await SystemAudioCapture.prewarm()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.shutdown()
    }
}
