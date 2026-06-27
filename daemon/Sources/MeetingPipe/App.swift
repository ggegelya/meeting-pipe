import AppKit
import ApplicationServices
import Combine

@main
final class App {
    static func main() {
        Secrets.loadIfPresent()
        // CLI subcommands intercept before NSApplication boots so the menu-bar path stays separate from one-shot diagnostic runs.
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
    private let localModelPreloader = LocalModelPreloader()

    /// Dispatch source for SIGTERM. Held so it stays armed for the process
    /// lifetime (REC2 / AUD-6).
    private var sigtermSource: DispatchSourceSignal?

    /// One-shot relaunch override for the next quit (TECH-UX7). `nil` defers to
    /// the `disableAutoRestart` preference; `false` forces a no-relaunch quit
    /// (the "Quit (do not relaunch)" menu item). Reset implicitly by process exit.
    static var pendingRelaunchOverride: Bool? = nil

    /// Whether quitting should ask the LaunchAgent to relaunch us (TECH-UX7).
    /// Pure so it is unit-testable; the override wins, else the preference
    /// (default = relaunch). The LaunchAgent uses `KeepAlive = { SuccessfulExit
    /// = false }`, so a non-zero exit relaunches and exit 0 quits fully.
    static func shouldRelaunchOnQuit(override: Bool?, disableAutoRestart: Bool) -> Bool {
        override ?? !disableAutoRestart
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.main.info("MeetingPipe starting")

        // Ceiling on every synchronous Accessibility IPC this process makes. The
        // detection signals read the meeting app's AX tree with blocking
        // `AXUIElementCopyAttributeValue` calls (the Leave-button health poll
        // re-walks the whole Teams tree on the main thread); a busy or
        // unresponsive Teams could otherwise stall a single call long enough to
        // wedge the main run loop, so Record/Quit stopped responding. A
        // system-wide timeout bounds each call to 2 s for all elements, so the
        // run loop always recovers. Set once, before any signal arms.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2.0)

        // Tag a rebuild-triggered launch before any other event, so dogfood analysis can exclude the TCC re-grant churn that follows each `--reset-tcc` cycle.
        RebuildTagger.runOnce()

        // Apply theme before any window is created so the first paint matches the user's choice. Library, Preferences, HUD, and prompt panel all read NSApp.effectiveAppearance.
        UISettings.shared.applyTheme()

        // Export MP_VERBOSE=1 so pipeline subprocesses inherit it without a separate argv flag. Toggling requires a daemon restart to update the env for future spawns.
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
            Log.main.warning("No config at \(Config.defaultPath.path) - using defaults: \(String(describing: error))")
            config = Config.defaultFallback()
        }

        // ConfigStore powers the Preferences UI. Failure is non-fatal; the daemon runs with the in-memory config.
        let store: ConfigStore?
        do {
            store = try ConfigStore()
        } catch {
            Log.main.warning("ConfigStore disabled: \(String(describing: error))")
            store = nil
        }
        self.configStore = store

        // SecretsStore is unfailing: a missing secrets.env is normal on first run; the file is created (mode 0600) on the first Preferences save.
        let secrets = SecretsStore()
        self.secretsStore = secrets

        // Mirror secrets into process env on each Preferences save so future spawns pick them up immediately. PipelineLauncher.freshEnvironment also re-reads at spawn time; the env mirror keeps the contract explicit.
        self.secretsCancellable = secrets.didPersist.sink { [weak secrets] in
            guard let s = secrets else { return }
            setenv("ANTHROPIC_API_KEY", s.anthropicAPIKey, 1)
            setenv("NOTION_TOKEN", s.notionToken, 1)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusBar = StatusBarController(item: statusItem)

        // Wire coordinator into the status bar BEFORE setIdle(): NSMenu auto-disables items with a nil target (Cocoa menu validation), which would leave Start Recording / Open greyed out until the next state change.
        coordinator = Coordinator(
            config: config,
            statusBar: statusBar,
            configStore: store,
            secretsStore: secrets
        )
        statusBar.coordinator = coordinator
        statusBar.setIdle()
        coordinator.start()  // requests notification authorization via Notifier

        // TECH-UX1: on a fresh install, show the framed onboarding flow (which
        // requests each TCC one at a time) instead of letting the startup
        // prewarm fire an unframed Screen Recording dialog. Once onboarding has
        // been completed, prewarm as before so recording start never re-prompts.
        if OnboardingGate.isCompleted {
            Task.detached {
                await SystemAudioCapture.prewarm()
            }
        } else {
            coordinator.presentOnboardingIfNeeded()
        }

        // Optional local-model warm (TECH-A15), default off. Reads the backend / model from the Preferences round-trip store (the daemon's read-only Config snapshot doesn't model pipeline-side summarization fields). No-op unless the user opted in and the local model is already cached.
        if let store = store {
            localModelPreloader.start(
                enabled: UISettings.shared.preloadLocalModelAtLaunch,
                backend: store.summarizationBackend,
                localModel: store.summarizationLocalModel
            )
        }

        installTerminationSignalHandler()
    }

    /// launchd and `kill` send SIGTERM, whose default disposition terminates the
    /// process WITHOUT running `applicationWillTerminate`, so an in-flight
    /// recording's intermediates were never flushed (REC2 / AUD-6). Ignore the
    /// default action and handle SIGTERM on a main-queue dispatch source so the
    /// recorder is flushed synchronously before we exit with the LaunchAgent-keyed
    /// status the quit path uses.
    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            Log.main.info("SIGTERM received - flushing recorder before exit")
            self?.flushAndExit()
        }
        source.resume()
        sigtermSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        flushAndExit()
    }

    /// Single synchronous teardown path for SIGTERM and a normal quit: stop the
    /// preloader, flush the recorder (so no in-flight recording is stranded,
    /// REC2 / AUD-6), then exit with the exit code the LaunchAgent keys off
    /// (TECH-UX7): non-zero asks launchd to relaunch, zero quits fully.
    private func flushAndExit() -> Never {
        localModelPreloader.stop()
        coordinator?.shutdown()
        let relaunch = AppDelegate.shouldRelaunchOnQuit(
            override: AppDelegate.pendingRelaunchOverride,
            disableAutoRestart: UISettings.shared.disableAutoRestart
        )
        exit(relaunch ? EXIT_FAILURE : EXIT_SUCCESS)
    }
}
