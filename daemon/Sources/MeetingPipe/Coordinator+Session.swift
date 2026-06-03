import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import MeetingPipeCore

extension Coordinator {
    // MARK: Live-config readers
    //
    // Prefer the ConfigStore's current value over the boot-time `config`
    // snapshot, so Preferences edits apply without a daemon restart.

    var liveOutputDir: URL {
        guard let raw = configStore?.outputDirPath else { return config.recording.outputDir }
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    var liveAutoConsentApps: [String] {
        configStore?.autoConsentApps ?? config.recording.autoConsentApps
    }

    var livePromptTimeoutSec: Double {
        configStore?.promptTimeoutSec ?? config.detection.promptTimeoutSec
    }

    var liveRepromptCooldownSec: Double {
        configStore?.repromptCooldownSec ?? config.detection.repromptCooldownSec
    }

    var liveHonorAppMute: Bool {
        configStore?.honorAppMute ?? config.recording.honorAppMute
    }

    var liveVoiceProcessing: Bool {
        // Recorder binds this at start time, so live edits only take
        // effect on the next recording. The Preferences sublabel
        // documents that.
        configStore?.voiceProcessing ?? config.recording.voiceProcessing
    }

    var liveManualHotkey: String {
        configStore?.manualHotkey ?? config.detection.manualHotkey
    }

    var liveForceStopHotkey: String {
        configStore?.forceStopHotkey ?? config.detection.forceStopHotkey
    }

    // MARK: State transitions

    func toggleManual() {
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
    func forceStop(reason: String) {
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

    func beginRecording(source: AppSource?, summaryMode: SummaryMode) {
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

    func stopRecording(file: URL, source: AppSource?, summaryMode: SummaryMode) {
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
    func writeMetaSidecar(file: URL, source: AppSource?) {
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

    func startPromptTimeout(for source: AppSource) {
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

    func disarmSilenceDetector() {
        recorder.onMicLevel = nil
        recorder.onSystemLevel = nil
        silenceDetector = nil
    }

    func handleSilenceNotify() {
        Log.writeLine("daemon", "silence: 90s - surfacing 'still meeting?' banner")
        Log.event(category: "coordinator", action: "silence_notified")
        notifier.notifyStillMeeting()
    }

    func handleSilenceAutoStop() {
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
    func engageMicGate(source: AppSource?) {
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

        // Authoritative 1 Hz mute-state poll: re-resolves and reads the live
        // mute button(s) each tick (survives Teams 2 compact-view / backgrounded
        // window swaps and dropped AX notifications); events flow back via
        // injectAxMuteEvent. The primary probe above is the foreground fast-path.
        let watcher = MeetingAXWindowWatcher(
            pid: handles.context.pid,
            bundleID: handles.context.bundleID,
            catalogue: muteLabels,
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
    func handleDiscovery(_ source: AppSource) {
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
    func engageLifecycle(for source: AppSource) {
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
    func armLifecycleLeaveButton(source: AppSource?) {
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
        lifecycleCoord.armLeaveButton(leaveButton)
    }

    /// Tear down the lifecycle adapter + reset the engine. Wired to the
    /// state machine's idle transition so every idle path disengages once.
    func disengageLifecycle() {
        lifecycleCoord.disengage()
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
