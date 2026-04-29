import AppKit
import Foundation

/// Top-level state owner. Detector and HotkeyManager push events in; Coordinator
/// drives the state machine and tells Recorder / Notifier what to do.
///
/// Threading: every public method must run on the main queue. Detector and
/// HotkeyManager already dispatch back here.
final class Coordinator: NSObject {
    private let config: Config
    private let statusBar: StatusBarController
    private let recorder: Recorder
    private let notifier: Notifier
    private let detector: Detector
    private let hotkey: HotkeyManager
    private let consent: ConsentStore
    private let launcher: PipelineLauncher
    private let audioRouter: AudioRouter
    /// Non-nil only on macOS 14.2+. Type-erased to keep the field
    /// declaration outside the @available umbrella.
    private let processTapRouter: AnyObject?

    /// Which capture path is currently engaged for the active recording.
    /// Drives teardown so we hit the correct router on stop.
    private enum ActiveCapture { case none, processTap, blackHole }
    private var activeCapture: ActiveCapture = .none

    /// Overrides config.recording.audioDevice for the duration of an active
    /// recording when ProcessTapRouter generates a transient device name.
    private var captureDeviceOverride: String?

    private var state: AppState = .idle {
        didSet { Log.main.info("state: \(String(describing: oldValue)) → \(String(describing: self.state))") }
    }

    /// Auto-skip timer when the user ignores a prompt. Spec §7 prompt_timeout_sec.
    private var promptTimeoutTimer: Timer?

    init(config: Config, statusBar: StatusBarController) {
        self.config = config
        self.statusBar = statusBar
        self.recorder = Recorder()
        self.notifier = Notifier()
        self.detector = Detector(
            debounceStartSec: config.detection.debounceStartSec,
            debounceEndSec: config.detection.debounceEndSec
        )
        self.hotkey = HotkeyManager()
        self.consent = ConsentStore()
        self.launcher = PipelineLauncher()
        self.audioRouter = AudioRouter()
        if #available(macOS 14.2, *) {
            self.processTapRouter = ProcessTapRouter()
        } else {
            self.processTapRouter = nil
        }
        super.init()
    }

    /// Resolves config.captureMode + macOS version to the actual backend.
    private func effectiveCaptureMode() -> ActiveCapture {
        switch config.recording.captureMode.lowercased() {
        case "process_tap":
            if #available(macOS 14.2, *) { return .processTap }
            Log.recorder.warning("capture_mode=process_tap requires macOS 14.2+; falling back to blackhole")
            return .blackHole
        case "blackhole":
            return .blackHole
        case "none":
            return .none
        default: // "auto" or anything we don't recognize
            if #available(macOS 14.2, *) { return .processTap }
            return .blackHole
        }
    }

    func start() {
        notifier.delegate = self
        notifier.requestAuthorization()

        detector.delegate = self
        detector.start()

        if let parsed = HotkeyManager.parse(config.detection.manualHotkey) {
            hotkey.register(keyCode: parsed.keyCode, modifiers: parsed.modifiers) { [weak self] in
                DispatchQueue.main.async { self?.toggleManual() }
            }
            Log.main.info("Hotkey registered: \(self.config.detection.manualHotkey)")
        } else {
            Log.main.warning("Could not parse hotkey: \(self.config.detection.manualHotkey)")
        }
    }

    func shutdown() {
        Log.main.info("shutting down")
        detector.stop()
        hotkey.unregister()
        if recorder.isRecording {
            // Best-effort flush; we don't want orphan ffmpeg.
            recorder.stop()
        }
        // Always run — no-op if nothing was enabled. Ensures we never
        // leave the user's system output pointed at our transient device,
        // and don't leak transient process taps / aggregate devices.
        tearDownActiveCapture()
    }

    // MARK: Menu actions

    @objc func menuStart() { toggleManual() }
    @objc func menuStop() { toggleManual() }

    @objc func menuOpenLogs() {
        NSWorkspace.shared.open(Log.logsDir)
    }

    @objc func menuOpenRecordings() {
        try? FileManager.default.createDirectory(at: config.recording.outputDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(config.recording.outputDir)
    }

    // MARK: State transitions

    private func toggleManual() {
        switch state {
        case .idle, .prompting, .suppressed:
            beginRecording(source: nil)
        case .recording(let file, let src):
            stopRecording(file: file, source: src)
        case .stopping, .handoff:
            // Already in flight; ignore.
            break
        }
    }

    private func beginRecording(source: AppSource?) {
        cancelPromptTimeout()

        let mode = effectiveCaptureMode()
        var deviceName = config.recording.audioDevice
        activeCapture = .none
        captureDeviceOverride = nil

        // Engage the chosen capture backend. Each branch is best-effort:
        // a failure here logs + degrades gracefully (mic-only) rather than
        // aborting the recording entirely.
        switch mode {
        case .processTap:
            if #available(macOS 14.2, *), let router = processTapRouter as? ProcessTapRouter {
                do {
                    deviceName = try router.prepare()
                    activeCapture = .processTap
                    captureDeviceOverride = deviceName
                    Log.recorder.info("capture: process_tap → device=\(deviceName)")
                } catch {
                    Log.recorder.warning("process_tap setup failed (\(error.localizedDescription)); proceeding mic-only")
                    notifier.notifyError("System audio capture: \(error.localizedDescription)")
                }
            }

        case .blackHole:
            if config.recording.autoRouteOutput {
                do {
                    try audioRouter.enableCapture()
                    activeCapture = .blackHole
                } catch {
                    Log.recorder.warning("audio routing skipped: \(error.localizedDescription)")
                    notifier.notifyError("Audio routing: \(error.localizedDescription)")
                }
            }

        case .none:
            // Mic-only by user request.
            break
        }

        do {
            let file = try recorder.start(
                deviceName: deviceName,
                sampleRate: config.recording.sampleRate,
                outputDir: config.recording.outputDir
            )
            state = .recording(file: file, source: source)
            statusBar.setRecording(file: file)
            notifier.notifyRecordingStarted(file: file)
            Log.writeLine("daemon", "recording started → \(file.path) source=\(source?.bundleID ?? "manual") capture=\(activeCapture)")
        } catch {
            // Recorder failed — undo whichever capture path we engaged.
            tearDownActiveCapture()
            Log.main.error("failed to start recorder: \(error.localizedDescription)")
            notifier.notifyError("Could not start recording: \(error.localizedDescription)")
            state = .idle
            statusBar.setIdle()
        }
    }

    /// Reverse of the per-mode setup in beginRecording. Idempotent.
    private func tearDownActiveCapture() {
        switch activeCapture {
        case .processTap:
            if #available(macOS 14.2, *), let router = processTapRouter as? ProcessTapRouter {
                router.teardown()
            }
        case .blackHole:
            audioRouter.restoreOutput()
        case .none:
            break
        }
        activeCapture = .none
        captureDeviceOverride = nil
    }

    private func stopRecording(file: URL, source: AppSource?) {
        state = .stopping(file: file, source: source)
        statusBar.setStopping()

        // ffmpeg shutdown can take a beat; run off the main queue so the UI stays live.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.recorder.stop()
            DispatchQueue.main.async {
                // Tear down whichever capture backend we engaged AFTER ffmpeg
                // has flushed — flipping mid-recording would cause a click in
                // the captured audio.
                self.tearDownActiveCapture()
                Log.writeLine("daemon", "recording stopped → \(file.path)")
                self.handoff(file: file)
            }
        }
    }

    private func handoff(file: URL) {
        state = .handoff(file: file)
        statusBar.setHandoff()
        notifier.notifyProcessing(file: file)

        launcher.runAll(wav: file) { [weak self] result in
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
        promptTimeoutTimer = Timer.scheduledTimer(withTimeInterval: config.detection.promptTimeoutSec, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if case .prompting(let src) = self.state, src == source {
                    Log.writeLine("daemon", "prompt timed out → suppressed (\(source.bundleID))")
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
        if config.recording.autoConsentApps.contains(source.bundleID) ||
           consent.isAutoConsented(bundleID: source.bundleID) {
            Log.writeLine("daemon", "auto-consent → recording (\(source.bundleID))")
            beginRecording(source: source)
            return
        }

        state = .prompting(source: source)
        statusBar.setPrompting(source)
        notifier.notifyMeetingDetected(source: source)
        startPromptTimeout(for: source)
        Log.writeLine("daemon", "meeting detected → prompting (\(source.bundleID))")
    }

    private func handleMeetingEnded() {
        switch state {
        case .recording(let file, let src):
            stopRecording(file: file, source: src)
        case .prompting, .suppressed:
            cancelPromptTimeout()
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
        beginRecording(source: source)
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
        beginRecording(source: source)
    }

    func notifier(_ notifier: Notifier, didOpenPage url: URL) {
        NSWorkspace.shared.open(url)
    }
}
