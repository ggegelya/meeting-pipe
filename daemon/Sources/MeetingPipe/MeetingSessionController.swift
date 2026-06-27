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

    /// Observes window-created events so mute buttons that appear after
    /// `beginRecording` (Teams 2 compact view, PIP overlays) get watched
    /// too. Per-meeting (TECH-C14).
    var axWindowWatcher: MeetingAXWindowWatcher?

    /// True while an async `beginRecording` start is in flight. The engine
    /// bring-up is bounded off the main thread now, so the UI stays live during
    /// it; this guard stops a second Record/toggle press from stacking another
    /// `recorder.start()` (five stacked starts were seen in the 2026-06-12 freeze).
    private var recordingStartInFlight = false

    /// Latest system-audio dBFS (from `recorder.onSystemLevel`), read by
    /// the silence backstop. `-120` is the "no audio observed yet" sentinel.
    var latestSystemLevelDb: Float = -120

    /// Last MicGate verdict seen on the (deduped) verdict stream, re-fed to the
    /// idle backstop on the ~1 Hz mic-level callback so its horizons advance on
    /// the clock even when the verdict has stopped changing (TECH-END7). `nil`
    /// until the first verdict of a recording; reset at engage and stop.
    var latestVerdict: MicGateVerdict?

    /// Consumes `micGate.verdicts` (started in `startConsumers()`, cancelled at
    /// shutdown); forwards each to the recorder writer + silence backstop.
    var verdictConsumerTask: Task<Void, Never>?

    /// Consumes `lifecycleCoord.verdicts`; routes `.ended` into the
    /// recording-end path.
    var lifecycleConsumerTask: Task<Void, Never>?

    /// System channel "carries audio" above this 1 s RMS floor; the idle backstop's
    /// `hasSystemAudio` read draws the line here (TECH-END3).
    private static let systemSilenceThresholdDb: Double = -50.0

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
                    self.latestVerdict = verdict
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
            // Keep the source so "Always for {App}" still attributes; clear every
            // suppression (cooldown + skip latch) so this explicit start isn't held off.
            coordinator.promptWindow.dismiss()
            coordinator.stateMachine.clearSuppression(bundleID: src.bundleID)
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
            // Same as Skip: don't record, return to idle, and cool down the bundle
            // so the next discovery poll doesn't immediately re-prompt this meeting.
            coordinator.promptWindow.dismiss()
            coordinator.stateMachine.abandonPrompt(source: src)
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

        // A start is async now (the engine bring-up is bounded off the main
        // thread), so the UI stays live while a wedged device is waited out.
        // Ignore a second Record/toggle press while one is in flight rather than
        // stacking another recorder.start().
        guard !recordingStartInFlight else {
            Log.writeLine("daemon", "beginRecording ignored: a start is already in flight")
            return
        }

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

        // Resolve the capture mode (TECH-MIC4): regulated (global) or NDA
        // (per-workflow) takes the no-audio-at-rest gate; everything else
        // captures losslessly. Offline muted-span redaction (TECH-MIC5) is
        // opt-in per workflow and off by default (TECH-MIC9), so a normal
        // meeting keeps the full mic regardless of the mute oracle.
        let captureMode = CaptureMode.resolve(
            regulated: coordinator.configStore?.regulatedMode ?? false,
            nda: resolvedWorkflow?.flags.ndaMode ?? false,
            redactMuted: resolvedWorkflow?.flags.redactMutedSpans ?? false
        )

        // Committed to starting: guard re-entry until this start resolves. The
        // recorder bounds the engine bring-up off the main thread, so the await
        // below never blocks the UI; the post-start wiring runs back on main.
        recordingStartInFlight = true
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer { self.recordingStartInFlight = false }
            do {
                let file = try await self.coordinator.recorder.start(
                    outputDir: self.coordinator.liveOutputDir,
                    captureMode: captureMode,
                    voiceProcessing: self.coordinator.liveVoiceProcessing
                )
                self.activeWorkflow = resolvedWorkflow
                self.coordinator.stateMachine.setRecording(file: file, source: source, summaryMode: summaryMode)
                self.coordinator.statusBar.setRecording(file: file, source: source, summaryMode: summaryMode, workflow: resolvedWorkflow)
                self.coordinator.recordingHUD.present(
                    source: source,
                    workflow: resolvedWorkflow,
                    startedAt: Date(),
                    levelProvider: { [weak self] in self?.coordinator.recorder.currentMicLevelDb() ?? -120 }
                )
                self.coordinator.notifier.notifyRecordingStarted(file: file)
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
                self.armSystemLevelMirror()
                self.engageMicGate(source: source)
                // Re-walk for the Leave button now the call UI has rendered;
                // the discovery-time walk usually runs too early to see it.
                self.armLifecycleLeaveButton(source: source)
                // Recorder armed: promote `.starting` to `.inMeeting` (no-op for
                // manual recordings and the prompt-answered-late race).
                self.coordinator.lifecycleCoord.confirmRecording()
            } catch {
                Log.main.error("failed to start recorder: \(error.localizedDescription)")
                self.coordinator.notifier.notifyError("Could not start recording: \(error.localizedDescription)")
                self.coordinator.stateMachine.setIdle()
                self.coordinator.statusBar.setIdle()
            }
        }
    }

    func stopRecording(file: URL, source: AppSource?, summaryMode: SummaryMode) {
        coordinator.stateMachine.setStopping(file: file, source: source, summaryMode: summaryMode)
        coordinator.statusBar.setStopping()
        coordinator.recordingHUD.dismiss()
        disarmSystemLevelMirror()
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
            let producedUsableFinal = await recorder.stop()
            guard let self = self else { return }
            Log.writeLine("daemon", "recording stopped → \(file.path)")
            Log.event(category: "coordinator", action: "recording_stopped", attributes: [
                "file": file.lastPathComponent,
                "bundle_id": source?.bundleID ?? "manual",
                "system_audio_frames": recorder.lastSystemFires,
                "produced_final": producedUsableFinal,
            ])
            if producedUsableFinal {
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
            } else {
                // The merge/convert could not produce a usable final. stop() kept
                // any capture intermediates and wrote a failure breadcrumb, so the
                // orphan sweep recovers them on the next launch. Preserve the
                // meeting title / workflow for that run, and surface the failure
                // now rather than enqueueing a missing file (REC1 / AUD-5).
                self.writeMetaSidecar(file: file, source: source)
                self.coordinator.notifier.notifyError(
                    "Could not finalize \(file.lastPathComponent). The raw recording was kept and will be recovered on the next launch."
                )
            }
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
                Log.writeLine("daemon", "prompt timed out → idle + cooldown (\(source.bundleID))")
                // Like an explicit Skip: return to idle (other apps still detect) and
                // cool down this bundle. Not the old global `.suppressed`, which wedged
                // detection for the rest of the meeting when the leave-button end never
                // corroborated.
                self.coordinator.stateMachine.abandonPrompt(source: source)
                self.coordinator.statusBar.setIdle()
            }
        }
    }

    // MARK: - Detection-to-record handlers (lifecycle verdict consumers)

    func handleMeetingStarted(source: AppSource) {
        guard coordinator.stateMachine.isAcceptingPrompts else { return }

        // A meeting the user already dismissed stays dismissed for its whole lifetime:
        // the skip latch (refreshed by discovery in handleDiscovery) outlives the fixed
        // cooldown, so a `.starting` re-published mid-call can't re-open the prompt. Safety
        // net only - after a skip the lifecycle is disengaged, so this rarely fires - but it
        // closes the race where a `.starting` was queued just before disengage.
        if coordinator.stateMachine.isSkipLatched(bundleID: source.bundleID) {
            return
        }

        // Honor the per-bundle reprompt cooldown here, not only in handleDiscovery:
        // after a skip/timeout we go to .idle immediately, so a lifecycle `.starting`
        // published from a signal queued just before disengage (or a fast re-scan)
        // must not re-prompt the meeting the user just skipped within its cooldown.
        if coordinator.stateMachine.isCoolingDown(
            bundleID: source.bundleID,
            cooldownSec: coordinator.liveRepromptCooldownSec
        ) {
            return
        }

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

    // MARK: - Idle backstop (TECH-END3, was TECH-C2/C7)

    /// Mirror the system-audio level so the idle backstop's `hasSystemAudio` read
    /// stays current, and clock-feed the backstop off the ~1 Hz mic-level callback.
    /// The verdict stream is deduped (change-only), so after a call goes silent once
    /// the backstop would never be fed again and its nudge / auto-stop horizons
    /// could not fire on the forgotten-recording scenario they exist for (TECH-END7).
    /// `onMicLevel` fires throughout a recording (mic-only or not) on the main queue,
    /// the same context the verdict consumer feeds on, so re-ingesting the last
    /// verdict there advances the streak with no cross-queue race. It was left
    /// unconsumed when TECH-END3 dropped the RMS SilenceDetector.
    func armSystemLevelMirror() {
        coordinator.recorder.onSystemLevel = { [weak self] db in
            self?.latestSystemLevelDb = db
        }
        coordinator.recorder.onMicLevel = { [weak self] _ in
            guard let self = self, let verdict = self.latestVerdict else { return }
            let hasSystem = Double(self.latestSystemLevelDb) > Self.systemSilenceThresholdDb
            self.coordinator.silenceBackstop.ingest(verdict: verdict, hasSystemAudio: hasSystem)
        }
    }

    func disarmSystemLevelMirror() {
        coordinator.recorder.onSystemLevel = nil
        coordinator.recorder.onMicLevel = nil
    }

    func handleIdleNotify() {
        Log.writeLine("daemon", "idle: surfacing 'still meeting?' banner")
        Log.event(category: "coordinator", action: "silence_notified")
        coordinator.notifier.notifyStillMeeting()
    }

    func handleIdleAutoStop() {
        guard case .recording(let file, let src, let mode) = coordinator.stateMachine.current else { return }
        // Stand the backstop down when a native meeting is still tracked live: the
        // silence is a wait for someone to join, not an end. Re-nudge and keep
        // recording instead of killing an active meeting. Browser / stale-window /
        // manual recordings still stop on schedule. (The old MicOnly path force-stopped
        // here unconditionally; TECH-END3 brings the SilenceAutoStopPolicy stand-down to
        // the single backstop.)
        guard SilenceAutoStopPolicy.shouldAutoStop(
            sourceKind: src?.kind,
            lifecycleIsLive: coordinator.lifecycleCoord.current.isLive
        ) else {
            Log.writeLine("daemon", "idle: auto-stop horizon reached but meeting still live - keeping recording")
            Log.event(category: "coordinator", action: "auto_stop_silence_skipped", attributes: [
                "reason": "lifecycle_still_in_meeting",
                "bundle_id": src?.bundleID ?? "manual",
                "file": file.lastPathComponent,
            ])
            coordinator.silenceBackstop.keepAlive()
            coordinator.notifier.notifyStillMeeting()
            return
        }
        Log.writeLine("daemon", "idle: auto-stop horizon reached - auto-stopping recording")
        Log.event(category: "coordinator", action: "auto_stop_silence", attributes: [
            "bundle_id": src?.bundleID ?? "manual",
            "file": file.lastPathComponent,
        ])
        stopRecording(file: file, source: src, summaryMode: mode)
    }

    /// User tapped "Keep recording" on the idle nudge: restart the countdown so the
    /// recording is not auto-stopped. (TECH-END3)
    func keepRecordingFromNudge() {
        guard case .recording = coordinator.stateMachine.current else { return }
        Log.event(category: "coordinator", action: "silence_keep_recording")
        coordinator.silenceBackstop.keepAlive()
    }

    // MARK: - MicGate engage (TECH-G-MIC + TECH-C13)

    /// Build the AX handles and engage MicGate; also primes the silence
    /// backstop. Manual / browser-no-AX sources fall through to HAL VAD +
    /// RMS only (empty handles).
    func engageMicGate(source: AppSource?) {
        coordinator.silenceBackstop.reset()
        latestSystemLevelDb = -120
        latestVerdict = nil
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

        // The skipped-meeting latch is anchored here: this scan is proof the meeting the
        // user dismissed is still live, so refresh the latch and stay out. Keeping it armed
        // every ~3 s means it lapses only ~15 s after discovery stops seeing the meeting -
        // i.e. shortly after it actually ends - so the prompt never re-fires mid-call but
        // the next meeting in this app still prompts. We do NOT re-engage the lifecycle, so
        // there's no Leave-button poll to leak.
        if coordinator.stateMachine.isSkipLatched(bundleID: source.bundleID) {
            coordinator.stateMachine.refreshSkipLatch(bundleID: source.bundleID)
            return
        }

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
            // No Leave button on a fresh walk: the call really ended. The re-walk is the
            // corroboration, so drive the promotion to `.ended` now rather than leaving it to
            // stall in `.endingProvisional` until window-gone corroborates (which lagged ~4.5 min
            // in the wild) or the user stops by hand.
            Log.event(category: "coordinator", action: "lifecycle_provisional_end_confirmed", attributes: [
                "bundle_id": context.bundleID,
            ])
            coordinator.lifecycleCoord.confirmProvisionalEnd()
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
