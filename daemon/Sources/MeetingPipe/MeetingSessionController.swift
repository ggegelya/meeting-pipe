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
/// All methods run on the main queue, like Coordinator's. `@unchecked Sendable`
/// records that invariant so the two daemon-lifetime verdict-consumer Tasks can
/// capture `self` and hop back to the main actor; every stored property is touched
/// only on the main queue, so there is no unsynchronized shared state (CONC4).
/// `@MainActor` is the compiler-checked form, but propagating it here cascades into
/// the surrounding GCD / Timer / delegate idioms (measured: it turned these 2
/// warnings into 22), which is the `-strict-concurrency=complete` migration this
/// task scopes out.
final class MeetingSessionController: @unchecked Sendable {
    /// Back-reference to the state owner, narrowed to the `SessionHost` seam
    /// (ARCH4) so a test can drive this controller without a Coordinator and its
    /// ~18 AppKit / AVFoundation subsystems. `unowned` because the host owns this
    /// controller, so it never outlives the host.
    unowned let coordinator: any SessionHost

    /// Workflow for the in-flight recording (TECH-B3); nil between meetings.
    /// Read by `writeMetaSidecar`, cleared after flush.
    var activeWorkflow: Workflow?

    /// Capture mode of the in-flight recording; nil between meetings. Read by the MIC10-part-2
    /// stale-mute discredit so it only clears the AX mute in a capture-first mode, never under the
    /// regulated/NDA gate (where a wrong un-mute would leak at-rest-free audio on genuine muted
    /// side-talk); there the owner-owed re-scope (part 1) is the fix, not a VAD heuristic.
    var activeCaptureMode: CaptureMode?

    /// User's explicit workflow pick from the prompt chevron (TECH-B5),
    /// consumed by the next `beginRecording`. Highest matcher precedence,
    /// so it wins over rule matches.
    var pendingWorkflowOverride: UUID?

    /// AI9: the workflow the prompt currently shows pre-selected from repeated WF8
    /// corrections, and the source it was computed for. Consumed by
    /// `beginRecording` only when the source still matches, so an armed hint dies
    /// with its meeting rather than leaking into the next one (`pendingWorkflowOverride`
    /// is only cleared by a start, and this deliberately does not inherit that).
    /// Ranks below an explicit pick: the panel's Undo comes back as one.
    var preselectedRoutingHint: (source: AppSource, workflowID: UUID)?

    /// Observes window-created events so mute buttons that appear after
    /// `beginRecording` (Teams 2 compact view, PIP overlays) get watched
    /// too. Per-meeting (TECH-C14).
    var axWindowWatcher: MeetingAXWindowWatcher?

    /// True while an async `beginRecording` start is in flight. The engine
    /// bring-up is bounded off the main thread now, so the UI stays live during
    /// it; this guard stops a second Record/toggle press from stacking another
    /// `recorder.start()` (five stacked starts were seen in the 2026-06-12 freeze).
    private var recordingStartInFlight = false

    /// REC7: latched when a confirmed lifecycle `.ended` lands during the async
    /// `recorder.start()` window (the meeting ended as the user answered the
    /// prompt). Consumed once the start commits, so the fresh recording is stopped
    /// immediately instead of running against a dead meeting until the idle
    /// backstop. Main-queue only; the start Task and the verdict consumer both run
    /// on MainActor, so the set-then-read is serialized, not raced.
    private var endObservedDuringStart: EndingReason?

    /// Offsets (seconds from recording start) the user flagged mid-recording via
    /// the flag hotkey (FEAT8). Reset at start, flushed to `<stem>.markers.json`
    /// at stop. Main-queue only, like every field here.
    private var markerSeconds: [Double] = []

    /// Whether an off-the-record span is currently open (MIC14). Toggled by the hotkey; reset at
    /// stop. Main-queue only. The recorder holds the render-thread copy; this drives the HUD +
    /// the marker so the toggle is idempotent per press.
    private var offTheRecordOn = false

    /// DET1: one-shot flag set by `handleMicInUseDwell` and consumed by the very next
    /// `handleMeetingStarted`, marking that prompt as mic-in-use-originated. A flag (not a bundle
    /// that lingers) so that a whitelist prompt after a *skipped* DET1 prompt always resets the tag
    /// below, and can never be mis-tagged as DET1 (and thus mic-release-stopped mid-call).
    private var micTierPromptSource = false
    /// DET1: the bundle of the current prompt if it originated from the mic-in-use tier, else nil.
    /// Set for every prompt by `handleMeetingStarted` (from `micTierPromptSource`), read by
    /// `beginRecording` to tag a DET1 recording. Cleared there and reset on every prompt.
    private var micTierPromptBundle: String?
    /// DET1: the bundle of an in-flight recording that DET1's tier started. When the mic for this
    /// bundle is released (the call ended), the recording is stopped - a DET1 recording engages no
    /// lifecycle, so this mic-release end is its reliable stop (the idle backstop can be starved of
    /// a mic-gate verdict). nil for whitelist / manual recordings, which keep their own end path.
    private var micTierRecordingBundle: String?

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

    /// REC13(4): reports a stop that has not completed by its ceiling. Armed in
    /// `stopRecording`, disarmed when `recorder.stop()` returns.
    let stopStallWatchdog = StopStallWatchdog()

    init(coordinator: any SessionHost) {
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
                    self.coordinator.audioRecorder.setMicGateVerdict(verdict)
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
                    case .ended(let context, let reason):
                        self.handleMeetingEnded(bundleID: context.bundleID, reason: reason)
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
            startManual(summaryMode: .auto, trigger: "manual")
        case .prompting(let src), .suppressed(let src):
            // Keep the source so "Always for {App}" still attributes; clear every
            // suppression (cooldown + skip latch) so this explicit start isn't held off.
            coordinator.prompt.dismiss()
            coordinator.stateMachine.clearSuppression(bundleID: src.bundleID)
            beginRecording(source: src, summaryMode: .auto)
        case .recording(let file, let src, let mode):
            stopRecording(file: file, source: src, summaryMode: mode)
        case .stopping:
            // Mid-flush; a new start would race the await.
            break
        }
    }

    /// DET7: the one rule for an explicit start with no prompt in front of it, shared by
    /// the hotkey / menu row (`toggleManual` from `.idle`) and the `meetingpipe://record`
    /// verb. `.idle` is also the state a skipped-but-still-running meeting leaves behind
    /// (`abandonPrompt` returns here; `toggleManual`'s `.suppressed` branch is legacy and
    /// unreachable). If discovery still sees that meeting, an explicit start means "record
    /// *this*", so attach to it. There is no competing reading: the alternative is a generic
    /// recording of the same audio with no workflow, no source chip in the Library, and no
    /// AX end anchor, which in this dogfood is what actually stops a recording. Generic
    /// stays the truly-idle case.
    ///
    /// It lives here rather than at each caller so both paths cannot drift; the callers
    /// keep their own state guards (automation refuses anything but `.idle`).
    func startManual(summaryMode: SummaryMode, trigger: String) {
        if let candidate = coordinator.stateMachine.liveSuppressedCandidate() {
            recordAttached(to: candidate, summaryMode: summaryMode, trigger: trigger)
        } else {
            beginRecording(source: nil, summaryMode: summaryMode)
        }
    }

    /// DET7: start a recording attached to `source` from outside a prompt, i.e. the way
    /// back into a meeting the user already dismissed. The sequence is the one
    /// `didRequestStartLate` (UX10's start-late notification action) has always run, lifted
    /// here so every entry point shares it: only from a state that accepts a start, clear
    /// the suppression the skip armed, drop any prompt remnant, then record *with* the
    /// source, so the workflow rules see the app, the meta sidecar carries its identity, and
    /// `armLifecycleLeaveButton` has something to arm on.
    ///
    /// `trigger` names who asked, so the event log can tell a menu click from the hotkey,
    /// the URL scheme, or the notification; it does not change behaviour.
    func recordAttached(to source: AppSource, summaryMode: SummaryMode = .auto, trigger: String) {
        guard coordinator.stateMachine.isAcceptingPrompts else {
            Log.event(category: "coordinator", action: "record_attached_ignored", attributes: [
                "bundle_id": source.bundleID,
                "trigger": trigger,
                "state": DetectionStateMachine.label(coordinator.stateMachine.current),
            ])
            return
        }
        coordinator.prompt.dismiss()
        coordinator.stateMachine.clearSuppression(bundleID: source.bundleID)
        Log.writeLine("daemon", "record attached (\(source.bundleID)) via \(trigger)")
        Log.event(category: "coordinator", action: "record_attached", attributes: [
            "bundle_id": source.bundleID,
            "display_name": source.displayName,
            "trigger": trigger,
        ])
        beginRecording(source: source, summaryMode: summaryMode)
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
            coordinator.prompt.dismiss()
            coordinator.stateMachine.abandonPrompt(source: src)
            coordinator.statusUI.setIdle()
        case .idle, .suppressed, .stopping:
            break
        }
    }

    /// Stamp a timestamp marker on the active recording (FEAT8). Stop-only
    /// semantics like `forceStop`: pressing it when nothing is recording is a
    /// logged no-op, so it can never start a recording. The offset is seconds
    /// from recording start (the same clock the transcript segments use), the
    /// flag control acknowledges with the running count (UX73), and the batch
    /// is flushed at stop.
    func flagMoment() {
        guard case .recording(let file, _, _) = coordinator.stateMachine.current else {
            Log.event(category: "recorder", action: "marker_flag_ignored", attributes: [
                "state": DetectionStateMachine.label(coordinator.stateMachine.current),
            ])
            return
        }
        let startedAt = coordinator.audioRecorder.startedAt ?? Date()
        let elapsed = max(0, Date().timeIntervalSince(startedAt))
        markerSeconds.append(elapsed)
        // UX73: the acknowledgement reads its count straight off the array the sidecar is written
        // from, so the badge cannot claim a different number of moments than the artifact holds.
        coordinator.hud.acknowledgeFlag(count: markerSeconds.count)
        Log.event(category: "recorder", action: "marker_flagged", attributes: [
            "file": file.lastPathComponent,
            "t_seconds": elapsed,
            "index": markerSeconds.count,
        ])
        Log.writeLine("recorder", "flagged moment #\(markerSeconds.count) at \(String(format: "%.1f", elapsed))s")
    }

    /// Toggle an off-the-record span on the active recording (MIC14). A no-op when idle, like the
    /// flag-moment hotkey. Under the regulated/NDA gate the recorder zero-fills the span live; under
    /// capture-first it records a `.manual` timeline span for the offline redactor, and we persist a
    /// start-time marker so orphan recovery quarantines the recording if a crash loses the timeline.
    func toggleOffTheRecord() {
        guard case .recording(let file, _, _) = coordinator.stateMachine.current else {
            Log.event(category: "recorder", action: "off_the_record_ignored", attributes: [
                "state": DetectionStateMachine.label(coordinator.stateMachine.current),
            ])
            return
        }
        offTheRecordOn.toggle()
        let on = offTheRecordOn
        if on, activeCaptureMode?.capturesLosslessly ?? false {
            // Write the marker BEFORE the recorder starts the span, so no off-record audio can
            // exist on disk without the marker that flags it for quarantine.
            OffRecordMarker.write(forFinal: file)
        }
        coordinator.audioRecorder.setManualOffTheRecord(on)
        coordinator.hud.setOffTheRecord(on)
        Log.event(category: "recorder", action: on ? "off_the_record_started" : "off_the_record_stopped", attributes: [
            "file": file.lastPathComponent,
        ])
        Log.writeLine("recorder", "off the record \(on ? "started" : "stopped") for \(file.lastPathComponent)")
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

    /// AI9: what repeated WF8 corrections say the workflow for `source` should be,
    /// when that disagrees with `matched`. Nil is the normal answer.
    ///
    /// Reads the store in memory (it was loaded at launch and only grows on a
    /// reassignment), so this is a filter over a handful of structs on the main
    /// queue, not a disk hit in the detection path.
    func routingHint(source: AppSource?, matched: Workflow?) -> WorkflowRoutingHint.Suggestion? {
        WorkflowRoutingHint.suggest(
            source: source,
            matched: matched,
            corrections: coordinator.workflowCorrections.corrections,
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
        let micStatus = coordinator.micAuthorizationStatus
        if micStatus != .authorized {
            Log.main.warning("beginRecording aborted: microphone permission missing")
            Log.event(category: "coordinator", action: "recording_blocked", attributes: [
                "reason": "mic_permission",
                "status": "\(micStatus.rawValue)",
            ])
            coordinator.notifications.notifyError("Microphone permission is required. Grant it in Preferences → Permissions, then try again.")
            // Deeplink to the Permissions section so the user can act.
            coordinator.menuPreferencesPermissions()
            coordinator.stateMachine.setIdle()
            coordinator.statusUI.setIdle()
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
            coordinator.statusUI.setIdle()
            return
        }

        // Resolve the workflow controlling context/backend/sinks (TECH-B3):
        // override, then the AI9 pre-selection, then rule matches, then default.
        // Both are cleared so neither can leak into the next meeting.
        var overrideID = pendingWorkflowOverride
        if overrideID == nil, let hint = preselectedRoutingHint, hint.source == source {
            overrideID = hint.workflowID
        }
        let resolvedWorkflow = WorkflowMatcher.resolve(
            source: source,
            overrideID: overrideID,
            workflows: coordinator.workflowStore.workflows
        )
        pendingWorkflowOverride = nil
        preselectedRoutingHint = nil

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

        // MIC15(c): early-catch nudge. Read the running-somewhere state BEFORE `recorder.start`
        // arms the engine (once we hold the input device it always reads running, the confound
        // that sank END6's end-side read). If the input we are about to record sits idle while
        // another input device is active, the meeting client likely opened a different mic; warn
        // now rather than after the call. Never a gate: we still record what we captured.
        if InputDeviceResolver.defaultInputIsMismatched() {
            coordinator.notifications.notifyInputDeviceMismatch()
            Log.event(category: "recorder", action: "input_device_mismatch_warned", attributes: [
                "bundle_id": source?.bundleID ?? "manual",
            ])
        }

        // DET1: decide the mic-in-use tag NOW, synchronously, from the prompt this record answers.
        // The engine bring-up below is an `await`, during which a concurrent `handleMeetingStarted`
        // (a different meeting discovered while we start) could wipe `micTierPromptBundle`; reading
        // it after the await would then leave this DET1 recording untagged and thus never stopped.
        let isMicTierRecording = source?.bundleID != nil && source?.bundleID == micTierPromptBundle
        micTierPromptBundle = nil

        // Committed to starting: guard re-entry until this start resolves. The
        // recorder bounds the engine bring-up off the main thread, so the await
        // below never blocks the UI; the post-start wiring runs back on main.
        recordingStartInFlight = true
        endObservedDuringStart = nil  // REC7: a fresh latch per start (never a stale end from a prior failed start)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer { self.recordingStartInFlight = false }
            do {
                let file = try await self.coordinator.audioRecorder.start(
                    outputDir: self.coordinator.liveOutputDir,
                    captureMode: captureMode,
                    voiceProcessing: self.coordinator.liveVoiceProcessing
                )
                self.activeWorkflow = resolvedWorkflow
                self.activeCaptureMode = captureMode
                self.markerSeconds = []  // FEAT8: fresh marker batch per recording
                self.coordinator.hud.resetFlagCount()  // UX73: and a fresh count on the control
                // Persist the privacy + summary routing at START (REC2 / AUD-6) so a
                // crash / kill / rebuild before stop() can still recover this meeting
                // on-device: the manifest carries the summary mode (BYO must not become
                // an Anthropic+Notion auto-summary) and the meta sidecar payload (NDA /
                // regulated / workflow / title), which orphan recovery replays. Cleared
                // on a clean stop in `stopRecording`.
                self.writeRecoveryManifest(file: file, source: source, summaryMode: summaryMode)
                // DET1: apply the tag decision captured synchronously before the await, so
                // `handleMicBusyBundle` stops this recording when its app releases the mic. Reading
                // it here would race a concurrent handleMeetingStarted during the start.
                self.micTierRecordingBundle = isMicTierRecording ? source?.bundleID : nil
                self.coordinator.stateMachine.setRecording(file: file, source: source, summaryMode: summaryMode)
                self.coordinator.statusUI.setRecording(file: file, source: source, summaryMode: summaryMode, workflow: resolvedWorkflow)
                self.coordinator.hud.present(
                    source: source,
                    workflow: resolvedWorkflow,
                    startedAt: Date(),
                    levelProvider: { [weak self] in self?.coordinator.audioRecorder.currentMicLevelDb() ?? -120 }
                )
                self.coordinator.notifications.notifyRecordingStarted(file: file)
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
                // REC7: a confirmed `.ended` that landed during the async start above
                // was latched (it could not act while the state was still `.prompting`).
                // Honor it now, on the same MainActor run as `setRecording` (no await
                // between, so no verdict can interleave): stop the fresh recording so
                // its short capture is finalized and enqueued via the normal path,
                // instead of running against a dead meeting until the idle backstop.
                if let endReason = self.endObservedDuringStart {
                    self.endObservedDuringStart = nil
                    Log.event(category: "coordinator", action: "recording_ended_during_start", attributes: [
                        "file": file.lastPathComponent,
                        "leading_signal": endReason.leadingSignal,
                    ])
                    self.stopRecording(file: file, source: source, summaryMode: summaryMode)
                }
            } catch {
                // MIC11 / AUD: a failed start must fail *bounded*, not silently churn
                // the audio stack. The 2026-06-09 storm was an engine-start that
                // returned to .idle with no backoff, so the detector's next discovery
                // poll - and a user re-click - re-attempted immediately and unboundedly.
                // Arm the per-bundle reprompt cooldown so a device the engine can't start
                // on (a renegotiating Bluetooth headset) backs off for repromptCooldownSec
                // before it can re-prompt, and emit a structured event so `mp logs` /
                // `mp analyze-detection` can see failed starts (the catch was os_log-only).
                // Manual recordings have no bundle to cool down; `recordingStartInFlight`
                // already bounds re-clicks there.
                let reason = MeetingSessionController.startFailureReason(error)
                if let bundleID = source?.bundleID {
                    self.coordinator.stateMachine.recordCooldownEnd(bundleID: bundleID)
                }
                Log.event(category: "coordinator", action: "recording_error", attributes: [
                    "stage": "start",
                    "reason": reason,
                    "bundle_id": source?.bundleID ?? "manual",
                    "cooldown_armed": source != nil,
                ])
                Log.main.error("failed to start recorder: \(error.localizedDescription)")
                self.coordinator.notifications.notifyError("Could not start recording: \(error.localizedDescription)")
                self.coordinator.stateMachine.setIdle()
                self.coordinator.statusUI.setIdle()
            }
        }
    }

    /// Map a recorder start failure to a stable snake_case `reason` for the
    /// `recording_error` event (MIC11). Internal + static so it is unit-testable
    /// without constructing the controller, and exhaustive over `RecorderError`
    /// so a new failure case forces this mapping to be updated. The `reason`
    /// strings are a JSONL contract that `mp analyze-detection` can bucket on.
    static func startFailureReason(_ error: Error) -> String {
        guard let recorderError = error as? MeetingRecorder.RecorderError else {
            return "other"
        }
        switch recorderError {
        case .engineStartFailed: return "engine_start_failed"
        case .engineStartTimedOut: return "engine_start_timed_out"
        case .fileCreateFailed: return "file_create_failed"
        case .alreadyRecording: return "already_recording"
        }
    }

    /// Which "remote audio is missing" warning a finished recording warrants (REC4 / AUD-13).
    enum RemoteAudioWarning: Equatable {
        case none
        /// No system-audio frame ever arrived: the whole recording is mic-only
        /// (Screen Recording denied, or the SCStream never started).
        case micOnly
        /// System audio was captured, then the SCStream died mid-meeting and did not
        /// recover: the remote side is absent from the death point on, while the mic
        /// keeps recording to the end.
        ///
        /// That second half is a claim about the merge, not about the capture, and it
        /// only became true with REC9. The bare `amerge` ended at the shorter input,
        /// so a system channel that died early ended the whole recording early and
        /// the mic tail this case describes was discarded, silently, along with both
        /// intermediates. The distinction from `.micOnly` is real either way, but the
        /// "from the death point on" wording rests on the length policy holding.
        case interrupted
    }

    /// Pure coverage gate over the recorder's stop-time snapshot. Lifted out so it is
    /// unit-testable without the controller (like `startFailureReason`). A never-started
    /// capture takes precedence over a mid-meeting death (frames == 0 is the stronger,
    /// whole-recording signal).
    static func remoteAudioWarning(systemFires: UInt64, degraded: Bool) -> RemoteAudioWarning {
        if systemFires == 0 { return .micOnly }
        if degraded { return .interrupted }
        return .none
    }

    func stopRecording(file: URL, source: AppSource?, summaryMode: SummaryMode) {
        micTierRecordingBundle = nil // DET1: this recording is ending; drop its mic-release tag
        coordinator.stateMachine.setStopping(file: file, source: source, summaryMode: summaryMode)
        coordinator.statusUI.setStopping(file: file, source: source, summaryMode: summaryMode)
        coordinator.hud.dismiss()
        disarmSystemLevelMirror()
        // Tear down per-meeting AX subscriptions; the verdict stream stays
        // open for the next meeting.
        coordinator.lifecycleCoord.disengage()
        coordinator.micGate.stop()
        axWindowWatcher?.stop()
        axWindowWatcher = nil

        // recorder.stop is `@MainActor async` (REC11): main-isolated so its teardown
        // cannot race the main-thread owners of the fields it writes, but every wait
        // inside it is a suspension, so the UI stays live. Once flushed, enqueue for
        // the pipeline and return to .idle so the next meeting can start.
        let recorder = coordinator.audioRecorder
        // REC13(4): 52 minutes in `.stopping` produced no event and no notification on
        // 2026-08-14, so the only symptom was a Library row that never settled. Every
        // engine call inside `stop()` is bounded now, so this should never fire; if it
        // does, the next occurrence is readable from `events.jsonl` instead of needing a
        // live `sample` of the process.
        stopStallWatchdog.arm(file: file) { [weak self] elapsed in
            self?.coordinator.notifications.notifyError(
                StopStallWatchdog.stallMessage(elapsed: elapsed)
            )
        }
        Task { @MainActor [weak self] in
            let producedUsableFinal = await recorder.stop()
            self?.stopStallWatchdog.disarm()
            guard let self = self else { return }
            Log.writeLine("daemon", "recording stopped → \(file.path)")
            Log.event(category: "coordinator", action: "recording_stopped", attributes: [
                "file": file.lastPathComponent,
                "bundle_id": source?.bundleID ?? "manual",
                "system_audio_frames": recorder.lastSystemFires,
                "produced_final": producedUsableFinal,
            ])
            // FEAT8/REC7: flush the flagged moments before the merge-outcome branch,
            // so a failed merge (intermediates kept for the orphan sweep) does not
            // discard them; the sidecar sits beside where the final will land.
            MarkerFile.write(seconds: self.markerSeconds, forFinal: file)
            if producedUsableFinal {
                // Surface a missing-remote-side recording. Zero frames = the whole call was
                // mic-only (Screen Recording denied; the notifier shows "Open Settings" only
                // when a perm change helps). A mid-meeting SCStream death (frames > 0 but
                // degraded) is a partial loss the old `== 0` gate never caught (REC4 / AUD-13).
                switch MeetingSessionController.remoteAudioWarning(
                    systemFires: recorder.lastSystemFires,
                    degraded: recorder.lastSystemDegraded
                ) {
                case .micOnly:
                    let perm = SystemAudioCapture.permissionState
                    self.coordinator.notifications.notifyMicOnlyRecording(file: file, permissionState: perm)
                    if perm == .denied || perm == .unknown {
                        self.coordinator.statusUI.refreshMenuForPermissionChange()
                    }
                case .interrupted:
                    self.coordinator.notifications.notifyRemoteAudioInterrupted(file: file)
                case .none:
                    break
                }
                // REC9: the recording carries materially less audio than the meeting it
                // spanned. Orthogonal to the two warnings around it, which are about
                // which CHANNEL is missing; this one fires when the file itself is short,
                // whatever the cause, and it is the surface the 2026-07-15 truncation
                // never had.
                if let parity = recorder.lastDurationParity, parity.isShort {
                    self.coordinator.notifications.notifyShortRecording(
                        file: file, audioSec: parity.audioSec, wallclockSec: parity.wallclockSec
                    )
                }
                // MIC15(b): the mirror-image warning. RemoteAudioWarning fires when the SYSTEM
                // side is missing; this fires when the system side was fine the whole call but
                // the MIC channel stayed at the noise floor over an un-muted stretch (a wrong /
                // dead input device). Muted-whole-meeting is excluded by the un-muted-seconds
                // floor inside `evaluate`.
                let coverage = recorder.lastMicCoverage
                let micWarning = MicCoverageWarning.evaluate(
                    recordingSeconds: coverage.recordingSeconds,
                    systemAudioPresentWholeCall: recorder.lastSystemFires > 0 && !recorder.lastSystemDegraded,
                    unmutedSeconds: coverage.unmutedSeconds,
                    peakUnmutedRmsDb: coverage.peakUnmutedRmsDb
                )
                if micWarning == .micRecordedNothing {
                    self.coordinator.notifications.notifyMicRecordedNothing(file: file)
                    Log.event(category: "recorder", action: "mic_recorded_nothing", attributes: [
                        "file": file.lastPathComponent,
                        "recording_seconds": coverage.recordingSeconds,
                        "unmuted_seconds": coverage.unmutedSeconds,
                        "peak_unmuted_db": Double(coverage.peakUnmutedRmsDb),
                        "device": recorder.lastInputDevice?.displayName ?? "(unknown)",
                    ])
                }
                self.writeMetaSidecar(
                    file: file,
                    source: source,
                    micDeviceName: recorder.lastInputDevice?.displayName,
                    micSilent: micWarning == .micRecordedNothing
                )
                self.coordinator.notifications.notifyProcessing(file: file)
                self.coordinator.jobs.enqueue(file: file, summaryMode: summaryMode)
                // Clean finish: the meta sidecar is now on disk and the job is
                // enqueued, so drop the start-time recovery manifest. Kept on the
                // else branch below, where the merge failed and the orphan sweep
                // still needs it to route the retried recording (REC2 / AUD-6).
                RecordingManifest.remove(
                    forStem: file.deletingPathExtension().lastPathComponent,
                    in: file.deletingLastPathComponent()
                )
                // Clean finish: the recorder wrote any manual off-record timeline, so drop the
                // MIC14 orphan-quarantine marker. Kept on the else branch (merge failed), so the
                // orphan sweep still quarantines a recording whose manual span was never persisted.
                OffRecordMarker.remove(forFinal: file)
            } else {
                // The merge/convert could not produce a usable final. stop() kept
                // any capture intermediates and wrote a failure breadcrumb, so the
                // orphan sweep recovers them automatically (REC6: the sweep runs
                // after every job completion, not only at the next launch). Preserve
                // the meeting title / workflow for that run, and surface the failure
                // now rather than enqueueing a missing file (REC1 / AUD-5).
                self.writeMetaSidecar(file: file, source: source)
                self.coordinator.notifications.notifyError(
                    "Could not finalize \(file.lastPathComponent). The raw recording was kept and will be recovered automatically."
                )
            }
            // Drop the workflow + markers so they can't bleed into the next meeting.
            self.activeWorkflow = nil
            self.activeCaptureMode = nil
            self.markerSeconds = []
            self.coordinator.hud.resetFlagCount()  // UX73: paired with every markerSeconds reset
            self.offTheRecordOn = false
            // Arm the re-prompt cooldown so a post-call mic grab (Teams chat,
            // Zoom teardown toast) can't re-prompt right after the flush.
            if let bid = source?.bundleID {
                self.coordinator.stateMachine.recordCooldownEnd(bundleID: bid)
            }
            self.coordinator.stateMachine.setIdle()
            self.coordinator.statusUI.setIdle()
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
    func writeMetaSidecar(file: URL, source: AppSource?, micDeviceName: String? = nil, micSilent: Bool = false) {
        let dict = MeetingMetaSidecar.build(
            source: source,
            workflow: activeWorkflow,
            regulatedMode: coordinator.configStore?.regulatedMode ?? false,
            micDeviceName: micDeviceName,
            micSilent: micSilent
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

    /// Write the start-time recovery manifest (`<stem>.recovery.json`, REC2 /
    /// AUD-6). It carries the summary mode and the same `MeetingMetaSidecar`
    /// payload the clean-stop sidecar uses, so orphan recovery can route a
    /// crash-interrupted BYO / NDA / regulated meeting on-device instead of
    /// auto-egressing it. Removed on a clean stop that produced a final.
    func writeRecoveryManifest(file: URL, source: AppSource?, summaryMode: SummaryMode) {
        let meta = MeetingMetaSidecar.build(
            source: source,
            workflow: activeWorkflow,
            regulatedMode: coordinator.configStore?.regulatedMode ?? false
        )
        let stem = file.deletingPathExtension().lastPathComponent
        RecordingManifest.write(
            summaryMode: summaryMode,
            meta: meta,
            forStem: stem,
            in: file.deletingLastPathComponent()
        )
    }

    func startPromptTimeout(for source: AppSource) {
        coordinator.stateMachine.startPromptTimeout(
            for: source,
            timeoutSec: coordinator.livePromptTimeoutSec
        ) { [weak self] in
            guard let self = self else { return }
            let action = (self.coordinator.configStore?.defaultPromptAction ?? "skip").lowercased()
            self.coordinator.prompt.dismiss()
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
                // UX10 / AUD-12: unlike an explicit Skip, a *silent* timeout-skip
                // needs a surface. Show "Suppressed (<app>)" in the menu bar for as
                // long as the skip latch holds (the whole meeting), and notify with a
                // start-late action. The state machine stays `.idle` (START1); the
                // menu-bar label is presentation-only and polls the real latch.
                let bundleID = source.bundleID
                self.coordinator.statusUI.setSuppressed(source) { [weak self] in
                    self?.coordinator.stateMachine.isSkipLatched(bundleID: bundleID) ?? false
                }
                self.coordinator.notifications.notifySkippedMeeting(source: source, origin: .timedOut)
            }
        }
    }

    // MARK: - Detection-to-record handlers (lifecycle verdict consumers)

    /// DET1: a sustained mic-busy dwell with no whitelist winner. Route the synthesized generic
    /// source through the same prompt path as a lifecycle `.starting`, so the skip-latch, reprompt
    /// cooldown, and auto-consent all apply (the quiet-register guardrail: one prompt per cooldown,
    /// never a popup storm). The lifecycle is deliberately NOT engaged: this tier is permission-
    /// light (no AX / Screen Recording), so a recording it starts ends via the idle-stop backstop.
    func handleMicInUseDwell(_ source: AppSource) {
        Log.writeLine("daemon", "mic-in-use dwell -> prompting (\(source.bundleID))")
        // Mark the next prompt as mic-in-use-originated; handleMeetingStarted consumes this into
        // micTierPromptBundle so a recording started off it (auto-consent now or the prompt answered
        // later) is tagged DET1 and stopped on mic release.
        micTierPromptSource = true
        handleMeetingStarted(source: source)
    }

    /// DET1: the currently-held mic bundle updated (nil = idle). If a DET1-tagged recording's app is
    /// no longer the one holding the mic (the call ended), stop it - the reliable, permission-light
    /// end for a recording that engages no lifecycle. A LEVEL check (re-run every poll), so a
    /// recording that started AFTER its mic-busy span closed (a late prompt answer, a slow recorder
    /// bring-up) is still stopped, not left running forever. A no-op for whitelist / manual
    /// recordings (not tagged); the tracker debounces the release, so a brief flap keeps the bundle
    /// held and never triggers a false stop.
    func handleMicBusyBundle(_ currentBusyBundle: String?) {
        guard let recBundle = micTierRecordingBundle, currentBusyBundle != recBundle,
              case .recording(let file, let src, let mode) = coordinator.stateMachine.current,
              src?.bundleID == recBundle else { return }
        Log.event(category: "coordinator", action: "mic_in_use_stop", attributes: ["bundle_id": recBundle])
        Log.writeLine("daemon", "mic-in-use recording stopped: mic released (\(recBundle))")
        stopRecording(file: file, source: src, summaryMode: mode)
    }

    func handleMeetingStarted(source: AppSource) {
        // DET1: consume the one-shot mic-in-use flag now (so it never leaks to the next call), but
        // arm the per-prompt tag only once we COMMIT to showing/recording this prompt (after the
        // suppression guards below). Arming it here, before the guards, would let a DET1
        // `handleMeetingStarted` that early-returns while a whitelist prompt for the same bundle is
        // up leave a stale tag that mis-tags the later whitelist recording.
        let isMicTier = micTierPromptSource
        micTierPromptSource = false
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

        // Committed to this prompt: arm the DET1 tag (the bundle when mic-in-use-originated, else
        // clear any prior prompt's value so a whitelist prompt is never tagged). beginRecording
        // captures this synchronously before its async start.
        micTierPromptBundle = isMicTier ? source.bundleID : nil

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
        coordinator.statusUI.setPrompting(source)
        // The on-screen panel is the primary surface (not suppressed under
        // Focus modes); the banner stays off by default. Pass the resolved
        // workflow + full set so the chip and override menu render (TECH-B5).
        let promptWorkflow = workflowForPrompt(source: source)
        // AI9: the pre-selection is armed here and applied in `beginRecording`, so
        // hitting Record without reading the chip records under the suggested
        // workflow, and the panel's Undo (which comes back as an explicit
        // `didChooseWorkflow`) outranks it. Keyed to this source, so it cannot
        // leak into the next meeting the way a lingering explicit override could.
        let suggestion = routingHint(source: source, matched: promptWorkflow)
        preselectedRoutingHint = (suggestion?.preselects ?? false)
            ? (source: source, workflowID: suggestion!.workflowID)
            : nil
        if let suggestion = suggestion {
            Log.event(category: "workflow", action: "routing_hint_shown", attributes: [
                "bundle_id": source.bundleID,
                "suggested_workflow_id": suggestion.workflowID.uuidString,
                "suggested_workflow": suggestion.workflowName,
                "matched_workflow": promptWorkflow?.name ?? NSNull(),
                "corrections": suggestion.corrections,
                "matched_on": suggestion.matchedOnTitle ? "title" : "bundle",
                "preselected": suggestion.preselects,
            ])
        }
        coordinator.prompt.present(
            source: source,
            workflow: promptWorkflow,
            availableWorkflows: coordinator.workflowStore.workflows,
            suggestion: suggestion,
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

    func handleMeetingEnded(bundleID: String, reason: EndingReason) {
        // DET14: drop the attachable candidate for this bundle before anything else, and outside
        // the state switch below, because it is not about what this session is doing. The
        // suppressed candidate's grace is an upper bound on ignorance, a guess at how long to
        // keep believing in a call discovery has stopped confirming; a lifecycle end is the
        // positive signal that guess stands in for, so it should not have to be waited out. It is
        // what kept the menu offering "Record this <app> meeting" for up to two minutes after a
        // call finished.
        //
        // Not sticky, deliberately: a false end is re-sighted within a poll and writes the
        // candidate straight back, which is what keeps this clear of DET13's false-end rescue.
        coordinator.stateMachine.noteMeetingEnded(bundleID: bundleID)

        switch coordinator.stateMachine.current {
        case .recording(let file, let src, let mode):
            // Recording-stop honors every end, including uncorroborated ones: a
            // missed real end (recording runs forever) is worse than a rare late
            // stop. This path is deliberately unchanged.
            stopRecording(file: file, source: src, summaryMode: mode)
        case .prompting, .suppressed:
            // Both branches below used to be gated on `PromptEndPolicy.clearsPromptState`,
            // a second filter that dropped a bare `ax_leave_button_invalid` end carrying an
            // empty `confirmedBy`. START1 then put the same rule where the end is *made*:
            // `PromotionEngine.handleStarting` refuses to promote a `requiresCorroboration`
            // signal at all, `tick()` demands a cross-class corroborator, and
            // `confirmProvisionalEnd` always appends its re-walk signal, so no reachable
            // `.ended` can carry that shape any more and the filter had been returning true
            // for every end since. ARCH6 removed it; the guard that actually holds is
            // START1's, in Core. See `daemon/docs/gotchas.md`.
            //
            // REC7: if a start is in flight (the user just answered Record and the recorder
            // is coming up), the state machine is still `.prompting` until the start commits
            // `.recording`. A confirmed end here would be swallowed by that commit, so latch
            // it and let the start path stop the fresh recording at once.
            if recordingStartInFlight {
                endObservedDuringStart = reason
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
            coordinator.prompt.dismiss()
            coordinator.stateMachine.setIdle()
            coordinator.statusUI.setIdle()
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
        coordinator.audioRecorder.onSystemLevel = { [weak self] db in
            self?.latestSystemLevelDb = db
        }
        coordinator.audioRecorder.onMicLevel = { [weak self] _ in
            guard let self = self, let verdict = self.latestVerdict else { return }
            let hasSystem = Double(self.latestSystemLevelDb) > Self.systemSilenceThresholdDb
            self.coordinator.silenceBackstop.ingest(verdict: verdict, hasSystemAudio: hasSystem)
        }
    }

    func disarmSystemLevelMirror() {
        coordinator.audioRecorder.onSystemLevel = nil
        coordinator.audioRecorder.onMicLevel = nil
    }

    func handleIdleNotify() {
        Log.writeLine("daemon", "idle: surfacing 'still meeting?' banner")
        Log.event(category: "coordinator", action: "silence_notified")
        coordinator.notifications.notifyStillMeeting()
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
            coordinator.notifications.notifyStillMeeting()
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
            },
            vadActiveProvider: { [weak self] in
                self?.coordinator.micGate.currentVadActive ?? false
            },
            onStaleMuteContradiction: { [weak self] in
                guard let self = self else { return }
                // MIC10 part 2: discredit the stale AX read, but only in a capture-first mode.
                // Under the regulated/NDA gate a wrong un-mute would leak at-rest-free audio on a
                // genuine muted side-conversation, so there we leave the mute in place (the re-scope
                // in part 1, owner-owed on a live AX dump, is the real fix). Capture-first keeps the
                // full recording regardless, so recovering the user's voice is the safe default.
                if self.activeCaptureMode?.capturesLosslessly ?? false {
                    self.coordinator.micGate.clearAxMute()
                }
            },
            // MIC10 part 1: same mode gate, applied one step earlier. When the walk hands back two
            // windows' mute buttons that disagree, capture-first treats the read as blind (the
            // stale window can no longer out-vote the live one and zero the mic mid-sentence);
            // the regulated gate keeps the old MUTED bias, where a wrong un-mute is unrecoverable.
            blindOnWindowDisagreement: { [weak self] in
                self?.activeCaptureMode?.capturesLosslessly ?? false
            },
            // MIC16: run the 1 Hz mute-state AX walk on the shared serial queue (off main),
            // so a wedged meeting client can never stall the run loop and delay the
            // force-stop hotkey while a recording is live. Only the fused readings hop back.
            walkQueue: Self.axWalkQueue
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
        // user dismissed is still live, so refresh the latch and stay out. A scan reaches this
        // point only when it produced a *confident* winner, which is why the grace it refreshes is
        // `skipLatchGracePolls` polls wide rather than one (DET9): a live Teams call regularly goes
        // tens of seconds with no confident winner while its compact / backgrounded call UI hides
        // the Leave, Mute and toolbar controls, and a narrower grace dropped the latch inside that
        // stretch. So "discovery stopped seeing it" is not "it ended", and only a full grace of
        // silence is read as the end. We do NOT re-engage the lifecycle, so there's no
        // Leave-button poll to leak.
        if coordinator.stateMachine.isSkipLatched(bundleID: source.bundleID) {
            coordinator.stateMachine.refreshSkipLatch(bundleID: source.bundleID)
            // DET7: this sighting is also proof of *what* is running, and it is the only
            // live handle on it once the prompt is gone. Keep it so a manual start (menu
            // row, hotkey, `meetingpipe://record`) can attach to the meeting the user
            // skipped instead of recording `source: nil`, which resolves the default
            // workflow, writes no source into the sidecar, and arms no AX end detection.
            coordinator.stateMachine.noteSuppressedCandidate(source, origin: .skipLatch)
            return
        }

        if coordinator.stateMachine.isCoolingDown(
            bundleID: source.bundleID,
            cooldownSec: coordinator.liveRepromptCooldownSec
        ) {
            // DET13: this branch used to be a bare `return`, which is the asymmetry with the one
            // above. The cooldown is anchored on the *previous* meeting's end, so for 60 s after
            // any recording stops the same bundle yielded neither a prompt nor a retained
            // candidate, and a manual Record in that window fell to `beginRecording(source: nil)`:
            // default workflow, no source in the sidecar, no app chip, and nothing for
            // `armLifecycleLeaveButton` to arm on, so the recording did not stop when the call did
            // (15 m 35 s of room audio on 2026-08-04). The sighting is proof of what is running
            // here exactly as it is there, so keep it.
            //
            // Keeping it is all this does. The cooldown still suppresses the prompt, which is
            // load-bearing against END9's false-end re-prompt storms, and no skip latch is armed,
            // so the meeting still prompts normally once the window lapses.
            let previous = coordinator.stateMachine.liveSuppressedCandidate()
            coordinator.stateMachine.noteSuppressedCandidate(source, origin: .cooldown)
            if previous?.bundleID != source.bundleID {
                // Once per retention, not once per poll: discovery re-sights the same call every 3
                // to 12 s for the whole window. The 2026-08-04 occurrence was unreadable from
                // `events.jsonl` alone, which is what this fixes.
                Log.event(category: "coordinator", action: "cooldown_candidate_retained", attributes: [
                    "bundle_id": source.bundleID,
                    "display_name": source.displayName,
                    "cooldown_sec": coordinator.liveRepromptCooldownSec,
                ])
            }
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
        // The Leave-button search is a cross-process AX DFS over every window; run it OFF
        // main (TECH-CONC3) so a slow / hung AX call can't freeze the run loop while a
        // recording is live, then hop back to main to mutate the engine. Mirrors
        // `armLifecycleLeaveButton`.
        Self.axWalkQueue.async { [weak self] in
            let axApp = AXUIElementCreateApplication(context.pid)
            let leaveButtons = MeetingAXHandleBuilder.findAllLeaveButtons(
                in: axApp,
                bundleID: context.bundleID
            )
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let leaveButton = leaveButtons.first else {
                    // No Leave button on a fresh walk: the call really ended. The re-walk is the
                    // corroboration, so drive the promotion to `.ended` now rather than leaving it to
                    // stall in `.endingProvisional` until window-gone corroborates (which lagged ~4.5 min
                    // in the wild) or the user stops by hand.
                    Log.event(category: "coordinator", action: "lifecycle_provisional_end_confirmed", attributes: [
                        "bundle_id": context.bundleID,
                    ])
                    self.coordinator.lifecycleCoord.confirmProvisionalEnd()
                    return
                }
                Log.event(category: "coordinator", action: "lifecycle_provisional_end_rescued", attributes: [
                    "bundle_id": context.bundleID,
                    "leave_buttons_found": leaveButtons.count,
                ])
                self.coordinator.lifecycleCoord.armLeaveButton(leaveButton)
            }
        }
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
