import AppKit
import Combine
import Foundation

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
    /// `var` so we can swap in a fresh Detector when the user changes
    /// debounce values via Preferences. See `applyConfigRefreshIfPossible`.
    private var detector: Detector
    private let hotkey: HotkeyManager
    private let consent: ConsentStore
    private let launcher: PipelineDriver
    private let preferencesWindow: PreferencesWindow?
    /// Long-running transcription subprocess that runs in parallel with
    /// the recorder. When the recording stops, we signal it to flush;
    /// the orchestrator then picks up its `<stem>.json` and skips the
    /// offline ASR stage. Best-effort: a failure here is recoverable —
    /// the orchestrator falls back to a fresh offline transcribe when
    /// the streamed JSON is missing or has zero segments.
    private let streamingTranscriber = StreamingTranscriber()

    /// Pre-fetches the local-MLX model whenever the user picks a backend
    /// that needs one. The first meeting in local mode otherwise pays a
    /// 30s-3min download stall inside `mlx_lm.server`'s first call;
    /// running the prefetch up front turns that into a visible status-bar
    /// state instead. No-op when backend is anthropic.
    private let modelDownload = ModelDownloadSupervisor()

    /// Watches mic + system levels to surface a missed meeting end (TECH-C2).
    /// Created at recording start, released at stop. Notifies after 90 s of
    /// silence and auto-stops after 5 min.
    private var silenceDetector: SilenceDetector?

    private var state: AppState = .idle {
        didSet {
            Log.main.info("state: \(String(describing: oldValue)) → \(String(describing: self.state))")
            Log.event(category: "coordinator", action: "state_change", attributes: [
                "from": Coordinator.stateLabel(oldValue),
                "to": Coordinator.stateLabel(state),
            ])
            // Mid-recording config edits get deferred (see
            // applyConfigRefreshIfPossible) — apply them when we transition
            // back to idle so the next meeting picks up the new values.
            if case .idle = state { applyConfigRefreshIfPossible() }
        }
    }

    private static func stateLabel(_ s: AppState) -> String {
        switch s {
        case .idle: return "idle"
        case .prompting: return "prompting"
        case .suppressed: return "suppressed"
        case .recording: return "recording"
        case .stopping: return "stopping"
        }
    }

    /// Auto-skip timer when the user ignores a prompt. Spec §7 prompt_timeout_sec.
    private var promptTimeoutTimer: Timer?

    /// FIFO queue of pipeline jobs spawned after recordings flush. The
    /// queue is sequential (one whisper.cpp at a time) but the recording
    /// side of the state machine runs in parallel, so the user can start
    /// a new meeting while older recordings are still being transcribed.
    private var processingJobs: [ProcessingJob] = []
    /// Job whose subprocess is currently running (head of the queue).
    /// `nil` between jobs and when the queue is empty.
    private var activeJob: ProcessingJob?

    /// Set when ConfigStore persists while we're mid-recording. We can't
    /// rebuild the Detector live without losing its `hasFiredStart`
    /// bookkeeping (the new instance would never fire `.ended` for the
    /// in-flight meeting). Apply on next `.idle` instead.
    private var pendingDetectorRefresh: Bool = false

    /// Show the "Screen Recording disabled" startup notification at most
    /// once per daemon launch — repeated banners would be noisy.
    private var didNotifyAboutPermissionDenial: Bool = false

    /// Dry-run mode: detection + recognizer run end-to-end, all decisions
    /// hit the JSONL event log, but `MeetingRecorder.start` is never
    /// called. Lets the daemon ride along during a normal workday so the
    /// user can verify detection accuracy without producing audio. Read
    /// once at init from `MEETING_PIPE_DRY_RUN`; flipping it requires a
    /// daemon restart, which is fine for a debug knob.
    private let dryRun: Bool = (ProcessInfo.processInfo.environment["MEETING_PIPE_DRY_RUN"] == "1")

    private var configCancellable: AnyCancellable?

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
        self.detector = Detector(
            debounceStartSec: configStore?.debounceStartSec ?? config.detection.debounceStartSec,
            debounceEndSec: configStore?.debounceEndSec ?? config.detection.debounceEndSec,
            // Per-bundle end-debounce overrides aren't surfaced in
            // Preferences yet (TECH-C4 ships TOML support only), so we
            // read straight from the loaded Config. Editing requires a
            // daemon restart for now.
            debounceEndPerBundle: config.detection.debounceEndPerBundle
        )
        self.hotkey = HotkeyManager()
        self.consent = ConsentStore()
        self.launcher = launcher ?? PipelineLauncher()
        // PreferencesWindow needs both stores. When the daemon was
        // launched with neither (test fixtures, headless smoke runs)
        // the menu item is wired through this guard; clicking it
        // becomes a no-op rather than crashing.
        if let configStore = configStore, let secretsStore = secretsStore {
            self.preferencesWindow = PreferencesWindow(store: configStore, secrets: secretsStore)
        } else {
            self.preferencesWindow = nil
        }
        super.init()
    }

    func start() {
        notifier.delegate = self
        notifier.requestAuthorization()
        promptWindow.delegate = self
        recordingHUD.delegate = self

        if dryRun {
            Log.main.info("MEETING_PIPE_DRY_RUN=1: detection enabled, recorder disabled")
            Log.writeLine("daemon", "[dry-run] enabled")
            Log.event(category: "coordinator", action: "dry_run_enabled")
        }

        detector.delegate = self
        detector.start()

        if let parsed = HotkeyManager.parse(liveManualHotkey) {
            hotkey.register(keyCode: parsed.keyCode, modifiers: parsed.modifiers) { [weak self] in
                DispatchQueue.main.async { self?.toggleManual() }
            }
            Log.main.info("Hotkey registered: \(self.liveManualHotkey)")
        } else {
            Log.main.warning("Could not parse hotkey: \(self.liveManualHotkey)")
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

        // Surface the Screen Recording permission state once prewarm has had
        // a chance to settle. Without this, a denied TCC silently degrades
        // every recording to mic-only — and the user only finds out at
        // playback. 2.5s is enough for the prewarm Task to complete on a
        // cold launch; if it's still .unknown after that we don't bug the
        // user (the menu-bar warning catches it once the state resolves).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.checkScreenRecordingPermissionAtStartup()
        }
    }

    private func checkScreenRecordingPermissionAtStartup() {
        guard !didNotifyAboutPermissionDenial,
              SystemAudioCapture.permissionState == .denied else { return }
        didNotifyAboutPermissionDenial = true
        notifier.notifySystemAudioBlocked()
        statusBar.refreshMenuForPermissionChange()
    }

    func shutdown() {
        Log.main.info("shutting down")
        detector.stop()
        hotkey.unregister()
        if recorder.isRecording {
            // Best-effort flush; we don't want orphan recording state.
            // Streaming transcriber is signaled in parallel — its hard
            // SIGKILL escalation makes sure we can't sit here forever.
            let transcriber = self.streamingTranscriber
            Task {
                await recorder.stop()
                await transcriber.stop()
            }
        }
    }

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
    // at the next read without bouncing the daemon. Detector debounce
    // values are special-cased: they're constructor params, so we rebuild
    // the Detector on persist (see `applyConfigRefreshIfPossible`).

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

    private var liveManualHotkey: String {
        configStore?.manualHotkey ?? config.detection.manualHotkey
    }

    // MARK: State transitions

    private func toggleManual() {
        switch state {
        case .idle:
            beginRecording(source: nil, summaryMode: .auto)
        case .prompting(let src), .suppressed(let src):
            // Preserve meeting attribution when the user overrides via hotkey
            // — without this, "Always for {App}" would never see the source.
            promptWindow.dismiss()
            beginRecording(source: src, summaryMode: .auto)
        case .recording(let file, let src, let mode):
            stopRecording(file: file, source: src, summaryMode: mode)
        case .stopping:
            // Recorder is mid-flush; a new start would race the await.
            // Pipeline jobs no longer block this path — they live in
            // `processingJobs` and run independently.
            break
        }
    }

    private func beginRecording(source: AppSource?, summaryMode: SummaryMode) {
        cancelPromptTimeout()

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
            state = .idle
            statusBar.setIdle()
            return
        }

        do {
            let file = try recorder.start(outputDir: liveOutputDir)
            // Tell the detector our tap is live so micInUse() switches
            // its gating, and any endTimer armed by a pre-recording
            // mic flicker gets cancelled immediately. Without this, a
            // stale debounce can fire seconds into a fresh recording
            // and stop it.
            detector.recorderDidStart()
            state = .recording(file: file, source: source, summaryMode: summaryMode)
            statusBar.setRecording(file: file, source: source, summaryMode: summaryMode)
            recordingHUD.present(source: source, startedAt: Date())
            notifier.notifyRecordingStarted(file: file)
            Log.writeLine(
                "daemon",
                "recording started → \(file.path) source=\(source?.bundleID ?? "manual") mode=\(summaryMode == .byo ? "byo" : "auto")"
            )
            Log.event(category: "coordinator", action: "recording_started", attributes: [
                "file": file.lastPathComponent,
                "bundle_id": source?.bundleID ?? "manual",
                "summary_mode": summaryMode == .byo ? "byo" : "auto",
            ])
            armSilenceDetector()
            // Kick off streaming transcribe so transcription runs in
            // parallel with the meeting. Best-effort — a failure here
            // (mp not installed, AVAudioFile not yet flushing) just
            // means the orchestrator's offline path picks up at stop.
            // BYO mode skips streaming because the orchestrator short-
            // circuits before transcribe anyway, so spawning would be
            // wasted work.
            if summaryMode != .byo,
               let micURL = recorder.micURL {
                let stem = file.deletingPathExtension().lastPathComponent
                let outputDir = file.deletingLastPathComponent()
                do {
                    try streamingTranscriber.start(
                        stem: stem,
                        outputDir: outputDir,
                        micURL: micURL,
                        systemURL: recorder.systemURL,
                        language: nil  // pipeline reads its own config
                    )
                } catch {
                    Log.main.warning("Streaming transcriber failed to start (\(error.localizedDescription)) — offline transcribe will run at stop")
                }
            }
        } catch {
            Log.main.error("failed to start recorder: \(error.localizedDescription)")
            notifier.notifyError("Could not start recording: \(error.localizedDescription)")
            state = .idle
            statusBar.setIdle()
        }
    }

    private func stopRecording(file: URL, source: AppSource?, summaryMode: SummaryMode) {
        state = .stopping(file: file, source: source, summaryMode: summaryMode)
        statusBar.setStopping()
        recordingHUD.dismiss()
        disarmSilenceDetector()

        // Recorder.stop is async — runs on a background task so the UI
        // stays responsive. Once flushed, the audio is enqueued for
        // pipeline processing and the recording-side state returns to
        // .idle so the user can record another meeting immediately.
        let recorder = self.recorder
        let transcriber = self.streamingTranscriber
        Task { @MainActor [weak self] in
            await recorder.stop()
            // Tell the streaming transcriber to drain its remaining
            // buffer and finalize <stem>.json. The orchestrator then
            // skips the offline ASR stage. We bound the wait inside
            // StreamingTranscriber.stop (SIGTERM → 60 s grace → SIGKILL)
            // so a hung subprocess can't pin the daemon in `.stopping`.
            await transcriber.stop()
            guard let self = self else { return }
            // Recorder is no longer holding the input device, so
            // `micInUse` can re-enable its CoreAudio probe and the
            // detector resumes its normal pre-recording behaviour.
            self.detector.recorderDidStop()
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
            self.enqueueJob(file: file, summaryMode: summaryMode)
            self.state = .idle
            self.statusBar.setIdle()
        }
    }

    /// Drop a `<wav-stem>.meta.json` next to the recording so the pipeline
    /// can pick up the meeting name + source app for a contextual Notion
    /// title. Best-effort: a write failure is logged but doesn't block the
    /// pipeline (the LLM-derived title is the existing fallback).
    private func writeMetaSidecar(file: URL, source: AppSource?) {
        guard let source = source else { return }
        let stem = file.deletingPathExtension().lastPathComponent
        let sidecar = file.deletingLastPathComponent().appendingPathComponent("\(stem).meta.json")
        var dict: [String: Any] = [
            "source_bundle_id": source.bundleID,
            "source_display_name": source.displayName,
            "source_kind": source.kind == .browser ? "browser" : "native",
        ]
        if let title = source.meetingTitle, !title.isEmpty {
            dict["meeting_title"] = title
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: sidecar, options: .atomic)
            Log.writeLine("daemon", "meta sidecar → \(sidecar.lastPathComponent) title=\(source.meetingTitle ?? "(none)")")
        } catch {
            Log.main.warning("Failed to write meta sidecar: \(error.localizedDescription)")
        }
    }

    /// Append a freshly-flushed recording to the pipeline queue and start
    /// the runner if nothing is currently being processed.
    private func enqueueJob(file: URL, summaryMode: SummaryMode) {
        let job = ProcessingJob(id: UUID(), file: file, summaryMode: summaryMode, startedAt: Date())
        processingJobs.append(job)
        statusBar.setProcessingCount(processingJobs.count)
        Log.writeLine("daemon", "pipeline queued → \(file.lastPathComponent) (queue=\(processingJobs.count))")
        Log.event(category: "coordinator", action: "pipeline_queued", attributes: [
            "file": file.lastPathComponent,
            "queue_depth": processingJobs.count,
            "summary_mode": summaryMode == .byo ? "byo" : "auto",
        ])
        startNextJobIfNeeded()
    }

    /// Run the head of the queue. Sequential by design: two whisper.cpp
    /// processes at once would just thrash the CPU and slow both runs.
    /// Recording is unaffected — the user can start a new meeting at any
    /// time even while jobs are queued or running.
    private func startNextJobIfNeeded() {
        guard activeJob == nil, let next = processingJobs.first else { return }
        activeJob = next
        Log.writeLine("daemon", "pipeline starting → \(next.file.lastPathComponent)")
        Log.event(category: "coordinator", action: "pipeline_started", attributes: [
            "file": next.file.lastPathComponent,
        ])
        launcher.runAll(wav: next.file, summaryMode: next.summaryMode) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let pageURL):
                    let stem = next.file.deletingPathExtension().lastPathComponent
                    let recordingsDir = next.file.deletingLastPathComponent()
                    self.notifier.notifyDone(
                        stem: stem,
                        recordingsDir: recordingsDir,
                        pageURL: pageURL
                    )
                    Log.writeLine("daemon", "pipeline OK → \(pageURL?.absoluteString ?? "(local-only)")")
                    Log.event(category: "coordinator", action: "pipeline_succeeded", attributes: [
                        "file": next.file.lastPathComponent,
                        "page_url": pageURL?.absoluteString ?? NSNull(),
                    ])
                case .failure(let err):
                    self.notifier.notifyError("Pipeline failed: \(err.localizedDescription)")
                    Log.writeLine("daemon", "pipeline FAIL → \(err.localizedDescription)")
                    Log.event(category: "coordinator", action: "pipeline_failed", attributes: [
                        "file": next.file.lastPathComponent,
                        "error": err.localizedDescription,
                    ])
                }
                self.activeJob = nil
                if let head = self.processingJobs.first, head.id == next.id {
                    self.processingJobs.removeFirst()
                }
                self.statusBar.setProcessingCount(self.processingJobs.count)
                self.startNextJobIfNeeded()
            }
        }
    }

    private func startPromptTimeout(for source: AppSource) {
        cancelPromptTimeout()
        promptTimeoutTimer = Timer.scheduledTimer(withTimeInterval: livePromptTimeoutSec, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if case .prompting(let src) = self.state, src == source {
                    Log.writeLine("daemon", "prompt timed out → suppressed (\(source.bundleID))")
                    Log.event(category: "coordinator", action: "prompt_timeout", attributes: [
                        "bundle_id": source.bundleID,
                    ])
                    self.promptWindow.dismiss()
                    self.state = .suppressed(source: source)
                    self.statusBar.setIdle()
                }
            }
        }
    }

    private func cancelPromptTimeout() {
        promptTimeoutTimer?.invalidate()
        promptTimeoutTimer = nil
    }

    // MARK: Config refresh

    private func handleConfigPersisted() {
        pendingDetectorRefresh = true
        applyConfigRefreshIfPossible()
        ensureModelPrefetchIfNeeded()
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

    /// Rebuild the Detector with the live debounce values, but only when
    /// we're idle — rebuilding mid-recording would reset `hasFiredStart`,
    /// stranding the in-flight meeting because the new Detector wouldn't
    /// fire `.ended`. Anything stashed gets applied on the next idle
    /// transition (see `state.didSet`).
    private func applyConfigRefreshIfPossible() {
        guard pendingDetectorRefresh, case .idle = state, let store = configStore else { return }
        pendingDetectorRefresh = false

        let newStart = store.debounceStartSec
        let newEnd = store.debounceEndSec
        Log.main.info("config persisted → rebuilding detector (start=\(newStart) end=\(newEnd))")
        detector.stop()
        let fresh = Detector(
            debounceStartSec: newStart,
            debounceEndSec: newEnd,
            // Per-bundle overrides aren't writable via ConfigStore yet,
            // so we keep the boot-time snapshot. Re-applying them here
            // ensures the rebuilt Detector matches the constructor path.
            debounceEndPerBundle: config.detection.debounceEndPerBundle
        )
        fresh.delegate = self
        fresh.start()
        detector = fresh
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
        recorder.onSystemLevel = { [weak self] db in
            self?.silenceDetector?.observeSystem(db: Double(db))
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
        guard case .recording(let file, let src, let mode) = state else { return }
        Log.writeLine("daemon", "silence: 5min — auto-stopping recording")
        Log.event(category: "coordinator", action: "auto_stop_silence", attributes: [
            "bundle_id": src?.bundleID ?? "manual",
            "file": file.lastPathComponent,
        ])
        stopRecording(file: file, source: src, summaryMode: mode)
    }
}

extension Coordinator: DetectorDelegate {
    func detector(_ detector: Detector, event: DetectorEvent) {
        switch event {
        case .started(let src):
            handleMeetingStarted(source: src)
        case .ended:
            handleMeetingEnded()
        }
    }

    private func handleMeetingStarted(source: AppSource) {
        guard state.isAcceptingPrompts else { return }

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

        state = .prompting(source: source)
        statusBar.setPrompting(source)
        // On-screen panel is the primary surface (Notion-style top-right
        // floating window). Banner notification stays disabled by default —
        // the panel doesn't get suppressed under Focus modes and is harder
        // to miss. If the user wants OS-level persistence too, flip the
        // notifier call back on here.
        promptWindow.present(source: source, autoDismissAfter: livePromptTimeoutSec)
        startPromptTimeout(for: source)
        Log.writeLine("daemon", "meeting detected → prompting (\(source.bundleID))")
        Log.event(category: "coordinator", action: "prompt_shown", attributes: [
            "bundle_id": source.bundleID,
            "display_name": source.displayName,
            "timeout_sec": livePromptTimeoutSec,
        ])
    }

    private func handleMeetingEnded() {
        switch state {
        case .recording(let file, let src, let mode):
            stopRecording(file: file, source: src, summaryMode: mode)
        case .prompting, .suppressed:
            cancelPromptTimeout()
            promptWindow.dismiss()
            state = .idle
            statusBar.setIdle()
        default:
            break
        }
    }
}

extension Coordinator: NotifierDelegate {
    func notifier(_ notifier: Notifier, didChooseRecord source: AppSource) {
        guard case .prompting(let pending) = state, pending == source else { return }
        beginRecording(source: source, summaryMode: .auto)
    }

    func notifier(_ notifier: Notifier, didChooseSkip source: AppSource) {
        guard case .prompting(let pending) = state, pending == source else { return }
        cancelPromptTimeout()
        state = .suppressed(source: source)
        statusBar.setIdle()
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

    func notifierDidRequestStopRecording(_ notifier: Notifier) {
        // Reuse `toggleManual` so the stop path is identical to the
        // hotkey-stop and recorder-HUD-stop surfaces — one entry point.
        if case .recording = state { toggleManual() }
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
        guard case .prompting(let pending) = state, pending == source else { return }
        beginRecording(source: source, summaryMode: .byo)
    }
}

extension Coordinator: RecordingHUDDelegate {
    func recordingHUDDidRequestStop(_ hud: RecordingHUDWindow) {
        // Reuse the existing toggle path so manual-stop, hotkey-stop, and
        // HUD-stop all flow through one state-machine entry.
        toggleManual()
    }
}
