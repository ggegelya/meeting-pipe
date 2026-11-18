import AppKit
import ApplicationServices
import Combine
import os

@main
final class App {
    static func main() {
        let args = CommandLine.arguments
        // The long-lived daemon (not the one-shot CLI subcommands) refuses to be a second copy (UX54)
        // and migrates a legacy plaintext secrets.env into the Keychain once (SEC8). `doctor` and `prefetch-models` are diagnostics that must keep running
        // alongside a live daemon, so both only apply here.
        let isDaemon = !(args.count > 1 && (args[1] == "doctor" || args[1] == "prefetch-models"))
        if isDaemon {
            // First, ahead of everything this process could otherwise do twice: a second daemon means
            // two detectors, two recorders that can answer the same meeting, and a second process
            // outside PIPE11's job lane. A rejected instance exits inside this call, so it never
            // reaches the Keychain migration below, let alone the status item or any subsystem.
            SingleInstanceGuard.standDownIfPeerIsRunning()
            // OBS5: what the previous process left, settled before anything here can crash, so
            // a launch that dies before AppKit is up still reads as unclean to the next one.
            let previous = LaunchRecord.begin()
            // UX82 item 2: count a launch that followed a crash; past the threshold, start in the
            // safe idle mode below instead of the app, so launchd stops respawning a crash.
            let breaker = CrashLoopBreaker.evaluate(logsDir: Log.logsDir, previousExit: previous.exit)
            if breaker.tripped { AppDelegate.safeModeLaunchCount = breaker.count }
            SecretsStore.migrateEnvFileIfPresent()
        }
        Secrets.seedModelDownloadToken()
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
    private var mainThreadStallWatchdog: MainThreadStallWatchdog?
    private var configStore: ConfigStore?
    private var secretsStore: SecretsStore?
    private var localModelCancellable: AnyCancellable?
    private let localModelPreloader = LocalModelPreloader()

    /// Dispatch source for SIGTERM. Held so it stays armed for the process
    /// lifetime (REC2 / AUD-6).
    private var sigtermSource: DispatchSourceSignal?

    /// One-shot relaunch override for the next quit (TECH-UX7). `nil` defers to the
    /// relaunch-after-quit preference; `false` forces a no-relaunch quit ("Quit (do not
    /// relaunch)"), `true` a requested relaunch ("Restart MeetingPipe", onboarding's Relaunch,
    /// safe mode's normal start). Lock-backed since UX82 (F165): the SIGTERM queue and the
    /// termination ceiling read it off main.
    static var pendingRelaunchOverride: Bool? {
        get { relaunchOverride.withLock { $0 } }
        set { relaunchOverride.withLock { $0 = newValue } }
    }
    private static let relaunchOverride = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    /// Whether quitting should ask the LaunchAgent to relaunch us (TECH-UX7). Pure so it is
    /// unit-testable; the override wins, else the preference, which is off by default since
    /// UX82 (the owner's "Quit means quit", 2026-11-18).
    static func shouldRelaunchOnQuit(override: Bool?, relaunchAfterQuit: Bool) -> Bool {
        override ?? relaunchAfterQuit
    }

    /// UX82 item 1: the exit status of a requested relaunch. The agent's `KeepAlive =
    /// { SuccessfulExit = false }` answers any non-zero exit, so this one is chosen to say
    /// "asked for" (sysexits' `EX_TEMPFAIL`): a crash dies by a signal and an `exit(1)` is a
    /// failure, and neither is this. Beside `SingleInstanceGuard.standDownExitStatus`, which
    /// must stay 0 for the same agent.
    static let relaunchExitStatus: Int32 = 75

    /// The status a quit exits with: 0 when it means quit, `relaunchExitStatus` when it asks
    /// the agent for a relaunch.
    static func exitStatus(relaunch: Bool) -> Int32 {
        relaunch ? relaunchExitStatus : EXIT_SUCCESS
    }

    /// The relaunch decision from any thread: the lock-backed override and the stored preference,
    /// never `UISettings.shared` (main-owned), so the SIGTERM queue and a ceiling firing behind a
    /// wedged main can both resolve it (UX82 F165).
    static func resolvedRelaunch() -> Bool {
        shouldRelaunchOnQuit(override: pendingRelaunchOverride, relaunchAfterQuit: UISettings.storedRelaunchAfterQuit())
    }

    /// UX82 item 2: set by `App.main` when the crash-loop breaker tripped; this launch then starts
    /// `SafeModeController` instead of the app. Written once before `NSApplication` runs.
    static var safeModeLaunchCount: Int? {
        get { safeModeCount.withLock { $0 } }
        set { safeModeCount.withLock { $0 = newValue } }
    }
    private static let safeModeCount = OSAllocatedUnfairLock<Int?>(initialState: nil)
    private var safeMode: SafeModeController?

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
        // REC12: first, so no later startup work can raise past it. An uncaught ObjC
        // exception aborts this process, and a crash report does not carry the exception's
        // `reason`, which is the one string that says which precondition failed. Four
        // aborts were reconstructed without it; the fifth will not have to be.
        UncaughtExceptionLogger.install()
        _ = AppDelegate.launchUptime  // OBS5: pin the launch instant for `terminating`'s uptime

        Log.main.info("MeetingPipe starting")

        // Tighten any pre-existing 0644 log files to 0600 once at startup (SEC11);
        // new files are already created 0600. The logs carry verbatim meeting titles.
        Log.tightenLogPermissions()
        // OBS9: launchd writes these from the agent plist and nothing else bounds them. They were
        // opened before this process started, so this run keeps writing to the renamed generation
        // and the next spawn gets a fresh base; a check per launch is enough for files that grow
        // only on a crash or a stray stderr write.
        for name in Log.launchdOwnedLogs {
            Log.rotateIfNeeded(Log.logsDir.appendingPathComponent(name))
        }

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
        // OBS5: the launch row, right after the rebuild tag, with what the previous process left.
        LaunchRecord.recordLaunch()

        // UX82 item 2: a tripped crash-loop breaker starts the safe idle mode and nothing else,
        // so none of the subsystems a start-time crash would come from runs. Quit still goes
        // through `flushAndExit` (no coordinator, so it only writes the row and the marker).
        if let count = AppDelegate.safeModeLaunchCount {
            let safe = SafeModeController(launchCount: count)
            safe.start()
            safeMode = safe
            installTerminationSignalHandler()
            return
        }

        // Apply theme before any window is created so the first paint matches the user's choice. Library, Preferences, HUD, and prompt panel all read NSApp.effectiveAppearance.
        UISettings.shared.applyTheme()

        // Export MP_VERBOSE=1 so pipeline subprocesses inherit it without a separate argv flag. Toggling requires a daemon restart to update the env for future spawns.
        if UISettings.shared.verboseLogging {
            Log.main.info("verbose logging: ON")
            setenv("MP_VERBOSE", "1", 1)
        } else {
            Log.main.debug("verbose logging: off")
        }

        // ConfigStore is the one reader of config.toml (ARCH9): it powers Preferences and produces the daemon's launch-time Config. A file that does not parse fails closed (regulated, no saves) instead of being replaced by defaults on the next Preferences edit.
        let store = ConfigStore()
        if let parseError = store.parseError {
            Log.failure(category: "daemon", action: "config_unreadable", reason: "config.toml cannot be read (a syntax error runs on defaults, a PIPE42 regulated-switch problem on the file's values), with regulated mode on and saves refused: \(parseError.message)")
        } else {
            Log.main.info("Loaded config from \(Config.defaultPath.path)")
        }
        // STOR6 item 2: before the launch-time Config is taken, so a library at the old default
        // that the file never named stays where it is rather than appearing to vanish.
        store.pinLegacyDefaults()
        let config = store.config
        self.configStore = store
        // UX96: a hand edit while the app runs reaches the in-memory readers (the
        // regulated glyph, the recording's meta) instead of waiting for a relaunch.
        store.startWatching()
        // UX97: an older install's "Always for <app>" picks lived in auto_consent.json, a list
        // Preferences never showed. Move them onto the allowlist once; here and nowhere else,
        // because tests build Coordinators and this rewrites the real config.
        LegacyConsentMigration.run(into: store)

        // SecretsStore is unfailing: it reads the tokens from the Keychain (a missing item is normal on first run) and writes only the accounts a Preferences edit changed. The tokens are not put into the process environment (SEC23): `PipelineLauncher.runMP` and `NotionDatabaseList` read them from `SecretsStore.live`.
        let secrets = SecretsStore()
        self.secretsStore = secrets
        SecretsStore.live = secrets

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusBar = StatusBarController(item: statusItem)

        // Wire coordinator into the status bar BEFORE setIdle(): NSMenu auto-disables items with a nil target (Cocoa menu validation), which would leave Start Recording / Open greyed out in a menu populated without one (since PERF24 the menu is populated on open, and the status bar also resolves the recordings directory through this reference).
        coordinator = Coordinator(
            config: config,
            statusBar: statusBar,
            configStore: store,
            secretsStore: secrets
        )
        statusBar.coordinator = coordinator
        statusBar.setIdle()
        coordinator.start()  // requests notification authorization via Notifier

        // PERF11: on from launch, so a main-thread stall is a `perf` / `main_thread_stall` row instead of a mistimed live `sample`. The context closure runs on main.
        let stallWatchdog = MainThreadStallWatchdog(context: { [weak self] in
            [
                "recording": self?.coordinator?.recorder.isRecording ?? false,
                "key_window": NSApp.keyWindow?.identifier?.rawValue ?? NSApp.keyWindow?.title ?? NSNull(),
            ]
        })
        stallWatchdog.start()
        self.mainThreadStallWatchdog = stallWatchdog

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

        installTerminationSignalHandler()
    }

    /// launchd and `kill` send SIGTERM, whose default disposition terminates the
    /// process WITHOUT running `applicationWillTerminate`, so an in-flight
    /// recording's intermediates were never flushed (REC2 / AUD-6). Ignore the
    /// default action and handle the signal ourselves so the recorder is flushed
    /// before we exit with the status the quit path uses.
    ///
    /// UX82 F165: the source runs on its own serial queue, not main, and arms REC13's ceiling
    /// there before handing the flush to main. On main, a main thread already wedged when the
    /// signal arrived never ran the handler, so the ceiling was never armed and the default
    /// disposition was gone: a hand `kill` did nothing, and launchd's SIGKILL came with no flush
    /// and no row.
    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: AppDelegate.terminationSignalQueue)
        source.setEventHandler {
            AppDelegate.armTerminationCeiling()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Log.main.info("SIGTERM received - flushing recorder before exit")
                    (NSApp.delegate as? AppDelegate)?.flushAndExit(reason: .sigterm)
                }
            }
        }
        source.resume()
        sigtermSource = source
    }

    /// UX82 F165: the queue the SIGTERM source runs on, never main.
    static let terminationSignalQueue = DispatchQueue(label: "com.meetingpipe.sigterm", qos: .userInitiated)

    func applicationWillTerminate(_ notification: Notification) {
        flushAndExit(reason: .quit)
    }

    /// OBS5: why this process is exiting, on the `daemon` / `terminating` row.
    enum TerminationReason: String {
        case quit, sigterm
    }

    /// When this process started, on the monotonic clock, for `terminating`'s `uptime_sec`.
    /// Read once in `applicationDidFinishLaunching` so it is not first touched at quit.
    static let launchUptime = ProcessInfo.processInfo.systemUptime

    /// OBS5: the row a clean exit leaves, written before anything in the teardown can block. A
    /// launch with no `terminating` row before it is a crash or a kill, readable from the log
    /// alone; the relaunch on 2026-10-18 was visible only in loginwindow's system log, because
    /// the two lines this path wrote went to os.Logger, which macOS does not persist.
    static func recordTermination(
        reason: TerminationReason, relaunch: Bool, uptimeSec: Int, recordingOpen: Bool,
        recordingStem: String? = nil, logsDir: URL = Log.logsDir
    ) {
        // The marker first: the next launch's `previous_exit` and its orphan sweep's `stop_cause`
        // read it (OBS5). A failed write costs those a precise answer, never the exit.
        LaunchRecord.persist(
            LaunchRecord.Termination(
                reason: reason.rawValue, recordingStem: recordingStem, launchID: LaunchRecord.launchID, relaunch: relaunch
            ),
            to: LaunchRecord.terminationURL(in: logsDir)
        )
        Log.writeLine(
            "daemon",
            "terminating (\(reason.rawValue), relaunch=\(relaunch), up \(uptimeSec) s\(recordingOpen ? ", a recording open" : ""))"
        )
        Log.event(category: "daemon", action: "terminating", attributes: [
            "reason": reason.rawValue,
            "relaunch": relaunch,
            "uptime_sec": uptimeSec,
            "recording_open": recordingOpen,
        ])
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
    /// preloader, SIGTERM the supervised `mp` runs (PIPE37, inside
    /// `Coordinator.shutdown`), flush the recorder (so no in-flight recording is
    /// stranded, REC2 / AUD-6), then exit with the exit code the LaunchAgent keys off
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
    private func flushAndExit(reason: TerminationReason) -> Never {
        // REC13: the ceiling first, so nothing after it (the logger's lock included) can hold the
        // exit. Idempotent (UX82 F165): the SIGTERM path armed it already on its own queue.
        AppDelegate.armTerminationCeiling()
        AppDelegate.recordTermination(
            reason: reason,
            relaunch: AppDelegate.resolvedRelaunch(),
            uptimeSec: Int(ProcessInfo.processInfo.systemUptime - AppDelegate.launchUptime),
            recordingOpen: coordinator?.recorder.isRecording ?? false,
            recordingStem: coordinator?.recorder.currentFile?.deletingPathExtension().lastPathComponent
        )
        localModelPreloader.stop()
        coordinator?.shutdown()
        exit(AppDelegate.exitStatus(relaunch: AppDelegate.resolvedRelaunch()))
    }

    /// Arm the termination ceiling on a global queue, so it fires whatever the main
    /// thread is doing. Once per process (UX82 F165): `applicationWillTerminate` and the SIGTERM
    /// source both arm it, and the second arm is a no-op, so two quits schedule one ceiling.
    /// Callable from any thread: the exit status is resolved when it fires, from the
    /// lock-backed override and the stored preference, never from main-owned state, which a
    /// ceiling firing behind a wedged main cannot safely read.
    ///
    /// Exiting mid-flush loses only whatever the writers had not drained yet. The
    /// capture intermediates are append-only and already on disk, and the
    /// `.recovery.json` manifest is written at start, so the next launch's orphan
    /// sweep merges and publishes what landed. That is strictly more than the
    /// `kill -9` this replaces, which is what actually happened on 2026-08-14.
    ///
    /// UX82 item 3: `_exit`, not `exit`. `exit` runs `atexit` handlers and C++ static
    /// destructors on this thread while main may still be inside `shutdown()` and the audio
    /// render threads are live, which can turn a wedged quit into a crash report. Both log lines
    /// before it are synchronous appends, so skipping the handlers loses nothing.
    /// - Returns: whether this call armed it (false when it was already armed).
    @discardableResult
    static func armTerminationCeiling() -> Bool {
        guard ceilingLatch.claim() else { return false }
        let ceiling = terminationCeilingSeconds
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + ceiling) {
            let relaunch = AppDelegate.resolvedRelaunch()
            Log.writeLine("daemon", "WARN: termination did not finish within \(Int(ceiling))s - forcing exit; the orphan sweep recovers any in-flight recording on the next launch")
            Log.event(category: "daemon", action: "termination_ceiling_exceeded", attributes: [
                "ceiling_s": ceiling,
                "relaunch": relaunch,
            ])
            guard AppDelegate.terminationCeilingExits else { return }
            _exit(AppDelegate.exitStatus(relaunch: relaunch))
        }
        return true
    }

    /// The ceiling's arm-once latch. A test claims a fresh `OnceLatch`, never this one: arming the
    /// real ceiling inside the test runner would `_exit` it nine seconds later.
    static let ceilingLatch = OnceLatch()
}

/// UX82 F165: true for the first `claim()` and false for every later one, from any thread.
final class OnceLatch: Sendable {
    private let claimed = OSAllocatedUnfairLock(initialState: false)

    func claim() -> Bool {
        claimed.withLock { taken -> Bool in
            defer { taken = true }
            return !taken
        }
    }
}
