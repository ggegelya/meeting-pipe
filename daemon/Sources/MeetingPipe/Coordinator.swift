import AppKit
import AVFoundation
import Combine
import Foundation
import MeetingPipeCore

/// Top-level state owner. Detector and HotkeyManager push events in;
/// Coordinator drives the state machine and tells MeetingRecorder /
/// Notifier what to do.
///
/// Threading: every public method must run on the main queue. Detector
/// and HotkeyManager already dispatch back here.
final class Coordinator: NSObject {
    private let config: Config
    private let configStore: ConfigStore?
    private let statusBar: StatusBarController
    private let recorder: MeetingRecorder
    private let notifier: Notifier
    private let promptWindow: MeetingPromptWindow
    private let recordingHUD: RecordingHUDWindow
    /// Cold-start meeting discovery: scans for a meeting app, engages
    /// the lifecycle adapter, and the `.starting` verdict raises the
    /// prompt (TECH-C13 step 5).
    private let discoveryWatcher = MeetingDiscoveryWatcher()
    private let hotkey: HotkeyManager
    private let consent: ConsentStore
    private let launcher: PipelineDriver
    private let preferencesWindow: PreferencesWindow?
    /// Library window — daemon's primary UI surface for browsing past
    /// recordings. Built lazily-once; `show()` brings it forward on
    /// every "Open Library…" click.
    private let libraryWindow: LibraryWindow
    /// Observable mirror of the recording state machine + processing
    /// queue + model-download progress. The library window subscribes
    /// to this; StatusBarController writes into it from each state setter.
    private let libraryModel: LibraryWindowModel
    /// Recording-side state machine + per-bundle cooldown + prompt
    /// timeout timer. Owns every `AppState` transition; the Coordinator
    /// drives surfaces (status bar, prompt window, HUD) off of it.
    private let stateMachine = DetectionStateMachine()

    /// Pipeline-job queue + streaming transcriber subprocess. The
    /// Coordinator routes start/stop transitions through here; per-job
    /// completion flows back via `onJobCompleted` so the notifier and
    /// status bar stay in one place.
    private let sinkDispatcher: SinkDispatcher

    /// Event-driven MicGate + Lifecycle stack (TECH-G-MIC + TECH-C13).
    /// Replaces the 1 Hz `MuteProbeSubsystem` poll: `MicGate` fuses AX
    /// mute observations, HAL system-input mute, HAL VAD, and per-buffer
    /// RMS into a single verdict stream that the recorder's writer
    /// applies in place. `MeetingLifecycleCoordinator` runs alongside
    /// for the per-meeting AX subscription lifecycle (its `.ended`
    /// verdict-fusion path is wired in a follow-up TECH-C13 step).
    private let halBus: CoreAudioHALBus
    private let axBus: AXObserverBus
    private let muteLabels: MuteLabels
    private let lifecycleCoord: MeetingLifecycleCoordinator
    private let micGate: MicGate
    /// Mic-only-silence backstop (TECH-C7). Force-stops the recording
    /// after `windowSeconds` of continuous non-`.hot` MicGate verdicts
    /// while the system audio channel is also silent: catches the
    /// "everyone else left and the user forgot" failure mode.
    private let silenceBackstop: MicOnlySilenceBackstop

    /// Latest system-audio level in dBFS, updated on the main queue from
    /// the existing `recorder.onSystemLevel` callback. Read by the
    /// verdict-consumer Task to decide whether the system channel still
    /// carries audible content for the silence backstop. `-120` is the
    /// "no audio observed yet" sentinel used by `accumulateAndEmit`.
    private var latestSystemLevelDb: Float = -120

    /// Consumes `micGate.verdicts`. Launched in `start()` once; cancelled
    /// at shutdown. Each verdict is forwarded to the recorder's writer
    /// and the silence backstop on the main actor.
    private var verdictConsumerTask: Task<Void, Never>?

    /// Consumes `lifecycleCoord.verdicts`. Launched in `start()` once; cancelled at shutdown. Routes `.ended` into the recording-end path.
    private var lifecycleConsumerTask: Task<Void, Never>?

    /// Watches the AX application for window-created events so mute
    /// buttons that appear after `beginRecording` (Teams 2 compact
    /// view, PIP overlays, ...) get observed too. Owned per-meeting;
    /// created in `engageMicGate`, torn down in `stopRecording`.
    /// See TECH-C14.
    private var axWindowWatcher: MeetingAXWindowWatcher?

    /// Pre-fetches the local-MLX model whenever the user picks a backend
    /// that needs one. The first meeting in local mode otherwise pays a
    /// 30s-3min download stall inside `mlx_lm.server`'s first call;
    /// running the prefetch up front turns that into a visible status-bar
    /// state instead. No-op when backend is anthropic.
    private let modelDownload = ModelDownloadSupervisor()

    /// Per-context routing rules (TECH-B). Workflows live as TOML files
    /// under `~/.config/meeting-pipe/workflows/`. Held as a published
    /// store so the Workflows tab + the prompt window's chip can both
    /// subscribe directly.
    let workflowStore: WorkflowStore

    /// Watches mic + system levels to surface a missed meeting end (TECH-C2).
    /// Created at recording start, released at stop. Notifies after 90 s of
    /// silence and auto-stops after 5 min.
    private var silenceDetector: SilenceDetector?

    /// Show the "Screen Recording disabled" startup notification at most
    /// once per daemon launch — repeated banners would be noisy.
    private var didNotifyAboutPermissionDenial: Bool = false

    /// Workflow resolved at the start of the current recording (TECH-B3).
    /// Nil between meetings. Read by `writeMetaSidecar` so the pipeline
    /// picks up the workflow's context prompt + backend + sinks; cleared
    /// when the recorder finishes flushing.
    private var activeWorkflow: Workflow?

    /// Explicit override from the prompt window's chevron menu (TECH-B5).
    /// Set when the user picks a non-default workflow before clicking
    /// Record; consumed (and cleared) by the next `beginRecording`. The
    /// matcher's precedence rules treat this as the highest-specificity
    /// signal so it always wins over rule matches.
    private var pendingWorkflowOverride: UUID?

    /// Dry-run mode: detection + recognizer run end-to-end, all decisions
    /// hit the JSONL event log, but `MeetingRecorder.start` is never
    /// called. Lets the daemon ride along during a normal workday so the
    /// user can verify detection accuracy without producing audio. Read
    /// once at init from `MEETING_PIPE_DRY_RUN`; flipping it requires a
    /// daemon restart, which is fine for a debug knob.
    private let dryRun: Bool = (ProcessInfo.processInfo.environment["MEETING_PIPE_DRY_RUN"] == "1")

    private var configCancellable: AnyCancellable?
    private var permissionGrantedCancellable: AnyCancellable?

    init(
        config: Config,
        statusBar: StatusBarController,
        launcher: PipelineDriver? = nil,
        configStore: ConfigStore? = nil,
        secretsStore: SecretsStore? = nil
    ) {
        self.config = config
        self.configStore = configStore
        self.statusBar = statusBar
        self.recorder = MeetingRecorder()
        self.notifier = Notifier()
        self.promptWindow = MeetingPromptWindow()
        self.recordingHUD = RecordingHUDWindow()
        self.hotkey = HotkeyManager()
        self.consent = ConsentStore()
        let resolvedLauncher = launcher ?? PipelineLauncher()
        self.launcher = resolvedLauncher
        // FluidAudio is the only ASR path: the daemon owns transcription
        // in-process via Parakeet TDT + pyannote on the Apple Neural
        // Engine. The Python pipeline runs summarize + publish only.
        let runner = TranscriptionService.makeRunner()
        Log.event(category: "transcription", action: "engine_resolved", attributes: [
            "engine": runner.backendName,
        ])
        self.sinkDispatcher = SinkDispatcher(
            launcher: resolvedLauncher,
            transcriptionRunner: runner
        )
        // PreferencesWindow needs both stores. When the daemon was
        // launched with neither (test fixtures, headless smoke runs)
        // the menu item is wired through this guard; clicking it
        // becomes a no-op rather than crashing.
        if let configStore = configStore, let secretsStore = secretsStore {
            self.preferencesWindow = PreferencesWindow(store: configStore, secrets: secretsStore)
        } else {
            self.preferencesWindow = nil
        }
        // The recordings dir is read from ConfigStore at runtime so the
        // Library list reflects edits made in Preferences. We snapshot
        // here at init for the store's root; live-config switches require
        // a daemon restart for the library window (acceptable since the
        // recordings dir is rarely changed).
        let recordingsDir: URL = {
            if let raw = configStore?.outputDirPath {
                return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            }
            return config.recording.outputDir
        }()
        let libraryModel = LibraryWindowModel(recordingsDir: recordingsDir)
        self.libraryModel = libraryModel
        self.libraryWindow = LibraryWindow(model: libraryModel)
        // Workflow store (TECH-B1): per-context routing rules live as
        // TOML files under `~/.config/meeting-pipe/workflows/`. Loaded
        // synchronously so the matcher (TECH-B3) and Workflows tab see
        // a populated store on the first detection / window open.
        // TECH-B2: if the store is empty we seed a "General" workflow
        // from the legacy `summarization.team_context` so the pipeline's
        // observable behaviour doesn't change for existing installs.
        let workflowStore = WorkflowStore()
        workflowStore.load()
        WorkflowMigrator.runIfNeeded(
            store: workflowStore,
            configStore: configStore,
            config: config
        )
        self.workflowStore = workflowStore
        libraryModel.workflowStore = workflowStore

        // MicGate + Lifecycle stack (TECH-G-MIC + TECH-C13). The shared
        // buses centralise CoreAudio HAL + AX observer registrations;
        // adapters live in MeetingPipeCore and dispatch per-bundle. The
        // EventLog bridge forwards `MeetingPipeCore` telemetry into the
        // daemon's existing events.jsonl stream via `Log.event`.
        let logAdapter = LogEventAdapter()
        let halBus = CoreAudioHALBus(backend: RealCoreAudioBackend(), eventLog: logAdapter)
        let axBus = AXObserverBus(backend: RealAXBackend(), eventLog: logAdapter)
        let muteLabels: MuteLabels
        do {
            muteLabels = try MuteLabelsLoader.loadDefault()
        } catch {
            // Bundle resource missing or malformed: keep the daemon
            // running with an empty catalogue. AX mute matching becomes
            // a no-op; HAL VAD + RMS still drive the gate.
            Log.main.warning("MuteLabels.loadDefault failed: \(error.localizedDescription), using empty catalogue")
            Log.event(category: "coordinator", action: "mute_labels_load_failed", attributes: [
                "error": error.localizedDescription,
            ])
            muteLabels = MuteLabels(entries: [:])
        }
        self.halBus = halBus
        self.axBus = axBus
        self.muteLabels = muteLabels
        self.lifecycleCoord = MeetingLifecycleCoordinator(
            halBus: halBus,
            axBus: axBus,
            eventLog: logAdapter,
            adapters: [
                TeamsLifecycleAdapter(halBus: halBus, axBus: axBus, eventLog: logAdapter),
                ZoomLifecycleAdapter(halBus: halBus, axBus: axBus, eventLog: logAdapter),
                WebexLifecycleAdapter(axBus: axBus, eventLog: logAdapter),
                SlackLifecycleAdapter(axBus: axBus, eventLog: logAdapter),
                BrowserMeetingLifecycleAdapter(axBus: axBus, eventLog: logAdapter),
            ]
        )
        self.micGate = MicGate(
            catalogue: muteLabels,
            halBus: halBus,
            axBus: axBus,
            eventLog: logAdapter,
            adapters: [
                TeamsMuteAdapter(axBus: axBus, catalogue: muteLabels, eventLog: logAdapter),
                ZoomMuteAdapter(axBus: axBus, catalogue: muteLabels, eventLog: logAdapter),
                WebexMuteAdapter(axBus: axBus, catalogue: muteLabels, eventLog: logAdapter),
                SlackMuteAdapter(axBus: axBus, catalogue: muteLabels, eventLog: logAdapter),
                MeetMuteAdapter(eventLog: logAdapter),
                BrowserMuteAdapter(eventLog: logAdapter),
            ]
        )
        // Window read from the TOML knob (TECH-C7). Live edits in
        // Preferences only take effect on the next meeting because the
        // backstop is constructed once at Coordinator init.
        let micOnlySilenceSec = configStore?.micOnlySilenceSec ?? config.detection.micOnlySilenceSec
        self.silenceBackstop = MicOnlySilenceBackstop(windowSeconds: micOnlySilenceSec)

        super.init()
        // Wire the model back to the Coordinator so the sidebar's
        // Start/Stop button can route through the existing menu handlers.
        // Done post-super.init so the weak ref is valid.
        libraryModel.coordinator = self
        statusBar.libraryModel = libraryModel
        wireSubsystems()
    }

    /// Bind the three Coordination subordinates back to the Coordinator
    /// (state-machine callbacks, sink-dispatcher per-job results, mute
    /// probe transitions). Done after `super.init` so `self` is valid.
    private func wireSubsystems() {
        stateMachine.onIdleTransition = { [weak self] in
            // Every path back to idle (record then stop, skip, prompt
            // timeout, stale-prompt end) tears down the lifecycle
            // adapter through this single hook.
            self?.disengageLifecycle()
        }
        sinkDispatcher.onQueueDepthChanged = { [weak self] depth in
            self?.statusBar.setProcessingCount(depth)
        }
        sinkDispatcher.onJobCompleted = { [weak self] job, result in
            guard let self = self else { return }
            switch result {
            case .success(let pageURL):
                let stem = job.file.deletingPathExtension().lastPathComponent
                let recordingsDir = job.file.deletingLastPathComponent()
                self.notifier.notifyDone(
                    stem: stem,
                    recordingsDir: recordingsDir,
                    pageURL: pageURL
                )
            case .failure(let err):
                self.notifier.notifyError("Pipeline failed: \(err.localizedDescription)")
            }
        }
        // MicGate consumes the recorder's per-buffer mic RMS; the gate
        // is allocation-free and defers its publish off the render
        // thread, so calling from the audio tap is safe.
        recorder.onMicRmsDb = { [weak self] db in
            self?.micGate.ingest(rmsDb: db)
        }
        // Backstop fires once when the mic-only-silence threshold is
        // exceeded. Hop to the main actor and route through the
        // existing forceStop path so the event log records the reason.
        silenceBackstop.onTriggered = { [weak self] _ in
            Task { @MainActor in
                self?.forceStop(reason: "mic_only_silence")
            }
        }
    }

    func start() {
        notifier.delegate = self
        promptWindow.delegate = self
        recordingHUD.delegate = self

        // Drive the recorder's writer + silence backstop from the gate's
        // verdict stream. The stream is unbounded and lives for the
        // daemon's lifetime; verdicts only flow while a meeting is
        // engaged. Cancelled in `shutdown()`.
        verdictConsumerTask = Task { [weak self] in
            guard let self = self else { return }
            for await verdict in self.micGate.verdicts {
                await MainActor.run {
                    self.recorder.setMicGateVerdict(verdict)
                    let hasSystem = Double(self.latestSystemLevelDb) > Coordinator.systemSilenceThresholdDb
                    self.silenceBackstop.ingest(verdict: verdict, hasSystemAudio: hasSystem)
                }
            }
        }

        // Consume the lifecycle verdict stream: `.starting` raises the
        // prompt, `.ended` closes the recording or dismisses a stale
        // prompt. `.inMeeting` / `.endingProvisional` are telemetry.
        lifecycleConsumerTask = Task { [weak self] in
            guard let self = self else { return }
            for await verdict in self.lifecycleCoord.verdicts {
                await MainActor.run {
                    switch verdict {
                    case .starting(let context):
                        self.handleMeetingStarted(source: self.appSource(from: context))
                    case .ended:
                        self.handleMeetingEnded()
                    default:
                        break
                    }
                }
            }
        }

        // Funnel every TCC dialog through PermissionsCenter so the
        // Preferences "Permissions" tab and the startup sequence both
        // read from the same published state. macOS still serializes
        // the actual prompts (notifications first, then mic, then
        // screen recording, then accessibility), but they now all
        // surface within the first few seconds of launch instead of
        // dribbling out across the first recording.
        requestPermissionsAtStartup()

        if dryRun {
            Log.main.info("MEETING_PIPE_DRY_RUN=1: detection enabled, recorder disabled")
            Log.writeLine("daemon", "[dry-run] enabled")
            Log.event(category: "coordinator", action: "dry_run_enabled")
        }

        // Cold-start discovery: the watcher reports a winning source,
        // the Coordinator engages the lifecycle adapter, and the
        // `.starting` verdict raises the prompt (TECH-C13 step 5).
        discoveryWatcher.onDiscovered = { [weak self] source in
            self?.handleDiscovery(source)
        }
        discoveryWatcher.start()

        // Seed the status bar with the initial regulated-mode flag so
        // the lock glyph (if the user has it enabled) shows from boot
        // rather than appearing only after the first config save.
        statusBar.setRegulatedMode(configStore?.regulatedMode ?? false)

        if let parsed = HotkeyManager.parse(liveManualHotkey) {
            hotkey.register(keyCode: parsed.keyCode, modifiers: parsed.modifiers) { [weak self] in
                DispatchQueue.main.async { self?.toggleManual() }
            }
            Log.main.info("Hotkey registered: \(self.liveManualHotkey)")
        } else {
            Log.main.warning("Could not parse hotkey: \(self.liveManualHotkey)")
        }

        // Stop-only hotkey (TECH-C5). Distinct so a panic-press can
        // never accidentally start a recording the way the toggle
        // hotkey can when the daemon is idle. Logged with a different
        // event action so the post-mortem analyzer can tell them apart.
        if liveForceStopHotkey == liveManualHotkey {
            Log.main.warning("Force-stop hotkey matches manual hotkey — skipping second registration")
        } else if let parsed = HotkeyManager.parse(liveForceStopHotkey) {
            hotkey.register(keyCode: parsed.keyCode, modifiers: parsed.modifiers) { [weak self] in
                DispatchQueue.main.async { self?.forceStop(reason: "hotkey") }
            }
            Log.main.info("Force-stop hotkey registered: \(self.liveForceStopHotkey)")
        } else {
            Log.main.warning("Could not parse force-stop hotkey: \(self.liveForceStopHotkey)")
        }

        // Refresh affected components when the user saves Preferences.
        // ConfigStore already debounces 500ms, so we don't pile up rebuilds
        // while a slider is being dragged.
        configCancellable = configStore?.didPersist
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handleConfigPersisted() }

        // Status-bar reflects the model-download state. Wired here once
        // so we don't have to re-subscribe when the supervisor restarts.
        modelDownload.onStateChange = { [weak self] state in
            self?.statusBar.setModelDownload(state)
        }
        // Eager prefetch on launch when the user is already in local/auto
        // mode. No-op for backend=anthropic (the typical first-time install).
        ensureModelPrefetchIfNeeded()

        // Subscribe to permission grants so the detector picks up an
        // in-progress meeting the moment Mic / Accessibility flip on.
        // Without this, a user who restarts the daemon mid-meeting (the
        // typical Accessibility-grant flow) waits for the next Workspace
        // notification before detection kicks in, by which point the
        // meeting may have started silently.
        permissionGrantedCancellable = PermissionsCenter.shared.permissionGranted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] kind in
                guard let self = self else { return }
                Log.main.info("permission granted: \(kind.displayName) — re-evaluating detector")
                Log.event(category: "coordinator", action: "permission_granted", attributes: [
                    "kind": kind.rawValue,
                ])
                self.discoveryWatcher.refreshNow()
                self.statusBar.refreshMenuForPermissionChange()
            }

        // Recover any recording orphaned by a daemon that terminated
        // mid-recording (crash, kill, rebuild, or the reinstall
        // permission-grant restart churn). Runs once, here at startup.
        recoverOrphanedRecordings()
    }

    /// Fire every TCC dialog the daemon needs in a single ordered
    /// sequence at startup. macOS serializes prompts internally (the
    /// second dialog only paints once the first is dismissed) but they
    /// all surface within the first few seconds, instead of dribbling
    /// out across the first recording. The Permissions tab in
    /// Preferences is the canonical surface for re-prompting later.
    private func requestPermissionsAtStartup() {
        Task { @MainActor in
            // 1. Notifications — silent prompt; non-blocking either way.
            await PermissionsCenter.shared.requestNotifications()
            // 2. Microphone — used to be implicit (KVO on AVCaptureDevice),
            //    which fired the dialog a couple of seconds after launch.
            //    Explicit request keeps it next to its siblings.
            await PermissionsCenter.shared.requestMic()
            // 3. Screen Recording — CGRequestScreenCaptureAccess +
            //    SCShareableContent prewarm. prewarm() was already
            //    triggered from App.swift; this re-runs it through the
            //    Permissions center so the published state is current.
            await PermissionsCenter.shared.requestScreenRecording()
            // 4. Accessibility — surfaces the "App wants to control your
            //    Mac" prompt + adds MeetingPipe to System Settings.
            //    Granting requires a daemon restart for AX trust to
            //    propagate; the notifier banner explains that.
            _ = PermissionsCenter.shared.requestAccessibility()
            // Surface follow-ups (banner + menu refresh) once the dust
            // has settled.
            checkScreenRecordingPermissionAtStartup()
            checkAccessibilityPermissionAtStartup()
        }
    }

    private func checkScreenRecordingPermissionAtStartup() {
        guard !didNotifyAboutPermissionDenial,
              SystemAudioCapture.permissionState == .denied else { return }
        didNotifyAboutPermissionDenial = true
        notifier.notifySystemAudioBlocked()
        statusBar.refreshMenuForPermissionChange()
    }

    private func checkAccessibilityPermissionAtStartup() {
        // PermissionsCenter.requestAccessibility() has already surfaced
        // the system prompt by the time this runs. Here we only fan out
        // the side effects: log the verdict, raise the fallback banner
        // when still untrusted (the user dismissed the dialog without
        // granting, or revoked previously and needs a restart for the
        // change to propagate).
        if AXIsProcessTrusted() {
            Log.main.info("Accessibility: trusted")
            return
        }
        Log.main.warning("Accessibility: NOT trusted - native meeting end-detection disabled")
        Log.writeLine("daemon", "ACCESSIBILITY DENIED at startup - native end-detection will not fire. Enable MeetingPipe in Preferences → Permissions, or in System Settings → Privacy & Security → Accessibility.")
        Log.event(category: "coordinator", action: "accessibility_denied_at_startup")
        notifier.notifyAccessibilityBlocked()
    }

    func shutdown() {
        Log.main.info("shutting down")
        discoveryWatcher.stop()
        hotkey.unregister()
        verdictConsumerTask?.cancel()
        verdictConsumerTask = nil
        lifecycleConsumerTask?.cancel()
        lifecycleConsumerTask = nil
        micGate.shutdown()
        lifecycleCoord.shutdown()
        if recorder.isRecording {
            // Best-effort flush; we don't want orphan recording state.
            let recorder = self.recorder
            Task { await recorder.stop() }
        }
    }

    /// Recover recordings orphaned by a daemon that terminated
    /// mid-recording: a crash, a `kill`, a `rebuild.sh` during
    /// testing, or the permission-grant restart churn after a
    /// reinstall. `shutdown()`'s flush above is a detached task the
    /// exiting process may never finish, so an interrupted recording
    /// leaves `<stem>.mic.wav` / `<stem>.system.wav` intermediates
    /// with no merged `<stem>.wav`. Each such pair is merged and
    /// enqueued for the pipeline. The orphan set is snapshotted
    /// synchronously here, before discovery can start a new recording,
    /// so a live recording's in-flight intermediates are never
    /// mistaken for an orphan; the ffmpeg merges then run off the main
    /// actor so the menu bar is not stalled.
    private func recoverOrphanedRecordings() {
        let dir = liveOutputDir
        let stems = OrphanRecordingRecovery.scanOrphanStems(in: dir)
        guard !stems.isEmpty else { return }
        Task { @MainActor [weak self] in
            let recovered = await OrphanRecordingRecovery.recover(stems: stems, in: dir)
            guard let self = self else { return }
            for url in recovered {
                Log.writeLine("daemon", "recovered orphaned recording → \(url.lastPathComponent)")
                Log.event(category: "coordinator", action: "orphan_recording_recovered", attributes: [
                    "file": url.lastPathComponent,
                ])
                self.sinkDispatcher.enqueue(file: url, summaryMode: .auto)
            }
        }
    }

    /// Treat the system channel as "carries audio" when its 1 s RMS
    /// average sits above this floor. Mirrors `SilenceDetector`'s
    /// `defaultThresholdDb` so the silence backstop and the existing
    /// 5-min auto-stop draw the same line between silence and content.
    private static let systemSilenceThresholdDb: Double = SilenceDetector.defaultThresholdDb

    // MARK: Menu actions

    @objc func menuStart() { toggleManual() }
    @objc func menuStop() { toggleManual() }

    @objc func menuOpenLogs() {
        NSWorkspace.shared.open(Log.logsDir)
    }

    @objc func menuOpenRecordings() {
        let dir = liveOutputDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc func menuPreferences() {
        preferencesWindow?.show()
    }

    /// Deeplink entry for the menu-bar warning row and the recording-
    /// blocked-on-mic-permission path. Opens Preferences directly on
    /// the Permissions section so the user can resolve the TCC issue
    /// without hunting through the sidebar.
    @objc func menuPreferencesPermissions() {
        preferencesWindow?.show(initial: .permissions)
    }

    @objc func menuOpenLibrary() {
        libraryWindow.show()
    }

    @objc func menuQuickFind() {
        quickFindWindow.show()
    }

    /// Open the Library window and select the row with the given stem.
    /// Called by the Quick Find panel when the user picks a result.
    func openMeeting(stem: String) {
        libraryModel.pendingSelection = stem
        libraryWindow.show()
    }

    private lazy var quickFindWindow: QuickFindWindow = QuickFindWindow(
        meetingStore: libraryModel.meetingStore,
        onSelect: { [weak self] meeting in
            self?.openMeeting(stem: meeting.stem)
        }
    )

    /// Retry the full pipeline for a meeting whose original run never
    /// produced a summary (daemon was killed mid-transcribe, the
    /// orchestrator crashed, etc.). Enqueues the same `mp run-all`
    /// subprocess the normal flow uses, so progress shows up in the
    /// status-bar processing badge and any sidecars get overwritten.
    /// Returns failure if the wav file is missing — every other error
    /// surfaces as a notifier banner from the existing pipeline path.
    func retryMeeting(stem: String) -> Result<Void, Error> {
        let dir = liveOutputDir
        let wavURL = dir.appendingPathComponent("\(stem).wav")
        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            return .failure(NSError(
                domain: "Coordinator", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "No audio at \(wavURL.lastPathComponent) - cannot retry"]
            ))
        }
        Log.writeLine("daemon", "retry pipeline → \(stem)")
        Log.event(category: "coordinator", action: "retry_requested", attributes: [
            "stem": stem,
        ])
        sinkDispatcher.enqueue(file: wavURL, summaryMode: .auto)
        return .success(())
    }

    /// Regenerate the summary for the given stem by re-running the
    /// `mp summarize` stage against the existing transcript, then
    /// re-running publish so the Notion page reflects the new summary.
    /// Returns the resulting Notion page URL on success.
    ///
    /// Workflow / backend override is not yet wired (TECH-B ships the
    /// workflow data model; backend-override env var is not piped into
    /// `mp summarize`). For now the regenerate uses whatever the
    /// configured backend / context resolves to at subprocess time.
    func regenerateMeeting(
        stem: String,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        let dir = liveOutputDir
        let transcriptURL = dir.appendingPathComponent("\(stem).md")
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            completion(.failure(NSError(
                domain: "Coordinator", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "No transcript at \(transcriptURL.lastPathComponent) — cannot regenerate"]
            )))
            return
        }
        Log.writeLine("daemon", "regenerate requested → \(stem)")
        Log.event(category: "coordinator", action: "regenerate_started", attributes: [
            "stem": stem,
        ])
        launcher.summarize(transcriptMD: transcriptURL) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    // Summarize wrote a fresh <stem>.summary.json next to
                    // the transcript; chain into publish so the Notion
                    // page picks up the new content too.
                    self.republishMeeting(stem: stem, completion: completion)
                case .failure(let err):
                    Log.event(category: "coordinator", action: "regenerate_failed", attributes: [
                        "stem": stem,
                        "error": err.localizedDescription,
                    ])
                    self.notifier.notifyError("Regenerate failed: \(err.localizedDescription)")
                    completion(.failure(err))
                }
            }
        }
    }

    /// Move every sidecar associated with a stem (audio, transcript,
    /// summary, run, meta, notion, obsidian, READY_FOR_MANUAL) to the
    /// user's Trash. Recoverable from Finder until the user empties the
    /// Trash. The recordings-dir watcher picks up the deletes and
    /// refreshes the Library list automatically.
    func softDeleteMeeting(stem: String) -> Result<Void, Error> {
        let dir = liveOutputDir
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])
        } catch {
            return .failure(error)
        }
        let matching = entries.filter { url in
            MeetingStore.stem(of: url) == stem
        }
        guard !matching.isEmpty else {
            return .failure(NSError(
                domain: "Coordinator", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No files found for \(stem)"]
            ))
        }
        var firstFailure: Error?
        for url in matching {
            var trashedURL: NSURL?
            do {
                try fm.trashItem(at: url, resultingItemURL: &trashedURL)
            } catch {
                Log.main.warning("trashItem failed for \(url.lastPathComponent): \(error.localizedDescription)")
                if firstFailure == nil { firstFailure = error }
            }
        }
        Log.event(category: "coordinator", action: "meeting_deleted", attributes: [
            "stem": stem,
            "files_count": matching.count,
        ])
        if let err = firstFailure { return .failure(err) }
        return .success(())
    }

    /// Copy the standard human-facing artefacts for a stem (summary
    /// markdown, transcript markdown, summary JSON, raw audio) into a
    /// user-chosen folder. Missing files are silently skipped — the
    /// export is best-effort and aimed at sharing rather than archival
    /// completeness (use Reveal in Finder + a manual copy for the
    /// latter). Returns the count of files copied on success.
    func exportMeeting(stem: String, to destination: URL) -> Result<Int, Error> {
        let dir = liveOutputDir
        let fm = FileManager.default
        let candidates = [
            "\(stem).summary.md",
            "\(stem).md",
            "\(stem).summary.json",
            "\(stem).wav",
            "\(stem).notion.json",
            "\(stem).meta.json",
        ]
        var copied = 0
        for name in candidates {
            let src = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = destination.appendingPathComponent(name)
            // Overwrite existing destination files so a second export
            // pass to the same folder refreshes the bundle.
            if fm.fileExists(atPath: dst.path) {
                _ = try? fm.removeItem(at: dst)
            }
            do {
                try fm.copyItem(at: src, to: dst)
                copied += 1
            } catch {
                Log.main.warning("export copy failed: \(name) → \(error.localizedDescription)")
            }
        }
        Log.event(category: "coordinator", action: "meeting_exported", attributes: [
            "stem": stem,
            "files_copied": copied,
            "destination": destination.lastPathComponent,
        ])
        return .success(copied)
    }

    /// Re-run the publish step for the given meeting stem. Spawns the
    /// same `mp publish-notion` subprocess the orchestrator uses at end
    /// of pipeline, so success / failure / sidecar updates flow through
    /// the same code path. Returns the resulting Notion page URL via the
    /// completion handler — nil under regulated_mode or when the page
    /// link is not in the sidecar.
    ///
    /// Used by the Library window's summary-edit flow (TECH-A5). The
    /// caller is expected to have already written the corrected summary
    /// to `<stem>.summary.json` before invoking this.
    func republishMeeting(
        stem: String,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        let dir = liveOutputDir
        let summaryURL = dir.appendingPathComponent("\(stem).summary.json")
        guard FileManager.default.fileExists(atPath: summaryURL.path) else {
            completion(.failure(NSError(
                domain: "Coordinator", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "No summary.json for \(stem) — corrected summary must be written before republish"]
            )))
            return
        }
        Log.writeLine("daemon", "republish requested → \(stem)")
        Log.event(category: "coordinator", action: "republish_started", attributes: [
            "stem": stem,
        ])
        launcher.publish(summaryJSON: summaryURL) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    Log.event(category: "coordinator", action: "republish_succeeded", attributes: [
                        "stem": stem,
                        "page_url": url?.absoluteString ?? NSNull(),
                    ])
                case .failure(let err):
                    Log.event(category: "coordinator", action: "republish_failed", attributes: [
                        "stem": stem,
                        "error": err.localizedDescription,
                    ])
                    self?.notifier.notifyError("Republish failed: \(err.localizedDescription)")
                }
                completion(result)
            }
        }
    }

    @objc func menuOpenScreenRecordingSettings() {
        SystemAudioCapture.openScreenRecordingSettings()
    }

    /// Open the correction sheet for whichever stem the menu item carries
    /// in `representedObject`. The status bar builds the submenu from
    /// `recentCorrectableMeetings()` so menus and the click site share
    /// the same path resolution.
    @objc func menuRecentMeeting(_ sender: NSMenuItem) {
        guard let stem = sender.representedObject as? String else { return }
        CorrectionWindow.present(stem: stem, recordingsDir: liveOutputDir)
    }

    /// List the last `limit` meetings that have a run sidecar on disk
    /// (i.e. the summarize stage actually finished). Sorted newest
    /// first by run-sidecar mtime so the most recent meeting is always
    /// at the top of the menu.
    func recentCorrectableMeetings(limit: Int = 10) -> [(stem: String, displayName: String)] {
        let dir = liveOutputDir
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let sidecars = entries.filter { $0.lastPathComponent.hasSuffix(".run.json") }
        let sorted = sidecars.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return lDate > rDate
        }
        return sorted.prefix(limit).map { url in
            let name = url.lastPathComponent
            // Strip the trailing ".run.json" suffix.
            let stem = String(name.dropLast(".run.json".count))
            return (stem: stem, displayName: stem)
        }
    }

    // MARK: Live-config readers
    //
    // When a `ConfigStore` is wired up, prefer its current value over the
    // boot-time `config` snapshot. That way Preferences edits take effect
    // at the next read without bouncing the daemon.

    private var liveOutputDir: URL {
        guard let raw = configStore?.outputDirPath else { return config.recording.outputDir }
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    private var liveAutoConsentApps: [String] {
        configStore?.autoConsentApps ?? config.recording.autoConsentApps
    }

    private var livePromptTimeoutSec: Double {
        configStore?.promptTimeoutSec ?? config.detection.promptTimeoutSec
    }

    private var liveRepromptCooldownSec: Double {
        configStore?.repromptCooldownSec ?? config.detection.repromptCooldownSec
    }

    private var liveHonorAppMute: Bool {
        configStore?.honorAppMute ?? config.recording.honorAppMute
    }

    private var liveVoiceProcessing: Bool {
        // Recorder binds this at start time, so live edits only take
        // effect on the next recording. The Preferences sublabel
        // documents that.
        configStore?.voiceProcessing ?? config.recording.voiceProcessing
    }

    private var liveManualHotkey: String {
        configStore?.manualHotkey ?? config.detection.manualHotkey
    }

    private var liveForceStopHotkey: String {
        configStore?.forceStopHotkey ?? config.detection.forceStopHotkey
    }

    // MARK: State transitions

    private func toggleManual() {
        switch stateMachine.current {
        case .idle:
            beginRecording(source: nil, summaryMode: .auto)
        case .prompting(let src), .suppressed(let src):
            // Preserve meeting attribution when the user overrides via hotkey
            // — without this, "Always for {App}" would never see the source.
            promptWindow.dismiss()
            // Manual override is an explicit "start now" signal; drop
            // any cooldown entry for this bundle so the next detector-
            // driven detection isn't suppressed by a stale skip/end.
            stateMachine.clearCooldown(bundleID: src.bundleID)
            beginRecording(source: src, summaryMode: .auto)
        case .recording(let file, let src, let mode):
            stopRecording(file: file, source: src, summaryMode: mode)
        case .stopping:
            // Recorder is mid-flush; a new start would race the await.
            // Pipeline jobs run in their own queue inside the dispatcher.
            break
        }
    }

    /// Stop-only entry point used by the force-stop hotkey and any other
    /// surface that needs an unambiguous "stop, never start" semantics
    /// (TECH-C5). Unlike `toggleManual`, this never transitions out of
    /// `.idle` into a recording — pressing the force-stop hotkey when
    /// nothing is running is a logged no-op. The detector's own state
    /// (`hasFiredStart`) is preserved so it can't re-prompt for the same
    /// meeting; a fresh `.started` only fires after a real `.ended`.
    private func forceStop(reason: String) {
        Log.event(category: "coordinator", action: "force_stop", attributes: [
            "reason": reason,
            "state": DetectionStateMachine.label(stateMachine.current),
        ])
        switch stateMachine.current {
        case .recording(let file, let src, let mode):
            stopRecording(file: file, source: src, summaryMode: mode)
        case .prompting(let src):
            // Treat as "no, don't record, and don't ask again until the
            // detector sees this meeting end" — same as clicking Skip.
            stateMachine.cancelPromptTimeout()
            promptWindow.dismiss()
            stateMachine.setSuppressed(source: src)
            statusBar.setIdle()
        case .idle, .suppressed, .stopping:
            break
        }
    }

    /// Public setter used by the prompt window's chevron menu (TECH-B5)
    /// to pin the next recording to a specific workflow. The override is
    /// consumed by the next `beginRecording`; if the user dismisses the
    /// prompt without recording, the override is cleared when the
    /// prompt times out so a stale pick can't leak into the next call.
    func setPendingWorkflowOverride(_ id: UUID?) {
        pendingWorkflowOverride = id
    }

    /// Active workflow (if any) for the in-flight recording. Surfaced so
    /// the HUD and status-bar UI can paint the workflow's color/chip
    /// without holding a reference to the matcher.
    var currentActiveWorkflow: Workflow? { activeWorkflow }

    /// Resolve the workflow that would apply to a given source right
    /// now. Used by the prompt window to render its chip ahead of the
    /// Record click. Returns the default workflow when no source / no
    /// rule matches.
    func workflowForPrompt(source: AppSource?) -> Workflow? {
        return WorkflowMatcher.resolve(
            source: source,
            overrideID: pendingWorkflowOverride,
            workflows: workflowStore.workflows
        )
    }

    private func beginRecording(source: AppSource?, summaryMode: SummaryMode) {
        stateMachine.cancelPromptTimeout()

        // Pre-record gate. Mic is non-negotiable — without it the
        // recording is silent and the pipeline produces empty
        // transcripts. Screen Recording stays optional (mic-only is a
        // documented fallback). We re-probe synchronously here so a
        // permission the user just granted via Preferences is reflected
        // without a daemon restart.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus != .authorized {
            Log.main.warning("beginRecording aborted: microphone permission missing")
            Log.event(category: "coordinator", action: "recording_blocked", attributes: [
                "reason": "mic_permission",
                "status": "\(micStatus.rawValue)",
            ])
            notifier.notifyError("Microphone permission is required. Grant it in Preferences → Permissions, then try again.")
            // Pop the Preferences window so the user can act without
            // hunting for the menu item. Deeplink directly to the
            // Permissions section since the error is permission-shaped.
            menuPreferencesPermissions()
            stateMachine.setIdle()
            statusBar.setIdle()
            return
        }

        if dryRun {
            // Detection happened, consent was resolved, but we deliberately
            // do not start the recorder, the streaming transcriber, or the
            // HUD. Returning to .idle keeps the detector ready for the next
            // .started event so a workday's worth of meetings can be
            // captured in the JSONL stream as detection-only signals.
            Log.writeLine("daemon", "[dry-run] would record (\(source?.bundleID ?? "manual"))")
            Log.event(category: "coordinator", action: "dry_run_would_record", attributes: [
                "bundle_id": source?.bundleID ?? "manual",
                "summary_mode": summaryMode == .byo ? "byo" : "auto",
            ])
            stateMachine.setIdle()
            statusBar.setIdle()
            return
        }

        // Resolve the workflow that controls this meeting's context
        // prompt / backend / sinks (TECH-B3). The lookup is deterministic
        // and uses the explicit override the prompt window may have set,
        // then falls through to rule matches, then to the default. After
        // resolution we clear the override so it can't leak into the
        // next meeting.
        let resolvedWorkflow = WorkflowMatcher.resolve(
            source: source,
            overrideID: pendingWorkflowOverride,
            workflows: workflowStore.workflows
        )
        pendingWorkflowOverride = nil

        do {
            let file = try recorder.start(
                outputDir: liveOutputDir,
                voiceProcessing: liveVoiceProcessing
            )
            activeWorkflow = resolvedWorkflow
            stateMachine.setRecording(file: file, source: source, summaryMode: summaryMode)
            statusBar.setRecording(file: file, source: source, summaryMode: summaryMode, workflow: resolvedWorkflow)
            recordingHUD.present(source: source, workflow: resolvedWorkflow, startedAt: Date())
            notifier.notifyRecordingStarted(file: file)
            Log.writeLine(
                "daemon",
                "recording started → \(file.path) source=\(source?.bundleID ?? "manual") mode=\(summaryMode == .byo ? "byo" : "auto") workflow=\(resolvedWorkflow?.name ?? "(none)")"
            )
            Log.event(category: "coordinator", action: "recording_started", attributes: [
                "file": file.lastPathComponent,
                "bundle_id": source?.bundleID ?? "manual",
                "summary_mode": summaryMode == .byo ? "byo" : "auto",
                "workflow_id": resolvedWorkflow?.id.uuidString ?? NSNull(),
                "workflow_name": resolvedWorkflow?.name ?? NSNull(),
            ])
            armSilenceDetector()
            engageMicGate(source: source)
            // Late-arm the lifecycle Leave-button signal. The
            // discovery-time AX walk that drove `engageLifecycle` runs
            // before the call UI renders, so the Leave button is
            // usually absent then; re-walk now that the recorder is up.
            armLifecycleLeaveButton(source: source)
            // The recorder is armed: promote the lifecycle verdict from
            // `.starting` to `.inMeeting`. A no-op for manual recordings
            // (no adapter engaged) and for the prompt-answered-late race.
            lifecycleCoord.confirmRecording()
        } catch {
            Log.main.error("failed to start recorder: \(error.localizedDescription)")
            notifier.notifyError("Could not start recording: \(error.localizedDescription)")
            stateMachine.setIdle()
            statusBar.setIdle()
        }
    }

    private func stopRecording(file: URL, source: AppSource?, summaryMode: SummaryMode) {
        stateMachine.setStopping(file: file, source: source, summaryMode: summaryMode)
        statusBar.setStopping()
        recordingHUD.dismiss()
        disarmSilenceDetector()
        // Tear down the per-meeting AX subscriptions and the gate's
        // adapter. The verdict stream stays open for the next meeting.
        lifecycleCoord.disengage()
        micGate.stop()
        axWindowWatcher?.stop()
        axWindowWatcher = nil

        // Recorder.stop is async; runs on a background task so the UI
        // stays responsive. Once flushed, the audio is enqueued for
        // pipeline processing and the recording-side state returns to
        // .idle so the user can record another meeting immediately.
        let recorder = self.recorder
        Task { @MainActor [weak self] in
            await recorder.stop()
            guard let self = self else { return }
            Log.writeLine("daemon", "recording stopped → \(file.path)")
            Log.event(category: "coordinator", action: "recording_stopped", attributes: [
                "file": file.lastPathComponent,
                "bundle_id": source?.bundleID ?? "manual",
                "system_audio_frames": recorder.lastSystemFires,
            ])
            // No system-audio frames means the user just lost the other
            // side of the call. Always surface it — the previous gate
            // also required `permissionState == .denied`, which silently
            // dropped the warning when the state was `.unknown` (fresh
            // launch, prewarm hadn't run yet) and produced exactly the
            // mic-only recording the user reported losing on May 5.
            // The notifier message branches on permissionState so
            // "Open Settings" only appears when a perm change would help.
            if recorder.lastSystemFires == 0 {
                let perm = SystemAudioCapture.permissionState
                self.notifier.notifyMicOnlyRecording(file: file, permissionState: perm)
                if perm == .denied || perm == .unknown {
                    self.statusBar.refreshMenuForPermissionChange()
                }
            }
            self.writeMetaSidecar(file: file, source: source)
            self.notifier.notifyProcessing(file: file)
            self.sinkDispatcher.enqueue(file: file, summaryMode: summaryMode)
            // Drop the workflow attribution after the sidecar lands so it
            // can't bleed into the next meeting; a fresh resolve runs at
            // the start of the next `beginRecording`.
            self.activeWorkflow = nil
            // Arm the re-prompt cooldown for this bundle so the post-
            // call surface (Teams chat reclaiming the mic, Zoom's
            // teardown toast) can't trigger a fresh "Record this
            // meeting?" prompt within seconds of the stop flush.
            if let bid = source?.bundleID {
                self.stateMachine.recordCooldownEnd(bundleID: bid)
            }
            self.stateMachine.setIdle()
            self.statusBar.setIdle()
        }
    }

    /// Drop a `<wav-stem>.meta.json` next to the recording so the pipeline
    /// can pick up the meeting name + source app for a contextual Notion
    /// title. Best-effort: a write failure is logged but doesn't block the
    /// pipeline (the LLM-derived title is the existing fallback).
    ///
    /// TECH-B4 piggy-backs the active workflow onto the same sidecar
    /// (`workflow_id`, `workflow_name`, `workflow_color`, plus the per-
    /// workflow overrides the pipeline applies at run-all time). Writing
    /// it here keeps the sidecar a single atomic file: the pipeline
    /// reads `<stem>.meta.json` once and gets every per-meeting knob.
    private func writeMetaSidecar(file: URL, source: AppSource?) {
        let dict = MeetingMetaSidecar.build(source: source, workflow: activeWorkflow)
        if dict.isEmpty { return }
        let stem = file.deletingPathExtension().lastPathComponent
        let sidecar = file.deletingLastPathComponent().appendingPathComponent("\(stem).meta.json")
        do {
            let data = try JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: sidecar, options: .atomic)
            Log.writeLine("daemon", "meta sidecar → \(sidecar.lastPathComponent) title=\(source?.meetingTitle ?? "(none)") workflow=\(activeWorkflow?.name ?? "(none)")")
        } catch {
            Log.main.warning("Failed to write meta sidecar: \(error.localizedDescription)")
        }
    }

    private func startPromptTimeout(for source: AppSource) {
        stateMachine.startPromptTimeout(
            for: source,
            timeoutSec: livePromptTimeoutSec
        ) { [weak self] in
            guard let self = self else { return }
            let action = (self.configStore?.defaultPromptAction ?? "skip").lowercased()
            self.promptWindow.dismiss()
            Log.event(category: "coordinator", action: "prompt_timeout", attributes: [
                "bundle_id": source.bundleID,
                "default_action": action,
            ])
            switch action {
            case "record":
                Log.writeLine("daemon", "prompt timed out → auto-record (\(source.bundleID))")
                self.beginRecording(source: source, summaryMode: .auto)
            case "byo":
                Log.writeLine("daemon", "prompt timed out → auto-record byo (\(source.bundleID))")
                self.beginRecording(source: source, summaryMode: .byo)
            default:
                Log.writeLine("daemon", "prompt timed out → suppressed (\(source.bundleID))")
                self.stateMachine.setSuppressed(source: source)
                // Same reasoning as the explicit-skip path: the user's
                // silence is a "don't pester me for this call" signal,
                // so arm the cooldown to absorb post-call mic flickers
                // after suppression lifts.
                self.stateMachine.recordCooldownEnd(bundleID: source.bundleID)
                self.statusBar.setIdle()
            }
        }
    }

    // MARK: Config refresh

    private func handleConfigPersisted() {
        ensureModelPrefetchIfNeeded()
        statusBar.setRegulatedMode(configStore?.regulatedMode ?? false)
    }

    /// Spawn (or skip) a background `mp prefetch-model` for the configured
    /// local model. Idempotent and safe to call from any config-change
    /// path; the supervisor short-circuits when the model is already
    /// cached or already downloading.
    private func ensureModelPrefetchIfNeeded() {
        guard let store = configStore else { return }
        let backend = store.summarizationBackend
        guard backend == "local" || backend == "auto" else {
            // Cancel any in-flight prefetch when the user reverts to
            // anthropic; no point burning bandwidth for a model the
            // pipeline won't load.
            modelDownload.cancel()
            statusBar.setModelDownload(.idle)
            return
        }
        let modelId = store.summarizationLocalModel
        guard !modelId.isEmpty else { return }
        modelDownload.ensure(modelId: modelId)
    }

    // MARK: - Silence detection (TECH-C2)

    private func armSilenceDetector() {
        let detector = SilenceDetector(
            onNotifySilence: { [weak self] in
                self?.handleSilenceNotify()
            },
            onAutoStopSilence: { [weak self] in
                self?.handleSilenceAutoStop()
            }
        )
        silenceDetector = detector
        // RMS callbacks are dispatched to main by the Recorder, so it's
        // safe to touch the SilenceDetector directly here.
        recorder.onMicLevel = { [weak self] db in
            self?.silenceDetector?.observeMic(db: Double(db))
        }
        // Forward the system level both to the silence detector and to
        // the latest-level mirror the MicOnlySilenceBackstop reads. One
        // callback site so the two consumers can never drift.
        recorder.onSystemLevel = { [weak self] db in
            guard let self = self else { return }
            self.latestSystemLevelDb = db
            self.silenceDetector?.observeSystem(db: Double(db))
        }
    }

    private func disarmSilenceDetector() {
        recorder.onMicLevel = nil
        recorder.onSystemLevel = nil
        silenceDetector = nil
    }

    private func handleSilenceNotify() {
        Log.writeLine("daemon", "silence: 90s — surfacing 'still meeting?' banner")
        Log.event(category: "coordinator", action: "silence_notified")
        notifier.notifyStillMeeting()
    }

    private func handleSilenceAutoStop() {
        guard case .recording(let file, let src, let mode) = stateMachine.current else { return }
        Log.writeLine("daemon", "silence: 5min — auto-stopping recording")
        Log.event(category: "coordinator", action: "auto_stop_silence", attributes: [
            "bundle_id": src?.bundleID ?? "manual",
            "file": file.lastPathComponent,
        ])
        stopRecording(file: file, source: src, summaryMode: mode)
    }

    // MARK: - MicGate engage (TECH-G-MIC + TECH-C13)

    /// Walk the AX tree for the active meeting, build the
    /// `LifecycleAdapterHandle` + `MicGateAdapterHandle`, and engage
    /// both subsystems. Manual / browser-no-AX sources still call this:
    /// the builder returns empty handles in those cases and the
    /// subsystems fall through to HAL VAD + RMS only. Also primes the
    /// silence-backstop state for the new meeting.
    private func engageMicGate(source: AppSource?) {
        silenceBackstop.reset()
        latestSystemLevelDb = -120
        guard liveHonorAppMute, let source = source else { return }
        guard let handles = MeetingAXHandleBuilder.build(source: source, catalogue: muteLabels) else {
            Log.event(category: "coordinator", action: "micgate_engage_skipped", attributes: [
                "bundle_id": source.bundleID,
                "reason": "no_pid",
            ])
            return
        }
        do {
            try micGate.start(context: handles.context, handle: handles.micGate)
        } catch {
            Log.event(category: "coordinator", action: "micgate_start_failed", attributes: [
                "bundle_id": source.bundleID,
                "error": error.localizedDescription,
            ])
        }

        // Reactive AX subscription for mute buttons that only appear
        // after recording-start (Teams 2 compact view, etc.). Each
        // newly-discovered button gets its own AXMuteButtonProbe;
        // events flow back into MicGate's state via injectAxMuteEvent.
        let watcher = MeetingAXWindowWatcher(
            pid: handles.context.pid,
            bundleID: handles.context.bundleID,
            catalogue: muteLabels,
            axBus: axBus,
            eventLog: LogEventAdapter(),
            onMuteEvent: { [weak self] event in
                self?.micGate.injectAxMuteEvent(event)
            }
        )
        watcher.start()
        axWindowWatcher = watcher
    }

    // MARK: - Lifecycle discovery (TECH-C13)

    /// Watcher callback: a discovery scan found a winning meeting
    /// source. Engage the lifecycle subsystem for it when we are idle
    /// and the bundle is not in its post-meeting cooldown. The
    /// `.starting` verdict the adapter then produces raises the prompt.
    private func handleDiscovery(_ source: AppSource) {
        guard stateMachine.isAcceptingPrompts else { return }
        if stateMachine.isCoolingDown(
            bundleID: source.bundleID,
            cooldownSec: liveRepromptCooldownSec
        ) {
            return
        }
        engageLifecycle(for: source)
    }

    /// Walk the meeting app's AX tree and engage the lifecycle adapter
    /// so it fuses PRIMARY signals into the verdict stream. Replaces the
    /// recording-time engage that used to live in `engageMicGate`.
    private func engageLifecycle(for source: AppSource) {
        guard let handles = MeetingAXHandleBuilder.build(source: source, catalogue: muteLabels) else {
            Log.event(category: "coordinator", action: "lifecycle_engage_skipped", attributes: [
                "bundle_id": source.bundleID,
                "reason": "no_pid",
            ])
            return
        }
        do {
            try lifecycleCoord.engage(context: handles.context, handle: handles.lifecycle)
        } catch {
            Log.event(category: "coordinator", action: "lifecycle_engage_failed", attributes: [
                "bundle_id": source.bundleID,
                "error": error.localizedDescription,
            ])
        }
    }

    /// Re-walk the meeting AX tree at recording-start and late-arm the
    /// lifecycle adapter's Leave-button signal. `engageLifecycle` runs
    /// at discovery time, before the call UI renders, so the Leave
    /// button is usually absent then (`ax_handles_built` logs
    /// `found_leave:false`); by recording-start it exists. The
    /// re-walk's `ax_handles_built` event records that second reading.
    /// Idempotent: `armLeaveButton` is a no-op when the signal already
    /// armed at engage time; a still-missing button leaves the
    /// recording on the silence backstop, as before.
    private func armLifecycleLeaveButton(source: AppSource?) {
        guard let source = source else { return }
        guard let handles = MeetingAXHandleBuilder.build(source: source, catalogue: muteLabels),
              let leaveButton = handles.lifecycle.leaveButton else {
            return
        }
        lifecycleCoord.armLeaveButton(leaveButton)
    }

    /// Tear down the lifecycle adapter + reset the engine. Wired to the
    /// state machine's idle transition so every path back to idle
    /// disengages exactly once.
    private func disengageLifecycle() {
        lifecycleCoord.disengage()
    }

    /// Bridge a lifecycle verdict's `MeetingLifecycleContext` back into
    /// an `AppSource` for the prompt + workflow matcher. The context
    /// has no display name (resolved here via `NSRunningApplication`)
    /// and its title is best-effort, so the meeting title is re-walked
    /// synchronously for the workflow matcher's title rules.
    private func appSource(from context: MeetingLifecycleContext) -> AppSource {
        let kind: AppSourceKind = context.kind == .browser ? .browser : .native
        let displayName = NSRunningApplication(processIdentifier: context.pid)?
            .localizedName ?? context.bundleID
        let title = MeetingTitleResolver.resolve(
            bundleID: context.bundleID,
            kind: kind,
            pid: context.pid
        )
        return AppSource(
            bundleID: context.bundleID,
            displayName: displayName,
            kind: kind,
            meetingTitle: title
        )
    }
}

/// Bridge between `MeetingPipeCore`'s `EventLog` protocol and the
/// daemon-side `Log.event(...)` sink. `MeetingPipeCore` doesn't link
/// against `Logger.swift` so it can't call `Log.event` directly;
/// adapters and coordinators receive this concrete forwarder at
/// construction time.
private final class LogEventAdapter: EventLog {
    func emit(category: String, action: String, attributes: [String: Any]) {
        Log.event(category: category, action: action, attributes: attributes)
    }
}

extension Coordinator {

    private func handleMeetingStarted(source: AppSource) {
        guard stateMachine.isAcceptingPrompts else { return }

        // Auto-consent (config or persisted "Always").
        if liveAutoConsentApps.contains(source.bundleID) ||
           consent.isAutoConsented(bundleID: source.bundleID) {
            Log.writeLine("daemon", "auto-consent → recording (\(source.bundleID))")
            Log.event(category: "coordinator", action: "auto_consent", attributes: [
                "bundle_id": source.bundleID,
            ])
            beginRecording(source: source, summaryMode: .auto)
            return
        }

        stateMachine.setPrompting(source: source)
        statusBar.setPrompting(source)
        // On-screen panel is the primary surface (Notion-style top-right
        // floating window). Banner notification stays disabled by default —
        // the panel doesn't get suppressed under Focus modes and is harder
        // to miss. If the user wants OS-level persistence too, flip the
        // notifier call back on here.
        //
        // TECH-B5: pass the resolved workflow + the full set so the chip
        // can render the current match and the popup menu can show every
        // workflow as an override option.
        let promptWorkflow = workflowForPrompt(source: source)
        promptWindow.present(
            source: source,
            workflow: promptWorkflow,
            availableWorkflows: workflowStore.workflows,
            autoDismissAfter: livePromptTimeoutSec
        )
        startPromptTimeout(for: source)
        Log.writeLine("daemon", "meeting detected → prompting (\(source.bundleID))")
        Log.event(category: "coordinator", action: "prompt_shown", attributes: [
            "bundle_id": source.bundleID,
            "display_name": source.displayName,
            "timeout_sec": livePromptTimeoutSec,
        ])
    }

    private func handleMeetingEnded() {
        switch stateMachine.current {
        case .recording(let file, let src, let mode):
            stopRecording(file: file, source: src, summaryMode: mode)
        case .prompting, .suppressed:
            handleMeetingEndedDuringPrompt()
        default:
            break
        }
    }

    /// Dismiss a stale prompt when the meeting ends before the user
    /// answers. Reached via the lifecycle `.ended` verdict.
    private func handleMeetingEndedDuringPrompt() {
        switch stateMachine.current {
        case .prompting, .suppressed:
            stateMachine.cancelPromptTimeout()
            promptWindow.dismiss()
            stateMachine.setIdle()
            statusBar.setIdle()
        default:
            break
        }
    }
}

extension Coordinator: NotifierDelegate {
    func notifier(_ notifier: Notifier, didChooseRecord source: AppSource) {
        guard case .prompting(let pending) = stateMachine.current, pending == source else { return }
        beginRecording(source: source, summaryMode: .auto)
    }

    func notifier(_ notifier: Notifier, didChooseSkip source: AppSource) {
        guard case .prompting(let pending) = stateMachine.current, pending == source else { return }
        stateMachine.cancelPromptTimeout()
        stateMachine.setSuppressed(source: source)
        statusBar.setIdle()
        // Skip is a "don't ask again about this call" signal, so we
        // also gate near-future detections of the same bundle. The
        // `suppressed` state already covers the current call (until
        // the detector reports `.ended`), but post-call mic flickers
        // can fire a fresh `.started` after the suppression lifts.
        stateMachine.recordCooldownEnd(bundleID: source.bundleID)
        Log.writeLine("daemon", "user skipped (\(source.bundleID))")
        Log.event(category: "coordinator", action: "user_skipped", attributes: [
            "bundle_id": source.bundleID,
        ])
    }

    func notifier(_ notifier: Notifier, didChooseAlways source: AppSource) {
        consent.setAutoConsented(bundleID: source.bundleID, value: true)
        Log.writeLine("daemon", "user always-consented (\(source.bundleID))")
        Log.event(category: "coordinator", action: "user_consented_always", attributes: [
            "bundle_id": source.bundleID,
        ])
        // Drop the cooldown entry for the same reason as the manual
        // hotkey path: an explicit "yes, record this and the next one
        // too" mustn't be blocked by a stale skip/end from earlier in
        // the session.
        stateMachine.clearCooldown(bundleID: source.bundleID)
        beginRecording(source: source, summaryMode: .auto)
    }

    func notifier(_ notifier: Notifier, didOpenPage url: URL) {
        NSWorkspace.shared.open(url)
    }

    func notifier(
        _ notifier: Notifier,
        didRequestEditSummaryFor stem: String,
        recordingsDir: URL
    ) {
        CorrectionWindow.present(stem: stem, recordingsDir: recordingsDir)
    }

    func notifier(
        _ notifier: Notifier,
        didMarkLooksGoodFor stem: String,
        recordingsDir: URL
    ) {
        // Inline write of a verdict-good correction record. Reads the
        // run sidecar (for backend + model_id) and the summary JSON
        // (for the original_summary blob) so the file is self-contained
        // for Phase 3 training. A failure here is logged, not
        // user-visible: the user already clicked "Looks good" and would
        // rather have a silent miss than a banner about a sidecar.
        let runURL = recordingsDir.appendingPathComponent("\(stem).run.json")
        let summaryURL = recordingsDir.appendingPathComponent("\(stem).summary.json")
        do {
            let run = try CorrectionStore.loadRunSidecar(at: runURL)
            let summary = try CorrectionStore.loadOriginalSummary(at: summaryURL)
            let backend = (run["backend"] as? String) ?? ""
            let model = (run["model"] as? String) ?? ""
            let transcriptPath = (run["transcript_path"] as? String) ?? ""
            let summaryJsonPath = (run["summary_json_path"] as? String) ?? summaryURL.path
            let written = try CorrectionStore.write(
                stem: stem,
                transcriptPath: transcriptPath,
                summaryJsonPath: summaryJsonPath,
                modelId: model,
                backend: backend,
                verdict: .good,
                originalSummary: summary
            )
            Log.writeLine("daemon", "correction saved → \(written.lastPathComponent) verdict=good")
            Log.event(category: "correction", action: "saved", attributes: [
                "stem": stem,
                "verdict": "good",
                "backend": backend,
                "model_id": model,
            ])
        } catch {
            Log.main.warning(
                "Looks good: failed to record correction for \(stem): \(error.localizedDescription)"
            )
            Log.event(category: "correction", action: "failed", attributes: [
                "stem": stem,
                "verdict": "good",
                "error": error.localizedDescription,
            ])
        }
    }

    func notifierDidRequestScreenRecordingSettings(_ notifier: Notifier) {
        SystemAudioCapture.openScreenRecordingSettings()
    }

    func notifierDidRequestAccessibilitySettings(_ notifier: Notifier) {
        // `Privacy_Accessibility` is the documented anchor for the
        // Accessibility pane in System Settings (Ventura+); the legacy
        // panel URL is the macOS 12 fallback. NSWorkspace.open returns
        // false if the URL can't resolve, so try the modern one first
        // and fall back.
        let modern = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(modern) {
            let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess")!
            NSWorkspace.shared.open(legacy)
        }
    }

    func notifierDidRequestStopRecording(_ notifier: Notifier) {
        // Reuse `toggleManual` so the stop path is identical to the
        // hotkey-stop and recorder-HUD-stop surfaces — one entry point.
        if case .recording = stateMachine.current { toggleManual() }
    }
}

extension Coordinator: MeetingPromptDelegate {
    // The on-screen panel re-uses the same outcome semantics as the banner
    // notification path. Funnel both into the existing handlers so the state
    // machine sees one entry point per outcome.
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseRecord source: AppSource) {
        notifier(notifier, didChooseRecord: source)
    }
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseSkip source: AppSource) {
        notifier(notifier, didChooseSkip: source)
    }
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseAlways source: AppSource) {
        notifier(notifier, didChooseAlways: source)
    }
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseRecordBYO source: AppSource) {
        guard case .prompting(let pending) = stateMachine.current, pending == source else { return }
        beginRecording(source: source, summaryMode: .byo)
    }

    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseWorkflow id: UUID?) {
        // Stash the override so the next beginRecording's matcher call
        // resolves to the user's pick. Cleared after consumption inside
        // beginRecording so a dismissed prompt can't leak a stale pick
        // into the next meeting.
        setPendingWorkflowOverride(id)
        Log.event(category: "workflow", action: "override_picked", attributes: [
            "workflow_id": id?.uuidString ?? NSNull(),
        ])
    }
}

extension Coordinator: RecordingHUDDelegate {
    func recordingHUDDidRequestStop(_ hud: RecordingHUDWindow) {
        // Reuse the existing toggle path so manual-stop, hotkey-stop, and
        // HUD-stop all flow through one state-machine entry.
        toggleManual()
    }
}
