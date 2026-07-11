import AVFoundation
import Foundation
import MeetingPipeCore

/// The seam `MeetingSessionController` sees instead of `Coordinator` (ARCH4).
///
/// TECH-ARCH2 split the session logic out of Coordinator but not the *seams*: the
/// controller reached back through `unowned let coordinator: Coordinator`, so
/// constructing one in a test meant constructing a Coordinator, whose init builds
/// ~18 concrete AVFoundation / AppKit subsystems. Nothing could build it, so the
/// state-machine invariants ARCHITECTURE.md declares (never two `.recording`,
/// `.stopping` always advances) were enforced by `swift build` and nothing else.
///
/// `SessionHost` is that surface, and only that surface: every member the
/// controller reads through `coordinator.`, nothing more. Coordinator conforms in
/// `Coordinator+SessionHost.swift`; `FakeSessionHost` (in the test target) is the
/// other conformer.
///
/// Two design notes worth knowing before extending it:
///
/// - **Only the UI and I/O collaborators are protocol-typed.** The status bar,
///   notifier, recorder, HUD, prompt window, and job dispatcher touch AppKit,
///   AVFoundation, UserNotifications, or spawn processes, so a test cannot have
///   the real ones. Everything else (`DetectionStateMachine`, `MicGate`,
///   `ConsentStore`, `WorkflowStore`, `IdleStopBackstop`, ...) is already
///   constructible in a test and stays concrete. Protocolising those too would be
///   ceremony that buys nothing.
///
/// - **`micAuthorizationStatus` is here even though it is not a Coordinator
///   member.** `beginRecording` read `AVCaptureDevice.authorizationStatus(for:)`
///   directly, a global. That single call is what made the permission-denied
///   branch, the one that decides whether a meeting records at all, untestable.
///   Routing it through the host is the smallest change that opens it up.
protocol SessionHost: AnyObject {
    // Subsystems the controller drives. Concrete where a test can build them.
    var stateMachine: DetectionStateMachine { get }
    var micGate: MicGate { get }
    var lifecycleCoord: MeetingLifecycleCoordinator { get }
    var silenceBackstop: IdleStopBackstop { get }
    var consent: ConsentStore { get }
    var workflowStore: WorkflowStore { get }
    var configStore: ConfigStore? { get }
    var muteLabels: MuteLabels { get }

    // Collaborators a test must fake. Named for their role rather than their
    // concrete type, because Coordinator's stored properties keep the old names
    // (`statusBar`, `notifier`, ...) and a protocol requirement cannot be
    // witnessed by a stored property of a different type.
    var statusUI: any SessionStatusPresenting { get }
    var notifications: any SessionNotifying { get }
    var audioRecorder: any SessionRecording { get }
    var hud: any SessionHUDPresenting { get }
    var prompt: any SessionPromptPresenting { get }
    var jobs: any SessionJobDispatching { get }

    // Ambient state and live-config reads.
    var dryRun: Bool { get }
    var micAuthorizationStatus: AVAuthorizationStatus { get }
    var liveOutputDir: URL { get }
    var liveAutoConsentApps: [String] { get }
    var livePromptTimeoutSec: Double { get }
    var liveRepromptCooldownSec: Double { get }
    var liveHonorAppMute: Bool { get }
    var liveVoiceProcessing: Bool { get }

    /// Deep-links Preferences to the Permissions tab. Called when a start is
    /// refused for a missing microphone permission, so the refusal is actionable.
    func menuPreferencesPermissions()
}

// MARK: - Collaborator protocols
//
// Each lists exactly the members MeetingSessionController calls, so the fake has
// no dead surface. Default arguments live on the concrete types; a protocol
// requirement cannot carry them, which is why the parameters are spelled out.

/// The menu-bar item's state display (`StatusBarController`).
protocol SessionStatusPresenting: AnyObject {
    func setIdle()
    func setPrompting(_ source: AppSource)
    func setRecording(file: URL, source: AppSource?, summaryMode: SummaryMode, workflow: Workflow?)
    func setStopping()
    func setSuppressed(_ source: AppSource, isStillSuppressed: @escaping () -> Bool)
    func refreshMenuForPermissionChange()
}

/// User-facing notifications (`Notifier`).
protocol SessionNotifying: AnyObject {
    func notifyRecordingStarted(file: URL)
    func notifyProcessing(file: URL)
    func notifyError(_ message: String)
    func notifySkippedMeeting(source: AppSource)
    func notifyStillMeeting()
    func notifyMicOnlyRecording(file: URL, permissionState: SystemAudioCapture.PermissionState)
    func notifyRemoteAudioInterrupted(file: URL)
    func notifyMicRecordedNothing(file: URL)
    func notifyInputDeviceMismatch()
}

/// Audio capture (`MeetingRecorder`). `onMicLevel` / `onSystemLevel` are settable:
/// the controller installs them at start and clears them at stop.
protocol SessionRecording: AnyObject {
    var startedAt: Date? { get }
    var lastSystemFires: UInt64 { get }
    var lastSystemDegraded: Bool { get }
    /// Stop-time mic coverage + captured input-device identity (MIC15), read by the controller
    /// for the dead-mic warning and the `mic_device_name` sidecar key.
    var lastMicCoverage: MicCoverageSnapshot { get }
    var lastInputDevice: InputDeviceIdentity? { get }
    var onMicLevel: ((Float) -> Void)? { get set }
    var onSystemLevel: ((Float) -> Void)? { get set }
    func currentMicLevelDb() -> Float
    func start(outputDir: URL, captureMode: CaptureMode, voiceProcessing: Bool) async throws -> URL
    /// Returns whether a usable final artifact reached disk.
    func stop() async -> Bool
    func setMicGateVerdict(_ verdict: MicGateVerdict)
    /// MIC14: toggle the off-the-record state (zero-fill live under the regulated gate, or record a
    /// manual redaction span under capture-first).
    func setManualOffTheRecord(_ on: Bool)
}

/// The recording HUD (`RecordingHUDWindow`).
protocol SessionHUDPresenting: AnyObject {
    func present(source: AppSource?, workflow: Workflow?, startedAt: Date, levelProvider: (() -> Float)?)
    func dismiss(animated: Bool)
    func blink()
    /// MIC14: show or clear the persistent "Off the record" state on the HUD.
    func setOffTheRecord(_ on: Bool)
}

/// The "record this meeting?" prompt (`MeetingPromptWindow`).
protocol SessionPromptPresenting: AnyObject {
    func present(source: AppSource, workflow: Workflow?, availableWorkflows: [Workflow], autoDismissAfter seconds: TimeInterval)
    func dismiss(animated: Bool)
}

// A protocol requirement carries no default argument, but every `dismiss()` call
// site means "animated". Restore the concrete types' default here rather than
// spelling `animated: true` at six call sites.
extension SessionHUDPresenting {
    func dismiss() { dismiss(animated: true) }
}

extension SessionPromptPresenting {
    func dismiss() { dismiss(animated: true) }
}

/// Hands a finished recording to the pipeline (`PipelineJobDispatcher`).
protocol SessionJobDispatching: AnyObject {
    func enqueue(file: URL, summaryMode: SummaryMode)
}

// MARK: - Conformances
//
// Empty where the concrete signatures already match. The compiler is the check
// that this stays an Extract Interface and not a redesign.

extension StatusBarController: SessionStatusPresenting {}
extension Notifier: SessionNotifying {}
extension MeetingRecorder: SessionRecording {}
extension RecordingHUDWindow: SessionHUDPresenting {}
extension MeetingPromptWindow: SessionPromptPresenting {}
extension PipelineJobDispatcher: SessionJobDispatching {}
