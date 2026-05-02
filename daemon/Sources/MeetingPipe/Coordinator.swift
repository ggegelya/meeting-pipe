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

    private var state: AppState = .idle {
        didSet {
            Log.main.info("state: \(String(describing: oldValue)) → \(String(describing: self.state))")
            // Mid-recording config edits get deferred (see
            // applyConfigRefreshIfPossible) — apply them when we transition
            // back to idle so the next meeting picks up the new values.
            if case .idle = state { applyConfigRefreshIfPossible() }
        }
    }

    /// Auto-skip timer when the user ignores a prompt. Spec §7 prompt_timeout_sec.
    private var promptTimeoutTimer: Timer?

    /// Set when ConfigStore persists while we're mid-recording. We can't
    /// rebuild the Detector live without losing its `hasFiredStart`
    /// bookkeeping (the new instance would never fire `.ended` for the
    /// in-flight meeting). Apply on next `.idle` instead.
    private var pendingDetectorRefresh: Bool = false

    /// Show the "Screen Recording disabled" startup notification at most
    /// once per daemon launch — repeated banners would be noisy.
    private var didNotifyAboutPermissionDenial: Bool = false

    private var configCancellable: AnyCancellable?

    init(
        config: Config,
        statusBar: StatusBarController,
        launcher: PipelineDriver? = nil,
        configStore: ConfigStore? = nil
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
            debounceEndSec: configStore?.debounceEndSec ?? config.detection.debounceEndSec
        )
        self.hotkey = HotkeyManager()
        self.consent = ConsentStore()
        self.launcher = launcher ?? PipelineLauncher()
        self.preferencesWindow = configStore.map { PreferencesWindow(store: $0) }
        super.init()
    }

    func start() {
        notifier.delegate = self
        notifier.requestAuthorization()
        promptWindow.delegate = self
        recordingHUD.delegate = self

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
            Task { await recorder.stop() }
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
        case .stopping, .handoff:
            // Already in flight; ignore.
            break
        }
    }

    private func beginRecording(source: AppSource?, summaryMode: SummaryMode) {
        cancelPromptTimeout()

        do {
            let file = try recorder.start(outputDir: liveOutputDir)
            state = .recording(file: file, source: source, summaryMode: summaryMode)
            statusBar.setRecording(file: file, source: source, summaryMode: summaryMode)
            recordingHUD.present(source: source, startedAt: Date())
            notifier.notifyRecordingStarted(file: file)
            Log.writeLine(
                "daemon",
                "recording started → \(file.path) source=\(source?.bundleID ?? "manual") mode=\(summaryMode == .byo ? "byo" : "auto")"
            )
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

        // Recorder.stop is async — runs on a background task so the UI stays
        // responsive. Once flushed, we kick off the pipeline handoff.
        let recorder = self.recorder
        Task { @MainActor [weak self] in
            await recorder.stop()
            guard let self = self else { return }
            Log.writeLine("daemon", "recording stopped → \(file.path)")
            // The recording captured no system-audio frames AND we know the
            // TCC perm is denied → user just lost the other side of the
            // call. Surface it. We avoid the heuristic "0 frames implies
            // perm denied" because legitimate silent system audio also
            // produces low fire counts; we gate on permissionState too.
            if recorder.lastSystemFires == 0,
               SystemAudioCapture.permissionState == .denied {
                self.notifier.notifyMicOnlyRecording(file: file)
                self.statusBar.refreshMenuForPermissionChange()
            }
            self.handoff(file: file, summaryMode: summaryMode)
        }
    }

    private func handoff(file: URL, summaryMode: SummaryMode) {
        state = .handoff(file: file)
        statusBar.setHandoff()
        notifier.notifyProcessing(file: file)

        launcher.runAll(wav: file, summaryMode: summaryMode) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let pageURL):
                    self.notifier.notifyDone(pageURL: pageURL)
                    Log.writeLine("daemon", "pipeline OK → \(pageURL?.absoluteString ?? "(local-only)")")
                case .failure(let err):
                    self.notifier.notifyError("Pipeline failed: \(err.localizedDescription)")
                    Log.writeLine("daemon", "pipeline FAIL → \(err.localizedDescription)")
                }
                self.state = .idle
                self.statusBar.setIdle()
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
        let fresh = Detector(debounceStartSec: newStart, debounceEndSec: newEnd)
        fresh.delegate = self
        fresh.start()
        detector = fresh
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
    }

    func notifier(_ notifier: Notifier, didChooseAlways source: AppSource) {
        consent.setAutoConsented(bundleID: source.bundleID, value: true)
        Log.writeLine("daemon", "user always-consented (\(source.bundleID))")
        beginRecording(source: source, summaryMode: .auto)
    }

    func notifier(_ notifier: Notifier, didOpenPage url: URL) {
        NSWorkspace.shared.open(url)
    }

    func notifierDidRequestScreenRecordingSettings(_ notifier: Notifier) {
        SystemAudioCapture.openScreenRecordingSettings()
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
