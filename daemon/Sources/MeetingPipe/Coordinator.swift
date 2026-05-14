import AppKit
import AVFoundation
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
    /// Library window — daemon's primary UI surface for browsing past
    /// recordings. Built lazily-once; `show()` brings it forward on
    /// every "Open Library…" click.
    private let libraryWindow: LibraryWindow
    /// Observable mirror of the recording state machine + processing
    /// queue + model-download progress. The library window subscribes
    /// to this; StatusBarController writes into it from each state setter.
    private let libraryModel: LibraryWindowModel
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

    /// Per-context routing rules (TECH-B). Workflows live as TOML files
    /// under `~/.config/meeting-pipe/workflows/`. Held as a published
    /// store so the Workflows tab + the prompt window's chip can both
    /// subscribe directly.
    let workflowStore: WorkflowStore

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

    /// Per-bundle re-prompt suppression. Recorded on every end-of-
    /// recording / skip / timeout transition so the next detector-
    /// driven `.started` for the same bundle is gated by the
    /// cooldown. See `RepromptCooldown` for the why.
    private var repromptCooldown = RepromptCooldown()

    /// AX handle to the active recording's meeting window. Captured
    /// when `beginRecording` arms a recording for a native source, used
    /// by the `MeetingMuteProbe` poll to read the client's mute state.
    /// `nil` for manual / browser recordings, AX-denied sessions, or
    /// when no window matched at capture time — in any of those cases
    /// the mute probe stays off and the recorder behaves as before.
    private var recordingWindow: MeetingWindowHandle?

    /// 1 Hz timer that polls `MeetingMuteProbe.evaluate` while
    /// recording. Toggles `recorder.micPaused` on transitions and
    /// emits `mic_paused_due_to_mute` / `mic_resumed` events to the
    /// jsonl. Armed in `armMuteProbe`, disarmed in `disarmMuteProbe`.
    private var muteProbeTimer: Timer?

    /// Last mute state we observed (or `.unknown` before the first
    /// successful probe). Stored so we only emit transition events
    /// when the state actually flips — otherwise the events log would
    /// fill with one redundant line per poll.
    private var lastMuteState: MeetingMuteProbe.State = .unknown

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
        super.init()
        // Wire the model back to the Coordinator so the sidebar's
        // Start/Stop button can route through the existing menu handlers.
        // Done post-super.init so the weak ref is valid.
        libraryModel.coordinator = self
        statusBar.libraryModel = libraryModel
    }

    func start() {
        notifier.delegate = self
        promptWindow.delegate = self
        recordingHUD.delegate = self

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

        detector.delegate = self
        detector.start()

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
                self.detector.refreshNow()
                self.statusBar.refreshMenuForPermissionChange()
            }
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

    @objc func menuOpenLibrary() {
        libraryWindow.show()
    }

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
        enqueueJob(file: wavURL, summaryMode: .auto)
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

    private var liveRepromptCooldownSec: Double {
        configStore?.repromptCooldownSec ?? config.detection.repromptCooldownSec
    }

    private var liveHonorAppMute: Bool {
        // `Recording.honorAppMute` isn't wired through ConfigStore's
        // SwiftUI surface yet (the Preferences tab doesn't expose a
        // toggle for it). Read straight from the Config snapshot so
        // editing the TOML still works for the personal-tool case.
        config.recording.honorAppMute
    }

    private var liveManualHotkey: String {
        configStore?.manualHotkey ?? config.detection.manualHotkey
    }

    private var liveForceStopHotkey: String {
        configStore?.forceStopHotkey ?? config.detection.forceStopHotkey
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
            // Manual override is an explicit "start now" signal; drop
            // any cooldown entry for this bundle so the next detector-
            // driven detection isn't suppressed by a stale skip/end.
            repromptCooldown.clear(bundleID: src.bundleID)
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
            "state": Coordinator.stateLabel(state),
        ])
        switch state {
        case .recording(let file, let src, let mode):
            stopRecording(file: file, source: src, summaryMode: mode)
        case .prompting(let src):
            // Treat as "no, don't record, and don't ask again until the
            // detector sees this meeting end" — same as clicking Skip.
            cancelPromptTimeout()
            promptWindow.dismiss()
            state = .suppressed(source: src)
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
        cancelPromptTimeout()

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
            // hunting for the menu item. The Preferences tab order
            // surfaces Permissions; the existing menu menuPreferences
            // handler activates the right window.
            menuPreferences()
            state = .idle
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
            state = .idle
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
                voiceProcessing: config.recording.voiceProcessing
            )
            // Tell the detector our tap is live so micInUse() switches
            // its gating, and any endTimer armed by a pre-recording
            // mic flicker gets cancelled immediately. Without this, a
            // stale debounce can fire seconds into a fresh recording
            // and stop it.
            detector.recorderDidStart()
            activeWorkflow = resolvedWorkflow
            state = .recording(file: file, source: source, summaryMode: summaryMode)
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
            armMuteProbe(source: source)
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
        disarmMuteProbe()

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
            // Drop the workflow attribution after the sidecar lands so it
            // can't bleed into the next meeting; a fresh resolve runs at
            // the start of the next `beginRecording`.
            self.activeWorkflow = nil
            // Arm the re-prompt cooldown for this bundle so the post-
            // call surface (Teams chat reclaiming the mic, Zoom's
            // teardown toast) can't trigger a fresh "Record this
            // meeting?" prompt within seconds of the stop flush.
            if let bid = source?.bundleID {
                self.repromptCooldown.recordEnd(bundleID: bid)
            }
            self.state = .idle
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
                guard case .prompting(let src) = self.state, src == source else { return }
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
                    self.state = .suppressed(source: source)
                    // Same reasoning as the explicit-skip path: the
                    // user's silence is a "don't pester me for this
                    // call" signal, so arm the cooldown to absorb
                    // post-call mic flickers after suppression lifts.
                    self.repromptCooldown.recordEnd(bundleID: source.bundleID)
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

    // MARK: - Mute probe (honor app-level mute)

    /// Capture the meeting window for a native source and start the 1 Hz
    /// poll that gates `recorder.micPaused` on the client's mute state.
    /// No-op when the probe is disabled by config, when the source is
    /// browser / manual (no native AX window to inspect), or when AX
    /// permission is missing (the capture returns nil and the recorder
    /// behaves as before).
    private func armMuteProbe(source: AppSource?) {
        muteProbeTimer?.invalidate()
        muteProbeTimer = nil
        recordingWindow = nil
        lastMuteState = .unknown
        guard liveHonorAppMute else { return }
        guard let source = source, source.kind == .native else { return }
        guard let handle = MeetingWindowProbe.capture(source: source) else {
            Log.writeLine(
                "daemon",
                "mute probe disabled: no AX window handle for \(source.bundleID)"
            )
            return
        }
        recordingWindow = handle
        Log.writeLine("daemon", "mute probe armed for \(source.bundleID)")
        Log.event(category: "coordinator", action: "mute_probe_armed", attributes: [
            "bundle_id": source.bundleID,
        ])
        // 1 Hz is responsive enough that a few hundred ms of speech
        // after toggling mute is the worst-case spillover. Faster
        // polling burns AX RPCs without meaningful UX benefit.
        muteProbeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickMuteProbe()
        }
    }

    private func disarmMuteProbe() {
        muteProbeTimer?.invalidate()
        muteProbeTimer = nil
        recordingWindow = nil
        // Leave `recorder.micPaused` alone — the recorder resets it on
        // its next `start()`. Resetting here would race the stop flush
        // which is still draining buffered mic frames.
        if lastMuteState != .unknown {
            Log.event(category: "coordinator", action: "mute_probe_disarmed", attributes: [
                "last_state": Coordinator.muteLabel(lastMuteState),
            ])
        }
        lastMuteState = .unknown
    }

    private func tickMuteProbe() {
        guard let handle = recordingWindow else { return }
        guard case .recording = state else { return }
        let state = MeetingMuteProbe.evaluate(handle)
        if state == lastMuteState || state == .unknown { return }
        // Confirmed transition. Flip the recorder and log.
        switch state {
        case .muted:
            recorder.micPaused = true
            Log.writeLine("daemon", "mute probe: user muted → pausing mic capture")
            Log.event(category: "coordinator", action: "mic_paused_due_to_mute", attributes: [
                "bundle_id": handle.bundleID,
            ])
        case .unmuted:
            recorder.micPaused = false
            Log.writeLine("daemon", "mute probe: user unmuted → resuming mic capture")
            Log.event(category: "coordinator", action: "mic_resumed", attributes: [
                "bundle_id": handle.bundleID,
            ])
        case .unknown:
            return
        }
        lastMuteState = state
    }

    private static func muteLabel(_ state: MeetingMuteProbe.State) -> String {
        switch state {
        case .muted: return "muted"
        case .unmuted: return "unmuted"
        case .unknown: return "unknown"
        }
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

        // Re-prompt cooldown gate. After a recording / skipped prompt
        // for this bundle, post-call surfaces (Teams chat reclaiming
        // mic, Zoom's teardown audio session) regularly trigger a
        // fresh `.started` within seconds of the previous end. Drop
        // the prompt for the cooldown window. Manual hotkey path
        // clears the entry so the user can still force a fresh
        // recording in the same app immediately.
        let cooldown = liveRepromptCooldownSec
        if repromptCooldown.isCoolingDown(bundleID: source.bundleID, cooldownSec: cooldown) {
            Log.writeLine(
                "daemon",
                "prompt suppressed (cooldown) → \(source.bundleID) (\(Int(cooldown))s window)"
            )
            Log.event(category: "coordinator", action: "prompt_suppressed_cooldown", attributes: [
                "bundle_id": source.bundleID,
                "cooldown_sec": cooldown,
            ])
            return
        }

        state = .prompting(source: source)
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
        // Skip is a "don't ask again about this call" signal, so we
        // also gate near-future detections of the same bundle. The
        // `suppressed` state already covers the current call (until
        // the detector reports `.ended`), but post-call mic flickers
        // can fire a fresh `.started` after the suppression lifts.
        repromptCooldown.recordEnd(bundleID: source.bundleID)
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
        repromptCooldown.clear(bundleID: source.bundleID)
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
