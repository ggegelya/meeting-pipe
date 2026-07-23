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
    /// Retained so the menu-bar "Finish setup" checklist (UX22) and the
    /// onboarding publish-target step can read secret presence. Nil in
    /// headless/test builds, like `configStore`.
    let secretsStore: SecretsStore?
    let statusBar: StatusBarController
    let recorder: MeetingRecorder
    let notifier: Notifier
    let promptWindow: MeetingPromptWindow
    let recordingHUD: RecordingHUDWindow
    /// CAL2: supplies the prompt's "Last time" card. Owned here because the panel
    /// holds it weakly, and it reads the same recordings root the Library does.
    let prepCards: PrepCardStore
    /// Cold-start discovery: finds a meeting app and engages the lifecycle
    /// adapter; the `.starting` verdict raises the prompt (TECH-C13 step 5).
    let discoveryWatcher = MeetingDiscoveryWatcher()
    let hotkey: HotkeyManager
    let consent: ConsentStore
    let launcher: PipelineDriver
    let preferencesWindow: PreferencesWindow?
    /// Daemon's primary UI for browsing past recordings.
    let libraryWindow: LibraryWindow
    /// Read-only in-app viewer over the JSONL event logs (UX20). No dependencies,
    /// so it self-initializes; reads `Log.logsDir` lazily on show.
    let diagnosticsWindow = DiagnosticsWindow()
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
    /// The single VAD-gated idle backstop (TECH-END3): nudges, then auto-stops,
    /// after a long stretch of non-`.hot` MicGate verdicts with system audio also
    /// silent, the "everyone left and the user forgot" case. Replaced the RMS
    /// `SilenceDetector` + `MicOnlySilenceBackstop` pair.
    let silenceBackstop: IdleStopBackstop

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
        self.secretsStore = secretsStore
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
        let runner = TranscriptionService.makeRunner(
            clusteringThreshold: config.transcription.diarizationClusteringThreshold
        )
        Log.event(category: "transcription", action: "engine_resolved", attributes: [
            "engine": runner.backendName,
        ])
        // HYG2: honor the ASR language knob. It was read into ConfigStore and shown
        // as a Preferences picker but never reached the runner, which always got
        // `languageHint: nil`. Read once at init (edits apply next launch), like the
        // end-debounce and silence-backstop windows below.
        let transcriptionLanguage = configStore?.transcriptionLanguage ?? config.transcription.language
        self.sinkDispatcher = SinkDispatcher(
            launcher: resolvedLauncher,
            transcriptionRunner: runner,
            languageHint: transcriptionLanguage
        )
        // Snapshot the recordings dir at init for the library root; a live
        // change needs a daemon restart for the library window (rare).
        let recordingsDir: URL = {
            if let raw = configStore?.outputDirPath {
                return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            }
            return config.recording.outputDir
        }()
        self.prepCards = PrepCardStore(recordingsDir: recordingsDir)
        let libraryModel = LibraryWindowModel(recordingsDir: recordingsDir)
        // UX16: the FTS5 search index, built over the same store. Attached here (not in the model's
        // init) so headless tests never touch the real cache and fall back to in-memory search.
        libraryModel.attachSearchIndexer(SearchIndexer(store: libraryModel.meetingStore))
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

        // PreferencesWindow needs all three stores; without config + secrets
        // (test/headless) the menu item is a no-op instead of a crash. Built after
        // the workflow store because the Storage section reports per-workflow
        // retention (STOR1).
        if let configStore = configStore, let secretsStore = secretsStore {
            self.preferencesWindow = PreferencesWindow(
                store: configStore, secrets: secretsStore, workflows: workflowStore
            )
        } else {
            self.preferencesWindow = nil
        }

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
        // TECH-END4 (b): honor the end-debounce knob. It was read into Config /
        // ConfigStore and shown as a Preferences slider but never reached the
        // engine, which always used the hardcoded 2.0s. Read once at init (edits
        // apply next launch), like the silence-backstop window below.
        let debounceEndSec = configStore?.debounceEndSec ?? config.detection.debounceEndSec
        self.lifecycleCoord = MeetingLifecycleCoordinator(
            halBus: halBus,
            axBus: axBus,
            eventLog: logAdapter,
            adapters: [
                NativeLifecycleAdapter(config: .teams, halBus: halBus, axBus: axBus, eventLog: logAdapter),
                NativeLifecycleAdapter(config: .zoom, halBus: halBus, axBus: axBus, eventLog: logAdapter),
                NativeLifecycleAdapter(config: .webex, axBus: axBus, eventLog: logAdapter),
                NativeLifecycleAdapter(config: .slack, axBus: axBus, eventLog: logAdapter),
                // Handle exactly the browsers discovery enumerates (registry = bundled
                // meeting_apps.toml + user overlay), so a listed browser is never
                // discovered-but-adapterless and an overlay browser gets full coverage
                // on relaunch (DET4).
                BrowserMeetingLifecycleAdapter(
                    axBus: axBus,
                    eventLog: logAdapter,
                    bundleIDs: MeetingAppRegistry.shared.browserBundles
                ),
            ],
            engine: PromotionEngine(debounce: debounceEndSec)
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
        // TECH-END3: idle auto-stop horizon from TOML (`mic_only_silence_seconds`,
        // default 15 min); built once, so edits apply next launch. The nudge keeps
        // the unit's default mid-streak horizon.
        let idleAutoStopSec = configStore?.micOnlySilenceSec ?? config.detection.micOnlySilenceSec
        self.silenceBackstop = IdleStopBackstop(
            notifySeconds: IdleStopBackstop.safeNotifySeconds(forAutoStop: idleAutoStopSec),
            autoStopSeconds: idleAutoStopSec
        )

        super.init()
        // Post-super.init: wire the model + status bar back to self.
        libraryModel.coordinator = self
        // ARCH4: the Library window drives `MeetingLibraryService` directly. The
        // coordinator reference above survives only for start/stop, Preferences,
        // job cancellation, and the backend read.
        libraryModel.library = library
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
                guard let self = self else { return }
                self.libraryModel.activeProcessing = nil
                // ADR 0016 / MIC13 / STOR1: keep the originals folder and the raw/
                // library bounded through a long-running session, not only at
                // launch. Runs on every completion path below (including the
                // empty-skip early return).
                self.reapStorage()
                // A no-speech / suspect-transcript skip finishes with no summary
                // and no page. The pipeline wrote <stem>.empty.json; post an
                // honest terminal notice and skip the completion tone, rather
                // than the misleading "Local Markdown ready (regulated mode)" the
                // generic done path posts for a nil page URL (PIPE3 / AUD-16a).
                // An empty-skip meeting never produces a summary, so the marker
                // unambiguously identifies this completion as the skip.
                if let reason = EmptyMarker.read(stem: stem, in: recordingsDir) {
                    self.notifier.notifyEmptySkip(reason: reason)
                    return
                }
                // TECH-DSN5: opt-in, default-off completion tone (the summary is
                // ready). Never plays during a call; separate from the done
                // notification's sound, which Focus can suppress.
                if UISettings.shared.playCompletionTone {
                    NSSound(named: "Glass")?.play()
                }
                self.notifier.notifyDone(
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
        // Escalate a sustained run of swallowed write failures (disk full, or the
        // 4 GiB WAV cap) from silent os_log-and-drop to a force-stop that
        // preserves the intact prefix, plus a notification (REC3 / AUD-7). The
        // force-stop tears down the HUD, so there is no lingering banner to clear.
        recorder.onWriteFailure = { [weak self] channel in
            guard let self = self else { return }
            self.notifier.notifyError(
                "Recording stopped: couldn't keep writing \(channel) audio to disk (the disk may be full). The recording up to that point was kept."
            )
            self.session.forceStop(reason: "write_failure_\(channel)")
        }
        // TECH-END3: route the idle backstop's two horizons to the session on main.
        // The nudge surfaces "still meeting?"; the auto-stop applies the native
        // stand-down (keep a quiet-but-live native call) before stopping, unlike the
        // old MicOnly path that force-stopped unconditionally.
        silenceBackstop.onNotify = { [weak self] _ in
            Task { @MainActor in self?.session.handleIdleNotify() }
        }
        silenceBackstop.onAutoStop = { [weak self] _ in
            Task { @MainActor in self?.session.handleIdleAutoStop() }
        }
    }

    func start() {
        notifier.delegate = self
        promptWindow.delegate = self
        promptWindow.prepProvider = prepCards
        recordingHUD.delegate = self

        // Drive the recorder writer + silence backstop from the gate's
        // verdict stream, and route lifecycle verdicts into prompt/record/end.
        // Both are unbounded, daemon-lifetime; cancelled in shutdown (TECH-ARCH2).
        session.startConsumers()

        // Funnel every TCC dialog through PermissionsCenter so the
        // Preferences tab and startup share one published state, and the
        // prompts surface in the first seconds instead of across the first
        // recording. UX21: only for a returning install. On a fresh one the
        // framed onboarding permissions step is the sole prompt surface, so
        // firing the burst here would stack four unframed system dialogs over
        // the onboarding window and pre-answer its permissions step. The
        // onboarding-completion handler (`onboardingDidComplete`) does the
        // lightweight prewarm + refresh in the burst's place.
        if OnboardingGate.isCompleted {
            requestPermissionsAtStartup()
        }

        if dryRun {
            Log.main.info("MEETING_PIPE_DRY_RUN=1: detection enabled, recorder disabled")
            Log.writeLine("daemon", "[dry-run] enabled")
            Log.event(category: "coordinator", action: "dry_run_enabled")
        }

        discoveryWatcher.onDiscovered = { [weak self] source in
            self?.session.handleDiscovery(source)
        }
        // DET1: a sustained mic-busy dwell with no whitelist winner routes through the same prompt
        // path as a discovered meeting (skip-latch / cooldown / auto-consent all apply).
        discoveryWatcher.onMicInUseDwell = { [weak self] source in
            self?.session.handleMicInUseDwell(source)
        }
        // DET1: the mic no longer being held by the DET1 recording's app ends it (its
        // permission-light end path; a level check, so a late-started recording still stops).
        discoveryWatcher.onMicBusyBundle = { [weak self] bundle in
            self?.session.handleMicBusyBundle(bundle)
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

        // Flag-moment hotkey (FEAT8): stamps a timestamp marker on the active
        // recording (a quiet HUD blink); a no-op when idle, like force-stop.
        let flagHotkey = liveFlagMomentHotkey
        if flagHotkey == liveManualHotkey || flagHotkey == liveForceStopHotkey {
            Log.main.warning("Flag-moment hotkey matches another hotkey - skipping registration")
        } else if let parsed = HotkeyManager.parse(flagHotkey) {
            hotkey.register(keyCode: parsed.keyCode, modifiers: parsed.modifiers) { [weak self] in
                DispatchQueue.main.async { self?.session.flagMoment() }
            }
            Log.main.info("Flag-moment hotkey registered: \(flagHotkey)")
        } else {
            Log.main.warning("Could not parse flag-moment hotkey: \(flagHotkey)")
        }

        // Off-the-record hotkey (MIC14): toggles a manual redaction span on the active
        // recording; a no-op when idle, like the others.
        let offRecordHotkey = liveOffTheRecordHotkey
        if offRecordHotkey == liveManualHotkey || offRecordHotkey == liveForceStopHotkey || offRecordHotkey == flagHotkey {
            Log.main.warning("Off-the-record hotkey matches another hotkey - skipping registration")
        } else if let parsed = HotkeyManager.parse(offRecordHotkey) {
            hotkey.register(keyCode: parsed.keyCode, modifiers: parsed.modifiers) { [weak self] in
                DispatchQueue.main.async { self?.session.toggleOffTheRecord() }
            }
            Log.main.info("Off-the-record hotkey registered: \(offRecordHotkey)")
        } else {
            Log.main.warning("Could not parse off-the-record hotkey: \(offRecordHotkey)")
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

        // Surface jobs stranded by a restart mid-pipeline (final WAV, no terminal
        // sidecar). Runs synchronously before the orphan recovery folded into
        // reapStorage below, so it observes the directory before that recovery's
        // async merges create any new final WAVs (else a just-recovered WAV would
        // look stranded and re-enqueue).
        reconcileStrandedJobs()
        // Re-enqueue recordings orphaned by a mid-recording termination (REC6 runs
        // the orphan sweep from here now, launch + after every job), reclaim kept
        // full recordings past their retention window (ADR 0016 / MIC13), and apply
        // per-workflow audio retention to raw/ (STOR1). The orphan sweep runs before
        // the reapers, so retention never sees a recording it is about to re-enqueue.
        reapStorage()
        // SEC14: one-time self-heal of any pre-existing 0644 transcript/summary
        // artifacts to 0600 (new writes are already 0600). Mirrors the SEC11 log sweep.
        let artifactsDir = liveOutputDir
        Task.detached(priority: .background) {
            MeetingStore.tightenArtifactPermissions(in: artifactsDir)
        }
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
            // Synchronously finalize the capture intermediates so a SIGTERM / quit
            // can't strand a half-written recording (REC2 / AUD-6). The old
            // fire-and-forget `Task { await recorder.stop() }` never completed
            // before exit() (dead code); the orphan sweep merges + privacy-routes
            // these on the next launch via the start-time manifest. assumeIsolated
            // is safe: both callers (applicationWillTerminate, the SIGTERM source)
            // run on the main queue.
            MainActor.assumeIsolated {
                recorder.flushIntermediatesForTermination()
            }
        }
    }

    /// The launch sweep, three scopes (MIC13 + STOR1 + LOCAL10):
    ///   1. `OriginalsReaper` reclaims kept full recordings (`originals/`) past
    ///      their retention window (ADR 0016). Bounded-cache eviction.
    ///   2. `AudioRetentionSweep` applies each workflow's audio retention policy
    ///      to settled meetings in `raw/`. Per-meeting policy, not eviction.
    ///   3. `LocalServerReaper` kills an `mlx_lm.server` left behind by an `mp`
    ///      the pipeline watchdog SIGKILLed. Reclaims RAM, not disk, but it is
    ///      the same "clean up what a previous run leaked" slot, and a launch is
    ///      the moment we can be sure no `mp` of ours is mid-summarize.
    ///
    /// Different algorithms, one scheduler and one event category. Runs off-main:
    /// a directory scan, some deletes, an ffmpeg subprocess (for `compress`), and
    /// a `ps` probe. No scope touches a live recording or a non-terminal meeting,
    /// so this is independent of the recording and pipeline state machines.
    private func reapStorage() {
        // Snapshot main-owned state before detaching.
        let dir = liveOutputDir
        let policies = Dictionary(
            uniqueKeysWithValues: workflowStore.workflows.map { ($0.id, $0.retention) }
        )
        let liveStem = libraryModel.liveRecordingStem
        // REC6: recover any recording orphaned by a mid-recording termination now,
        // not only at launch. This slot runs at launch and after every job
        // completion, so a stop-time merge failure recovers on the next job instead
        // of waiting for a relaunch (a launchd daemon can run for days). The live
        // recording's stem is excluded so its in-flight intermediates are untouched;
        // a re-merge that fails again keeps its `.recordfail.json` for the doctor.
        recoverOrphanedRecordings(liveStem: liveStem)
        Task.detached(priority: .background) {
            OriginalsReaper.sweep()
            AudioRetentionSweep.sweep(in: dir, policies: policies, liveStem: liveStem)
            LocalServerReaper.reapIfOrphaned()
        }
    }

    /// Re-enqueue recordings orphaned by a mid-recording termination
    /// (crash, kill, rebuild, reinstall restart) that left unmerged
    /// `.mic.wav`/`.system.wav` intermediates. REC6 runs this from `reapStorage`
    /// (launch + after every job completion), not only at launch, so a merge that
    /// failed while the daemon keeps running recovers on the next job instead of
    /// waiting for a relaunch. `liveStem` excludes the currently-recording stem so
    /// its in-flight intermediates are never merged; the ffmpeg merges run off-main
    /// so the menu bar isn't stalled.
    private func recoverOrphanedRecordings(liveStem: String?) {
        let dir = liveOutputDir
        let stems = OrphanRecordingRecovery.scanOrphanStems(in: dir, excludingStem: liveStem)
        guard !stems.isEmpty else { return }
        Task { @MainActor [weak self] in
            let result = await OrphanRecordingRecovery.recover(stems: stems, in: dir)
            guard let self = self else { return }
            for rec in result.ready {
                let modeLabel = rec.summaryMode == .byo ? "byo" : "auto"
                Log.writeLine("daemon", "recovered orphaned recording → \(rec.url.lastPathComponent) mode=\(modeLabel)")
                Log.event(category: "coordinator", action: "orphan_recording_recovered", attributes: [
                    "file": rec.url.lastPathComponent,
                    "summary_mode": modeLabel,
                ])
                // REC2 / AUD-6: route by the recorded summary mode so a crash-
                // interrupted BYO meeting produces a paste bundle, not an
                // Anthropic+Notion auto-summary.
                self.jobDispatcher.enqueue(file: rec.url, summaryMode: rec.summaryMode)
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

    /// Surface pipeline jobs stranded by a mid-processing restart: a finished
    /// `<stem>.wav` whose pipeline never reached a terminal sidecar, because the
    /// in-memory `SinkDispatcher` queue did not survive (PIPE3 / AUD-16b). Without
    /// this they masquerade as `.processing` for the staleness window, then decay
    /// to a generic `.failed`. Writing an honest `.interrupted` failure sidecar
    /// makes them retryable immediately and counts them in the failed badge.
    ///
    /// Mark, do not auto-re-enqueue: a cleanly-stopped meeting's start-time
    /// recovery manifest is gone, so the recorded BYO/auto mode is unknown, and
    /// auto-reprocessing could egress a meeting recorded BYO (REC2's no-auto-egress
    /// posture). Retry is the user's explicit choice. Runs synchronously at startup
    /// before the orphan sweep's async merges land, so a freshly-merged orphan
    /// final (enqueued by `recoverOrphanedRecordings`) is never seen here.
    private func reconcileStrandedJobs() {
        let dir = liveOutputDir
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return
        }
        for stem in StrandedJobRecovery.detect(fileNames: names) {
            guard MeetingStore.parseStem(stem) != nil else { continue }  // real recordings only
            PipelineFailureSidecar.write(
                stem: stem, in: dir, stage: .interrupted,
                reason: "MeetingPipe restarted before this meeting finished processing. Retry to resume."
            )
            Log.writeLine("daemon", "stranded pipeline job marked interrupted: \(stem)")
            Log.event(category: "coordinator", action: "stranded_job_reconciled", attributes: [
                "stem": stem,
            ])
        }
    }

    lazy var quickFindWindow: QuickFindWindow = QuickFindWindow(
        meetingStore: libraryModel.meetingStore,
        ftsMatches: { [weak self] query in self?.libraryModel.matchingStems(query) },
        searchHealth: { [weak self] in self?.libraryModel.searchHealth ?? .ready },
        onSelect: { [weak self] meeting in
            self?.openMeeting(stem: meeting.stem)
        },
        // UX25: hand a question-shaped query straight to the Ask rail through the same
        // router `meetingpipe://ask` uses, so the panel and the URL scheme cannot drift
        // into two prefill paths.
        onAsk: { [weak self] question in
            self?.handleAutomation(.ask(question: question), source: "quick_find")
        }
    )

    /// Post-recording meeting operations (TECH-H1-FINISH). Handed to
    /// `libraryModel` in `init` so the Library window calls it directly (ARCH4);
    /// the Coordinator keeps only `recentCorrectableMeetings` / `failedMeetingCount`
    /// for the status-bar menu. `enqueue` reads `jobDispatcher` inside the closure,
    /// not at construction, so forcing this lazy var in `init` is safe while that
    /// IUO is still nil.
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

