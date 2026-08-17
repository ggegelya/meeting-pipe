import AppKit
import ApplicationServices
import Combine

@main
final class App {
    static func main() {
        let args = CommandLine.arguments
        // The long-lived daemon (not the one-shot CLI subcommands) refuses to be a second copy (UX54)
        // and migrates a legacy plaintext secrets.env into the Keychain once (SEC8), before seeding the
        // process env from it. `doctor` and `prefetch-models` are diagnostics that must keep running
        // alongside a live daemon, so both only apply here.
        let isDaemon = !(args.count > 1 && (args[1] == "doctor" || args[1] == "prefetch-models"))
        if isDaemon {
            // First, ahead of everything this process could otherwise do twice: a second daemon means
            // two detectors, two recorders that can answer the same meeting, and a second process
            // outside PIPE11's job lane. A rejected instance exits inside this call, so it never
            // reaches the Keychain migration below, let alone the status item or any subsystem.
            SingleInstanceGuard.standDownIfPeerIsRunning()
            SecretsStore.migrateEnvFileIfPresent()
        }
        Secrets.loadIfPresent()
        // CLI subcommands intercept before NSApplication boots so the menu-bar path stays separate from one-shot diagnostic runs.
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
    private var localModelCancellable: AnyCancellable?
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

    /// AUTO1: handle a `meetingpipe://` deeplink (a Shortcuts "Open URL" action,
    /// Raycast, Stream Deck, or `open meetingpipe://...`). Launch Services delivers
    /// it here on the already-running instance once the scheme is registered in the
    /// bundle Info.plist, so no App Intents metadata is needed. Parsed off the URL
    /// and routed to the live coordinator, which applies the hotkey's own gates.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = AutomationCommand.parse(url) else {
                Log.event(category: "automation", action: "url_unrecognized",
                          attributes: ["url": url.absoluteString])
                continue
            }
            coordinator?.handleAutomation(command)
        }
    }

    /// UX48: the main menu's Preferences item dispatches with a nil target so AppKit walks the
    /// responder chain, and `NSApp`'s delegate is on that chain where `Coordinator` is not. Keeps
    /// `MainMenu` from having to be handed a coordinator it would then have to hold weakly.
    @objc func openPreferencesFromMainMenu(_ sender: Any?) {
        coordinator?.menuPreferences()
    }

    /// UX48 follow-up, owner-approved 2026-08-04. Same seam and the same reason as Preferences
    /// above: a nil-target menu item walks the responder chain to `NSApp`'s delegate.
    ///
    /// This exists because the status-bar menu's own Cmd+K is only matched while that menu is
    /// **open**, and `NSApp.mainMenu.performKeyEquivalent` cannot see an `NSStatusItem`'s menu, so
    /// before this row Cmd+K did nothing from a MeetingPipe window. Two owners for one chord is
    /// deliberate and safe: they are matched by different mechanisms and never both while one menu
    /// is open. The rejected alternative was a Carbon global hotkey, which would have taken Cmd+K
    /// from every app on the machine.
    @objc func openQuickFindFromMainMenu(_ sender: Any?) {
        coordinator?.menuQuickFind()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.main.info("MeetingPipe starting")

        // Tighten any pre-existing 0644 log files to 0600 once at startup (SEC11);
        // new files are already created 0600. The logs carry verbatim meeting titles.
        Log.tightenLogPermissions()

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
            setenv("OPENAI_API_KEY", s.openaiAPIKey, 1)
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
                localModel: store.summarizationLocalModel,
                adapterPath: store.summarizationLocalAdapterPath
            )
            // LOCAL11: the warm server pins one model + adapter for the daemon's
            // lifetime, so without this a Preferences change to either left the old
            // weights answering every summary until the app was quit. `mp` refuses
            // to kill a server it did not spawn (rightly - it would race this
            // supervisor), which makes restarting it our job. `didPersist` is
            // already debounced 500 ms and `refresh` no-ops on an unrelated save.
            localModelCancellable = store.didPersist
                .receive(on: DispatchQueue.main)
                .sink { [weak store, weak localModelPreloader] in
                    guard let store, let localModelPreloader else { return }
                    localModelPreloader.refresh(
                        enabled: UISettings.shared.preloadLocalModelAtLaunch,
                        backend: store.summarizationBackend,
                        localModel: store.summarizationLocalModel,
                        adapterPath: store.summarizationLocalAdapterPath
                    )
                }
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

    /// REC13(3): how long the whole termination path gets before the process exits
    /// regardless. Above the sum of the budgets a healthy teardown can spend (two 3 s
    /// writer drains plus a 1.5 s bounded engine teardown) and below the ~10 s that
    /// launchd and `rebuild.sh` give the daemon before they escalate to SIGKILL, so a
    /// real quit always beats it and a wedged one never outlives it. The window is
    /// genuinely narrow; `AppDelegateRelaunchTests` fences both ends, because neither
    /// constant can see the other from its own file.
    static let terminationCeilingSeconds: TimeInterval = 9
    /// Whether the ceiling that fires below actually exits. Tests set it false to
    /// pin the arming and the log line without killing the test runner.
    static var terminationCeilingExits = true

    /// Single synchronous teardown path for SIGTERM and a normal quit: stop the
    /// preloader, flush the recorder (so no in-flight recording is stranded,
    /// REC2 / AUD-6), then exit with the exit code the LaunchAgent keys off
    /// (TECH-UX7): non-zero asks launchd to relaunch, zero quits fully.
    ///
    /// REC13: a hard ceiling is armed first, because on 2026-08-14 this path did not
    /// come back. SIGTERM stopped the capture, the process was still alive ten seconds
    /// later, and `kill -9` was the only way out. `MeetingRecorder.flushIntermediatesForTermination`
    /// never ran at all: its first statement is an unbuffered `Log.writeLine` and that
    /// line is absent for the whole day, so something upstream of it here blocked the
    /// main thread. Which call is NOT established (the live `sample` predates the
    /// SIGTERM), and that is the point of putting the ceiling here rather than inside
    /// the flush: bounding the flush's own internals, which REC13 also does, would not
    /// have saved that recording, because the flush never started.
    private func flushAndExit() -> Never {
        armTerminationCeiling()
        localModelPreloader.stop()
        coordinator?.shutdown()
        let relaunch = AppDelegate.shouldRelaunchOnQuit(
            override: AppDelegate.pendingRelaunchOverride,
            disableAutoRestart: UISettings.shared.disableAutoRestart
        )
        exit(relaunch ? EXIT_FAILURE : EXIT_SUCCESS)
    }

    /// Arm the termination ceiling on a global queue, so it fires whatever the main
    /// thread is doing. The exit code is resolved here, before `shutdown()` runs,
    /// for two reasons: nothing in `shutdown()` touches `pendingRelaunchOverride` or
    /// `disableAutoRestart`, so it is the same answer either way, and reading
    /// main-owned settings from the timer's thread after main has wedged is exactly
    /// the kind of call that would make the backstop need a backstop.
    ///
    /// Exiting mid-flush loses only whatever the writers had not drained yet. The
    /// capture intermediates are append-only and already on disk, and the
    /// `.recovery.json` manifest is written at start, so the next launch's orphan
    /// sweep merges and publishes what landed. That is strictly more than the
    /// `kill -9` this replaces, which is what actually happened on 2026-08-14.
    private func armTerminationCeiling() {
        let relaunch = AppDelegate.shouldRelaunchOnQuit(
            override: AppDelegate.pendingRelaunchOverride,
            disableAutoRestart: UISettings.shared.disableAutoRestart
        )
        let ceiling = AppDelegate.terminationCeilingSeconds
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + ceiling) {
            Log.writeLine("daemon", "WARN: termination did not finish within \(Int(ceiling))s - forcing exit; the orphan sweep recovers any in-flight recording on the next launch")
            Log.event(category: "daemon", action: "termination_ceiling_exceeded", attributes: [
                "ceiling_s": ceiling,
                "relaunch": relaunch,
            ])
            guard AppDelegate.terminationCeilingExits else { return }
            exit(relaunch ? EXIT_FAILURE : EXIT_SUCCESS)
        }
    }
}
