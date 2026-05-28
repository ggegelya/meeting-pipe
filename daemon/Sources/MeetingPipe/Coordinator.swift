import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import MeetingPipeCore

/// Top-level state owner: detection + hotkey events come in, the state
/// machine drives, the recorder/notifier/HUD act. All public methods run
/// on the main queue.
final class Coordinator: NSObject {
    private let config: Config
    private let configStore: ConfigStore?
    private let statusBar: StatusBarController
    private let recorder: MeetingRecorder
    private let notifier: Notifier
    private let promptWindow: MeetingPromptWindow
    private let recordingHUD: RecordingHUDWindow
    /// Cold-start discovery: finds a meeting app and engages the lifecycle
    /// adapter; the `.starting` verdict raises the prompt (TECH-C13 step 5).
    private let discoveryWatcher = MeetingDiscoveryWatcher()
    private let hotkey: HotkeyManager
    private let consent: ConsentStore
    private let launcher: PipelineDriver
    private let preferencesWindow: PreferencesWindow?
    /// Daemon's primary UI for browsing past recordings.
    private let libraryWindow: LibraryWindow
    /// Observable mirror of recording state + processing queue +
    /// model-download progress; the library window reads it, the status
    /// bar writes it.
    private let libraryModel: LibraryWindowModel
    /// Owns every `AppState` transition, plus per-bundle cooldown and the
    /// prompt-timeout timer; Coordinator drives the UI surfaces off it.
    private let stateMachine = DetectionStateMachine()

    /// Pipeline-job queue + in-process transcription runner.
    private let sinkDispatcher: SinkDispatcher

    /// Wraps `sinkDispatcher`; owns per-job completion routing + the
    /// queue-depth surface (TECH-H1-FINISH). Built in `wireSubsystems()`.
    private var jobDispatcher: PipelineJobDispatcher!

    /// First-run onboarding window (TECH-UX1); retained while shown.
    private var onboardingController: OnboardingWindowController?

    /// Event-driven MicGate + Lifecycle stack (TECH-G-MIC + TECH-C13).
    /// MicGate fuses AX mute, HAL system-mute, HAL VAD, and per-buffer RMS
    /// into one verdict stream the recorder applies in place;
    /// MeetingLifecycleCoordinator owns the per-meeting AX lifecycle.
    private let halBus: CoreAudioHALBus
    private let axBus: AXObserverBus
    private let muteLabels: MuteLabels
    private let lifecycleCoord: MeetingLifecycleCoordinator
    private let micGate: MicGate
    /// Force-stops after `windowSeconds` of non-`.hot` MicGate verdicts
    /// while system audio is also silent: the "everyone left and the user
    /// forgot" case (TECH-C7).
    private let silenceBackstop: MicOnlySilenceBackstop

    /// Latest system-audio dBFS (from `recorder.onSystemLevel`), read by
    /// the silence backstop. `-120` is the "no audio observed yet" sentinel.
    private var latestSystemLevelDb: Float = -120

    /// Consumes `micGate.verdicts` (started in `start()`, cancelled at
    /// shutdown); forwards each to the recorder writer + silence backstop.
    private var verdictConsumerTask: Task<Void, Never>?

    /// Consumes `lifecycleCoord.verdicts`; routes `.ended` into the
    /// recording-end path.
    private var lifecycleConsumerTask: Task<Void, Never>?

    /// Observes window-created events so mute buttons that appear after
    /// `beginRecording` (Teams 2 compact view, PIP overlays) get watched
    /// too. Per-meeting (TECH-C14).
    private var axWindowWatcher: MeetingAXWindowWatcher?

    /// Per-context routing rules (TECH-B): TOML files under
    /// `~/.config/meeting-pipe/workflows/`. Published so the Workflows tab
    /// and the prompt chip can subscribe.
    let workflowStore: WorkflowStore

    /// Surfaces a missed meeting end (TECH-C2): notify after 90 s of
    /// mic+system silence, auto-stop after 5 min. Lives for the recording.
    private var silenceDetector: SilenceDetector?

    /// Gate the "Screen Recording disabled" banner to once per launch.
    private var didNotifyAboutPermissionDenial: Bool = false

    /// Workflow for the in-flight recording (TECH-B3); nil between
    /// meetings. Read by `writeMetaSidecar`, cleared after flush.
    private var activeWorkflow: Workflow?

    /// User's explicit workflow pick from the prompt chevron (TECH-B5),
    /// consumed by the next `beginRecording`. Highest matcher precedence,
    /// so it wins over rule matches.
    private var pendingWorkflowOverride: UUID?

    /// Dry-run (`MEETING_PIPE_DRY_RUN`): detection runs and logs, but the
    /// recorder never starts. Verify detection accuracy without producing
    /// audio. Read once at init.
    private let dryRun: Bool = (ProcessInfo.processInfo.environment["MEETING_PIPE_DRY_RUN"] == "1")

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
        // FluidAudio is the only ASR path: in-process Parakeet TDT +
        // pyannote on the ANE; Python does summarize + publish only.
        let runner = TranscriptionService.makeRunner()
        Log.event(category: "transcription", action: "engine_resolved", attributes: [
            "engine": runner.backendName,
        ])
        self.sinkDispatcher = SinkDispatcher(
            launcher: resolvedLauncher,
            transcriptionRunner: runner
        )
        // PreferencesWindow needs both stores; without them (test/headless)
        // the menu item is a no-op instead of a crash.
        if let configStore = configStore, let secretsStore = secretsStore {
            self.preferencesWindow = PreferencesWindow(store: configStore, secrets: secretsStore)
        } else {
            self.preferencesWindow = nil
        }
        // Snapshot the recordings dir at init for the library root; a live
        // change needs a daemon restart for the library window (rare).
        let recordingsDir: URL = {
            if let raw = configStore?.outputDirPath {
                return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            }
            return config.recording.outputDir
        }()
        let libraryModel = LibraryWindowModel(recordingsDir: recordingsDir)
        self.libraryModel = libraryModel
        self.libraryWindow = LibraryWindow(model: libraryModel)
        // Load workflows synchronously so the matcher (TECH-B3) and
        // Workflows tab see them on first detection (TECH-B1). The migrator
        // seeds a "General" workflow from legacy team_context if empty
        // (TECH-B2) so behaviour is unchanged for existing installs.
        let workflowStore = WorkflowStore()
        workflowStore.load()
        WorkflowMigrator.runIfNeeded(
            store: workflowStore,
            configStore: configStore,
            config: config
        )
        self.workflowStore = workflowStore
        libraryModel.workflowStore = workflowStore

        // Shared HAL + AX buses centralise CoreAudio/AX registrations;
        // adapters dispatch per-bundle. LogEventAdapter bridges
        // MeetingPipeCore telemetry into events.jsonl.
        let logAdapter = LogEventAdapter()
        let halBus = CoreAudioHALBus(backend: RealCoreAudioBackend(), eventLog: logAdapter)
        let axBus = AXObserverBus(backend: RealAXBackend(), eventLog: logAdapter)
        let muteLabels: MuteLabels
        do {
            muteLabels = try MuteLabelsLoader.loadDefault()
        } catch {
            // Missing/malformed resource: run with an empty catalogue. AX
            // mute matching no-ops; HAL VAD + RMS still drive the gate.
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
                NativeLifecycleAdapter(config: .teams, halBus: halBus, axBus: axBus, eventLog: logAdapter),
                NativeLifecycleAdapter(config: .zoom, halBus: halBus, axBus: axBus, eventLog: logAdapter),
                NativeLifecycleAdapter(config: .webex, axBus: axBus, eventLog: logAdapter),
                NativeLifecycleAdapter(config: .slack, axBus: axBus, eventLog: logAdapter),
                BrowserMeetingLifecycleAdapter(axBus: axBus, eventLog: logAdapter),
            ]
        )
        self.micGate = MicGate(
            catalogue: muteLabels,
            halBus: halBus,
            axBus: axBus,
            eventLog: logAdapter,
            adapters: [
                NativeMuteAdapter(config: .teams, axBus: axBus, catalogue: muteLabels, eventLog: logAdapter),
                NativeMuteAdapter(config: .zoom, axBus: axBus, catalogue: muteLabels, eventLog: logAdapter),
                NativeMuteAdapter(config: .webex, axBus: axBus, catalogue: muteLabels, eventLog: logAdapter),
                NativeMuteAdapter(config: .slack, axBus: axBus, catalogue: muteLabels, eventLog: logAdapter),
                NoOpMuteAdapter(config: .meet, eventLog: logAdapter),
                NoOpMuteAdapter(config: .browser, eventLog: logAdapter),
            ]
        )
        // TECH-C7 window from TOML; built once, so edits apply next meeting.
        let micOnlySilenceSec = configStore?.micOnlySilenceSec ?? config.detection.micOnlySilenceSec
        self.silenceBackstop = MicOnlySilenceBackstop(windowSeconds: micOnlySilenceSec)

        super.init()
        // Post-super.init: wire the model + status bar back to self.
        libraryModel.coordinator = self
        statusBar.libraryModel = libraryModel
        wireSubsystems()
    }

    /// Bind subsystem callbacks back to self. Post-super.init so self is valid.
    private func wireSubsystems() {
        stateMachine.onIdleTransition = { [weak self] in
            // Every path back to idle (record then stop, skip, prompt
            // timeout, stale-prompt end) tears down the lifecycle
            // adapter through this single hook.
            self?.disengageLifecycle()
        }
        // PipelineJobDispatcher wraps the SinkDispatcher queue and owns
        // the per-job completion routing (done notification + error
        // banner) and the queue-depth badge. Constructing it here wires
        // the dispatcher callbacks at the same point the inline closures
        // used to be set (TECH-H1-FINISH).
        jobDispatcher = PipelineJobDispatcher(
            sinkDispatcher: sinkDispatcher,
            onDone: { [weak self] stem, recordingsDir, pageURL in
                self?.libraryModel.activeProcessing = nil
                self?.notifier.notifyDone(
                    stem: stem,
                    recordingsDir: recordingsDir,
                    pageURL: pageURL
                )
            },
            onError: { [weak self] message in
                self?.libraryModel.activeProcessing = nil
                self?.notifier.notifyError(message)
            },
            onQueueDepth: { [weak self] depth in self?.statusBar.setProcessingCount(depth) },
            onProgress: { [weak self] stem, progress in
                // Live pipeline progress for the row (TECH-UX5). Preserve a
                // prior stalled flag if a late beat arrives after stalling.
                self?.libraryModel.activeProcessing = ActiveProcessing(
                    stem: stem,
                    stage: progress.stage,
                    elapsedSec: progress.elapsedSec,
                    stalled: false
                )
            },
            onStalled: { [weak self] stem in
                guard let self = self else { return }
                let prior = self.libraryModel.activeProcessing
                self.libraryModel.activeProcessing = ActiveProcessing(
                    stem: stem,
                    stage: prior?.stem == stem ? (prior?.stage ?? "") : "",
                    elapsedSec: prior?.stem == stem ? (prior?.elapsedSec ?? 0) : 0,
                    stalled: true
                )
            }
        )
        // MicGate consumes the recorder's per-buffer mic RMS; the gate
        // is allocation-free and defers its publish off the render
        // thread, so calling from the audio tap is safe.
        recorder.onMicRmsDb = { [weak self] db in
            self?.micGate.ingest(rmsDb: db)
        }
        // Surface a mid-recording input device change. The recorder
        // re-arms capture where it can; this just tells the user.
        recorder.onConfigurationChange = { [weak self] outcome in
            guard let self = self else { return }
            switch outcome {
            case .resumed: self.notifier.notifyCaptureRecovered()
            case .failed:  self.notifier.notifyCaptureLost()
            }
        }
        // Surface a system-audio (SCStream) failure on the HUD during the
        // meeting (TECH-UX4) instead of leaving the user to discover a
        // half-empty recording afterwards.
        recorder.onSystemAudioDegraded = { [weak self] reason in
            guard let self = self else { return }
            Log.event(category: "recording", action: "degraded", attributes: ["reason": reason])
            self.recordingHUD.showSystemAudioDegraded()
        }
        recorder.onSystemAudioRecovered = { [weak self] in
            guard let self = self else { return }
            Log.event(category: "recording", action: "recovered", attributes: [:])
            self.recordingHUD.clearSystemAudioDegraded()
        }
        // Route the one-shot backstop trigger through forceStop (on main)
        // so the event log records the reason.
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

        // Drive the recorder writer + silence backstop from the gate's
        // verdict stream (unbounded, daemon-lifetime; cancelled in shutdown).
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

        // Lifecycle verdicts: `.starting` raises the prompt,
        // `.endingProvisional` triggers the compact-view rescue re-walk,
        // `.ended` closes the recording or dismisses a stale prompt.
        lifecycleConsumerTask = Task { [weak self] in
            guard let self = self else { return }
            for await verdict in self.lifecycleCoord.verdicts {
                await MainActor.run {
                    switch verdict {
                    case .starting(let context):
                        self.handleMeetingStarted(source: self.appSource(from: context))
                    case .endingProvisional(let context, _):
                        self.rescueProvisionalEnd(context: context)
                    case .ended:
                        self.handleMeetingEnded()
                    default:
                        break
                    }
                }
            }
        }

        // Funnel every TCC dialog through PermissionsCenter so the
        // Preferences tab and startup share one published state, and the
        // prompts surface in the first seconds instead of across the first
        // recording.
        requestPermissionsAtStartup()

        if dryRun {
            Log.main.info("MEETING_PIPE_DRY_RUN=1: detection enabled, recorder disabled")
            Log.writeLine("daemon", "[dry-run] enabled")
            Log.event(category: "coordinator", action: "dry_run_enabled")
        }

        discoveryWatcher.onDiscovered = { [weak self] source in
            self?.handleDiscovery(source)
        }
        discoveryWatcher.start()

        if let parsed = HotkeyManager.parse(liveManualHotkey) {
            hotkey.register(keyCode: parsed.keyCode, modifiers: parsed.modifiers) { [weak self] in
                DispatchQueue.main.async { self?.toggleManual() }
            }
            Log.main.info("Hotkey registered: \(self.liveManualHotkey)")
        } else {
            Log.main.warning("Could not parse hotkey: \(self.liveManualHotkey)")
        }

        // Stop-only hotkey (TECH-C5): distinct from the toggle so a
        // panic-press can never start a recording, and logged with its own
        // event action.
        if liveForceStopHotkey == liveManualHotkey {
            Log.main.warning("Force-stop hotkey matches manual hotkey - skipping second registration")
        } else if let parsed = HotkeyManager.parse(liveForceStopHotkey) {
            hotkey.register(keyCode: parsed.keyCode, modifiers: parsed.modifiers) { [weak self] in
                DispatchQueue.main.async { self?.forceStop(reason: "hotkey") }
            }
            Log.main.info("Force-stop hotkey registered: \(self.liveForceStopHotkey)")
        } else {
            Log.main.warning("Could not parse force-stop hotkey: \(self.liveForceStopHotkey)")
        }

        // Seed the regulated-mode glyph, wire the model-download status,
        // run the eager local-model prefetch, and subscribe to config
        // persistence. Owned by ConfigRefreshCoordinator (TECH-H1-FINISH).
        configRefresh.start()

        // Re-evaluate detection the moment Mic/Accessibility flip on, so a
        // daemon restarted mid-meeting (the typical AX-grant flow) doesn't
        // wait for the next Workspace notification.
        permissionGrantedCancellable = PermissionsCenter.shared.permissionGranted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] kind in
                guard let self = self else { return }
                Log.main.info("permission granted: \(kind.displayName) - re-evaluating detector")
                Log.event(category: "coordinator", action: "permission_granted", attributes: [
                    "kind": kind.rawValue,
                ])
                self.discoveryWatcher.refreshNow()
                self.statusBar.refreshMenuForPermissionChange()
            }

        // Re-enqueue recordings orphaned by a mid-recording termination
        // (crash, kill, rebuild, reinstall restart).
        recoverOrphanedRecordings()
    }

    /// Fire every startup TCC dialog in order. macOS serializes the prompts
    /// internally, but they all surface in the first few seconds; the
    /// Preferences Permissions tab is the surface for re-prompting later.
    private func requestPermissionsAtStartup() {
        Task { @MainActor in
            await PermissionsCenter.shared.requestNotifications()
            await PermissionsCenter.shared.requestMic()
            // Re-runs the SCShareableContent prewarm App.swift already
            // triggered, so the published state is current.
            await PermissionsCenter.shared.requestScreenRecording()
            // Granting AX requires a daemon restart for trust to propagate;
            // the notifier banner explains that.
            _ = PermissionsCenter.shared.requestAccessibility()
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
        // The prompt was already surfaced by requestAccessibility(); here we
        // only log the verdict and raise the fallback banner if still
        // untrusted.
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
            // Best-effort flush so we don't orphan recording state.
            let recorder = self.recorder
            Task { await recorder.stop() }
        }
    }

    /// Re-enqueue recordings orphaned by a mid-recording termination
    /// (crash, kill, rebuild, reinstall restart) that left unmerged
    /// `.mic.wav`/`.system.wav` intermediates. Snapshot synchronously
    /// before discovery so a live recording's intermediates aren't seen as
    /// orphans; the ffmpeg merges run off-main so the menu bar isn't stalled.
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
                self.jobDispatcher.enqueue(file: url, summaryMode: .auto)
            }
        }
    }

    /// System channel "carries audio" above this 1 s RMS floor. Mirrors
    /// `SilenceDetector.defaultThresholdDb` so the backstop and the 5-min
    /// auto-stop draw the same line.
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

    /// Deeplink to the Preferences Permissions section (from the warning
    /// row and the mic-permission-blocked path).
    @objc func menuPreferencesPermissions() {
        preferencesWindow?.show(initial: .permissions)
    }

    @objc func menuOpenLibrary() {
        libraryWindow.show()
    }

    @objc func menuQuickFind() {
        quickFindWindow.show()
    }

    /// Open the Library window and select the given stem (from Quick Find).
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

    /// Post-recording meeting operations (TECH-H1-FINISH); the methods
    /// below forward to it so external callers keep the Coordinator API.
    private lazy var library = MeetingLibraryService(
        outputDir: { [weak self] in
            self?.liveOutputDir ?? URL(fileURLWithPath: NSTemporaryDirectory())
        },
        launcher: launcher,
        notifyError: { [weak self] message in self?.notifier.notifyError(message) },
        enqueue: { [weak self] file, mode in
            self?.jobDispatcher.enqueue(file: file, summaryMode: mode)
        },
        summarizationBackend: { [weak self] in
            self?.configStore?.summarizationBackend ?? "anthropic"
        }
    )

    /// Config-change responses: eager local-model prefetch, model-download
    /// status surface, regulated-mode glyph, and the `didPersist`
    /// subscription. Extracted in TECH-H1-FINISH; started from `start()`.
    private lazy var configRefresh = ConfigRefreshCoordinator(
        configStore: configStore,
        onModelDownloadState: { [weak self] state in self?.statusBar.setModelDownload(state) },
        onRegulatedMode: { [weak self] flag in self?.statusBar.setRegulatedMode(flag) }
    )

    func retryMeeting(stem: String) -> Result<Void, Error> {
        library.retryMeeting(stem: stem)
    }

    func regenerateMeeting(
        stem: String,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        library.regenerateMeeting(stem: stem, completion: completion)
    }

    func softDeleteMeeting(stem: String) -> Result<Void, Error> {
        library.softDeleteMeeting(stem: stem)
    }

    func exportMeeting(stem: String, to destination: URL) -> Result<Int, Error> {
        library.exportMeeting(stem: stem, to: destination)
    }

    func republishMeeting(
        stem: String,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        library.republishMeeting(stem: stem, completion: completion)
    }

    func publishFromPaste(
        stem: String,
        summaryText: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        library.publishFromPaste(stem: stem, summaryText: summaryText, completion: completion)
    }

    /// Cancel the active pipeline subprocess (TECH-UX5), e.g. from a stalled row.
    func cancelActiveJob() {
        jobDispatcher.cancelActive()
    }

    // MARK: - Local re-run summary preview (TECH-A16)

    /// Configured summarization backend, so the UI can gate the local re-run
    /// preview to `local` / `apple_intelligence`.
    var summarizationBackend: String {
        configStore?.summarizationBackend ?? "anthropic"
    }

    func previewSummary(stem: String, completion: @escaping (Result<Void, Error>) -> Void) {
        library.previewSummary(stem: stem, completion: completion)
    }

    @discardableResult
    func keepCandidateSummary(stem: String) -> Result<Void, Error> {
        library.keepCandidate(stem: stem)
    }

    func discardCandidateSummary(stem: String) {
        library.discardCandidate(stem: stem)
    }

    /// Show the first-run onboarding window unless it has already been completed
    /// (TECH-UX1). The flow requests each TCC one at a time, so the caller skips
    /// the startup permission prewarm on a fresh install.
    func presentOnboardingIfNeeded() {
        guard !OnboardingGate.isCompleted else { return }
        let controller = OnboardingWindowController(deps: OnboardingDependencies(
            workflowStore: workflowStore,
            toggleRecording: { [weak self] in self?.menuStart() },
            isRecording: { [weak self] in self?.recorder.isRecording ?? false }
        ))
        onboardingController = controller
        controller.show()
    }

    @objc func menuOpenScreenRecordingSettings() {
        SystemAudioCapture.openScreenRecordingSettings()
    }

    /// "Quit (do not relaunch)" (TECH-UX7): a one-off quit that suppresses the
    /// LaunchAgent relaunch even when the auto-restart preference is on.
    @objc func menuQuitWithoutRelaunch() {
        AppDelegate.pendingRelaunchOverride = false
        NSApp.terminate(nil)
    }

    /// Open the correction sheet for the stem in the menu item's
    /// `representedObject` (submenu built from `recentCorrectableMeetings()`).
    @objc func menuRecentMeeting(_ sender: NSMenuItem) {
        guard let stem = sender.representedObject as? String else { return }
        CorrectionWindow.present(stem: stem, recordingsDir: liveOutputDir)
    }

    func recentCorrectableMeetings(limit: Int = 10) -> [(stem: String, displayName: String)] {
        library.recentCorrectableMeetings(limit: limit)
    }

    func failedMeetingCount() -> Int {
        library.failedMeetingCount()
    }

    // MARK: Live-config readers
    //
    // Prefer the ConfigStore's current value over the boot-time `config`
    // snapshot, so Preferences edits apply without a daemon restart.

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
            // Keep the source so "Always for {App}" still attributes; clear
            // the cooldown so this explicit start isn't suppressed.
            promptWindow.dismiss()
            stateMachine.clearCooldown(bundleID: src.bundleID)
            beginRecording(source: src, summaryMode: .auto)
        case .recording(let file, let src, let mode):
            stopRecording(file: file, source: src, summaryMode: mode)
        case .stopping:
            // Mid-flush; a new start would race the await.
            break
        }
    }

    /// Stop-only entry (TECH-C5): never starts a recording from `.idle`, so
    /// a panic-press when nothing runs is a logged no-op. The detector
    /// state is preserved, so a fresh `.started` only fires after a real end.
    private func forceStop(reason: String) {
        Log.event(category: "coordinator", action: "force_stop", attributes: [
            "reason": reason,
            "state": DetectionStateMachine.label(stateMachine.current),
        ])
        switch stateMachine.current {
        case .recording(let file, let src, let mode):
            stopRecording(file: file, source: src, summaryMode: mode)
        case .prompting(let src):
            // Same as Skip: suppress until the detector sees this meeting end.
            stateMachine.cancelPromptTimeout()
            promptWindow.dismiss()
            stateMachine.setSuppressed(source: src)
            statusBar.setIdle()
        case .idle, .suppressed, .stopping:
            break
        }
    }

    /// Pin the next recording to a workflow (prompt chevron, TECH-B5).
    /// Consumed by the next `beginRecording`.
    func setPendingWorkflowOverride(_ id: UUID?) {
        pendingWorkflowOverride = id
    }

    /// Workflow for the in-flight recording, for the HUD/status-bar chip.
    var currentActiveWorkflow: Workflow? { activeWorkflow }

    /// Workflow that would apply to `source` now (for the prompt chip);
    /// falls back to the default when nothing matches.
    func workflowForPrompt(source: AppSource?) -> Workflow? {
        return WorkflowMatcher.resolve(
            source: source,
            overrideID: pendingWorkflowOverride,
            workflows: workflowStore.workflows
        )
    }

    private func beginRecording(source: AppSource?, summaryMode: SummaryMode) {
        stateMachine.cancelPromptTimeout()

        // Mic is non-negotiable (no mic = silent recording, empty
        // transcript); Screen Recording stays optional. Re-probe
        // synchronously so a just-granted permission counts without restart.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus != .authorized {
            Log.main.warning("beginRecording aborted: microphone permission missing")
            Log.event(category: "coordinator", action: "recording_blocked", attributes: [
                "reason": "mic_permission",
                "status": "\(micStatus.rawValue)",
            ])
            notifier.notifyError("Microphone permission is required. Grant it in Preferences → Permissions, then try again.")
            // Deeplink to the Permissions section so the user can act.
            menuPreferencesPermissions()
            stateMachine.setIdle()
            statusBar.setIdle()
            return
        }

        if dryRun {
            // Detection ran but we deliberately skip the recorder/HUD and
            // return to .idle, so a workday logs as detection-only signals.
            Log.writeLine("daemon", "[dry-run] would record (\(source?.bundleID ?? "manual"))")
            Log.event(category: "coordinator", action: "dry_run_would_record", attributes: [
                "bundle_id": source?.bundleID ?? "manual",
                "summary_mode": summaryMode == .byo ? "byo" : "auto",
            ])
            stateMachine.setIdle()
            statusBar.setIdle()
            return
        }

        // Resolve the workflow controlling context/backend/sinks (TECH-B3):
        // override, then rule matches, then default. Clear the override so
        // it can't leak into the next meeting.
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
            recordingHUD.present(
                source: source,
                workflow: resolvedWorkflow,
                startedAt: Date(),
                levelProvider: { [weak self] in self?.recorder.currentMicLevelDb() ?? -120 }
            )
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
            // Re-walk for the Leave button now the call UI has rendered;
            // the discovery-time walk usually runs too early to see it.
            armLifecycleLeaveButton(source: source)
            // Recorder armed: promote `.starting` to `.inMeeting` (no-op for
            // manual recordings and the prompt-answered-late race).
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
        // Tear down per-meeting AX subscriptions; the verdict stream stays
        // open for the next meeting.
        lifecycleCoord.disengage()
        micGate.stop()
        axWindowWatcher?.stop()
        axWindowWatcher = nil

        // recorder.stop is async (off the UI); once flushed, enqueue for the
        // pipeline and return to .idle so the next meeting can start.
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
            // Zero system-audio frames = lost the other side of the call;
            // always surface it. (A prior gate also required
            // `permissionState == .denied` and silently dropped the warning
            // when `.unknown`, the mic-only loss reported on May 5.) The
            // notifier shows "Open Settings" only when a perm change helps.
            if recorder.lastSystemFires == 0 {
                let perm = SystemAudioCapture.permissionState
                self.notifier.notifyMicOnlyRecording(file: file, permissionState: perm)
                if perm == .denied || perm == .unknown {
                    self.statusBar.refreshMenuForPermissionChange()
                }
            }
            self.writeMetaSidecar(file: file, source: source)
            self.notifier.notifyProcessing(file: file)
            self.jobDispatcher.enqueue(file: file, summaryMode: summaryMode)
            // Drop the workflow so it can't bleed into the next meeting.
            self.activeWorkflow = nil
            // Arm the re-prompt cooldown so a post-call mic grab (Teams chat,
            // Zoom teardown toast) can't re-prompt right after the flush.
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
                // Like an explicit Skip: arm the cooldown to absorb post-call
                // mic flickers once suppression lifts.
                self.stateMachine.recordCooldownEnd(bundleID: source.bundleID)
                self.statusBar.setIdle()
            }
        }
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
        // Recorder dispatches RMS callbacks to main, so touching the
        // detector directly here is safe.
        recorder.onMicLevel = { [weak self] db in
            self?.silenceDetector?.observeMic(db: Double(db))
        }
        // One callback site feeds both the detector and the backstop's
        // level mirror so the two can't drift.
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
        Log.writeLine("daemon", "silence: 90s - surfacing 'still meeting?' banner")
        Log.event(category: "coordinator", action: "silence_notified")
        notifier.notifyStillMeeting()
    }

    private func handleSilenceAutoStop() {
        guard case .recording(let file, let src, let mode) = stateMachine.current else { return }
        Log.writeLine("daemon", "silence: 5min - auto-stopping recording")
        Log.event(category: "coordinator", action: "auto_stop_silence", attributes: [
            "bundle_id": src?.bundleID ?? "manual",
            "file": file.lastPathComponent,
        ])
        stopRecording(file: file, source: src, summaryMode: mode)
    }

    // MARK: - MicGate engage (TECH-G-MIC + TECH-C13)

    /// Build the AX handles and engage MicGate; also primes the silence
    /// backstop. Manual / browser-no-AX sources fall through to HAL VAD +
    /// RMS only (empty handles).
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

        // Watch for mute buttons that appear after recording-start (Teams 2
        // compact view, etc.); events flow back via injectAxMuteEvent.
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

    /// Discovery found a meeting source: engage the lifecycle subsystem if
    /// idle and the bundle isn't in its post-meeting cooldown.
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

    /// Engage the lifecycle adapter so it fuses PRIMARY signals into the
    /// verdict stream.
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

    /// Late-arm the Leave-button signal at recording-start: the
    /// discovery-time walk usually runs before the call UI renders the
    /// button. Idempotent; a still-missing button leaves the recording on
    /// the silence backstop.
    private func armLifecycleLeaveButton(source: AppSource?) {
        guard let source = source else { return }
        guard let handles = MeetingAXHandleBuilder.build(source: source, catalogue: muteLabels),
              let leaveButton = handles.lifecycle.leaveButton else {
            return
        }
        lifecycleCoord.armLeaveButton(leaveButton)
    }

    /// Rescue a provisional end caused by the Teams 2 compact-view swap,
    /// which destroys the Leave button while the call continues. If a Leave
    /// button still exists (moved to the compact panel), re-arm on it so its
    /// healthy baseline flips back to `.inMeeting` before the debounce
    /// promotes to `.ended`. A genuine end finds none and proceeds.
    private func rescueProvisionalEnd(context: MeetingLifecycleContext) {
        guard context.kind == .native else { return }
        let axApp = AXUIElementCreateApplication(context.pid)
        let leaveButtons = MeetingAXHandleBuilder.findAllLeaveButtons(
            in: axApp,
            bundleID: context.bundleID
        )
        guard let leaveButton = leaveButtons.first else {
            Log.event(category: "coordinator", action: "lifecycle_provisional_end_confirmed", attributes: [
                "bundle_id": context.bundleID,
            ])
            return
        }
        Log.event(category: "coordinator", action: "lifecycle_provisional_end_rescued", attributes: [
            "bundle_id": context.bundleID,
            "leave_buttons_found": leaveButtons.count,
        ])
        lifecycleCoord.armLeaveButton(leaveButton)
    }

    /// Tear down the lifecycle adapter + reset the engine. Wired to the
    /// state machine's idle transition so every idle path disengages once.
    private func disengageLifecycle() {
        lifecycleCoord.disengage()
    }

    /// Bridge a lifecycle context back into an `AppSource` for the prompt +
    /// matcher: resolve the display name via `NSRunningApplication` and
    /// re-walk the title for the matcher's title rules.
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

/// Forwards `MeetingPipeCore`'s `EventLog` protocol to the daemon's
/// `Log.event`, which that module can't link against directly.
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
        // The on-screen panel is the primary surface (not suppressed under
        // Focus modes); the banner stays off by default. Pass the resolved
        // workflow + full set so the chip and override menu render (TECH-B5).
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
        // Skip = don't ask again for this call: also cool down the bundle so
        // a post-call mic flicker can't re-prompt once suppression lifts.
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
        // Explicit "always": clear the cooldown so a stale skip/end can't
        // block it (as with the manual hotkey path).
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
        // Write a verdict-good correction record (self-contained for Phase 3
        // training). Failure is logged, not surfaced: the user already
        // clicked "Looks good" and shouldn't get a sidecar banner.
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
        // Modern (Ventura+) anchor first, macOS 12 panel URL as fallback;
        // NSWorkspace.open returns false when a URL can't resolve.
        let modern = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(modern) {
            let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess")!
            NSWorkspace.shared.open(legacy)
        }
    }

    func notifierDidRequestStopRecording(_ notifier: Notifier) {
        // One stop entry point shared with hotkey-stop and HUD-stop.
        if case .recording = stateMachine.current { toggleManual() }
    }
}

extension Coordinator: MeetingPromptDelegate {
    // Panel and banner share one handler per outcome.
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
        // Stash the override for the next beginRecording's matcher.
        setPendingWorkflowOverride(id)
        Log.event(category: "workflow", action: "override_picked", attributes: [
            "workflow_id": id?.uuidString ?? NSNull(),
        ])
    }
}

extension Coordinator: RecordingHUDDelegate {
    func recordingHUDDidRequestStop(_ hud: RecordingHUDWindow) {
        // One stop entry point shared with manual-stop and hotkey-stop.
        toggleManual()
    }

    func recordingHUDDidRequestRetrySystemAudio(_ hud: RecordingHUDWindow) {
        // TECH-UX4: re-attempt SCStream capture; the recorder fires
        // onSystemAudioRecovered to clear the banner on success.
        recorder.retrySystemAudio()
    }
}
