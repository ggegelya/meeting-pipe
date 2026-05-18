import AppKit
import Combine

@main
final class App {
    static func main() {
        Secrets.loadIfPresent()
        // CLI subcommands intercept before NSApplication boots so the
        // menu-bar surface and LaunchAgent path stay separate from
        // one-shot diagnostic invocations.
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "doctor" {
            exit(DoctorCommand.run())
        }
        if args.count > 1, args[1] == "prefetch-models" {
            exit(PrefetchModelsCommand.run())
        }
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
    private var secretsStore: SecretsStore?
    private var secretsCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.main.info("MeetingPipe starting")

        // Tag a launch whose cdhash differs from the previous launch
        // before any other event lands, so dogfood analysis can exclude
        // the re-grant churn that follows each `--reset-tcc` cycle.
        RebuildTagger.runOnce()

        // Apply the user's theme override before any window is created
        // so the first paint already matches their choice (otherwise the
        // Library/Preferences windows briefly flash the system
        // appearance). The recording HUD + prompt panel also read
        // `NSApp.effectiveAppearance`, so this propagates everywhere.
        UISettings.shared.applyTheme()

        // Verbose logging is plumbed at startup: log its state to the
        // unified log so the user can grep for it, and export
        // `MP_VERBOSE=1` so spawned pipeline subprocesses pick it up via
        // env without us threading another argv flag through. Toggling
        // requires a daemon restart to flip the env for new subprocesses.
        if UISettings.shared.verboseLogging {
            Log.main.info("verbose logging: ON")
            setenv("MP_VERBOSE", "1", 1)
        } else {
            Log.main.debug("verbose logging: off")
        }

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

        // SecretsStore is unfailing: a missing secrets.env is a normal
        // first-run state, not an error — the file will be created by
        // the first save from Preferences (with mode 0600).
        let secrets = SecretsStore()
        self.secretsStore = secrets

        // When the user edits secrets via Preferences, mirror the new
        // values into the daemon's process env immediately so any
        // future spawn picks them up. PipelineLauncher.freshEnvironment
        // re-reads the file at spawn time too, but the env mirror is
        // important for fields the daemon reads directly (none today,
        // but the contract is clearer this way).
        self.secretsCancellable = secrets.didPersist.sink { [weak secrets] in
            guard let s = secrets else { return }
            setenv("ANTHROPIC_API_KEY", s.anthropicAPIKey, 1)
            setenv("NOTION_TOKEN", s.notionToken, 1)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusBar = StatusBarController(item: statusItem)

        // Wire the coordinator into the status bar BEFORE setIdle() so the
        // initial menu build sees a non-nil target. NSMenu auto-disables
        // items whose target is nil (Cocoa menu validation), which would
        // otherwise leave Start Recording / Open … greyed out until the
        // next state change rebuilt the menu.
        coordinator = Coordinator(
            config: config,
            statusBar: statusBar,
            configStore: store,
            secretsStore: secrets
        )
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
