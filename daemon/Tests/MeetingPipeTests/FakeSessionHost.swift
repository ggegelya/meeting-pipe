import AVFoundation
import Foundation
import MeetingPipeCore
@testable import MeetingPipe

/// A `SessionHost` a test can actually build (ARCH4).
///
/// Coordinator's init constructs ~18 concrete AVFoundation / AppKit subsystems, so
/// no test ever built one, and `MeetingSessionController` (every transition in the
/// daemon) had no constructible coverage at all. This fake stands in for it.
///
/// The six UI / I/O collaborators are recording spies. Everything else is the real
/// type: `DetectionStateMachine`, `MicGate`, `ConsentStore`, `WorkflowStore`,
/// `IdleStopBackstop` and friends are all constructible without TCC, a window
/// server, or a process spawn, so faking them would only add a layer that can lie.
/// The state machine in particular is the real one, which is the point: a test
/// asserts on the state the controller actually drove it into.
final class FakeSessionHost: SessionHost {

    // MARK: Concrete subsystems (the real types)

    let stateMachine = DetectionStateMachine()
    let micGate: MicGate
    let lifecycleCoord = MeetingLifecycleCoordinator()
    let silenceBackstop = IdleStopBackstop()
    let consent: ConsentStore
    let workflowStore: WorkflowStore
    var configStore: ConfigStore?
    let muteLabels: MuteLabels

    // MARK: Spies

    let statusBarSpy = SpyStatusPresenter()
    let notifierSpy = SpyNotifier()
    let recorderSpy = SpyRecorder()
    let hudSpy = SpyHUD()
    let promptSpy = SpyPrompt()
    let jobsSpy = SpyJobDispatcher()

    var statusUI: any SessionStatusPresenting { statusBarSpy }
    var notifications: any SessionNotifying { notifierSpy }
    var audioRecorder: any SessionRecording { recorderSpy }
    var hud: any SessionHUDPresenting { hudSpy }
    var prompt: any SessionPromptPresenting { promptSpy }
    var jobs: any SessionJobDispatching { jobsSpy }

    // MARK: Ambient state the tests drive

    var dryRun = false
    var micAuthorizationStatus: AVAuthorizationStatus = .authorized
    var liveOutputDir: URL
    var liveAutoConsentApps: [String] = []
    var livePromptTimeoutSec: Double = 12
    var liveRepromptCooldownSec: Double = 60
    var liveHonorAppMute = false
    var liveVoiceProcessing = false

    private(set) var menuPreferencesPermissionsCallCount = 0
    func menuPreferencesPermissions() { menuPreferencesPermissionsCallCount += 1 }

    /// `tempDir` backs the output dir, the consent store, and the workflow store,
    /// so nothing here touches the owner's real library or `~/.config`.
    init(tempDir: URL, workflows: [Workflow] = []) {
        self.liveOutputDir = tempDir
        self.consent = ConsentStore(url: tempDir.appendingPathComponent("consent.json"))
        let workflowDir = tempDir.appendingPathComponent("workflows", isDirectory: true)
        try? FileManager.default.createDirectory(at: workflowDir, withIntermediateDirectories: true)
        self.workflowStore = WorkflowStore(directory: workflowDir)
        self.muteLabels = MuteLabels(entries: [:])
        self.micGate = MicGate(catalogue: muteLabels, halBus: CoreAudioHALBus(), axBus: AXObserverBus())
        // Through the real `upsert`, not a back door: the store owns the TOML
        // round-trip and `workflows` is private(set) precisely so nobody skips it.
        for workflow in workflows {
            try? workflowStore.upsert(workflow)
        }
    }
}

// MARK: - Spies

final class SpyStatusPresenter: SessionStatusPresenting {
    private(set) var idleCount = 0
    private(set) var stoppingCount = 0
    private(set) var promptedSources: [AppSource] = []
    private(set) var suppressedSources: [AppSource] = []
    private(set) var permissionRefreshCount = 0
    /// Every `setRecording` the controller drove, in order.
    private(set) var recordings: [(file: URL, source: AppSource?, summaryMode: SummaryMode, workflow: Workflow?)] = []

    func setIdle() { idleCount += 1 }
    func setPrompting(_ source: AppSource) { promptedSources.append(source) }
    func setRecording(file: URL, source: AppSource?, summaryMode: SummaryMode, workflow: Workflow?) {
        recordings.append((file, source, summaryMode, workflow))
    }
    func setStopping() { stoppingCount += 1 }
    func setSuppressed(_ source: AppSource, isStillSuppressed: @escaping () -> Bool) {
        suppressedSources.append(source)
    }
    func refreshMenuForPermissionChange() { permissionRefreshCount += 1 }
}

final class SpyNotifier: SessionNotifying {
    private(set) var errors: [String] = []
    private(set) var recordingStarted: [URL] = []
    private(set) var processing: [URL] = []
    private(set) var skipped: [AppSource] = []
    private(set) var stillMeetingCount = 0
    private(set) var micOnly: [URL] = []
    private(set) var remoteInterrupted: [URL] = []

    func notifyRecordingStarted(file: URL) { recordingStarted.append(file) }
    func notifyProcessing(file: URL) { processing.append(file) }
    func notifyError(_ message: String) { errors.append(message) }
    func notifySkippedMeeting(source: AppSource) { skipped.append(source) }
    func notifyStillMeeting() { stillMeetingCount += 1 }
    func notifyMicOnlyRecording(file: URL, permissionState: SystemAudioCapture.PermissionState) {
        micOnly.append(file)
    }
    func notifyRemoteAudioInterrupted(file: URL) { remoteInterrupted.append(file) }
}

final class SpyRecorder: SessionRecording {
    /// What `start` should do. `.succeed` hands back `fileToReturn`.
    enum StartBehaviour {
        case succeed
        case fail(Error)
        /// Never returns, so a test can observe the in-flight guard.
        case hang
    }

    var startBehaviour: StartBehaviour = .succeed
    var fileToReturn: URL = URL(fileURLWithPath: "/tmp/meetingpipe-test/20260710-1200.wav")
    var stopResult = true

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var lastStartArgs: (outputDir: URL, captureMode: CaptureMode, voiceProcessing: Bool)?
    private(set) var verdicts: [MicGateVerdict] = []

    /// Fulfilled on each `start` entry, so a test can await the async Task that
    /// `beginRecording` spawns instead of sleeping.
    var onStart: (() -> Void)?

    var startedAt: Date?
    var lastSystemFires: UInt64 = 0
    var lastSystemDegraded = false
    var onMicLevel: ((Float) -> Void)?
    var onSystemLevel: ((Float) -> Void)?

    func currentMicLevelDb() -> Float { -30 }

    func start(outputDir: URL, captureMode: CaptureMode, voiceProcessing: Bool) async throws -> URL {
        startCallCount += 1
        lastStartArgs = (outputDir, captureMode, voiceProcessing)
        onStart?()
        switch startBehaviour {
        case .succeed:
            startedAt = Date()
            return fileToReturn
        case .fail(let error):
            throw error
        case .hang:
            // Long enough that a test never outruns it; cancelled with the Task.
            try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
            throw CancellationError()
        }
    }

    func stop() async -> Bool {
        stopCallCount += 1
        return stopResult
    }

    func setMicGateVerdict(_ verdict: MicGateVerdict) { verdicts.append(verdict) }
}

final class SpyHUD: SessionHUDPresenting {
    private(set) var presentCount = 0
    private(set) var dismissCount = 0
    private(set) var blinkCount = 0
    private(set) var presentedWorkflows: [Workflow?] = []

    func present(source: AppSource?, workflow: Workflow?, startedAt: Date, levelProvider: (() -> Float)?) {
        presentCount += 1
        presentedWorkflows.append(workflow)
    }
    func dismiss(animated: Bool) { dismissCount += 1 }
    func blink() { blinkCount += 1 }
}

final class SpyPrompt: SessionPromptPresenting {
    private(set) var presentCount = 0
    private(set) var dismissCount = 0
    private(set) var lastAutoDismissAfter: TimeInterval?
    private(set) var lastAvailableWorkflows: [Workflow] = []

    func present(source: AppSource, workflow: Workflow?, availableWorkflows: [Workflow], autoDismissAfter seconds: TimeInterval) {
        presentCount += 1
        lastAutoDismissAfter = seconds
        lastAvailableWorkflows = availableWorkflows
    }
    func dismiss(animated: Bool) { dismissCount += 1 }
}

final class SpyJobDispatcher: SessionJobDispatching {
    private(set) var enqueued: [(file: URL, summaryMode: SummaryMode)] = []
    func enqueue(file: URL, summaryMode: SummaryMode) { enqueued.append((file, summaryMode)) }
}
