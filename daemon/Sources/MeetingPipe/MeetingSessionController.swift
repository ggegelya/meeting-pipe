import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import MeetingPipeCore

/// Owns one meeting's lifetime (TECH-ARCH2): the two verdict-consumer Tasks,
/// the recording begin/stop path, prompt-timeout, silence-detector arming, the
/// MicGate / lifecycle engage-disengage, and meta-sidecar writing. Coordinator
/// owns the subsystems and the UI-delegate conformances, and forwards detection
/// and delegate events here. Subsystems are reached through `coordinator`, which
/// stays the central state owner; this type holds only the per-meeting state.
/// All methods run on the main queue, like Coordinator's.
final class MeetingSessionController {
    /// Back-reference to the state owner. `unowned` because Coordinator owns
    /// this controller (so it never outlives the coordinator).
    unowned let coordinator: Coordinator

    /// Workflow for the in-flight recording (TECH-B3); nil between meetings.
    /// Read by `writeMetaSidecar`, cleared after flush.
    var activeWorkflow: Workflow?

    /// User's explicit workflow pick from the prompt chevron (TECH-B5),
    /// consumed by the next `beginRecording`. Highest matcher precedence,
    /// so it wins over rule matches.
    var pendingWorkflowOverride: UUID?

    /// Surfaces a missed meeting end (TECH-C2): notify after 90 s of
    /// mic+system silence, auto-stop after 5 min. Lives for the recording.
    var silenceDetector: SilenceDetector?

    /// Observes window-created events so mute buttons that appear after
    /// `beginRecording` (Teams 2 compact view, PIP overlays) get watched
    /// too. Per-meeting (TECH-C14).
    var axWindowWatcher: MeetingAXWindowWatcher?

    /// Latest system-audio dBFS (from `recorder.onSystemLevel`), read by
    /// the silence backstop. `-120` is the "no audio observed yet" sentinel.
    var latestSystemLevelDb: Float = -120

    /// Consumes `micGate.verdicts` (started in `startConsumers()`, cancelled at
    /// shutdown); forwards each to the recorder writer + silence backstop.
    var verdictConsumerTask: Task<Void, Never>?

    /// Consumes `lifecycleCoord.verdicts`; routes `.ended` into the
    /// recording-end path.
    var lifecycleConsumerTask: Task<Void, Never>?

    /// System channel "carries audio" above this 1 s RMS floor. Mirrors
    /// `SilenceDetector.defaultThresholdDb` so the backstop and the 5-min
    /// auto-stop draw the same line.
    private static let systemSilenceThresholdDb: Double = SilenceDetector.defaultThresholdDb

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Verdict consumers (started from Coordinator.start)

    /// Drive the recorder writer + silence backstop from the gate's verdict
    /// stream, and route lifecycle verdicts into prompt/record/end. Both
    /// streams are unbounded and daemon-lifetime; cancelled in `shutdownConsumers`.
    func startConsumers() {
        verdictConsumerTask = Task { [weak self] in
            guard let self = self else { return }
            for await verdict in self.coordinator.micGate.verdicts {
                await MainActor.run {
                    self.coordinator.recorder.setMicGateVerdict(verdict)
                    let hasSystem = Double(self.latestSystemLevelDb) > Self.systemSilenceThresholdDb
                    self.coordinator.silenceBackstop.ingest(verdict: verdict, hasSystemAudio: hasSystem)
                }
            }
        }

        // Lifecycle verdicts: `.starting` raises the prompt,
        // `.endingProvisional` triggers the compact-view rescue re-walk,
        // `.ended` closes the recording or dismisses a stale prompt.
        lifecycleConsumerTask = Task { [weak self] in
            guard let self = self else { return }
            for await verdict in self.coordinator.lifecycleCoord.verdicts {
                await MainActor.run {
                    switch verdict {
                    case .starting(let context):
                        self.handleMeetingStarted(source: self.appSource(from: context))
                    case .endingProvisional(let context, _):
                        self.rescueProvisionalEnd(context: context)
                    case .ended(_, let reason):
                        self.handleMeetingEnded(reason: reason)
                    default:
                        break
                    }
                }
            }
        }
    }

    func shutdownConsumers() {
        verdictConsumerTask?.cancel()
        verdictConsumerTask = nil
        lifecycleConsumerTask?.cancel()
        lifecycleConsumerTask = nil
    }

    // MARK: - State transitions

    func toggleManual() {
        switch coordinator.stateMachine.current {
        case .idle:
            beginRecording(source: nil, summaryMode: .auto)
        case .prompting(let src), .suppressed(let src):
            // Keep the source so "Always for {App}" still attributes; clear
            // the cooldown so this explicit start isn't suppressed.
            coordinator.promptWindow.dismiss()
            coordinator.stateMachine.clearCooldown(bundleID: src.bundleID)
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
    func forceStop(reason: String) {
        Log.event(category: "coordinator", action: "force_stop", attributes: [
            "reason": reason,
            "state": DetectionStateMachine.label(coordinator.stateMachine.current),
        ])
        switch coordinator.stateMachine.current {
        case .recording(let file, let src, let mode):
            stopRecording(file: file, source: src, summaryMode: mode)
        case .prompting(let src):
            // Same as Skip: suppress until the detector sees this meeting end.
            coordinator.stateMachine.cancelPromptTimeout()
            coordinator.promptWindow.dismiss()
            coordinator.stateMachine.setSuppressed(source: src)
            coordinator.statusBar.setIdle()
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
            workflows: coordinator.workflowStore.workflows
        )
    }

    func beginRecording(source: AppSource?, summaryMode: SummaryMode) {
        coordinator.stateMachine.cancelPromptTimeout()

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
            coordinator.notifier.notifyError("Microphone permission is required. Grant it in Preferences → Permissions, then try again.")
            // Deeplink to the Permissions section so the user can act.
            coordinator.menuPreferencesPermissions()
            coordinator.stateMachine.setIdle()
            coordinator.statusBar.setIdle()
            return
        }

        if coordinator.dryRun {
            // Detection ran but we deliberately skip the recorder/HUD and
            // return to .idle, so a workday logs as detection-only signals.
            Log.writeLine("daemon", "[dry-run] would record (\(source?.bundleID ?? "manual"))")
            Log.event(category: "coordinator", action: "dry_run_would_record", attributes: [
                "bundle_id": source?.bundleID ?? "manual",
                "summary_mode": summaryMode == .byo ? "byo" : "auto",
            ])
            coordinator.stateMachine.setIdle()
            coordinator.statusBar.setIdle()
            return
        }

        // Resolve the workflow controlling context/backend/sinks (TECH-B3):
        // override, then rule matches, then default. Clear the override so
        // it can't leak into the next meeting.
        let resolvedWorkflow = WorkflowMatcher.resolve(
            source: source,
            overrideID: pendingWorkflowOverride,
            workflows: coordinator.workflowStore.workflows
        )
        pendingWorkflowOverride = nil

        do {
            let file = try coordinator.recorder.start(
                outputDir: coordinator.liveOutputDir,
                voiceProcessing: coordinator.liveVoiceProcessing
            )
            activeWorkflow = resolvedWorkflow
            coordinator.stateMachine.setRecording(file: file, source: source, summaryMode: summaryMode)
            coordinator.statusBar.setRecording(file: file, source: source, summaryMode: summaryMode, workflow: resolvedWorkflow)
            coordinator.recordingHUD.present(
                source: source,
                workflow: resolvedWorkflow,
                startedAt: Date(),
                levelProvider: { [weak self] in self?.coordinator.recorder.currentMicLevelDb() ?? -120 }
            )
            coordinator.notifier.notifyRecordingStarted(file: file)
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
            coordinator.lifecycleCoord.confirmRecording()
        } catch {
            Log.main.error("failed to start recorder: \(error.localizedDescription)")
            coordinator.notifier.notifyError("Could not start recording: \(error.localizedDescription)")
            coordinator.stateMachine.setIdle()
            coordinator.statusBar.setIdle()
        }
    }

    func stopRecording(file: URL, source: AppSource?, summaryMode: SummaryMode) {
        coordinator.stateMachine.setStopping(file: file, source: source, summaryMode: summaryMode)
        coordinator.statusBar.setStopping()
        coordinator.recordingHUD.dismiss()
        disarmSilenceDetector()
        // Tear down per-meeting AX subscriptions; the verdict stream stays
        // open for the next meeting.
        coordinator.lifecycleCoord.disengage()
        coordinator.micGate.stop()
        axWindowWatcher?.stop()
        axWindowWatcher = nil

        // recorder.stop is async (off the UI); once flushed, enqueue for the
        // pipeline and return to .idle so the next meeting can start.
        let recorder = coordinator.recorder
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
                self.coordinator.notifier.notifyMicOnlyRecording(file: file, permissionState: perm)
                if perm == .denied || perm == .unknown {
                    self.coordinator.statusBar.refreshMenuForPermissionChange()
                }
            }
            self.writeMetaSidecar(file: file, source: source)
            self.coordinator.notifier.notifyProcessing(file: file)
            self.coordinator.jobDispatcher.enqueue(file: file, summaryMode: summaryMode)
            // Drop the workflow so it can't bleed into the next meeting.
            self.activeWorkflow = nil
            // Arm the re-prompt cooldown so a post-call mic grab (Teams chat,
            // Zoom teardown toast) can't re-prompt right after the flush.
            if let bid = source?.bundleID {
                self.coordinator.stateMachine.recordCooldownEnd(bundleID: bid)
            }
            self.coordinator.stateMachine.setIdle()
            self.coordinator.statusBar.setIdle()
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
    func writeMetaSidecar(file: URL, source: AppSource?) {
        let dict = MeetingMetaSidecar.build(
            source: source,
            workflow: activeWorkflow,
            regulatedMode: coordinator.configStore?.regulatedMode ?? false
        )
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

    func startPromptTimeout(for source: AppSource) {
        coordinator.stateMachine.startPromptTimeout(
            for: source,
            timeoutSec: coordinator.livePromptTimeoutSec
        ) { [weak self] in
            guard let self = self else { return }
            let action = (self.coordinator.configStore?.defaultPromptAction ?? "skip").lowercased()
            self.coordinator.promptWindow.dismiss()
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
                self.coordinator.stateMachine.setSuppressed(source: source)
                // Like an explicit Skip: arm the cooldown to absorb post-call
                // mic flickers once suppression lifts.
                self.coordinator.stateMachine.recordCooldownEnd(bundleID: source.bundleID)
                self.coordinator.statusBar.setIdle()
            }
        }
    }

    // MARK: - Detection-to-record handlers (lifecycle verdict consumers)

    func handleMeetingStarted(source: AppSource) {
        guard coordinator.stateMachine.isAcceptingPrompts else { return }

        // Auto-consent (config or persisted "Always").
        if coordinator.liveAutoConsentApps.contains(source.bundleID) ||
           coordinator.consent.isAutoConsented(bundleID: source.bundleID) {
            Log.writeLine("daemon", "auto-consent → recording (\(source.bundleID))")
            Log.event(category: "coordinator", action: "auto_consent", attributes: [
                "bundle_id": source.bundleID,
            ])
            beginRecording(source: source, summaryMode: .auto)
            return
        }

        coordinator.stateMachine.setPrompting(source: source)
        coordinator.statusBar.setPrompting(source)
        // The on-screen panel is the primary surface (not suppressed under
        // Focus modes); the banner stays off by default. Pass the resolved
        // workflow + full set so the chip and override menu render (TECH-B5).
        let promptWorkflow = workflowForPrompt(source: source)
        coordinator.promptWindow.present(
            source: source,
            workflow: promptWorkflow,
            availableWorkflows: coordinator.workflowStore.workflows,
            autoDismissAfter: coordinator.livePromptTimeoutSec
        )
        startPromptTimeout(for: source)
        Log.writeLine("daemon", "meeting detected → prompting (\(source.bundleID))")
        Log.event(category: "coordinator", action: "prompt_shown", attributes: [
            "bundle_id": source.bundleID,
            "display_name": source.displayName,
            "timeout_sec": coordinator.livePromptTimeoutSec,
        ])
    }

    func handleMeetingEnded(reason: EndingReason) {
        switch coordinator.stateMachine.current {
        case .recording(let file, let src, let mode):
            // Recording-stop honors every end, including uncorroborated ones: a
            // missed real end (recording runs forever) is worse than a rare late
            // stop. This path is deliberately unchanged.
            stopRecording(file: file, source: src, summaryMode: mode)
        case .prompting, .suppressed:
            // A bare leave-button invalidation with zero corroboration is the
            // Teams compact/mini-window swap, not a real end (PromptEndPolicy).
            // Acting on it here used to tear down an explicit Skip and re-open the
            // prompt every ~minute for the whole call.
            guard PromptEndPolicy.clearsPromptState(reason: reason) else {
                Log.event(category: "coordinator", action: "prompt_end_ignored_unconfirmed", attributes: [
                    "leading_signal": reason.leadingSignal,
                    "state": DetectionStateMachine.label(coordinator.stateMachine.current),
                ])
                return
            }
            handleMeetingEndedDuringPrompt()
        default:
            break
        }
    }

    /// Dismiss a stale prompt when the meeting ends before the user
    /// answers. Reached via the lifecycle `.ended` verdict.
    func handleMeetingEndedDuringPrompt() {
        switch coordinator.stateMachine.current {
        case .prompting, .suppressed:
            coordinator.stateMachine.cancelPromptTimeout()
            coordinator.promptWindow.dismiss()
            coordinator.stateMachine.setIdle()
            coordinator.statusBar.setIdle()
        default:
            break
        }
    }

    // MARK: - Silence detection (TECH-C2)

    func armSilenceDetector() {
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
        coordinator.recorder.onMicLevel = { [weak self] db in
            self?.silenceDetector?.observeMic(db: Double(db))
        }
        // One callback site feeds both the detector and the backstop's
        // level mirror so the two can't drift.
        coordinator.recorder.onSystemLevel = { [weak self] db in
            guard let self = self else { return }
            self.latestSystemLevelDb = db
            self.silenceDetector?.observeSystem(db: Double(db))
        }
    }

    func disarmSilenceDetector() {
        coordinator.recorder.onMicLevel = nil
        coordinator.recorder.onSystemLevel = nil
        silenceDetector = nil
    }

    func handleSilenceNotify() {
        Log.writeLine("daemon", "silence: 90s - surfacing 'still meeting?' banner")
        Log.event(category: "coordinator", action: "silence_notified")
        coordinator.notifier.notifyStillMeeting()
    }

    func handleSilenceAutoStop() {
        guard case .recording(let file, let src, let mode) = coordinator.stateMachine.current else { return }
        // Stand the backstop down when a native meeting is still tracked live:
        // the silence is a wait for someone to join, not an end. Re-nudge and
        // keep recording instead of killing an active meeting (TECH-C2). Browser
        // / stale-window / manual recordings still stop on schedule.
        guard SilenceAutoStopPolicy.shouldAutoStop(
            sourceKind: src?.kind,
            lifecycleIsLive: coordinator.lifecycleCoord.current.isLive
        ) else {
            Log.writeLine("daemon", "silence: 5min but meeting still live - keeping recording")
            Log.event(category: "coordinator", action: "auto_stop_silence_skipped", attributes: [
                "reason": "lifecycle_still_in_meeting",
                "bundle_id": src?.bundleID ?? "manual",
                "file": file.lastPathComponent,
            ])
            silenceDetector?.keepAlive()
            coordinator.notifier.notifyStillMeeting()
            return
        }
        Log.writeLine("daemon", "silence: 5min - auto-stopping recording")
        Log.event(category: "coordinator", action: "auto_stop_silence", attributes: [
            "bundle_id": src?.bundleID ?? "manual",
            "file": file.lastPathComponent,
        ])
        stopRecording(file: file, source: src, summaryMode: mode)
    }

    /// User tapped "Keep recording" on the silence nudge: restart the silence
    /// countdown so the recording is not auto-stopped. The single override for
    /// the browser / stale-window meetings the native lifecycle gate cannot
    /// cover. (TECH-C2)
    func keepRecordingFromNudge() {
        guard case .recording = coordinator.stateMachine.current else { return }
        Log.event(category: "coordinator", action: "silence_keep_recording")
        silenceDetector?.keepAlive()
    }

    // MARK: - MicGate engage (TECH-G-MIC + TECH-C13)

    /// Build the AX handles and engage MicGate; also primes the silence
    /// backstop. Manual / browser-no-AX sources fall through to HAL VAD +
    /// RMS only (empty handles).
    func engageMicGate(source: AppSource?) {
        coordinator.silenceBackstop.reset()
        latestSystemLevelDb = -120
        guard coordinator.liveHonorAppMute, let source = source else { return }
        guard let handles = MeetingAXHandleBuilder.build(source: source, catalogue: coordinator.muteLabels) else {
            Log.event(category: "coordinator", action: "micgate_engage_skipped", attributes: [
                "bundle_id": source.bundleID,
                "reason": "no_pid",
            ])
            return
        }
        do {
            try coordinator.micGate.start(context: handles.context, handle: handles.micGate)
        } catch {
            Log.event(category: "coordinator", action: "micgate_start_failed", attributes: [
                "bundle_id": source.bundleID,
                "error": error.localizedDescription,
            ])
        }

        // Authoritative 1 Hz mute-state poll: re-resolves and reads the live
        // mute button(s) each tick (survives Teams 2 compact-view / backgrounded
        // window swaps and dropped AX notifications); events flow back via
        // injectAxMuteEvent. The primary probe above is the foreground fast-path.
        let watcher = MeetingAXWindowWatcher(
            pid: handles.context.pid,
            bundleID: handles.context.bundleID,
            catalogue: coordinator.muteLabels,
            eventLog: LogEventAdapter(),
            onMuteEvent: { [weak self] event in
                self?.coordinator.micGate.injectAxMuteEvent(event)
            },
            onMuteCleared: { [weak self] in
                self?.coordinator.micGate.clearAxMute()
            }
        )
        watcher.start()
        axWindowWatcher = watcher
    }

    // MARK: - Lifecycle discovery (TECH-C13)

    /// Discovery found a meeting source: engage the lifecycle subsystem if
    /// idle and the bundle isn't in its post-meeting cooldown.
    func handleDiscovery(_ source: AppSource) {
        guard coordinator.stateMachine.isAcceptingPrompts else { return }
        if coordinator.stateMachine.isCoolingDown(
            bundleID: source.bundleID,
            cooldownSec: coordinator.liveRepromptCooldownSec
        ) {
            return
        }
        engageLifecycle(for: source)
    }

    /// Engage the lifecycle adapter so it fuses PRIMARY signals into the
    /// verdict stream.
    func engageLifecycle(for source: AppSource) {
        guard let handles = MeetingAXHandleBuilder.build(source: source, catalogue: coordinator.muteLabels) else {
            Log.event(category: "coordinator", action: "lifecycle_engage_skipped", attributes: [
                "bundle_id": source.bundleID,
                "reason": "no_pid",
            ])
            return
        }
        do {
            try coordinator.lifecycleCoord.engage(context: handles.context, handle: handles.lifecycle)
        } catch {
            Log.event(category: "coordinator", action: "lifecycle_engage_failed", attributes: [
                "bundle_id": source.bundleID,
                "error": error.localizedDescription,
            ])
        }
    }

    /// Serial queue for cross-process AX tree walks that would otherwise run on
    /// the main thread at recording-start. Mirrors `MeetingDiscoveryWatcher.scanQueue`.
    private static let axWalkQueue = DispatchQueue(
        label: "com.meetingpipe.session.ax-walk",
        qos: .userInitiated
    )

    /// Late-arm the Leave-button signal at recording-start: the
    /// discovery-time walk usually runs before the call UI renders the
    /// button. Idempotent; a still-missing button leaves the recording on
    /// the silence backstop.
    ///
    /// The AX tree walk (a cross-process DFS over every window) runs OFF the
    /// main thread so it can't stall the run loop right after the HUD appears,
    /// then hops back to main to arm. This is end-detection only, so arming a
    /// beat later (the call just started) is harmless. The mic-gate engage
    /// deliberately stays synchronous: its verdict gates the very first buffers
    /// and the recorder zeros the mic until that first verdict, so deferring it
    /// would clip the start of the recording.
    func armLifecycleLeaveButton(source: AppSource?) {
        guard let source = source else { return }
        let catalogue = coordinator.muteLabels
        Self.axWalkQueue.async { [weak self] in
            guard
                let handles = MeetingAXHandleBuilder.build(source: source, catalogue: catalogue),
                let leaveButton = handles.lifecycle.leaveButton
            else { return }
            DispatchQueue.main.async {
                self?.coordinator.lifecycleCoord.armLeaveButton(leaveButton)
            }
        }
    }

    /// Rescue a provisional end caused by the Teams 2 compact-view swap,
    /// which destroys the Leave button while the call continues. If a Leave
    /// button still exists (moved to the compact panel), re-arm on it so its
    /// healthy baseline flips back to `.inMeeting` before the debounce
    /// promotes to `.ended`. A genuine end finds none and proceeds.
    func rescueProvisionalEnd(context: MeetingLifecycleContext) {
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
        coordinator.lifecycleCoord.armLeaveButton(leaveButton)
    }

    /// Tear down the lifecycle adapter + reset the engine. Wired to the
    /// state machine's idle transition so every idle path disengages once.
    func disengageLifecycle() {
        coordinator.lifecycleCoord.disengage()
    }

    /// Bridge a lifecycle context back into an `AppSource` for the prompt +
    /// matcher: resolve the display name via `NSRunningApplication` and
    /// re-walk the title for the matcher's title rules.
    func appSource(from context: MeetingLifecycleContext) -> AppSource {
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
