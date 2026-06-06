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
    let config: Config
    let configStore: ConfigStore?
    let statusBar: StatusBarController
    let recorder: MeetingRecorder
    let notifier: Notifier
    let promptWindow: MeetingPromptWindow
    let recordingHUD: RecordingHUDWindow
    /// Cold-start discovery: finds a meeting app and engages the lifecycle
    /// adapter; the `.starting` verdict raises the prompt (TECH-C13 step 5).
    let discoveryWatcher = MeetingDiscoveryWatcher()
    let hotkey: HotkeyManager
    let consent: ConsentStore
    let launcher: PipelineDriver
    let preferencesWindow: PreferencesWindow?
    /// Daemon's primary UI for browsing past recordings.
    let libraryWindow: LibraryWindow
    /// Observable mirror of recording state + processing queue +
    /// model-download progress; the library window reads it, the status
    /// bar writes it.
    let libraryModel: LibraryWindowModel
    /// Owns every `AppState` transition, plus per-bundle cooldown and the
    /// prompt-timeout timer; Coordinator drives the UI surfaces off it.
    let stateMachine = DetectionStateMachine()

    /// Pipeline-job queue + in-process transcription runner.
    let sinkDispatcher: SinkDispatcher

    /// Wraps `sinkDispatcher`; owns per-job completion routing + the
    /// queue-depth surface (TECH-H1-FINISH). Built in `wireSubsystems()`.
    var jobDispatcher: PipelineJobDispatcher!

    /// Owns one meeting's lifetime (TECH-ARCH2): the verdict consumers, the
    /// record begin/stop path, prompt-timeout, silence + MicGate engage, and
    /// meta-sidecar writing. Built post-`super.init`; Coordinator forwards
    /// detection + delegate events here and keeps the subsystems + UI wiring.
    var session: MeetingSessionController!

    /// First-run onboarding window (TECH-UX1); retained while shown.
    var onboardingController: OnboardingWindowController?

    /// Event-driven MicGate + Lifecycle stack (TECH-G-MIC + TECH-C13).
    /// MicGate fuses AX mute, HAL system-mute, HAL VAD, and per-buffer RMS
    /// into one verdict stream the recorder applies in place;
    /// MeetingLifecycleCoordinator owns the per-meeting AX lifecycle.
    let halBus: CoreAudioHALBus
    let axBus: AXObserverBus
    let muteLabels: MuteLabels
    let lifecycleCoord: MeetingLifecycleCoordinator
    let micGate: MicGate
    /// Force-stops after `windowSeconds` of non-`.hot` MicGate verdicts
    /// while system audio is also silent: the "everyone left and the user
    /// forgot" case (TECH-C7).
    let silenceBackstop: MicOnlySilenceBackstop

    /// Per-context routing rules (TECH-B): TOML files under
    /// `~/.config/meeting-pipe/workflows/`. Published so the Workflows tab
    /// and the prompt chip can subscribe.
    let workflowStore: WorkflowStore

    /// Gate the "Screen Recording disabled" banner to once per launch.
    var didNotifyAboutPermissionDenial: Bool = false

    /// Dry-run (`MEETING_PIPE_DRY_RUN`): detection runs and logs, but the
    /// recorder never starts. Verify detection accuracy without producing
    /// audio. Read once at init.
    let dryRun: Bool = (ProcessInfo.processInfo.environment["MEETING_PIPE_DRY_RUN"] == "1")

    var permissionGrantedCancellable: AnyCancellable?

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
        // The meeting-lifetime owner (TECH-ARCH2); holds an unowned backref.
        session = MeetingSessionController(coordinator: self)
        wireSubsystems()
    }

    /// Bind subsystem callbacks back to self. Post-super.init so self is valid.
    private func wireSubsystems() {
        stateMachine.onIdleTransition = { [weak self] in
            // Every path back to idle (record then stop, skip, prompt
            // timeout, stale-prompt end) tears down the lifecycle
            // adapter through this single hook.
            self?.session.disengageLifecycle()
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
                // TECH-DSN5: opt-in, default-off completion tone (the summary is
                // ready). Never plays during a call; separate from the done
                // notification's sound, which Focus can suppress.
                if UISettings.shared.playCompletionTone {
                    NSSound(named: "Glass")?.play()
                }
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
        // MicGate consumes the recorder's per-buffer mic RMS on the
        // render thread. The RMS gate is allocation-free, and a verdict
        // change now defers its lock, the events.jsonl emit, and the
        // verdict-stream yield onto MicGate's serial queue, so nothing
        // touches the file system on this thread (TECH-CONC1).
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
                self?.session.forceStop(reason: "mic_only_silence")
            }
        }
    }

    func start() {
        notifier.delegate = self
        promptWindow.delegate = self
        recordingHUD.delegate = self

        // Drive the recorder writer + silence backstop from the gate's
        // verdict stream, and route lifecycle verdicts into prompt/record/end.
        // Both are unbounded, daemon-lifetime; cancelled in shutdown (TECH-ARCH2).
        session.startConsumers()

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
            self?.session.handleDiscovery(source)
        }
        discoveryWatcher.start()

        if let parsed = HotkeyManager.parse(liveManualHotkey) {
            hotkey.register(keyCode: parsed.keyCode, modifiers: parsed.modifiers) { [weak self] in
                DispatchQueue.main.async { self?.session.toggleManual() }
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
                DispatchQueue.main.async { self?.session.forceStop(reason: "hotkey") }
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
        session.shutdownConsumers()
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
            let result = await OrphanRecordingRecovery.recover(stems: stems, in: dir)
            guard let self = self else { return }
            for url in result.ready {
                Log.writeLine("daemon", "recovered orphaned recording → \(url.lastPathComponent)")
                Log.event(category: "coordinator", action: "orphan_recording_recovered", attributes: [
                    "file": url.lastPathComponent,
                ])
                self.jobDispatcher.enqueue(file: url, summaryMode: .auto)
            }
            if !result.quarantined.isEmpty {
                // Fail-closed capture-first orphans were kept aside, not published
                // (TECH-MIC5 review). Tell the user so they can recover manually.
                let n = result.quarantined.count
                self.notifier.notifyError(
                    "\(n) interrupted recording\(n == 1 ? "" : "s") were kept for review but not auto-published: the mute timeline was lost when the app stopped unexpectedly, so muted moments could not be removed. They are in the MeetingPipe originals folder."
                )
            }
        }
    }

    lazy var quickFindWindow: QuickFindWindow = QuickFindWindow(
        meetingStore: libraryModel.meetingStore,
        onSelect: { [weak self] meeting in
            self?.openMeeting(stem: meeting.stem)
        }
    )

    /// Post-recording meeting operations (TECH-H1-FINISH); the methods
    /// below forward to it so external callers keep the Coordinator API.
    lazy var library = MeetingLibraryService(
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
    lazy var configRefresh = ConfigRefreshCoordinator(
        configStore: configStore,
        onModelDownloadState: { [weak self] state in self?.statusBar.setModelDownload(state) },
        onRegulatedMode: { [weak self] flag in self?.statusBar.setRegulatedMode(flag) }
    )


}

/// Forwards `MeetingPipeCore`'s `EventLog` protocol to the daemon's
/// `Log.event`, which that module can't link against directly.
final class LogEventAdapter: EventLog {
    func emit(category: String, action: String, attributes: [String: Any]) {
        Log.event(category: category, action: action, attributes: attributes)
    }
}

