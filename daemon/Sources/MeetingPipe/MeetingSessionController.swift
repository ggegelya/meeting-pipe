import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import os
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

    /// User's explicit workflow pick from the prompt's workflow chip (TECH-B5), keyed to the
    /// prompt's source (SEC39). Consumed by `beginRecording` only for that source, and cleared on
    /// every prompt exit (`clearPromptRouting`), so a pick made for a meeting that was not recorded
    /// can no longer decide the next one. Highest matcher precedence for its own meeting. The one
    /// exit that keeps it is a timeout into DET18's offer, which moves it to `offerWorkflowOverride`.
    var pendingWorkflowOverride: (source: AppSource, workflowID: UUID)?

    /// SEC40: the chip pick a timed-out prompt left with its one-click offer, for that source only.
    /// Its own slot, so another app's prompt or recording while the offer lives does not wipe it;
    /// `recordAttached` hands it to the start, and it goes with the offer (span lapse, Skip) or
    /// with any start of its source. Carried only when it is not weaker than the source's rule
    /// match, because the source key cannot tell this call from the next one in the same app.
    var offerWorkflowOverride: (source: AppSource, workflowID: UUID)?

    /// SEC39: the workflow a resume decided (`WorkflowMatcher.resumeWorkflow`), for the resumed
    /// source only. Separate from the chip pick on purpose: it is a decision already made, not a
    /// user's override.
    private var pendingResumeWorkflow: (source: AppSource, workflowID: UUID)?

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

    /// END20: the async `beginRecording` start in flight, if any, and what happened to it during the
    /// bring-up. Non-nil stops a second Record press from stacking another `recorder.start()` (five
    /// stacked starts were seen in the 2026-06-12 freeze), latches an end of the start's own meeting
    /// (REC7, now for every origin) and a Stop pressed meanwhile. Main-queue only.
    /// END9: the open call-teardown hold's decisions (T8: `TeardownHoldPolicy`, in Core so the
    /// detection corpus replays them on a virtual clock). Main-queue only, like everything else here.
    var holdPolicy = TeardownHoldPolicy()
    /// END16: the open hold's teardown consults, for the edge rows and the blind count.
    private(set) var consultLedger = TeardownConsultLedger()

    /// Cancels the 1 Hz consult timer while a hold is shown, or nil. Host-side, since Core has no run
    /// loop; common-mode (CONC10), so an alert left open cannot keep an ended meeting recording.
    /// Non-nil is also the record that the HUD was told the hold is showing.
    var cancelHoldTimer: (() -> Void)?

    /// END9: where to cut the recording when the held end confirms, or nil for an ordinary end.
    /// Read once by `stopRecording` and cleared there, so it can never leak into the next meeting.
    var pendingEndTrimAt: Date?

    /// END23: the running Teams recording's mic-release ceiling, its 1 Hz timer, and the cut it
    /// anchored on the wall clock. All nil outside a native Teams recording.
    var micReleaseCeiling: MicReleaseCeiling?
    var cancelMicReleaseCeilingTimer: (() -> Void)?
    var micReleaseCutAt: Date?

    /// END22: the sleep-excluding clock the resume window is measured on. A test injects one.
    var sessionUptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private(set) var startLatch = RecordingStartLatch()

    /// END19: the engage discovery's last winner left behind, and how many winnerless scans it has
    /// gone without a sighting. Main-queue only.
    private(set) var staleEngage = StaleEngageBound()

    /// END19: when the lifecycle was last engaged, and when the running recording committed, and
    /// whether that engage reached `.inMeeting` under this recording. Together they say whether an
    /// end that reaches a source-less recording came from an engage that was ever its own.
    private var lifecycleEngagedAt: Date?
    private var recordingCommittedAt: Date?
    private var lifecycleReachedInMeetingThisRecording = false

    /// END17 item 5: what the last lifecycle end stopped, kept for `ResumeAfterEnd.windowSec` so a
    /// call sighted again inside it resumes instead of being suppressed by the cooldown.
    var resumeCandidate: ResumeAfterEnd?

    /// END17 item 5: the stem a resume links to, handed from `handleMeetingStarted` to the start it
    /// triggers, then held as the active recording's for its sidecar. Main-queue only.
    private var pendingResumedFrom: String?
    /// STOR16: a start that arrived while a library move ran, replayed when the move finishes.
    /// Latest wins: a second press while held replaces the first.
    private(set) var heldStart: (source: AppSource?, summaryMode: SummaryMode)?
    /// When the first press of the held start arrived. A later press replaces what is replayed but
    /// not this, since the meeting's opening has been going unrecorded since the first one.
    private var heldSince: Date?
    /// The clock the held start's wait is measured on. Tests move it.
    var heldStartClock: () -> Date = { Date() }
    private var activeResumedFrom: String?

    /// END28: which call the running recording is of (`CallIdentityTracker`), its 2 s read timer,
    /// and a split waiting for the stop it triggered to finish. Main-queue only.
    var callIdentity = CallIdentityTracker()
    var cancelCallIdentityTimer: (() -> Void)?
    var pendingSplit: PendingCallSplit?
    /// END28: the stem a split's prompt links to, keyed to the prompt's source (SEC39's rule), so a
    /// skipped split prompt cannot hand its link to the next start. Cleared on every prompt exit.
    var pendingSplitFrom: (source: AppSource, stem: String)?
    /// END28: the running recording's `split_from`, for its sidecar and recovery manifest.
    var activeSplitFrom: String?

    /// Offsets (seconds from recording start) the user flagged mid-recording via
    /// the flag hotkey (FEAT8). Reset at start, written to `<stem>.markers.json`
    /// on every press (REC26) and once more at stop. Main-queue only, like every field here.
    private var markerSeconds: [Double] = []

    /// Whether an off-the-record span is currently open (MIC14). Toggled by the hotkey; reset at
    /// stop. Main-queue only. The recorder holds the render-thread copy; this drives the HUD +
    /// the marker so the toggle is idempotent per press.
    private var offTheRecordOn = false
    /// REC21: this recording owes a redaction, so the job carries it whatever the disk markers
    /// say. Set at start for `.captureFirstRedact` and when a span opens under lossless capture;
    /// sticky until stop, since closing the span still owes its cut.
    private(set) var redactionOwed = false
    /// REC21: what the start-time recovery manifest was written from, so opening an off-the-record
    /// span can rewrite it with `off_record` from the session's own copy rather than from disk.
    private var manifestInputs: (summaryMode: SummaryMode, meta: [String: Any], captureMode: CaptureMode)?
    /// REC21: the stem whose manifest says `off_record`, so a start-time manifest write that lands
    /// late (PERF28 keeps it) and overwrites it with `false` can be written back.
    private var offRecordManifestStem: String?
    /// REC21: the `.offrecord` write, a seam so a test can make it fail.
    var offRecordMarkerWriter: (URL) throws -> Void = { try OffRecordMarker.write(forFinal: $0) }
    /// END28: read by the call-split tick, which must not end an off-the-record span by splitting.
    var isOffTheRecord: Bool { offTheRecordOn }

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

    /// DET18 item 4: a prompt withdrawn while the call may still be on screen is not re-raised by
    /// the very next discovery refresh. Held for one idle poll. Before this, 298 prompts in era 1
    /// were withdrawn by a weak end and re-raised within 15 s, on screen for 15 to 30 ms each.
    var promptBackoff: (bundleID: String, until: Date)?

    /// DET17 guard 2: the tab key of each browser's latest discovery sighting. A prompt is raised
    /// from a lifecycle `.starting`, whose source carries no tab key, so a skip or a timeout reads
    /// the tab it was for from here. In memory only.
    private var lastBrowserTabKey: [String: Int] = [:]

    /// The tab a hold on `source` is for: its own key, else the browser's last sighted tab. Nil for
    /// a native source, whose hold covers the whole bundle.
    func holdTabKey(for source: AppSource) -> Int? {
        assertMainQueue()
        guard source.kind == .browser, micTierPromptBundle != source.bundleID else { return nil }
        return source.tabKey ?? lastBrowserTabKey[source.bundleID]
    }

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
    /// `.live(hasAudio:)` read draws the line here (TECH-END3). Consulted only while the
    /// recorder reports the channel live (REC17).
    private static let systemSilenceThresholdDb: Double = -50.0

    /// REC13(4): reports a stop that has not completed by its ceiling. Armed in
    /// `stopRecording`, disarmed when `recorder.stop()` returns.
    let stopStallWatchdog = StopStallWatchdog()

    /// OBS10: the clock `stop_began`'s delay is measured on (`systemUptime`); a test steps it.
    var stopClock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// PERF15: the parts of an engage that reach the system, behind seams so a test can gate a build
    /// on a semaphore, count builds, and see MicGate engage without touching the HAL. Production
    /// never sets them. `buildHandles` and `resolveContext` are read on main and the closure is
    /// then run on `axWalkQueue`; `startMicGate` nil means `coordinator.micGate.start`.
    struct EngageSeams {
        var buildHandles: (AppSource, MuteLabels) -> MeetingAXHandleBuilder.Handles? = MeetingAXHandleBuilder.build
        var resolveContext: (AppSource) -> MeetingLifecycleContext? = MeetingAXHandleBuilder.context(for:)
        var startMicGate: ((MeetingLifecycleContext, MicGateAdapterHandle) throws -> Void)?
        /// END20 (D075): the prompt's source for a `.starting`, a title read on `axWalkQueue`.
        var resolveStartingSource: @Sendable (MeetingLifecycleContext) async -> AppSource = { context in
            await MeetingSessionController.resolveAppSource(from: context)
        }
    }
    var engageSeams = EngageSeams()

    /// END20 (D075): how long a prompt waits for its window title before it shows without one. A
    /// healthy read takes milliseconds; the bound is for a hung client, where each AX call waits out
    /// the 2 s messaging timeout. The title is not on the panel, only in the workflow rules' match,
    /// so the cost of the bound is a title-rule workflow not being preselected for that one prompt.
    static let startingTitleDeadline: TimeInterval = 2.0
    var startingTitleDeadlineSec = MeetingSessionController.startingTitleDeadline

    /// PERF15: the discovery-time build in flight, or nil. One per bundle at a time, so a 3 s poll
    /// cannot stack walks against a slow client; `generation` is how its landing tells it is still
    /// the newest request. Cleared by the landing and by `disengageLifecycle`.
    private var lifecycleBuild: (bundleID: String, generation: Int)?
    private var lifecycleBuildGeneration = 0

    /// PERF15: how long a recording start waits for its AX build before MicGate engages without it.
    ///
    /// Measured: the build takes 11 to 31 ms for Zoom (eight builds on 2026-10-13, discovery pick
    /// or `recording_started` to `ax_handles_built`) and about 547 ms for a healthy Teams (DET12,
    /// 2026-08-19, pick to `ax_handles_built`). Against a hung client each AX call can wait
    /// `App.swift`'s 2 s messaging timeout and a walk makes hundreds, so there is no ceiling to
    /// measure on that side. 1.5 s is close to three times the healthy Teams build, and the clock
    /// starts only once the recorder is up, while the build started when the start committed and
    /// has had the whole engine bring-up already. Until MicGate engages the recorder's verdict is
    /// `.uncertain(not_started)`, which zero-fills the mic under the regulated / NDA gate, so this
    /// is also the longest the start of such a recording can be silenced by a slow client. Past it
    /// MicGate engages with empty AX handles (HAL VAD plus RMS) and `MeetingAXWindowWatcher`'s
    /// walk supplies the AX reading once `axWalkQueue` frees up.
    static let recordStartBuildDeadline: TimeInterval = 1.5
    /// The deadline this controller applies; a test shortens it.
    var recordStartBuildDeadlineSec = MeetingSessionController.recordStartBuildDeadline

    /// PERF15: the record start's one AX build. `recordStartBuildID` names the current one, so a
    /// landing for any other id is stale. `recordStartBuilt` holds a result that landed before the
    /// recorder came up; `recordStartAttach` is the recording waiting on it once it has.
    private var recordStartBuildID = 0
    private var recordStartBuilt: (id: Int, handles: MeetingAXHandleBuilder.Handles?)?
    private var recordStartAttach: RecordStartAttach?

    private struct RecordStartAttach {
        let id: Int
        let source: AppSource
        let file: URL
        /// Set when the deadline engaged MicGate without the build, so the late landing skips it.
        var micGateEngaged: Bool
    }

    init(coordinator: any SessionHost) {
        self.coordinator = coordinator
    }

    // MARK: - Verdict consumers (started from Coordinator.start)

    /// Drive the recorder writer + silence backstop from the gate's verdict
    /// stream, and route lifecycle verdicts into prompt/record/end. Both
    /// streams are unbounded and daemon-lifetime; cancelled in `shutdownConsumers`.
    func startConsumers() {
        assertMainQueue()
        verdictConsumerTask = Task { [weak self] in
            guard let self = self else { return }
            for await verdict in self.coordinator.micGate.verdicts {
                await MainActor.run {
                    self.latestVerdict = verdict
                    self.coordinator.audioRecorder.setMicGateVerdict(verdict)
                    self.coordinator.silenceBackstop.ingest(verdict: verdict, systemChannel: self.backstopSystemChannel())
                    self.syncStoppingSoon()
                }
            }
        }

        // Lifecycle verdicts: `.starting` raises the prompt,
        // `.endingProvisional` triggers the compact-view rescue re-walk,
        // `.ended` closes the recording or dismisses a stale prompt.
        lifecycleConsumerTask = Task { [weak self] in
            guard let self = self else { return }
            for await verdict in self.coordinator.lifecycleCoord.verdicts {
                // PERF15: the prompt's source (display name plus a window-title read per window)
                // resolves off main, awaited here so the verdicts still reach main in order: a
                // `.starting` handed off and an `.ended` behind it overtaking would prompt for a
                // call that is over.
                //
                // END20 (D075): the late-start confirm needs no title, so it runs first, and only a
                // `.starting` that is really a prompt waits for the read. That read shares
                // `axWalkQueue` with the mute walk and both AX builds, each AX call bounded only by
                // the 2 s messaging timeout, and while it waited an explicit start sat in
                // `.starting`, where a reliable end is immediate. The read is bounded too now.
                if case .starting(let context) = verdict {
                    // The seam and the deadline are read on main with everything else here.
                    let (confirmed, resolve, deadline) = await MainActor.run {
                        self.resolveTeardownHold(for: verdict)
                        return (
                            self.confirmLateStartIfRecording(context),
                            self.engageSeams.resolveStartingSource,
                            self.startingTitleDeadlineSec
                        )
                    }
                    if confirmed { continue }
                    let source = await MeetingSessionController.resolveAppSource(
                        from: context, within: deadline, using: resolve
                    )
                    await MainActor.run {
                        // The start may have committed while the title was read.
                        if self.confirmLateStartIfRecording(context) { return }
                        self.handleMeetingStarted(source: source)
                    }
                    continue
                }
                await MainActor.run {
                    self.resolveTeardownHold(for: verdict)
                    switch verdict {
                    case .starting:
                        break
                    case .inMeeting:
                        if case .recording = self.coordinator.stateMachine.current {
                            self.lifecycleReachedInMeetingThisRecording = true
                        }
                    case .endingProvisional(let context, _):
                        // END17: every weak end holds with the recorder running, browser included,
                        // and the native rescue re-walk still runs so a Leave button that merely
                        // moved reverts the hold through END8.
                        self.beginTeardownHold(context: context)
                        if self.holdPolicy.isOpen {
                            self.rescueProvisionalEnd(context: context)
                        }
                    case .ended(let context, let reason):
                        self.handleMeetingEnded(bundleID: context.bundleID, reason: reason)
                        // END20: an end that left a recording running means that recording's
                        // engine (or the one engaged beside it) is terminal and ignores every later
                        // signal. Countable, so the dogfood report can see it happen at all.
                        if case .recording(_, let src, _) = self.coordinator.stateMachine.current {
                            // END21 amendment (2026-11-17): `resolveTeardownHold` armed this end's
                            // cut before `handleMeetingEnded` decided not to act on it. The engine
                            // is terminal now, so no later verdict clears it, and every stop route
                            // consumes it: a hand Stop much later would cut the transcript at a
                            // foreign hold's stamp, and under NDA or regulated capture truncate
                            // the audio there. The cut belongs to the end that was not applied.
                            let trimDropped = self.pendingEndTrimAt != nil
                            self.pendingEndTrimAt = nil
                            self.noteRecordingOnTerminalEngine(
                                bundleID: context.bundleID, recordingBundleID: src?.bundleID, reason: "end_not_applied",
                                trimDropped: trimDropped
                            )
                        }
                    default:
                        break
                    }
                }
            }
        }
    }

    /// END9: any verdict other than another provisional resolves an open hold. An end concludes it,
    /// which is what marks the held tail for trimming whichever route confirmed it (END17: the
    /// teardown, a dwell, or an app quit). Anything else releases it, and the one that matters is
    /// `.inMeeting`: a returning signal reverts the hold, and that revert is the whole reason for
    /// holding.
    private func resolveTeardownHold(for verdict: MeetingLifecycleVerdict) {
        switch verdict {
        case .endingProvisional:
            break
        case .ended(_, let reason):
            // END21: a lone-dwell end is no evidence of when the call ended (F032).
            concludeTeardownHold(
                conclusion: reason.confirmedBy.contains(PromotionEngine.loneDwellEvidence) ? .loneDwell : .engineEnd
            )
        default:
            releaseTeardownHold(rescued: verdict.isLive)
            // A teardown confirm that lost the race to a revert never produced an `.ended`, so its
            // trim point must not survive into this call's real end.
            pendingEndTrimAt = nil
        }
    }

    /// END20: a recording is running on an engine that has already ended. Logged, never acted on.
    func noteRecordingOnTerminalEngine(
        bundleID: String, recordingBundleID: String?, reason: String, trimDropped: Bool = false
    ) {
        assertMainQueue()
        var attributes: [String: Any] = [
            "bundle_id": bundleID,
            "recording_bundle_id": recordingBundleID ?? "manual",
            "reason": reason,
        ]
        if trimDropped { attributes["trim_dropped"] = true }
        Log.event(category: "coordinator", action: "lifecycle_recording_on_terminal_engine", attributes: attributes)
    }

    func shutdownConsumers() {
        assertMainQueue()
        verdictConsumerTask?.cancel()
        verdictConsumerTask = nil
        lifecycleConsumerTask?.cancel()
        lifecycleConsumerTask = nil
    }

    // MARK: - State transitions

    /// The prompt's "Always for <app>": consent for good, then record. END20: guarded like its
    /// siblings (`didChooseRecord`, `didChooseSkip`) on the prompt it answers still being up. It was
    /// the one outcome without that guard, so a stale panel clicked while a recording ran called
    /// `beginRecording`, whose `alreadyRecording` catch then went idle over a running recorder.
    func chooseAlways(source: AppSource) {
        assertMainQueue()
        guard case .prompting(let pending) = coordinator.stateMachine.current, pending == source else { return }
        coordinator.addAutoConsentApp(source.bundleID)
        Log.writeLine("daemon", "user always-consented (\(source.bundleID))")
        Log.event(category: "coordinator", action: "user_consented_always", attributes: [
            "bundle_id": source.bundleID,
        ])
        // Explicit "always": clear every suppression (cooldown + skip latch) so a
        // stale skip/end can't block it (as with the manual hotkey path).
        coordinator.stateMachine.clearSuppression(bundleID: source.bundleID)
        beginRecording(source: source, summaryMode: .auto)
    }

    /// `surface` is the control that was pressed; on a stop it becomes the row's `stop_surface` (OBS5).
    func toggleManual(surface: StopSurface) {
        assertMainQueue()
        // END20: the toggle pressed while a start is coming up means stop, not a second start (which
        // `beginRecording` would ignore anyway), so it cancels the start in flight.
        if startLatch.cancel(by: "toggle") {
            // OBS7: the start's HUD never comes, so neither click is waiting on one.
            UILatency.shared.discardPending()
            Log.writeLine("daemon", "toggle during a start in flight → cancelling the start")
            return
        }
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
            pendingSplit = nil  // END28: a Stop is a Stop, not the first half of a split
            // OBS5: a Stop inside an open hold is the owner overruling (or beating) the end engine.
            let cause = StopCause.userStop(surface: surface, duringHold: holdPolicy.isOpen)
            stopRecording(file: file, source: src, summaryMode: mode, cause: cause)
        case .stopping:
            // Mid-flush; a new start would race the await. END28: a toggle during a split's stop
            // means stop, so the split's prompt is not raised once it finishes.
            pendingSplit = nil
            UILatency.shared.discardPending()  // OBS7: a press on a state that ignores it has no feedback
            notePressIgnored(state: "stopping", trigger: surface.rawValue)
        }
    }

    /// UX106: a press that meets a start or a stop in flight did nothing, so say so, in the log and
    /// on the status item. A queued start after the stop is a separate, owner-gated decision.
    private func notePressIgnored(state: String, trigger: String) {
        Log.event(category: "coordinator", action: "record_press_ignored", attributes: [
            "state": state,
            "trigger": trigger,
        ])
        coordinator.statusUI.flashNote(state == "stopping" ? "Still saving the last recording" : "Already starting")
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
        assertMainQueue()
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
        assertMainQueue()
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
        // SEC40: the offer's carried pick is this start's chip pick.
        if let carried = offerWorkflowOverride, carried.source == source {
            pendingWorkflowOverride = carried
        }
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
        assertMainQueue()
        // END20: a Stop during a start's bring-up cancels the start, which then stops the fresh
        // recording at commit. From `.idle` this used to do nothing at all.
        let cancelledStart = startLatch.cancel(by: reason)
        // END28: a Stop pressed during a split's stop must not be followed by the split's prompt.
        pendingSplit = nil
        Log.event(category: "coordinator", action: "force_stop", attributes: [
            "reason": reason,
            "state": DetectionStateMachine.label(coordinator.stateMachine.current),
            "cancelled_start": cancelledStart,
        ])
        switch coordinator.stateMachine.current {
        case .recording(let file, let src, let mode):
            stopRecording(file: file, source: src, summaryMode: mode, cause: .forced(reason: reason))
        case .prompting(let src):
            // Same as Skip: don't record, return to idle, and hold this call's prompt off for its
            // span (DET18) so the next discovery poll doesn't immediately re-prompt this meeting.
            notePromptDismissed(src, reason: .skipped, extra: ["route": reason])
            clearPromptRouting(exit: "force_stop")
            coordinator.prompt.dismiss()
            coordinator.stateMachine.abandonPrompt(source: src, liveness: holdLiveness(for: src), tabKey: holdTabKey(for: src))
            coordinator.statusUI.setIdle()
        case .idle, .suppressed, .stopping:
            break
        }
    }

    /// Stamp a timestamp marker on the active recording (FEAT8). Stop-only
    /// semantics like `forceStop`: pressing it when nothing is recording is a
    /// logged no-op, so it can never start a recording. The offset is seconds
    /// from recording start (the same clock the transcript segments use), the
    /// flag control acknowledges with the running count (UX73), and the whole
    /// batch is written to `<stem>.markers.json` on every press (REC26), so a
    /// crash, quit or rebuild relaunch mid-recording leaves the flags beside the
    /// intermediates the orphan sweep recovers. The stop-time write stays as the
    /// final flush.
    func flagMoment() {
        assertMainQueue()
        guard case .recording(let file, _, _) = coordinator.stateMachine.current else {
            Log.event(category: "recorder", action: "marker_flag_ignored", attributes: [
                "state": DetectionStateMachine.label(coordinator.stateMachine.current),
            ])
            return
        }
        let startedAt = coordinator.audioRecorder.startedAt ?? Date()
        let elapsed = max(0, Date().timeIntervalSince(startedAt))
        markerSeconds.append(elapsed)
        // REC26: persist now, not only at stop. An atomic replace of a sub-kilobyte file at human
        // press rates, beside where the final will land, which orphan recovery leaves in place.
        MarkerFile.write(seconds: markerSeconds, forFinal: file)
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
        assertMainQueue()
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
            // exist on disk without the marker that flags it for quarantine. REC21: a failed write
            // is reported and the span starts anyway; the job's `redactionOwed` covers a clean
            // stop and the manifest's `off_record` a crash.
            redactionOwed = true
            let stem = file.deletingPathExtension().lastPathComponent
            do {
                try offRecordMarkerWriter(file)
            } catch {
                StartMarkerWriteFailure.report(.offRecord, stem: stem, error: error)
            }
            offRecordManifestStem = stem
            if let inputs = manifestInputs {
                RecordingManifest.write(
                    summaryMode: inputs.summaryMode, meta: inputs.meta, captureMode: inputs.captureMode,
                    offRecord: true, forStem: stem, in: file.deletingLastPathComponent()
                )
            }
        }
        coordinator.audioRecorder.setManualOffTheRecord(on)
        coordinator.hud.setOffTheRecord(on)
        Log.event(category: "recorder", action: on ? "off_the_record_started" : "off_the_record_stopped", attributes: [
            "file": file.lastPathComponent,
        ])
        Log.writeLine("recorder", "off the record \(on ? "started" : "stopped") for \(file.lastPathComponent)")
    }

    /// Pin the prompt's meeting to a workflow (the prompt's chip, TECH-B5). SEC39: keyed to the
    /// source of the prompt that is up; ignored when none is.
    func setPendingWorkflowOverride(_ id: UUID?) {
        assertMainQueue()
        guard case .prompting(let source) = coordinator.stateMachine.current else { return }
        pendingWorkflowOverride = id.map { (source: source, workflowID: $0) }
    }

    /// SEC21: make the routing's blind spots countable at record start, changing nothing.
    ///
    /// A source with no meeting title is `meeting_title_unresolved` (F040: 155 of 155 recordings
    /// since 2026-09-01 had none, and nothing said so). A fallback that could not rule out an NDA
    /// workflow, because an NDA rule's bundle matched but its title rule could not be evaluated or
    /// a workflow file did not load, is `nda_classification_undecided`. By the owner's decision
    /// (2026-11-16) neither changes the capture posture while titles are unknown; revisit after
    /// CAL3. Neither row carries a title.
    private func noteRoutingUncertainty(source: AppSource?, reason: WorkflowMatcher.Reason) {
        if let source, (source.meetingTitle ?? "").isEmpty {
            Log.event(category: "coordinator", action: "meeting_title_unresolved", attributes: [
                "bundle_id": source.bundleID,
                "kind": source.kind == .browser ? "browser" : "native",
            ])
        }
        guard case .fallback(let undecided) = reason else { return }
        let brokenFiles = coordinator.workflowStore.broken.count
        guard !undecided.isEmpty || brokenFiles > 0 else { return }
        Log.event(category: "workflow", action: "nda_classification_undecided", attributes: [
            "bundle_id": source?.bundleID ?? "manual",
            "undecided_workflow_ids": undecided.map(\.id.uuidString),
            "broken_workflow_files": brokenFiles,
            "posture_changed": false,
        ])
    }

    /// SEC39: drop the prompt's routing state (the chip pick and AI9's pre-selection) on every way
    /// a prompt ends without recording, and before a new prompt resolves its chip. A timeout into
    /// the offer moves a carried pick out first (SEC40), so this never touches the offer's slot. A pick that was
    /// never recorded is logged, so a discarded routing choice leaves a trace.
    func clearPromptRouting(exit: String) {
        assertMainQueue()
        if let pick = pendingWorkflowOverride {
            Log.event(category: "workflow", action: "override_discarded", attributes: [
                "bundle_id": pick.source.bundleID,
                "exit": exit,
            ])
        }
        pendingWorkflowOverride = nil
        preselectedRoutingHint = nil
        pendingSplitFrom = nil
    }

    /// Workflow for the in-flight recording, for the HUD/status-bar chip.
    var currentActiveWorkflow: Workflow? { activeWorkflow }

    /// Workflow that would apply to `source` now (for the prompt chip);
    /// falls back to the default when nothing matches.
    func workflowForPrompt(source: AppSource?) -> Workflow? {
        assertMainQueue()
        return WorkflowMatcher.resolve(
            source: source,
            overrideID: pendingWorkflowOverride.flatMap { $0.source == source ? $0.workflowID : nil },
            workflows: coordinator.workflowStore.workflows
        )
    }

    /// STOR16: the move finished, success or failure; start what it held, if anything.
    func releaseHeldStart() {
        assertMainQueue()
        guard let held = heldStart else { return }
        heldStart = nil
        // The owner asked to see what a hold cost (2026-11-18): the seconds of meeting that went
        // unrecorded, so a cross-volume move that ever ate a real opening shows up in the log.
        let waited = heldSince.map { max(0, heldStartClock().timeIntervalSince($0)) } ?? 0
        heldSince = nil
        Log.writeLine("daemon", "beginRecording released after a library move: waited \(String(format: "%.1f", waited)) s")
        Log.event(category: "coordinator", action: "recording_start_released", attributes: [
            "reason": "library_move",
            "bundle_id": held.source?.bundleID ?? "manual",
            "waited_ms": Int((waited * 1000).rounded()),
        ])
        beginRecording(source: held.source, summaryMode: held.summaryMode)
    }

    /// AI9: what repeated WF8 corrections say the workflow for `source` should be,
    /// when that disagrees with `matched`. Nil is the normal answer.
    ///
    /// Reads the store in memory (it was loaded at launch and only grows on a
    /// reassignment), so this is a filter over a handful of structs on the main
    /// queue, not a disk hit in the detection path.
    func routingHint(source: AppSource?, matched: Workflow?) -> WorkflowRoutingHint.Suggestion? {
        assertMainQueue()
        return WorkflowRoutingHint.suggest(
            source: source,
            matched: matched,
            corrections: coordinator.workflowCorrections.corrections,
            workflows: coordinator.workflowStore.workflows
        )
    }

    func beginRecording(source: AppSource?, summaryMode: SummaryMode) {
        assertMainQueue()
        coordinator.stateMachine.cancelPromptTimeout()
        // STOR16 (option b, the owner's decision of 2026-11-18): while the library folder is being moved, no capture
        // file may open under the old root or the new one. Defer the start, before anything below
        // consumes routing state, and replay it unchanged when the move ends. The opening of the
        // meeting is lost for the move's length: milliseconds for a same-volume rename.
        if coordinator.libraryMoveInProgress {
            heldStart = (source, summaryMode)
            if heldSince == nil { heldSince = heldStartClock() }
            Log.writeLine("daemon", "beginRecording held: a library move is running")
            Log.event(category: "coordinator", action: "recording_start_held", attributes: [
                "reason": "library_move",
                "bundle_id": source?.bundleID ?? "manual",
            ])
            return
        }
        // END17 item 5: consumed first, before any early return, so a resume link can only ever
        // attach to the start it was armed for and never to a later, unrelated one.
        let resumedFrom = pendingResumedFrom
        pendingResumedFrom = nil
        // END28: the same, for a split's link, and only for the source its prompt was raised for.
        let splitFrom = pendingSplitFrom.flatMap { $0.source == source ? $0.stem : nil }
        pendingSplitFrom = nil

        // A start is async now (the engine bring-up is bounded off the main
        // thread), so the UI stays live while a wedged device is waited out.
        // Ignore a second Record/toggle press while one is in flight rather than
        // stacking another recorder.start().
        guard !startLatch.isInFlight else {
            Log.writeLine("daemon", "beginRecording ignored: a start is already in flight")
            notePressIgnored(state: "starting", trigger: source == nil ? "manual" : "prompt")
            return
        }
        // END20: never a second recording. Every caller already guards on its own state, except
        // the ones that did not (`didChooseAlways` until END20); refusing here, before the build
        // below bumps its id, keeps a stray start from detaching the live recording's AX attach,
        // and from the catch's `setIdle` that used to strand a running recorder.
        switch coordinator.stateMachine.current {
        case .recording, .stopping:
            Log.writeLine("daemon", "beginRecording ignored: already recording")
            return
        case .prompting(let src):
            // DET18 item 6: every accepting route (Record, Record BYO, Always, the toggle, a
            // `record` / `byo` default at the timeout) comes through here from the prompt.
            notePromptDismissed(src, reason: .accepted)
            coordinator.prompt.dismiss()
        case .idle, .suppressed:
            break
        }
        let startOrigin: RecordingStartLatch.Origin
        if resumedFrom != nil {
            startOrigin = .resume
        } else if case .idle = coordinator.stateMachine.current {
            startOrigin = .idle
        } else {
            startOrigin = .prompt
        }

        // The routing state, consumed before either early return below so a start refused there
        // (no microphone, dry run) cannot leave a pick, a resume decision or a hint armed for a
        // later start of the same source (SEC40, and SEC39's L3). The chip pick, then a resume's
        // decided workflow, then the AI9 pre-selection; each keyed to the source it was made for
        // (SEC39), so a start for another meeting, or a manual start with no source, consumes none
        // of them; all are cleared here either way, bar a carried offer pick for another source.
        var overrideID: UUID?
        if let pick = pendingWorkflowOverride, pick.source == source {
            overrideID = pick.workflowID
        } else if let resumed = pendingResumeWorkflow, resumed.source == source {
            overrideID = resumed.workflowID
        } else if let hint = preselectedRoutingHint, hint.source == source {
            overrideID = hint.workflowID
        }
        pendingWorkflowOverride = nil
        pendingResumeWorkflow = nil
        preselectedRoutingHint = nil
        if let source, offerWorkflowOverride?.source == source { offerWorkflowOverride = nil }

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
            coordinator.notifications.notifyError(
                "Microphone permission is required. Grant it in Preferences → Permissions, then try again.",
                operation: .recording, title: nil
            )
            // Deeplink to the Permissions section so the user can act.
            coordinator.menuPreferencesPermissions()
            coordinator.stateMachine.setIdle()
            coordinator.statusUI.setIdle()
            return
        }

        // UX94 / F056: with an unreadable config.toml and nothing remembered, the recordings folder is
        // a guess; a recording there would vanish from the Library once the file is fixed.
        if coordinator.recordingRootUnknown {
            Log.event(category: "coordinator", action: "recording_blocked", attributes: ["reason": "config_unreadable"])
            coordinator.notifications.notifyError(
                "Recordings are paused until config.toml is fixed: MeetingPipe cannot read it, so it cannot tell where your recordings go.",
                operation: .recording, title: nil
            )
            coordinator.menuPreferences()
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

        // Resolve the workflow controlling context/backend/sinks (TECH-B3): the chip pick (consumed
        // above, before the early returns), then rule matches, then default.
        let resolution = WorkflowMatcher.resolveWithReason(
            source: source,
            overrideID: overrideID,
            workflows: coordinator.workflowStore.workflows
        )
        let resolvedWorkflow = resolution.workflow
        noteRoutingUncertainty(source: source, reason: resolution.reason)

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

        // SEC18: a zero-egress recording over a synced library gets one warning per session, never a refusal.
        coordinator.notifications.notifyLibrarySyncedIfNeeded(captureMode: captureMode, libraryRoot: coordinator.liveOutputDir)

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

        // Committed to starting: guard re-entry until this start resolves. The await below
        // suspends rather than blocks: the recorder runs every engine call and the start's file
        // writes (marker, mic file) off main under bounds, and the recovery manifest after it is
        // written off main too (PERF28). The commit can therefore wait up to those bounds while
        // audio is already being captured; the post-start wiring runs back on main.
        startLatch.begin(origin: startOrigin, bundleID: source?.bundleID)
        // UX106: answer the click now, before the recorder is asked. `setRecording` and
        // `hud.present` promote both at commit; the catch reverts them.
        coordinator.statusUI.setStarting(source: source)
        coordinator.hud.presentStarting(source: source)
        // OBS7: Starting is now the first visible state of a Start, so the click is answered here,
        // once; the commit's `hud.present` no longer answers it.
        UILatency.shared.feedbackForLatest(.start)
        // PERF15: the start's one AX build, on `axWalkQueue` and overlapping the engine bring-up.
        // It replaces three: MicGate's (synchronous on main), the explicit-start lifecycle engage's
        // (also on main) and the Leave-button arm's (off main, its mute walks discarded).
        let recordStartBuild = source.map { beginRecordStartBuild(for: $0) }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let file = try await self.coordinator.audioRecorder.start(
                    outputDir: self.coordinator.liveOutputDir,
                    captureMode: captureMode,
                    voiceProcessing: self.coordinator.liveVoiceProcessing
                )
                // Persist the privacy + summary routing at START (REC2 / AUD-6) so a
                // crash / kill / rebuild before stop() can still recover this meeting
                // on-device: the manifest carries the summary mode (BYO must not become
                // an Anthropic+Notion auto-summary) and the meta sidecar payload (NDA /
                // regulated / workflow / title), which orphan recovery replays. Cleared
                // on a clean stop in `stopRecording`. PERF28: written off main and awaited
                // here, before the latch is read, so the resolve-to-`setRecording` span below
                // keeps no suspension point; an end during this write lands in the latch.
                await self.writeRecoveryManifest(
                    file: file, source: source, summaryMode: summaryMode, captureMode: captureMode,
                    workflow: resolvedWorkflow, resumedFrom: resumedFrom, splitFrom: splitFrom
                )
                // END20: read what happened during the bring-up before anything commits. No await
                // from here to `setRecording`, so no verdict or Stop can interleave.
                let startOutcome = self.startLatch.resolve()
                self.activeWorkflow = resolvedWorkflow
                self.activeCaptureMode = captureMode
                self.redactionOwed = captureMode == .captureFirstRedact  // REC21
                self.activeResumedFrom = resumedFrom
                self.activeSplitFrom = splitFrom
                self.markerSeconds = []  // FEAT8: fresh marker batch per recording
                self.coordinator.hud.resetFlagCount()  // UX73: and a fresh count on the control
                // DET1: apply the tag decision captured synchronously before the await, so
                // `handleMicBusyBundle` stops this recording when its app releases the mic. Reading
                // it here would race a concurrent handleMeetingStarted during the start.
                self.micTierRecordingBundle = isMicTierRecording ? source?.bundleID : nil
                // END20 (REC7 for every origin): an end of this meeting, or a Stop, that landed
                // during the bring-up stops the fresh recording here, before it is ever committed,
                // so no HUD or started notification flashes for it. The short capture is still
                // finalized and enqueued through the normal stop path; nothing is discarded.
                if startOutcome != .commit {
                    self.cancelRecordStartBuild()
                    var retainCandidate = true
                    var cause = StopCause.endedDuringStart
                    switch startOutcome {
                    case .endedDuringStart(let endReason):
                        // DET14 amendment: the same rule as a lifecycle end while recording.
                        retainCandidate = !endReason.isDefinitive(forBundleID: source?.bundleID ?? "")
                        Log.event(category: "coordinator", action: "recording_ended_during_start", attributes: [
                            "file": file.lastPathComponent,
                            "leading_signal": endReason.leadingSignal,
                            "origin": startOrigin.rawValue,
                        ])
                    case .cancelled(let by):
                        cause = .cancelledDuringStart(by: by)
                        Log.event(category: "coordinator", action: "recording_cancelled_during_start", attributes: [
                            "file": file.lastPathComponent,
                            "origin": startOrigin.rawValue,
                            "cancelled_by": by,
                        ])
                    case .commit:
                        break
                    }
                    self.stopRecording(
                        file: file, source: source, summaryMode: summaryMode, committed: false,
                        cause: cause, retainCandidate: retainCandidate
                    )
                    return
                }
                // END20: a prompt raised behind this start (a `.starting` that slipped in during an
                // idle-origin bring-up) would otherwise outlive the commit.
                switch self.coordinator.stateMachine.current {
                case .prompting(let src):
                    // A prompt-origin start already logged its own prompt's exit; only a prompt
                    // raised behind an idle-origin start is new here.
                    if startOrigin != .prompt {
                        self.notePromptDismissed(src, reason: .accepted, extra: ["route": "start_in_flight"])
                    }
                    self.coordinator.stateMachine.cancelPromptTimeout()
                    self.coordinator.prompt.dismiss()
                case .suppressed:
                    self.coordinator.stateMachine.cancelPromptTimeout()
                    self.coordinator.prompt.dismiss()
                default:
                    break
                }
                self.recordingCommittedAt = Date()
                self.lifecycleReachedInMeetingThisRecording = false
                // END21 amendment: a cut armed while no recording ran (an end the start latch
                // ignored, or one during a prompt) is no cut of this recording. An end of this
                // meeting during the bring-up stopped above with its cut; an open hold keeps its own.
                self.pendingEndTrimAt = nil
                self.coordinator.stateMachine.setRecording(file: file, source: source, summaryMode: summaryMode)
                self.coordinator.statusUI.setRecording(file: file, source: source, summaryMode: summaryMode, workflow: resolvedWorkflow)
                self.coordinator.hud.present(
                    source: source,
                    workflow: resolvedWorkflow,
                    startedAt: Date(),
                    levelProvider: { [weak self] in self?.coordinator.audioRecorder.currentMicLevelDb() ?? -120 }
                )
                self.coordinator.notifications.notifyRecordingStarted(file: file)
                // REC20 item 1: a start short of space still records, and says so on the HUD it
                // just presented and in one notification. The recorder already logged the event.
                if let notice = self.coordinator.audioRecorder.lowSpaceAtStart {
                    self.coordinator.hud.setLowSpace(RecordingLowSpace.hudText(coveredSeconds: notice.coveredSeconds))
                    let text = RecordingLowSpace.startMessage(notice)
                    self.coordinator.notifications.notifyLowSpace(title: text.title, body: text.body)
                }
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
                self.armMicQuietCheck()
                self.coordinator.micGate.beginSpeechEvidence()
                self.compareInputDeviceHolder(trigger: "start", source: source)
                self.resetMicGateBackstop()
                // PERF15: the AX attach (MicGate, END11's explicit-start engage, the Leave arm)
                // runs when the build lands, or MicGate alone at the deadline, so nothing on this
                // continuation waits for a walk. The recorder's verdict is `.uncertain(not_started)`
                // until MicGate engages, which is the zero-fill the synchronous build gave before.
                if let source = source, let recordStartBuild = recordStartBuild {
                    self.attachWhenBuilt(id: recordStartBuild, source: source, file: file)
                }
                // Recorder armed: promote `.starting` to `.inMeeting` (no-op for
                // manual recordings and the prompt-answered-late race). An explicit start's
                // engine reaches `.starting` only after this, once its build lands; the
                // lifecycle consumer promotes that one (`confirmLateStartIfRecording`).
                // END19 amendment: only this recording's own engine. Another app's `.starting`
                // promoted here became the recording's engine for good (M2 of the 2026-11-17
                // review); the build's engage replaces it instead. A source-less start keeps
                // promoting what it finds, which END19 item 3 relies on.
                let engaged = self.coordinator.lifecycleCoord.engagedBundleID
                if let source, let engaged, engaged != source.bundleID {
                    Log.event(category: "coordinator", action: "lifecycle_promotion_skipped", attributes: [
                        "bundle_id": source.bundleID,
                        "engaged_bundle_id": engaged,
                        "reason": "other_app_engaged",
                    ])
                } else {
                    self.coordinator.lifecycleCoord.confirmRecording()
                }
                // END28: from here on, a change of call splits this recording.
                self.armCallIdentityWatch(file: file, source: source)
                // END23: and a Teams recording stops 120 s into a mic release, whatever the engine says.
                self.armMicReleaseCeiling(file: file, source: source)
            } catch {
                self.startLatch.clear()
                // END20: a start refused because a recording is already running must not touch
                // that recording's state. The old path went `setIdle` here with the recorder still
                // running, and every stop path keys on `.recording`, so nothing could stop it.
                if case MeetingRecorder.RecorderError.alreadyRecording = error {
                    // UX106: take the Starting state back down; the running recording keeps its own.
                    if case .recording(let file, let src, let mode) = self.coordinator.stateMachine.current {
                        self.coordinator.statusUI.setRecording(file: file, source: src, summaryMode: mode, workflow: self.activeWorkflow)
                    } else {
                        self.coordinator.statusUI.setIdle()
                        self.coordinator.hud.dismiss(animated: false)
                    }
                    Log.event(category: "coordinator", action: "recording_error", attributes: [
                        "stage": "start",
                        "reason": "already_recording",
                        "bundle_id": source?.bundleID ?? "manual",
                        "cooldown_armed": false,
                    ])
                    return
                }
                // MIC11 / AUD: a failed start must fail *bounded*, not silently churn
                // the audio stack. The 2026-06-09 storm was an engine-start that
                // returned to .idle with no backoff, so the detector's next discovery
                // poll - and a user re-click - re-attempted immediately and unboundedly.
                // Arm the per-bundle reprompt cooldown so a device the engine can't start
                // on (a renegotiating Bluetooth headset) backs off for repromptCooldownSec
                // before it can re-prompt, and emit a structured event so `mp logs` /
                // `mp analyze-detection` can see failed starts (the catch was os_log-only).
                // Manual recordings have no bundle to cool down; `startLatch`
                // already bounds re-clicks there.
                let reason = MeetingSessionController.startFailureReason(error)
                self.cancelRecordStartBuild()  // PERF15: nothing to attach it to
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
                // UX106: revert the Starting state before the error says why.
                self.coordinator.hud.dismiss(animated: false)
                self.coordinator.stateMachine.setIdle()
                self.coordinator.statusUI.setIdle()
                self.coordinator.notifications.notifyError(
                    "Could not start recording: \(error.localizedDescription)", operation: .recording, title: nil
                )
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
        case .engineCallsExhausted: return "engine_calls_exhausted"
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
        /// REC30: the far side is missing for this many seconds in all (a late start, a short
        /// tail, or both), though the stream ended healthy. 10 s or more only
        /// (`ChannelCoverage.noticeThresholdSec`).
        case partlyMissing(seconds: Int)
    }

    /// Pure coverage gate over the recorder's stop-time snapshot. Lifted out so it is
    /// unit-testable without the controller (like `startFailureReason`). A never-started
    /// capture takes precedence over a mid-meeting death (frames == 0 is the stronger,
    /// whole-recording signal).
    static func remoteAudioWarning(
        systemFires: UInt64, degraded: Bool, farSideMissingSeconds: Int? = nil
    ) -> RemoteAudioWarning {
        if systemFires == 0 { return .micOnly }
        if degraded { return .interrupted }
        if let farSideMissingSeconds { return .partlyMissing(seconds: farSideMissingSeconds) }
        return .none
    }

    /// `committed` is false only for END20's start that an end or a Stop overtook during its
    /// bring-up: it is finalized and enqueued like any recording, but the coverage warnings below
    /// (no remote audio, short, silent mic) say nothing true about a capture a second long that
    /// nobody asked for.
    /// `cause` names why it stopped: `stop_cause` on `recording_stopped` (OBS5), and the route
    /// `held_end_trimmed` reports (END21).
    func stopRecording(
        file: URL, source: AppSource?, summaryMode: SummaryMode,
        committed: Bool = true, cause: StopCause, retainCandidate: Bool = true
    ) {
        assertMainQueue()
        // END21 item 3: a stop inside an open hold concludes it here, under the owner's rule of
        // 2026-11-16 (`TeardownHoldPolicy.trimPoint` with `.stop`): cut at the mic release only
        // while the mic still reads released, nothing read live again since, and the Leave button
        // or the call window went after it; otherwise nothing is cut. Before END21 every stop but a
        // lifecycle end reached here with no trim at all, so a Stop during Confirming end kept and
        // transcribed the post-call tail. A lifecycle end has already concluded and released its
        // hold before it reaches here.
        if holdPolicy.isOpen {
            concludeTeardownHold(conclusion: .stop)
        }
        disarmCallIdentityWatch()
        disarmMicReleaseCeiling()
        micTierRecordingBundle = nil // DET1: this recording is ending; drop its mic-release tag
        // END13 item 5: hand the just-stopped source to the candidate slot at the instant of the
        // stop, so a Record pressed straight afterwards attaches to it instead of recording
        // headless.
        //
        // The slot is otherwise written only by `handleDiscovery`'s two suppression branches, and
        // the cooldown branch this stands in for cannot run until the *next* discovery poll,
        // because the cooldown is armed by this stop. Measured over every restart within 120 s of a
        // stop since 2026-08-22, the first `cooldown_candidate_retained` landed 1.1 s to 14.1 s
        // after the stop; on 2026-09-04 the owner pressed Record at 4.2 s and beat it, and the
        // replacement ran 40 minutes as `bundle_id: "manual"` with no end anchor at all (END11).
        //
        // `.cooldown` origin rather than a new one: the claim is exactly the cooldown branch's
        // claim, "this call was running a moment ago and may still be", and DET14's 24 s grace is
        // already derived from the one quiet discovery poll (12 s) this has to bridge. It sits
        // after `handleMeetingEnded`'s DET14 clear on the lifecycle-end path, which is the right
        // order: that clear is about the *previous* sighting going stale, this is a fresh one.
        if let source = source, !retainCandidate {
            Log.event(category: "coordinator", action: "stopped_candidate_not_retained", attributes: [
                "bundle_id": source.bundleID,
                "reason": "definitive_end",
            ])
        } else if let source = source {
            coordinator.stateMachine.noteSuppressedCandidate(source, origin: .cooldown)
            Log.event(category: "coordinator", action: "stopped_candidate_retained", attributes: [
                "bundle_id": source.bundleID,
                "display_name": source.displayName,
                "grace_sec": DetectionStateMachine.cooldownCandidateGraceSec,
            ])
        }
        coordinator.stateMachine.setStopping(file: file, source: source, summaryMode: summaryMode)
        // OBS10: the stop decision, for `stop_began`'s delay (the main-thread stretch below).
        let stopDecidedAt = stopClock()
        coordinator.statusUI.setStopping(file: file, source: source, summaryMode: summaryMode)
        coordinator.hud.dismiss()
        // OBS7: the HUD fade is a Stop's first visible state. Read on the next main turn, so the
        // lifecycle and mic-gate teardown below (P005/P047) is inside the number.
        UILatency.shared.feedbackForLatest(.stop)
        disarmSystemLevelMirror()
        disarmMicQuietCheck()
        // Tear down per-meeting AX subscriptions; the verdict stream stays
        // open for the next meeting.
        coordinator.lifecycleCoord.disengage()
        // MIC21: the recording's one speech_evidence row, before `stop` resets the gate's state.
        coordinator.micGate.emitSpeechEvidence(bundleID: source?.bundleID)
        coordinator.micGate.stop()
        axWindowWatcher?.stop()
        axWindowWatcher = nil
        // PERF15: a record-start build still walking must not engage MicGate or the lifecycle
        // after the recording it was built for has stopped.
        cancelRecordStartBuild()

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
                StopStallWatchdog.stallMessage(elapsed: elapsed),
                operation: .recording, title: "Still finishing the recording"
            )
        }
        // END9: the cut a concluded hold left (since END21 the mic release, not the hold's start,
        // see `TeardownHoldPolicy.trimPoint`). Measured from
        // the recorder's own start rather than from the controller's clock, because that is the
        // origin the produced file's timeline actually has. Read here rather than inside the Task
        // below because this is main-confined controller state and that closure is `[weak self]`;
        // consumed either way, so it can never leak into the next meeting.
        let trimSeconds = pendingEndTrimAt.flatMap { trimAt -> Double? in
            guard let startedAt = recorder.startedAt else { return nil }
            let seconds = trimAt.timeIntervalSince(startedAt)
            return seconds > 0 ? seconds : nil
        }
        pendingEndTrimAt = nil
        // END17: keep, then trim. A lossless capture keeps the held tail on disk and only suggests
        // the cut, so a wrong end is one click from undone; the transcript and summary leave it out
        // (`HeldEndTrim`). Under the regulated and NDA postures ADR 0016 says post-call audio must
        // not exist at rest, so there the cut happens at stop, as it always did. An unknown mode
        // takes the private path.
        let keepsHeldTail = activeCaptureMode?.capturesLosslessly == true
        let redactionOwed = self.redactionOwed  // REC21: read before the Task, like the trim
        let suggestedTrimSeconds = keepsHeldTail ? trimSeconds : nil
        if let trimSeconds = trimSeconds {
            Log.event(category: "recorder", action: "held_end_trimmed", attributes: [
                "file": file.lastPathComponent,
                "limit_sec": trimSeconds,
                "mode": keepsHeldTail ? "suggested" : "truncated",
                "stop_route": cause.stopRoute,
            ])
        }
        let stopClock = self.stopClock
        // OBS10: the synchronous stretch ends here; the rest of `delay_ms` is the Task waiting for main.
        let stopQueuedAt = stopClock()
        Task { @MainActor [weak self] in
            // OBS10: the recorder's stop is called right after this row. In five field recordings it
            // began 5 to 24 s after the decision with the mic still capturing. `sync_ms` is
            // `stopRecording`'s own synchronous work (PERF14 wants it apart from the queue wait).
            Log.event(category: "recorder", action: "stop_began", attributes: [
                "file": file.lastPathComponent,
                "delay_ms": max(0, (stopClock() - stopDecidedAt) * 1000).rounded(),
                "sync_ms": max(0, (stopQueuedAt - stopDecidedAt) * 1000).rounded(),
            ])
            let producedUsableFinal = await recorder.stop(limitSeconds: keepsHeldTail ? nil : trimSeconds)
            self?.stopStallWatchdog.disarm()
            guard let self = self else { return }
            Log.writeLine("daemon", "recording stopped (\(cause.name)) → \(file.path)")
            Log.event(category: "coordinator", action: "recording_stopped", attributes: [
                "file": file.lastPathComponent,
                "bundle_id": source?.bundleID ?? "manual",
                "system_audio_frames": recorder.lastSystemFires,
                "produced_final": producedUsableFinal,
            ].merging(cause.attributes) { own, _ in own })
            // FEAT8/REC7: flush the flagged moments before the merge-outcome branch,
            // so a failed merge (intermediates kept for the orphan sweep) does not
            // discard them; the sidecar sits beside where the final will land.
            MarkerFile.write(seconds: self.markerSeconds, forFinal: file)
            if producedUsableFinal {
                // Surface a missing-remote-side recording. Zero frames = the whole call was
                // mic-only (Screen Recording denied; the notifier shows "Open Settings" only
                // when a perm change helps). A mid-meeting SCStream death (frames > 0 but
                // degraded) is a partial loss the old `== 0` gate never caught (REC4 / AUD-13).
                switch committed ? MeetingSessionController.remoteAudioWarning(
                    systemFires: recorder.lastSystemFires,
                    degraded: recorder.lastSystemDegraded,
                    farSideMissingSeconds: recorder.lastChannelCoverage?.noticeMissingSeconds
                ) : .none {
                case .micOnly:
                    let perm = SystemAudioCapture.permissionState
                    self.coordinator.notifications.notifyMicOnlyRecording(file: file, permissionState: perm)
                    if perm == .denied || perm == .unknown {
                        self.coordinator.statusUI.refreshMenuForPermissionChange()
                    }
                case .interrupted:
                    self.coordinator.notifications.notifyRemoteAudioInterrupted(file: file)
                case .partlyMissing(let seconds):
                    self.coordinator.notifications.notifyRemoteAudioPartlyMissing(file: file, missingSeconds: seconds)
                case .none:
                    break
                }
                // REC9: the recording carries materially less audio than the meeting it
                // spanned. Orthogonal to the two warnings around it, which are about
                // which CHANNEL is missing; this one fires when the file itself is short,
                // whatever the cause, and it is the surface the 2026-07-15 truncation
                // never had.
                if committed, let parity = recorder.lastDurationParity, parity.isShort {
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
                    peakUnmutedRmsDb: coverage.peakUnmutedRmsDb,
                    loudUnmutedSeconds: coverage.loudUnmutedSeconds
                )
                if committed, micWarning == .micRecordedNothing {
                    self.coordinator.notifications.notifyMicRecordedNothing(file: file)
                    Log.event(category: "recorder", action: "mic_recorded_nothing", attributes: [
                        "file": file.lastPathComponent,
                        "recording_seconds": coverage.recordingSeconds,
                        "unmuted_seconds": coverage.unmutedSeconds,
                        "peak_unmuted_db": Double(coverage.peakUnmutedRmsDb),
                        "device": recorder.lastInputDevice?.displayName ?? "(unknown)",
                    ])
                }
                // MIC17: the quiet tier, which `evaluate` returns only when the dead tier did not
                // fire. The stop notice stays even when the live HUD notice showed: the HUD can be
                // missed in a long call, and this is the one the owner reads afterwards.
                if committed, micWarning == .micVeryQuiet {
                    let device = recorder.lastInputDevice?.displayName
                    self.coordinator.notifications.notifyMicVeryQuiet(file: file, device: device)
                    Log.event(
                        category: "recorder", action: "mic_very_quiet",
                        attributes: Self.micVeryQuietAttributes(
                            phase: "stop", file: file.lastPathComponent, coverage: coverage, device: device
                        )
                    )
                }
                let stem = file.deletingPathExtension().lastPathComponent
                do {
                    try self.writeMetaSidecar(
                        file: file,
                        source: source,
                        micDeviceName: recorder.lastInputDevice?.displayName,
                        micSilent: micWarning == .micRecordedNothing,
                        heldEndTrimSec: suggestedTrimSeconds
                    )
                } catch {
                    // SEC25: the write is atomic, so a failure leaves no sidecar and the
                    // pipeline would read "no workflow". The recovery manifest holds the same
                    // routing, so it is kept, and a private workflow's job waits for a retry
                    // that restores the sidecar from it (`MeetingLibraryService.retryMeeting`).
                    let held = MetaWriteFailure.holdsJob(workflow: self.activeWorkflow)
                    self.reportMetaWriteFailure(error, stem: stem, held: held)
                    if held {
                        PipelineFailureSidecar.write(
                            stem: stem, in: file.deletingLastPathComponent(),
                            stage: .pipeline, reason: MetaWriteFailure.heldReason
                        )
                        self.coordinator.notifications.notifyError(MetaWriteFailure.heldReason, operation: .storage, title: nil)
                    } else {
                        self.coordinator.notifications.notifyProcessing(file: file, cause: cause)
                        self.coordinator.jobs.enqueue(file: file, summaryMode: summaryMode, redactionOwed: redactionOwed)
                    }
                    self.resetAfterStop(source: source)
                    return
                }
                self.coordinator.notifications.notifyProcessing(file: file, cause: cause)
                self.coordinator.jobs.enqueue(file: file, summaryMode: summaryMode, redactionOwed: redactionOwed)
                // Clean finish: the meta sidecar is now on disk and the job is
                // enqueued, so drop the start-time recovery manifest. Kept on the
                // else branch below, where the merge failed and the orphan sweep
                // still needs it to route the retried recording (REC2 / AUD-6), and
                // kept above when the sidecar write failed (SEC25). REC21: the job's
                // `redactionOwed` is memory only and the queue does not survive a quit, so
                // an owed cut is first put on disk as `.offrecord`; the manifest stays when
                // even that cannot land.
                if !redactionOwed || OffRecordMarker.persistOwed(forFinal: file) {
                    RecordingManifest.remove(forStem: stem, in: file.deletingLastPathComponent())
                }
                // The MIC14 `.offrecord` marker is deliberately NOT dropped here (SEC16). It used
                // to be, which left nothing on disk saying the recording had an off-record span
                // if the timeline write had failed. The job removes it once redaction succeeds.
            } else {
                // The merge/convert could not produce a usable final. stop() kept
                // any capture intermediates and wrote a failure breadcrumb, so the
                // orphan sweep recovers them automatically (REC6: the sweep runs
                // after every job completion, not only at the next launch). Preserve
                // the meeting title / workflow for that run, and surface the failure
                // now rather than enqueueing a missing file (REC1 / AUD-5).
                do {
                    try self.writeMetaSidecar(file: file, source: source, heldEndTrimSec: suggestedTrimSeconds)
                } catch {
                    // The manifest is kept on this branch anyway, and orphan recovery restores
                    // the sidecar from it before the recovered recording is enqueued.
                    self.reportMetaWriteFailure(
                        error, stem: file.deletingPathExtension().lastPathComponent, held: false
                    )
                }
                self.coordinator.notifications.notifyError(
                    "Could not finalize \(file.lastPathComponent). The raw recording was kept and will be recovered automatically.",
                    operation: .recording, title: "Couldn't finish the recording file"
                )
                // REC32: make "automatically" true with an empty queue too. `recorder.stop` has
                // returned, so the stem is handed back (REC23) unless an abandoned drain still
                // holds it, in which case this sweep skips it and the next settled job retries.
                self.coordinator.requestOrphanSweep()
            }
            self.resetAfterStop(source: source)
        }
    }

    /// The tail of every stop: drop the workflow + markers so they can't bleed into the next
    /// meeting, arm the re-prompt cooldown, and go idle.
    private func resetAfterStop(source: AppSource?) {
        activeWorkflow = nil
        activeCaptureMode = nil
        activeResumedFrom = nil
        activeSplitFrom = nil
        markerSeconds = []
        coordinator.hud.resetFlagCount()  // UX73: paired with every markerSeconds reset
        offTheRecordOn = false
        redactionOwed = false
        manifestInputs = nil
        offRecordManifestStem = nil
        // Arm the re-prompt cooldown so a post-call mic grab (Teams chat,
        // Zoom teardown toast) can't re-prompt right after the flush.
        if let bid = source?.bundleID {
            coordinator.stateMachine.recordCooldownEnd(bundleID: bid)
        }
        coordinator.stateMachine.setIdle()
        coordinator.statusUI.setIdle()
        // END28: a split's stop is done; raise the new call's prompt now (both stop paths end here).
        raisePendingSplitPrompt()
    }

    /// SEC25: a failed stop-time sidecar write reaches the daemon file log and the event log,
    /// not only os.Logger (whose interpolated reason is stored as `<private>`).
    private func reportMetaWriteFailure(_ error: Error, stem: String, held: Bool) {
        let ns = error as NSError
        Log.writeLine(
            "daemon",
            "WARN: could not write meta sidecar for \(stem) (\(ns.domain) \(ns.code)): \(error.localizedDescription); recovery manifest kept\(held ? ", job held" : "")"
        )
        Log.event(category: "recorder", action: "meta_write_failed", attributes: [
            "stem": stem,
            "domain": ns.domain,
            "code": ns.code,
            "held": held,
        ])
    }

    /// Drop a `<wav-stem>.meta.json` next to the recording so the pipeline
    /// can pick up the meeting name + source app for a contextual Notion
    /// title. Throws on a failed write (SEC25): the caller decides whether the
    /// job can run without it, since the sidecar also carries the workflow's
    /// NDA routing.
    ///
    /// TECH-B4 piggy-backs the active workflow onto the same sidecar
    /// (`workflow_id`, `workflow_name`, `workflow_color`, plus the per-
    /// workflow overrides the pipeline applies at run-all time). Writing
    /// it here keeps the sidecar a single atomic file: the pipeline
    /// reads `<stem>.meta.json` once and gets every per-meeting knob.
    func writeMetaSidecar(
        file: URL,
        source: AppSource?,
        micDeviceName: String? = nil,
        micSilent: Bool = false,
        heldEndTrimSec: Double? = nil
    ) throws {
        assertMainQueue()
        let dict = MeetingMetaSidecar.build(
            source: source,
            workflow: activeWorkflow,
            regulatedMode: coordinator.configStore?.regulatedMode ?? false,
            micDeviceName: micDeviceName,
            micSilent: micSilent,
            heldEndTrimSec: heldEndTrimSec,
            resumedFrom: activeResumedFrom,
            splitFrom: activeSplitFrom
        )
        if dict.isEmpty { return }
        let stem = file.deletingPathExtension().lastPathComponent
        let sidecar = file.deletingLastPathComponent().appendingPathComponent("\(stem).meta.json")
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: sidecar, options: .atomic)
        let titleKnown = source?.meetingTitle?.isEmpty == false  // SEC38: whether, never which
        Log.writeLine("daemon", "meta sidecar → \(sidecar.lastPathComponent) title_known=\(titleKnown) workflow=\(activeWorkflow?.name ?? "(none)")")
    }

    /// Write the start-time recovery manifest (`<stem>.recovery.json`, REC2 /
    /// AUD-6). It carries the summary mode and the same `MeetingMetaSidecar`
    /// payload the clean-stop sidecar uses, so orphan recovery can route a
    /// crash-interrupted BYO / NDA / regulated meeting on-device instead of
    /// auto-egressing it. Removed on a clean stop that produced a final.
    /// CONC6: `@MainActor`, because a plain `async` method runs on the generic executor (SE-0338) even
    /// when awaited from a main-actor `Task`, and this body reads `coordinator.configStore` and writes
    /// `manifestInputs`, both main-queue state. Only `RecordingManifest.writeOffMain` leaves main.
    @MainActor
    func writeRecoveryManifest(
        file: URL, source: AppSource?, summaryMode: SummaryMode, captureMode: CaptureMode,
        workflow: Workflow?, resumedFrom: String?, splitFrom: String? = nil
    ) async {
        assertMainQueue()
        let meta = MeetingMetaSidecar.build(
            source: source,
            workflow: workflow,
            regulatedMode: coordinator.configStore?.regulatedMode ?? false,
            resumedFrom: resumedFrom,
            splitFrom: splitFrom
        )
        let stem = file.deletingPathExtension().lastPathComponent
        manifestInputs = (summaryMode, meta, captureMode)
        await RecordingManifest.writeOffMain(
            summaryMode: summaryMode,
            meta: meta,
            captureMode: captureMode,
            forStem: stem,
            in: file.deletingLastPathComponent(),
            onLateFinish: { [weak self] in
                Task { @MainActor in self?.reassertOffRecordManifest(file: file) }
            }
        )
    }

    /// REC21: a start-time manifest write that ran past its budget is kept when it lands, and it
    /// was encoded with `off_record: false`. If a span opened in between, write it back.
    private func reassertOffRecordManifest(file: URL) {
        let stem = file.deletingPathExtension().lastPathComponent
        guard offRecordManifestStem == stem, let inputs = manifestInputs else { return }
        RecordingManifest.write(
            summaryMode: inputs.summaryMode, meta: inputs.meta, captureMode: inputs.captureMode,
            offRecord: true, forStem: stem, in: file.deletingLastPathComponent()
        )
    }

    func startPromptTimeout(for source: AppSource) {
        assertMainQueue()
        coordinator.stateMachine.startPromptTimeout(
            for: source,
            timeoutSec: coordinator.livePromptTimeoutSec
        ) { [weak self] in
            guard let self = self else { return }
            let configured = (self.coordinator.configStore?.defaultPromptAction ?? "skip").lowercased()
            // END28: a split's prompt never records on its own.
            let isSplit = self.isSplitPrompt(for: source)
            let action = isSplit ? "skip" : MeetingSessionController.effectiveTimeoutAction(configured: configured, kind: source.kind)
            Log.event(category: "coordinator", action: "prompt_timeout", attributes: [
                "bundle_id": source.bundleID,
                "default_action": configured,
                "effective_action": action,
                "split": isSplit,
            ])
            switch action {
            case "record":
                Log.writeLine("daemon", "prompt timed out → auto-record (\(source.bundleID))")
                self.beginRecording(source: source, summaryMode: .auto)
            case "byo":
                Log.writeLine("daemon", "prompt timed out → auto-record byo (\(source.bundleID))")
                self.beginRecording(source: source, summaryMode: .byo)
            default:
                Log.writeLine("daemon", "prompt timed out → one-click offer (\(source.bundleID))")
                self.notePromptDismissed(source, reason: .timedOutToOffer)
                // SEC40: the offer is the same call and the same source, so the chip pick survives
                // into it (`offerWorkflowOverride`), unless it is weaker than the rule match.
                let carried = self.pendingWorkflowOverride.flatMap {
                    $0.source == source && self.pickIsNotWeakerThanRule($0) ? $0 : nil
                }
                if carried != nil { self.pendingWorkflowOverride = nil }
                self.clearPromptRouting(exit: "timeout")
                if let carried {
                    self.offerWorkflowOverride = carried
                    Log.event(category: "workflow", action: "override_carried_to_offer", attributes: [
                        "bundle_id": source.bundleID,
                    ])
                }
                self.coordinator.prompt.dismiss()
                // DET18 item 1: a timeout is not a skip. On the work laptop all 32 timeouts became
                // skips and 19 Teams calls went wholly unrecorded while the app stayed on screen.
                // No cooldown and no latch: the panel collapses into a one-click offer holding the
                // prompt's own source, live for the call's span (item 2), so a click attaches with
                // the source and arms end detection.
                self.coordinator.stateMachine.offerPrompt(
                    source: source, liveness: self.holdLiveness(for: source), tabKey: self.holdTabKey(for: source)
                )
                // UX10's two surfaces stay, reworded: the menu bar reads "Detected <app>" with the
                // "Record this <app> meeting" row for as long as the offer lives, and the banner
                // carries the same one click.
                let bundleID = source.bundleID
                self.coordinator.statusUI.setOffered(source) { [weak self] in
                    self?.coordinator.stateMachine.isOffered(bundleID: bundleID) ?? false
                }
                self.coordinator.notifications.notifySkippedMeeting(source: source, origin: .timedOut)
            }
        }
    }

    /// DET17 guard 1: a browser source is never recorded without a click. Every plain browser
    /// source is title-only today (no microphone read), so a `record` or `byo` default acts as
    /// `skip` for it until DET20 adds audio evidence. Pure.
    static func effectiveTimeoutAction(configured: String, kind: AppSourceKind) -> String {
        guard kind == .browser, configured == "record" || configured == "byo" else { return configured }
        return "skip"
    }

    // MARK: - DET18: the prompt's exits, its offer and its pause

    /// Why a prompt left the screen (DET18 item 6). `coordinator/prompt_dismissed` carries it, so
    /// the field can finally say how a prompt ended rather than inferring it from the next state.
    enum PromptDismissReason: String {
        case accepted
        case skipped
        case timedOutToOffer = "timed_out_to_offer"
        case withdrawnDefinitive = "withdrawn_definitive"
        case withdrawnMicReleased = "withdrawn_mic_released"
        /// The offer a timeout left behind went away with its call's span.
        case spanLapsed = "span_lapsed"
    }

    func notePromptDismissed(_ source: AppSource, reason: PromptDismissReason, extra: [String: Any] = [:]) {
        assertMainQueue()
        var attributes: [String: Any] = [
            "bundle_id": source.bundleID,
            "reason": reason.rawValue,
            // An offer lapsing has no panel to be over.
            "pointer_over": reason == .spanLapsed ? false : coordinator.prompt.isPointerOver,
        ]
        attributes.merge(extra) { _, new in new }
        Log.event(category: "coordinator", action: "prompt_dismissed", attributes: attributes)
    }

    /// What keeps a hold on this prompt's call alive: the DET1 mic-in-use tier's sources are never
    /// scanner candidates, so they live on the mic-busy span; everything else on the scan.
    func holdLiveness(for source: AppSource) -> SkippedMeetingLatch.Liveness {
        assertMainQueue()
        return micTierPromptBundle == source.bundleID ? .micBusy : DetectionStateMachine.spanLiveness(for: source)
    }

    /// An explicit Skip (the panel's ×, the chevron's Skip, the banner's Skip). Holds this call's
    /// prompt off for its span, with the quiet undo surfaces DET7 gave it.
    func skipPrompt(source: AppSource) {
        assertMainQueue()
        guard case .prompting(let pending) = coordinator.stateMachine.current, pending == source else { return }
        notePromptDismissed(source, reason: .skipped)
        clearPromptRouting(exit: "skip")
        coordinator.prompt.dismiss()
        coordinator.stateMachine.abandonPrompt(
            source: source, liveness: holdLiveness(for: source), tabKey: holdTabKey(for: source)
        )
        noteSkipped(source)
    }

    /// DET7's two quiet surfaces for a skip: the menu-bar label, which reads the latch and collapses
    /// on its own once the call's span ends, and a silent banner as an undo affordance.
    private func noteSkipped(_ source: AppSource) {
        let bundleID = source.bundleID
        coordinator.statusUI.setSuppressed(source) { [weak self] in
            self?.coordinator.stateMachine.isSkipLatched(bundleID: bundleID) ?? false
        }
        coordinator.notifications.notifySkippedMeeting(source: source, origin: .dismissed)
        Log.writeLine("daemon", "user skipped (\(source.bundleID))")
        Log.event(category: "coordinator", action: "user_skipped", attributes: [
            "bundle_id": source.bundleID,
        ])
    }

    enum PromptPick: String {
        case record
        case recordBYO = "record_byo"
        case always
        case skip
    }

    /// DET18 item 5: a pick from the panel or its chevron menu, resolved against the source this
    /// controller holds rather than the panel's own copy, which the panel clears on dismiss. A pick
    /// that lands after the timeout collapsed the panel acts on the offer; one that matches neither
    /// is refused and returns false so the caller can say so. Returns true when it acted.
    @discardableResult
    func resolvePromptPick(_ pick: PromptPick, source: AppSource) -> Bool {
        assertMainQueue()
        if case .prompting(let pending) = coordinator.stateMachine.current, pending == source {
            switch pick {
            case .record: beginRecording(source: source, summaryMode: .auto)
            case .recordBYO: beginRecording(source: source, summaryMode: .byo)
            case .always: chooseAlways(source: source)
            case .skip: skipPrompt(source: source)
            }
            return true
        }
        if coordinator.stateMachine.isOffered(bundleID: source.bundleID),
           let held = coordinator.stateMachine.heldSource(bundleID: source.bundleID) {
            switch pick {
            case .record:
                recordAttached(to: held, summaryMode: .auto, trigger: "prompt_offer")
            case .recordBYO:
                recordAttached(to: held, summaryMode: .byo, trigger: "prompt_offer")
            case .always:
                coordinator.addAutoConsentApp(held.bundleID)
                Log.event(category: "coordinator", action: "user_consented_always", attributes: [
                    "bundle_id": held.bundleID,
                ])
                recordAttached(to: held, summaryMode: .auto, trigger: "prompt_offer")
            case .skip:
                // The offer becomes a skip, keeping the span it was already bound to.
                coordinator.stateMachine.armSkipLatch(
                    source: held,
                    liveness: coordinator.stateMachine.heldLiveness(bundleID: held.bundleID),
                    tabKey: coordinator.stateMachine.heldTabKey(bundleID: held.bundleID)
                )
                discardCarriedOverride(for: held, exit: "offer_skipped")
                noteSkipped(held)
            }
            return true
        }
        Log.event(category: "coordinator", action: "prompt_pick_refused", attributes: [
            "bundle_id": source.bundleID,
            "pick": pick.rawValue,
            "state": DetectionStateMachine.label(coordinator.stateMachine.current),
        ])
        return false
    }

    /// DET18 item 5: the pointer over the panel, or its chevron menu open, pauses the timer that
    /// acts. Driven by `MeetingPromptWindow` through its delegate.
    func setPromptTimeoutPaused(_ paused: Bool) {
        assertMainQueue()
        guard case .prompting = coordinator.stateMachine.current else { return }
        if paused {
            coordinator.stateMachine.pausePromptTimeout()
        } else {
            coordinator.stateMachine.resumePromptTimeout()
        }
    }

    /// DET18 item 2: one completed discovery scan's readings, fed before its winner is handled so a
    /// span that ended on this scan no longer holds that winner's prompt off.
    func handleScanReadings(_ readings: [String: SkippedMeetingLatch.Reading]) {
        assertMainQueue()
        noteHoldsEnded(coordinator.stateMachine.noteScanReadings(readings))
    }

    private func noteHoldsEnded(_ ended: [SkippedMeetingLatch.Entry]) {
        for entry in ended {
            Log.event(category: "coordinator", action: "prompt_hold_ended", attributes: [
                "bundle_id": entry.source.bundleID,
                "mode": entry.mode == .skipped ? "skipped" : "offered",
            ])
            if entry.mode == .offered {
                notePromptDismissed(entry.source, reason: .spanLapsed)
                discardCarriedOverride(for: entry.source, exit: "span_lapsed")
            }
        }
    }

    /// SEC40: an offer that ends without recording takes the pick it carried with it.
    private func discardCarriedOverride(for source: AppSource, exit: String) {
        guard let pick = offerWorkflowOverride, pick.source == source else { return }
        Log.event(category: "workflow", action: "override_discarded", attributes: [
            "bundle_id": pick.source.bundleID,
            "exit": exit,
        ])
        offerWorkflowOverride = nil
    }

    /// SEC40: a pick may ride the offer only if it is not a weaker privacy posture than the rule
    /// match for its source. The offer is keyed by app, so a back-to-back call that inherits the
    /// offer's hold would inherit the pick too; a stricter pick reaching it over-protects, a laxer
    /// one would downgrade a call the rule made NDA. A deleted workflow is not carried.
    private func pickIsNotWeakerThanRule(_ pick: (source: AppSource, workflowID: UUID)) -> Bool {
        let workflows = coordinator.workflowStore.workflows
        guard let picked = workflows.first(where: { $0.id == pick.workflowID }) else { return false }
        if picked.flags.ndaMode { return true }
        let matched = WorkflowMatcher.resolveWithReason(source: pick.source, workflows: workflows).workflow
        return !(matched?.flags.ndaMode ?? false)
    }

    private func isInPromptBackoff(_ bundleID: String, now: Date = Date()) -> Bool {
        guard let backoff = promptBackoff, backoff.bundleID == bundleID else { return false }
        if now < backoff.until { return true }
        promptBackoff = nil
        return false
    }

    // MARK: - Detection-to-record handlers (lifecycle verdict consumers)

    /// DET1: a sustained mic-busy dwell with no whitelist winner. Route the synthesized generic
    /// source through the same prompt path as a lifecycle `.starting`, so the skip-latch, reprompt
    /// cooldown, and auto-consent all apply (the quiet-register guardrail: one prompt per cooldown,
    /// never a popup storm). The lifecycle is deliberately NOT engaged: this tier is permission-
    /// light (no AX / Screen Recording), so a recording it starts ends via the idle-stop backstop.
    func handleMicInUseDwell(_ source: AppSource) {
        assertMainQueue()
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
        assertMainQueue()
        // DET18: a DET1 mic-tier hold (skip or offer) lives on this span.
        noteHoldsEnded(coordinator.stateMachine.noteMicBusy(bundleID: currentBusyBundle))
        guard let recBundle = micTierRecordingBundle, currentBusyBundle != recBundle,
              case .recording(let file, let src, let mode) = coordinator.stateMachine.current,
              src?.bundleID == recBundle else { return }
        Log.event(category: "coordinator", action: "mic_in_use_stop", attributes: ["bundle_id": recBundle])
        Log.writeLine("daemon", "mic-in-use recording stopped: mic released (\(recBundle))")
        stopRecording(file: file, source: src, summaryMode: mode, cause: .micRelease)
    }

    func handleMeetingStarted(source: AppSource) {
        assertMainQueue()
        // DET1: consume the one-shot mic-in-use flag now (so it never leaks to the next call), but
        // arm the per-prompt tag only once we COMMIT to showing/recording this prompt (after the
        // suppression guards below). Arming it here, before the guards, would let a DET1
        // `handleMeetingStarted` that early-returns while a whitelist prompt for the same bundle is
        // up leave a stale tag that mis-tags the later whitelist recording.
        let isMicTier = micTierPromptSource
        micTierPromptSource = false
        guard coordinator.stateMachine.isAcceptingPrompts else { return }
        // END20: an idle-origin start leaves the state `.idle` for its whole bring-up, so a
        // `.starting` landing then would raise a prompt for the meeting being started (or a
        // second one) that outlives the commit.
        guard !startLatch.isInFlight else { return }

        // END17 item 5: the same app's call is back inside the window after an end, so the end was
        // probably wrong. Resume without a prompt, under the workflow and mode the stopped
        // recording had, ahead of the cooldown and the skip latch that would otherwise hold it off.
        // Owner's decision (2026-11-16, DET17): a browser resume prompts. A browser sighting inside
        // the window is any admitted tab (a scheduled Meet, a doc page named "Meet: ..."), so it
        // gets the record prompt, and if ignored, DET18's span-bound offer; it never records
        // without a click. A native app's silent resume is untouched. The browser case also passes
        // the re-prompt cooldown below, which the end it resumes from armed: the owner asked for
        // a prompt here, not for silence.
        let browserResume = source.kind == .browser
            && resumeCandidate?.applies(to: source.bundleID, at: Date(), uptime: sessionUptime()) == true
        if browserResume {
            resumeCandidate = nil
            Log.event(category: "coordinator", action: "browser_resume_prompted", attributes: [
                "bundle_id": source.bundleID,
            ])
        }
        if source.kind != .browser, let candidate = resumeCandidate, candidate.applies(to: source.bundleID, at: Date(), uptime: sessionUptime()) {
            resumeCandidate = nil
            micTierPromptBundle = nil
            coordinator.stateMachine.clearSuppression(bundleID: source.bundleID)
            // SEC39: the resumed call runs the matcher. A rule match wins, the previous workflow
            // carries over otherwise, and never into a weaker privacy posture than the fallback.
            let workflows = coordinator.workflowStore.workflows
            let matched = WorkflowMatcher.resolveWithReason(source: source, workflows: workflows)
            let previous = candidate.workflowID.flatMap { id in workflows.first { $0.id == id } }
            let routing = WorkflowMatcher.resumeWorkflow(matched: matched.workflow, reason: matched.reason, previous: previous)
            clearPromptRouting(exit: "resume")
            pendingResumeWorkflow = routing.workflow.map { (source: source, workflowID: $0.id) }
            pendingResumedFrom = candidate.stem
            Log.event(category: "coordinator", action: "recording_resumed_after_end", attributes: [
                "bundle_id": source.bundleID,
                "resumed_from": candidate.stem,
                "since_end_sec": Date().timeIntervalSince(candidate.endedAt),
                "workflow_source": routing.source,
                "workflow_changed": routing.workflow?.id != candidate.workflowID,
            ])
            Log.writeLine("daemon", "\(source.bundleID) is back inside the resume window → resuming (\(candidate.stem))")
            beginRecording(source: source, summaryMode: candidate.summaryMode)
            return
        }

        // A meeting the user already dismissed stays dismissed for its whole lifetime:
        // the skip latch (refreshed by discovery in handleDiscovery) outlives the fixed
        // cooldown, so a `.starting` re-published mid-call can't re-open the prompt. Safety
        // net only - after a skip the lifecycle is disengaged, so this rarely fires - but it
        // closes the race where a `.starting` was queued just before disengage.
        if coordinator.stateMachine.isPromptHeld(bundleID: source.bundleID, tabKey: holdTabKey(for: source)) {
            return
        }
        // DET18 item 4: a prompt just withdrawn for this app is not re-raised inside its backoff.
        if isInPromptBackoff(source.bundleID) {
            return
        }

        // Honor the per-bundle reprompt cooldown here, not only in handleDiscovery:
        // after a skip/timeout we go to .idle immediately, so a lifecycle `.starting`
        // published from a signal queued just before disengage (or a fast re-scan)
        // must not re-prompt the meeting the user just skipped within its cooldown.
        if !browserResume, coordinator.stateMachine.isCoolingDown(
            bundleID: source.bundleID,
            cooldownSec: coordinator.liveRepromptCooldownSec
        ) {
            return
        }

        // Committed to this prompt: arm the DET1 tag (the bundle when mic-in-use-originated, else
        // clear any prior prompt's value so a whitelist prompt is never tagged). beginRecording
        // captures this synchronously before its async start.
        micTierPromptBundle = isMicTier ? source.bundleID : nil

        // Auto-consent: the allowlist, which since UX97 also holds every "Always for <app>" pick.
        // DET17 guard 1: a browser source carries no audio evidence today, so an auto-consented
        // browser prompts rather than recording without a click.
        if source.kind != .browser,
           coordinator.liveAutoConsentApps.contains(source.bundleID) {
            Log.writeLine("daemon", "auto-consent → recording (\(source.bundleID))")
            Log.event(category: "coordinator", action: "auto_consent", attributes: [
                "bundle_id": source.bundleID,
            ])
            beginRecording(source: source, summaryMode: .auto)
            return
        }

        presentPrompt(for: source)
    }

    /// Show the record prompt for `source`: the panel, its workflow chip and AI9's pre-selection,
    /// and the timeout. Shared by a detected meeting and END28's split, which reaches it past the
    /// guards above (the split's own stop armed the cooldown, and a split always asks, auto-consent
    /// included: the owner's decision of 2026-11-16).
    func presentPrompt(for source: AppSource) {
        assertMainQueue()
        // SEC39: a new prompt starts with no routing state of the last one's.
        clearPromptRouting(exit: "new_prompt")
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
        assertMainQueue()
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

        // END20: a start in flight owns the end, whatever the state machine reads. REC7 latched only
        // under `.prompting`, so an end during an idle-origin start (the resume, auto-consent, the
        // hotkey) fell to `default` and was dropped, and the start committed onto a dead meeting.
        // Only the start's own app's end is latched; a foreign one, or any end while a source-less
        // start comes up, is dropped rather than dismissing a prompt the start is answering.
        switch startLatch.noteEnd(bundleID: bundleID, reason: reason) {
        case .latched, .ignored:
            return
        case .notInFlight:
            break
        }

        switch coordinator.stateMachine.current {
        case .recording(let file, let src, let mode):
            // END11 item 4: an end belongs to the recording it names. A stale adapter for a
            // different app could otherwise stop this one. This changes *which* recording an end
            // applies to, never *whether* an end is honoured, which is the distinction the
            // paragraph below turns on.
            //
            // Only when this recording has a source of its own. A source-less recording has no
            // identity to compare against, and it is also the case with no AX end anchor at all,
            // so dropping the end there would remove the only automatic stop it can reach short
            // of the idle backstop. Honouring it stays the safer direction for that path.
            if let src = src, src.bundleID != bundleID {
                Log.event(category: "coordinator", action: "meeting_end_ignored_other_app", attributes: [
                    "ended_bundle_id": bundleID,
                    "recording_bundle_id": src.bundleID,
                    "leading_signal": reason.leadingSignal,
                ])
                return
            }
            // END19 item 3 (owner's decision, 2026-11-16): a source-less recording ignores an end
            // from an engage that began before it and never reached `.inMeeting` under it. That
            // engage was never this recording's: on 2026-11-11 a stale Chrome engage from 13 min
            // before a hand start reached `.starting` mid-recording and its unconfirmed tab-title
            // end stopped it at 876.9 s. This narrows END11 item 4 rather than reversing it: a
            // source-less recording with no engage at all, or whose engage it promoted, still
            // honours the end, since that is the only automatic stop it has short of the backstop.
            if src == nil, ignoresEndForSourcelessRecording() {
                Log.event(category: "coordinator", action: "meeting_end_ignored_sourceless", attributes: [
                    "ended_bundle_id": bundleID,
                    "leading_signal": reason.leadingSignal,
                    "engaged_before_recording": true,
                ])
                return
            }
            // Recording-stop honors every end the engine confirmed: since END17 a weak end only
            // reaches here after a dwell or a definitive signal, so what arrives is already the
            // late decision.
            //
            // END17 item 5: leave the way back open. A call of the same app sighted again inside
            // the window resumes into a new stem instead of meeting the cooldown.
            // END19 item 4: a source-less recording an end stopped resumes too, keyed to the app
            // that ended it, so the same call sighted again inside the window records (now with
            // its source) instead of meeting a prompt that times out into a skip.
            resumeCandidate = ResumeAfterEnd(
                bundleID: src?.bundleID ?? bundleID,
                stem: MeetingStore.stem(of: file),
                endedAt: Date(),
                endedUptime: sessionUptime(),
                workflowID: activeWorkflow?.id,
                summaryMode: mode
            )
            // DET14 amendment (D049): a definitive end leaves no call to re-attach to, so the stop
            // does not re-add the candidate DET14's clear above just dropped. A weak-signal end keeps
            // END13's retention: 20261022-150025 was a false end the owner rescued 22.9 s later by
            // pressing Record, and the retained candidate is what the restart attached to.
            stopRecording(
                file: file, source: src, summaryMode: mode, cause: .lifecycleEnd,
                retainCandidate: !reason.isDefinitive(forBundleID: src?.bundleID ?? bundleID)
            )
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
            // REC7's latch for a start in flight from here moved above the switch (END20).
            handleMeetingEndedDuringPrompt(bundleID: bundleID, reason: reason)
        default:
            break
        }
    }

    /// A lifecycle `.ended` arrived while the prompt was up (DET18 item 4).
    ///
    /// It used to withdraw the panel on every end, and in `.starting` the engine ends on any reliable
    /// weak end unless process audio vetoes it, which browsers never can. In era 1, 298 prompts were
    /// withdrawn by a lone `shareable_content_window_gone` and re-raised within 15 s, on screen for
    /// 15 to 30 ms each, and two Chrome prompts lasted 0.18 s and 0.84 s.
    ///
    /// Now only two ends withdraw it: a definitive one (the app quit), and a microphone release for
    /// an app whose microphone read is the call's span. Any other end keeps the panel up, marked
    /// "call may have ended", and leaves its timeout armed. No scan runs while prompting (PERF17)
    /// and the engine is terminal after `.ended` (END27), so the kept panel learns nothing new: its
    /// exits are the owner or the timeout, which collapses it into the span-bound offer, and that
    /// offer goes with the span. A Record from the kept panel re-engages the terminal engine
    /// (`engageLifecycleIfNeeded`, END27). A withdraw backs off for one idle poll so the very next
    /// discovery refresh does not re-raise it.
    func handleMeetingEndedDuringPrompt(bundleID: String, reason: EndingReason) {
        assertMainQueue()
        switch coordinator.stateMachine.current {
        case .prompting(let src) where src.bundleID == bundleID:
            let definitive = PrimarySignalKind(rawValue: reason.leadingSignal)?.isDefinitive == true
                || reason.confirmedBy.contains(PrimarySignalKind.workspaceAppTerminated.rawValue)
            let micReleased = DetectionStateMachine.spanLiveness(for: src) == .processAudio
                && coordinator.liveCallSignal == .callIsDown
            guard definitive || micReleased else {
                coordinator.prompt.markCallMayHaveEnded()
                Log.event(category: "coordinator", action: "prompt_kept_after_end", attributes: [
                    "bundle_id": src.bundleID,
                    "ended_bundle_id": bundleID,
                    "leading_signal": reason.leadingSignal,
                ])
                return
            }
            let backoffSec = DiscoveryScanCadence.discoveryDefault.idle
            notePromptDismissed(
                src,
                reason: definitive ? .withdrawnDefinitive : .withdrawnMicReleased,
                extra: ["leading_signal": reason.leadingSignal, "backoff_sec": backoffSec]
            )
            clearPromptRouting(exit: "ended")
            coordinator.stateMachine.cancelPromptTimeout()
            coordinator.prompt.dismiss()
            promptBackoff = (bundleID: src.bundleID, until: Date().addingTimeInterval(backoffSec))
            coordinator.stateMachine.setIdle()
            coordinator.statusUI.setIdle()
        case .prompting(let src):
            // Another app's end says nothing about this prompt's call.
            Log.event(category: "coordinator", action: "prompt_kept_after_end", attributes: [
                "bundle_id": src.bundleID,
                "ended_bundle_id": bundleID,
                "leading_signal": reason.leadingSignal,
            ])
        case .suppressed:
            coordinator.stateMachine.cancelPromptTimeout()
            coordinator.prompt.dismiss()
            coordinator.stateMachine.setIdle()
            coordinator.statusUI.setIdle()
        default:
            break
        }
    }

    // MARK: - Idle backstop (TECH-END3, was TECH-C2/C7)

    /// Mirror the system-audio level so the idle backstop's `.live(hasAudio:)` read
    /// stays current, and clock-feed the backstop off the ~1 Hz mic-level callback.
    /// The verdict stream is deduped (change-only), so after a call goes silent once
    /// the backstop would never be fed again and its nudge / auto-stop horizons
    /// could not fire on the forgotten-recording scenario they exist for (TECH-END7).
    /// `onMicLevel` fires throughout a recording (mic-only or not) on the main queue,
    /// the same context the verdict consumer feeds on, so re-ingesting the last
    /// verdict there advances the streak with no cross-queue race. It was left
    /// unconsumed when TECH-END3 dropped the RMS SilenceDetector.
    func armSystemLevelMirror() {
        assertMainQueue()
        coordinator.audioRecorder.onSystemLevel = { [weak self] db in
            self?.latestSystemLevelDb = db
        }
        coordinator.micHolderFeed.setRecording(true)
        coordinator.audioRecorder.onMicLevel = { [weak self] micDb in
            guard let self = self else { return }
            // DET23: the per-second levels the mic-holder monitor packs one row a minute; the
            // system level only once that channel has delivered (`.live` latches on the first
            // buffer, so a capture that stalls later still passes its last level).
            let live = self.coordinator.audioRecorder.systemChannelHealth == .live
            self.coordinator.micHolderFeed.noteLevels(micDb: micDb, systemDb: live ? self.latestSystemLevelDb : nil)
            self.noteHolderDevicesTick()
            guard let verdict = self.latestVerdict else { return }
            self.coordinator.silenceBackstop.ingest(verdict: verdict, systemChannel: self.backstopSystemChannel())
            self.syncStoppingSoon()
        }
    }

    /// What the backstop is told about the far side on this tick (REC17): the recorder's
    /// channel health decides whether the level mirror means anything. On main, like both
    /// ingest sites.
    private func backstopSystemChannel() -> IdleStopBackstop.SystemChannel {
        Self.backstopSystemChannel(
            health: coordinator.audioRecorder.systemChannelHealth,
            levelDb: latestSystemLevelDb
        )
    }

    /// Pure mapping from the recorder's channel health plus the ~1 Hz level mirror to the
    /// backstop's input. Lifted out so the three-way split is unit-testable without a
    /// recorder: a down channel is `.down` whatever the mirror last read (the mirror is fed
    /// by the system tap alone, so it simply stops moving when the channel does), a
    /// mic-only-by-permission recording is `.micOnly`, and only a live channel's level is
    /// compared against `systemSilenceThresholdDb`.
    static func backstopSystemChannel(
        health: MeetingRecorder.SystemChannelHealth,
        levelDb: Float
    ) -> IdleStopBackstop.SystemChannel {
        switch health {
        case .live:
            return .live(hasAudio: Double(levelDb) > systemSilenceThresholdDb)
        case .down:
            return .down
        case .micOnly:
            return .micOnly
        }
    }

    // MARK: - MIC22: which microphone the call uses

    /// MIC22 leg 1's seams: the device reads run off main (a HAL property read can wait on a busy
    /// `coreaudiod`), and a test runs them inline on fakes.
    struct InputHolderSeams {
        var captured: () -> InputDeviceIdentity? = { InputDeviceResolver.resolveDefaultInput() }
        /// One holder device's identities: itself, or an aggregate's active members.
        var holderIdentities: (AudioObjectID) -> [InputDeviceIdentity] = { InputDeviceResolver.holderIdentities(of: $0) }
        var run: (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) }
    }
    var inputHolderSeams = InputHolderSeams()
    /// How long after the recorder reconfigures the comparison waits, so the mic-holder monitor
    /// (1 Hz) has sampled the client's own switch before its devices are read.
    var inputHolderChangeSettleSec: TimeInterval = 2.0
    /// The client's held devices the last comparison saw, so the 1 Hz tick compares again only
    /// when the client switches. Main queue.
    private var lastComparedHolderDevices: [AudioObjectID]?
    /// The pending comparison after a recorder reconfigure: a flapping episode writes one row.
    private var pendingReconfigureCompare: DispatchWorkItem?

    /// The meeting client's held devices for `bundleID` in the monitor's latest snapshot, or nil
    /// when it does not read held (no devices to compare: unknown, not a mismatch).
    private func heldInputDevices(bundleID: String?) -> [AudioObjectID]? {
        let snapshot = coordinator.micHolderFeed.currentSnapshot()
        let reading = bundleID
            .flatMap { MicHolderMonitor.family(forBundleID: $0, in: Array(snapshot.readings.keys)) }
            .flatMap { snapshot.readings[$0] }
        return reading.flatMap { $0.level == .held ? $0.inputDevices : nil }
    }

    /// MIC22 leg 1, measure only: log the input devices the meeting client holds beside the one we
    /// capture (the system default). Called at a recording's start, when the client switches its
    /// device, and after the recorder reconfigures. Nothing is decided on it; leg 2 (capture the
    /// client's device) waits for a week of these rows.
    func compareInputDeviceHolder(trigger: String, source: AppSource?) {
        assertMainQueue()
        let bundleID = source?.bundleID
        let devices = heldInputDevices(bundleID: bundleID)
        lastComparedHolderDevices = devices
        let seams = inputHolderSeams
        seams.run {
            let captured = seams.captured()
            let holders = devices?.flatMap(seams.holderIdentities)
            Log.event(
                category: "recorder", action: "input_device_holder_compared",
                attributes: InputDeviceResolver.holderComparisonAttributes(
                    trigger: trigger, bundleID: bundleID, captured: captured, holders: holders
                )
            )
        }
    }

    /// The 1 Hz level tick: the client switched its microphone (its held devices changed to a
    /// non-empty set) without our engine reconfiguring, which is the walkthrough's case: the
    /// meeting app's mic changed and the system default did not. Also fires once when a client
    /// that held nothing at the start begins holding. Limits, accepted for a measurement: the tick
    /// rides the mic tap, so a stalled or abandoned tap writes none; and a switch the monitor
    /// samples mid-way (both devices held for a second) writes two rows.
    func noteHolderDevicesTick() {
        assertMainQueue()
        guard case .recording(_, let source?, _) = coordinator.stateMachine.current,
              let devices = heldInputDevices(bundleID: source.bundleID), !devices.isEmpty,
              devices != lastComparedHolderDevices else { return }
        compareInputDeviceHolder(trigger: "holder_change", source: source)
    }

    /// The recorder re-armed (or failed to re-arm) capture: an input change, or a tap-stall or wake
    /// recovery, which also reports through `onConfigurationChange`. Compared once the client's own
    /// switch has had a monitor tick to show, only if the same recording still runs, and once per
    /// burst: a newer report replaces a pending one.
    func noteInputDeviceChanged(recovered: Bool) {
        assertMainQueue()
        guard case .recording(let file, let source, _) = coordinator.stateMachine.current else { return }
        pendingReconfigureCompare?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReconfigureCompare = nil
            guard case .recording(let now, _, _) = self.coordinator.stateMachine.current, now == file else { return }
            self.compareInputDeviceHolder(
                trigger: recovered ? "recorder_reconfigured" : "recorder_reconfigure_failed", source: source
            )
        }
        pendingReconfigureCompare = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, inputHolderChangeSettleSec), execute: work)
    }

    // MARK: - MIC17: the live quiet-mic notice

    /// Asked every 30 s on main while recording; at most one HUD notice per recording.
    private var micQuietLive = MicQuietLiveCheck()
    private var micQuietShown = false
    private var cancelMicQuietTimer: (() -> Void)?
    /// Whether the 30 s check is running, so a test can pin that a real start arms it and a stop
    /// stands it down (END9's lesson: a component nobody starts passes every test of itself).
    var isMicQuietCheckArmed: Bool { cancelMicQuietTimer != nil }
    static let micQuietCheckIntervalSeconds: TimeInterval = 30

    /// Arm the 30 s check at the start of a recording. A common-mode run-loop timer (CONC10), so
    /// it keeps ticking under an open menu or alert.
    func armMicQuietCheck() {
        assertMainQueue()
        micQuietLive = MicQuietLiveCheck()
        micQuietShown = false
        cancelMicQuietTimer?()
        let interval = Self.micQuietCheckIntervalSeconds
        cancelMicQuietTimer = Schedulers.mainRunLoopRepeating(
            every: interval, firstFire: Date(timeIntervalSinceNow: interval), tolerance: 5
        ) { [weak self] in
            self?.checkMicQuiet()
        }
    }

    func disarmMicQuietCheck() {
        assertMainQueue()
        cancelMicQuietTimer?()
        cancelMicQuietTimer = nil
    }

    /// One tick: copy the recorder's running tally (under its per-buffer lock, never from the
    /// render thread) and raise the HUD notice the first time the quiet tier holds with the far
    /// side live. The stop-time tier uses the same bar (`MicCoverageWarning.isVeryQuiet`).
    func checkMicQuiet() {
        assertMainQueue()
        guard case .recording(let file, _, _) = coordinator.stateMachine.current else { return }
        let recorder = coordinator.audioRecorder
        let coverage = recorder.liveMicCoverage
        // Once the owner is audible again (they raised the input level, or simply spoke up), the
        // notice has done its job; take it down rather than leave a stale warning outranking
        // "Off the record" for the rest of the call. It does not come back in this recording.
        if micQuietShown, !MicCoverageWarning.isVeryQuiet(
            unmutedSeconds: coverage.unmutedSeconds, loudUnmutedSeconds: coverage.loudUnmutedSeconds
        ) {
            micQuietShown = false
            coordinator.hud.setMicVeryQuiet(false, device: nil)
            return
        }
        guard micQuietLive.shouldNotify(coverage: coverage, systemLive: recorder.systemChannelHealth == .live) else {
            return
        }
        let device = recorder.liveInputDevice?.displayName
        micQuietShown = true
        coordinator.hud.setMicVeryQuiet(true, device: device)
        Log.event(
            category: "recorder", action: "mic_very_quiet",
            attributes: Self.micVeryQuietAttributes(
                phase: "live", file: file.lastPathComponent, coverage: coverage, device: device
            )
        )
    }

    /// `mic_recorded_nothing`'s attributes plus the loud-seconds count and the phase.
    static func micVeryQuietAttributes(
        phase: String, file: String, coverage: MicCoverageSnapshot, device: String?
    ) -> [String: Any] {
        [
            "phase": phase,
            "file": file,
            "recording_seconds": coverage.recordingSeconds,
            "unmuted_seconds": coverage.unmutedSeconds,
            "peak_unmuted_db": Double(coverage.peakUnmutedRmsDb),
            "loud_seconds": coverage.loudUnmutedSeconds,
            "device": device ?? "(unknown)",
        ]
    }

    func disarmSystemLevelMirror() {
        assertMainQueue()
        coordinator.audioRecorder.onSystemLevel = nil
        coordinator.audioRecorder.onMicLevel = nil
        coordinator.micHolderFeed.setRecording(false)
    }

    func handleIdleNotify() {
        assertMainQueue()
        Log.writeLine("daemon", "idle: surfacing 'still meeting?' banner")
        Log.event(category: "coordinator", action: "silence_notified")
        coordinator.notifications.notifyStillMeeting()
        // UX92: the HUD says it too; a banner alone is lost under Focus or with notifications off.
        setStoppingSoon(true)
    }

    /// UX92: whether the HUD currently says "No audio, stopping soon".
    private var stoppingSoonShown = false

    private func setStoppingSoon(_ on: Bool) {
        guard on != stoppingSoonShown else { return }
        stoppingSoonShown = on
        coordinator.hud.setStoppingSoon(on)
    }

    /// UX92: after a backstop sample, clear the HUD state once audio has reset the nudge.
    private func syncStoppingSoon() {
        if stoppingSoonShown, !coordinator.silenceBackstop.didNotify { setStoppingSoon(false) }
    }

    /// REC20 item 2: one low-space update from the recorder's free-space watch, on main. The label
    /// and the warning only ever touch a live recording's HUD; the stop goes through `forceStop`,
    /// which is `stopRecording`, the path a user's Stop takes, so the merge runs. It is never
    /// `onWriteFailure`: nothing has failed, and the point of stopping here is that the merge
    /// still has room.
    func handleLowSpace(_ update: RecordingLowSpace.Update) {
        assertMainQueue()
        guard case .recording = coordinator.stateMachine.current else { return }
        switch update {
        case .label(let text):
            coordinator.hud.setLowSpace(text)
        case .warn(let hudText, let title, let body):
            coordinator.hud.setLowSpace(hudText)
            coordinator.notifications.notifyLowSpace(title: title, body: body)
        case .stop(let message):
            coordinator.notifications.notifyError(message, operation: .recording, title: "Recording stopped early")
            forceStop(reason: "low_space")
        }
    }

    /// REC22 (F155): a capture writer is over 30 s behind. HUD only: the owner learns the volume
    /// is not keeping up while there is still time to act, and the hard cap's force-stop posts its
    /// own banner if it comes to that.
    func handleWriterBacklog() {
        assertMainQueue()
        guard case .recording = coordinator.stateMachine.current else { return }
        coordinator.hud.setWriterBehind(true)
    }

    func handleIdleAutoStop() {
        assertMainQueue()
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
        stopRecording(file: file, source: src, summaryMode: mode, cause: .idleBackstop)
    }

    /// User tapped "Keep recording" on the idle nudge: restart the countdown so the
    /// recording is not auto-stopped. (TECH-END3)
    func keepRecordingFromNudge() {
        assertMainQueue()
        guard case .recording = coordinator.stateMachine.current else { return }
        Log.event(category: "coordinator", action: "silence_keep_recording")
        coordinator.silenceBackstop.keepAlive()
        setStoppingSoon(false)
    }

    // MARK: - MicGate engage (TECH-G-MIC + TECH-C13)

    /// Prime the silence backstop for a fresh recording. Every recording, source or not, at the
    /// moment it starts; split from the MicGate engage by PERF15 because that now waits on a build.
    func resetMicGateBackstop() {
        assertMainQueue()
        coordinator.silenceBackstop.reset()
        // UX92: a fresh recording starts without the previous one's nudge (the HUD resets its own
        // state at dismiss; this keeps the controller's mirror in step).
        stoppingSoonShown = false
        latestSystemLevelDb = -120
        latestVerdict = nil
    }

    /// Engage MicGate on prebuilt AX handles. Manual / browser-no-AX sources fall through to HAL
    /// VAD + RMS only (empty handles). `via` says whether the record-start build supplied them or
    /// its deadline passed first (PERF15), which `micgate_attached` carries so the field log shows
    /// how often a slow client costs the AX mute read at the start of a recording.
    func engageMicGate(source: AppSource, handles: MeetingAXHandleBuilder.Handles?, via: String) {
        assertMainQueue()
        guard coordinator.liveHonorAppMute else { return }
        guard let handles = handles else {
            Log.event(category: "coordinator", action: "micgate_engage_skipped", attributes: [
                "bundle_id": source.bundleID,
                "reason": "no_pid",
            ])
            return
        }
        Log.event(category: "coordinator", action: "micgate_attached", attributes: [
            "bundle_id": source.bundleID,
            "via": via,
            "mute_button": handles.micGate.muteButton != nil,
        ])
        do {
            if let startMicGate = engageSeams.startMicGate {
                try startMicGate(handles.context, handles.micGate)
            } else {
                try coordinator.micGate.start(context: handles.context, handle: handles.micGate)
            }
        } catch {
            Log.event(category: "coordinator", action: "micgate_start_failed", attributes: [
                "bundle_id": source.bundleID,
                "error": error.localizedDescription,
            ])
        }
        // MIC20: `MicGate.start` begins with a `stop`, which clears the held flag, so a gate that
        // engages while a hold is already open (a build landing after a weak end) hears it again.
        if holdPolicy.isOpen { coordinator.micGate.setEndHeld(true) }

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
        assertMainQueue()
        guard coordinator.stateMachine.isAcceptingPrompts else { return }
        // END19: every winner is a sighting of its bundle, whichever branch below handles it.
        staleEngage.sighted(bundleID: source.bundleID, at: Date())
        if source.kind == .browser, let tabKey = source.tabKey { lastBrowserTabKey[source.bundleID] = tabKey }

        // A held prompt (an explicit skip, or the offer a timeout left behind) stays out. DET18 bound
        // the hold to the call's span, which `handleScanReadings` feeds from this same scan before
        // this runs. A confident sighting used to refresh it and lapse it 60 s after the last one,
        // which was both too long (a second call in the same app inherited it: no prompt for 25.6
        // minutes on 2026-10-21) and too short (it lapsed mid-call, D016 and D067). We do NOT
        // re-engage the lifecycle, so there's no Leave-button poll to leak.
        if coordinator.stateMachine.isPromptHeld(bundleID: source.bundleID, tabKey: source.tabKey) {
            // DET7: this sighting is also proof of *what* is running, and it is the only
            // live handle on it once the prompt is gone. Keep it so a manual start (menu
            // row, hotkey, `meetingpipe://record`) can attach to the meeting the user
            // skipped instead of recording `source: nil`, which resolves the default
            // workflow, writes no source into the sidecar, and arms no AX end detection.
            coordinator.stateMachine.noteSuppressedCandidate(source, origin: .skipLatch)
            return
        }

        // DET18 item 4: a prompt withdrawn while the call was still on screen backs off one poll.
        if isInPromptBackoff(source.bundleID) {
            return
        }

        // END17 item 5: inside the resume window the cooldown does not apply to the app whose
        // recording just ended. Engaging the lifecycle is what lets its `.starting` reach
        // `handleMeetingStarted`, which resumes.
        if let candidate = resumeCandidate, candidate.applies(to: source.bundleID, at: Date(), uptime: sessionUptime()) {
            engageLifecycle(for: source)
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

    /// Engage the lifecycle adapter so it fuses PRIMARY signals into the verdict stream.
    ///
    /// PERF15: the AX build runs on `axWalkQueue` (about half a second of main per scan for a
    /// healthy Teams before, and unbounded against a hung one) and the engage hops back to main,
    /// but only if nothing has moved on meanwhile: the state still accepts prompts and no newer
    /// build was requested (another bundle's, or this one's after `disengageLifecycle`). A build
    /// already in flight for this bundle absorbs the request, so a 3 s poll cannot stack walks.
    ///
    /// A repeat engage of a bundle already engaged is NOT skipped, deliberately, and
    /// `test_aRepeatDiscoveryOfAnEngagedBundleStillReEngages` pins it. `engage` resets the engine,
    /// but this path only runs while `.idle`, where the engine has reached nothing worth keeping
    /// (any live signal would have raised `.starting` and left `.idle`), and the re-engage is what
    /// re-reads a relaunched app's pid and re-runs a build that may now see the Leave button.
    func engageLifecycle(for source: AppSource) {
        assertMainQueue()
        if let inFlight = lifecycleBuild, inFlight.bundleID == source.bundleID { return }
        lifecycleBuildGeneration += 1
        let generation = lifecycleBuildGeneration
        lifecycleBuild = (bundleID: source.bundleID, generation: generation)
        buildHandlesOffMain(for: source) { [weak self] handles in
            guard let self = self else { return }
            guard self.lifecycleBuild?.generation == generation else {
                Log.event(category: "coordinator", action: "lifecycle_engage_skipped", attributes: [
                    "bundle_id": source.bundleID,
                    "reason": "superseded_build",
                ])
                return
            }
            self.lifecycleBuild = nil
            guard self.coordinator.stateMachine.isAcceptingPrompts else {
                Log.event(category: "coordinator", action: "lifecycle_engage_skipped", attributes: [
                    "bundle_id": source.bundleID,
                    "reason": "state_changed",
                    "state": DetectionStateMachine.label(self.coordinator.stateMachine.current),
                ])
                return
            }
            self.engageLifecycle(source: source, handles: handles)
        }
    }

    /// Run the static AX build for `source` on `axWalkQueue` and hand the result back on main.
    /// The seam is read here, on main, so only the build itself crosses queues.
    private func buildHandlesOffMain(
        for source: AppSource,
        then land: @escaping (MeetingAXHandleBuilder.Handles?) -> Void
    ) {
        let build = engageSeams.buildHandles
        let catalogue = coordinator.muteLabels
        Self.axWalkQueue.async {
            let handles = build(source, catalogue)
            DispatchQueue.main.async { land(handles) }
        }
    }

    /// Engage on handles already built. Main only; never walks.
    private func engageLifecycle(source: AppSource, handles: MeetingAXHandleBuilder.Handles?) {
        guard let handles = handles else {
            Log.event(category: "coordinator", action: "lifecycle_engage_skipped", attributes: [
                "bundle_id": source.bundleID,
                "reason": "no_pid",
            ])
            return
        }
        do {
            try coordinator.lifecycleCoord.engage(context: handles.context, handle: handles.lifecycle)
            lifecycleEngagedAt = Date()
        } catch {
            Log.event(category: "coordinator", action: "lifecycle_engage_failed", attributes: [
                "bundle_id": source.bundleID,
                "error": error.localizedDescription,
            ])
        }
    }

    /// END11: engage the lifecycle for an explicit start that carries a source.
    ///
    /// The only caller of `engageLifecycle` is `handleDiscovery`, and both its skip-latch and
    /// `isCoolingDown` branches `return` before reaching it. So a recording started by hand had a
    /// resolved Leave button and no adapter to give it to: `armLeaveButton` dropped the element,
    /// nothing published `lifecycle`/`in_meeting`, and the recording could not end on its own.
    /// DET13 made the *element* reachable by retaining the cooldown-suppressed sighting; this is
    /// the neighbouring half that was assumed to follow from it and did not.
    ///
    /// The `isEngaged` guard is what makes this idempotent against a discovery already engaged,
    /// and it is not an optimisation: `MeetingLifecycleCoordinator.engage` opens with
    /// `disengage()`, so an unguarded call would stop a healthy adapter and reset the engine to
    /// `.idle` in the middle of a live meeting.
    ///
    /// PERF15: takes the record start's one build rather than walking again, and runs when that
    /// build lands, so it is no longer synchronous with the start.
    ///
    /// END27: "engaged" is not "working". An engine that has published `.ended` ignores every
    /// later signal, so a recording that keeps it has no end detection at all; on 2026-11-12 the
    /// resume `20261112-174606` started on one (a first-reading window-gone had ended it 63 ms
    /// before the recording committed) and ran 380 s past the leave. A terminal engine is
    /// re-engaged on the start's own handles instead, and the guard keeps protecting every live one.
    func engageLifecycleIfNeeded(source: AppSource?, handles: MeetingAXHandleBuilder.Handles?) {
        assertMainQueue()
        guard let source = source else { return }
        // END19 amendment (2026-11-17): engaged is not engaged for this recording. A discovery
        // engage of another app (a named Meet tab winning a scan while a Teams call sat on offer)
        // used to be kept as `already_engaged`, so the Teams recording ran on Chrome's engine: no
        // Teams end detection, every Chrome end ignored as another app's, and a Chrome hold's cut
        // left armed for the Teams stop. Tear it down and engage this source; with no handles
        // there is no engine at all, which is still better than another app's. Ahead of END27's
        // terminal branch, so another app's terminal engine is torn down too, never kept.
        if let engaged = coordinator.lifecycleCoord.engagedBundleID, engaged != source.bundleID {
            Log.event(category: "coordinator", action: "lifecycle_reengaged", attributes: [
                "bundle_id": source.bundleID,
                "reason": "other_app_at_start",
                "engaged_bundle_id": engaged,
                "has_handles": handles != nil,
            ])
            disengageLifecycle()
            engageLifecycle(source: source, handles: handles)
            return
        }
        if coordinator.lifecycleCoord.isTerminal {
            Log.event(category: "coordinator", action: "lifecycle_reengaged", attributes: [
                "bundle_id": source.bundleID,
                "reason": "terminal_at_start",
                // With no handles the engage below logs `no_pid` and the terminal engine stays;
                // this says which of the two the row was.
                "has_handles": handles != nil,
            ])
            engageLifecycle(source: source, handles: handles)
            if handles == nil {
                noteRecordingOnTerminalEngine(bundleID: source.bundleID, recordingBundleID: source.bundleID, reason: "no_handles")
            }
            return
        }
        guard !coordinator.lifecycleCoord.isEngaged else {
            Log.event(category: "coordinator", action: "lifecycle_engage_skipped", attributes: [
                "bundle_id": source.bundleID,
                "reason": "already_engaged",
            ])
            return
        }
        Log.event(category: "coordinator", action: "lifecycle_engage_explicit_start", attributes: [
            "bundle_id": source.bundleID,
        ])
        engageLifecycle(source: source, handles: handles)
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
    /// PERF15: arms from the record start's one build, walked off main and landed here on main.
    /// It used to run a build of its own on `axWalkQueue`, mute walks included and discarded.
    /// This is end-detection only, so arming a beat later (the call just started) is harmless.
    func armLifecycleLeaveButton(source: AppSource?, handles: MeetingAXHandleBuilder.Handles?) {
        assertMainQueue()
        guard source != nil, let leaveButton = handles?.lifecycle.leaveButton else { return }
        coordinator.lifecycleCoord.armLeaveButton(leaveButton)
    }

    // MARK: - PERF15: the record start's one build

    /// Dispatch the record start's build and return its id. Called when `beginRecording` commits,
    /// before the engine bring-up, so the walk overlaps it.
    private func beginRecordStartBuild(for source: AppSource) -> Int {
        recordStartBuildID += 1
        let id = recordStartBuildID
        recordStartBuilt = nil
        recordStartAttach = nil
        buildHandlesOffMain(for: source) { [weak self] handles in
            self?.recordStartBuildLanded(id: id, handles: handles)
        }
        return id
    }

    /// Drop whatever the record start's build would still do: the start failed, or the recording
    /// stopped before the build or its deadline came back.
    private func cancelRecordStartBuild() {
        recordStartBuildID += 1
        recordStartBuilt = nil
        recordStartAttach = nil
    }

    private func recordStartBuildLanded(id: Int, handles: MeetingAXHandleBuilder.Handles?) {
        guard id == recordStartBuildID else { return }
        guard let attach = recordStartAttach else {
            // The recorder is still coming up; `attachWhenBuilt` picks this up when it is.
            recordStartBuilt = (id: id, handles: handles)
            return
        }
        recordStartAttach = nil
        attachRecordStart(attach, handles: handles)
    }

    /// The recorder is up: attach now if the build already landed, else wait for it, with
    /// `recordStartBuildDeadlineSec` bounding how long MicGate goes without engaging.
    private func attachWhenBuilt(id: Int, source: AppSource, file: URL) {
        guard id == recordStartBuildID else { return }
        let attach = RecordStartAttach(id: id, source: source, file: file, micGateEngaged: false)
        if let built = recordStartBuilt, built.id == id {
            recordStartBuilt = nil
            attachRecordStart(attach, handles: built.handles)
            return
        }
        recordStartAttach = attach
        DispatchQueue.main.asyncAfter(deadline: .now() + recordStartBuildDeadlineSec) { [weak self] in
            self?.recordStartBuildDeadlinePassed(id: id)
        }
    }

    /// The build is late. Engage MicGate without it (the no-mute-button path, HAL VAD plus RMS)
    /// rather than keep the start of the recording on `not_started`; the window watcher supplies
    /// the AX reading through `injectAxMuteEvent` once it can walk. The lifecycle engage and the
    /// Leave arm still wait for the build, since they are end detection and lose nothing by it.
    private func recordStartBuildDeadlinePassed(id: Int) {
        guard var attach = recordStartAttach, attach.id == id, !attach.micGateEngaged else { return }
        attach.micGateEngaged = true
        recordStartAttach = attach
        let handles = engageSeams.resolveContext(attach.source).map {
            MeetingAXHandleBuilder.Handles(
                lifecycle: LifecycleAdapterHandle(),
                micGate: MicGateAdapterHandle(),
                context: $0
            )
        }
        engageMicGate(source: attach.source, handles: handles, via: "deadline")
    }

    private func attachRecordStart(_ attach: RecordStartAttach, handles: MeetingAXHandleBuilder.Handles?) {
        // `stopRecording` cancels the build, so this is a backstop: the recording it was built for
        // has to be the one still running.
        guard case .recording(let file, _, _) = coordinator.stateMachine.current, file == attach.file else { return }
        if !attach.micGateEngaged {
            engageMicGate(source: attach.source, handles: handles, via: "build")
        }
        // END11: engage BEFORE the arm below, or there is no adapter to arm onto. This is the one
        // place every explicit start converges (DET7 lifted the sequence into `beginRecording` for
        // exactly that reason), so the menu row, the hotkey, `meetingpipe://record` and
        // `didRequestStartLate` cannot drift apart.
        engageLifecycleIfNeeded(source: attach.source, handles: handles)
        // Arm on the Leave button this build saw now the call UI has rendered; the discovery-time
        // walk usually runs too early to see it.
        armLifecycleLeaveButton(source: attach.source, handles: handles)
    }

    /// PERF15: an explicit start's lifecycle engages once its build lands, after `beginRecording`'s
    /// `confirmRecording`, and its signals now start off main, so the engine reaches `.starting`
    /// with the recorder already running and nothing left to promote it. A `.starting` for the
    /// app being recorded is that case and only that case (discovery never engages while recording,
    /// and a revert from a held end returns to `.inMeeting`, not `.starting`), so confirm it here.
    /// Returns whether it did, which also means there is no prompt to raise.
    func confirmLateStartIfRecording(_ context: MeetingLifecycleContext) -> Bool {
        assertMainQueue()
        guard case .recording(_, let source?, _) = coordinator.stateMachine.current,
              source.bundleID == context.bundleID else { return false }
        Log.event(category: "coordinator", action: "lifecycle_late_start_confirmed", attributes: [
            "bundle_id": context.bundleID,
        ])
        coordinator.lifecycleCoord.confirmRecording()
        return true
    }

    /// Rescue a provisional end caused by the Teams 2 compact-view swap,
    /// which destroys the Leave button while the call continues. If a Leave
    /// button still exists (moved to the compact panel), hand it to the signal's rescue entry
    /// (`rescueLeaveButton`), which re-asserts an armed healthy button as a fresh live reading or
    /// re-arms on the new one, so the healthy baseline reaches the engine and reverts the hold to
    /// `.inMeeting` (END8). Until END18 this went through the late-arm, a no-op on an armed healthy
    /// button, so the revert never fired (F002). A genuine end finds none and the hold carries on.
    func rescueProvisionalEnd(context: MeetingLifecycleContext) {
        assertMainQueue()
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
                    // END9: an empty walk is NOT corroboration. It runs ~120 ms after
                    // `AXLeaveButtonSignal` did its own re-walk, and Teams' accessibility tree goes
                    // blank in-process for 1 to 65 s at a time while every window stays on screen,
                    // so both walks land inside one blackout. 18 recordings were chopped by reading
                    // that as an end, the worst losing 9 m 53 s. The hold already open decides.
                    return
                }
                Log.event(category: "coordinator", action: "lifecycle_provisional_end_rescued", attributes: [
                    "bundle_id": context.bundleID,
                    "leave_buttons_found": leaveButtons.count,
                ])
                // END18: the rescue entry, not the late-arm. `armLeaveButton` is a no-op on an
                // armed healthy button, so END8's revert never reached the engine (F002).
                self.coordinator.lifecycleCoord.rescueLeaveButton(leaveButton)
            }
        }
    }

    // MARK: - END9 / END17: the hold

    /// Open a hold and consult Teams' teardown line immediately, then once a second until something
    /// resolves it. A weak end is held with the recorder running (END17), waiting on a definitive
    /// signal, a dwell in the engine, or the call coming back. What the hold decides (its stamp,
    /// re-entry, the consult, the trim point) is `TeardownHoldPolicy`'s (T8); this side owns the
    /// clock, the timer, the watcher read, the log rows and the HUD.
    ///
    /// The immediate consult was meant to keep a genuine Teams end free: the teardown line led the
    /// AX edge (p50 about 1.3 s) when measured in 2026-08, so the first consult would confirm with
    /// no added latency. The field did not bear that out (END16: 0 of 59 Teams ends from 2026-09-29
    /// to 2026-11-13 were confirmed by the line; they ended on the pair dwell, 60 s after the mic
    /// release), and the `lifecycle_teardown_consult` rows are there to say why. The timer exists
    /// for a teardown that lands a moment late. It no longer bounds anything: since END17 the hold ends on the engine's
    /// dwells (`PromotionEngine.tick`), and this side only ever confirms on evidence.
    ///
    /// Re-entrant by design. A second provisional for the same call keeps the first stamp, because
    /// the stamp is where the held tail starts and a flapping signal must not move it.
    func beginTeardownHold(context: MeetingLifecycleContext) {
        assertMainQueue()
        guard holdPolicy.open(context: context, at: Date()) else {
            consultTeardownOracle()
            return
        }
        consultLedger = TeardownConsultLedger()
        consultTeardownOracle()
        // A confirm on the first consult already concluded it, and a genuine end that does never
        // reaches the lines below and looks exactly as it looked before END9, timer and HUD
        // included. That was meant to be the common Teams case; in the field it is rare (END16).
        guard holdPolicy.isOpen else { return }
        cancelHoldTimer = Schedulers.mainRunLoopRepeating(1.0) { [weak self] in
            self?.consultTeardownOracle()
        }
        let snapshot = coordinator.callTeardown.snapshot()
        var held: [String: Any] = [
            "bundle_id": context.bundleID,
            "kind": context.kind.rawValue,
            "confirm_dwell_sec": PromotionEngine.defaultConfirmDwell,
            "lone_dwell_sec": PromotionEngine.defaultLoneDwell,
            "oracle_available": snapshot.available,
            // END13: what the cross-class signal said when the hold opened, so a hold that later
            // runs long can be read back without correlating two logs.
            "live_signal": coordinator.liveCallSignal.rawValue,
        ]
        // END16: whether this hold asks Teams' line at all, and, for one that does, what the oracle
        // was looking at when it opened: END12's `log_written_sec_ago` (the oracle does not decide
        // on it; a quiet log and a dead one look the same for the length of a call), the tail and
        // the newest teardown's age. A hold that does not consult carries none of Teams' log.
        let consults = TeardownHoldPolicy.consultsTeardown(for: context)
        held["consults_teardown"] = consults
        if consults {
            held.merge(teardownTailAttributes(snapshot, now: Date())) { _, new in new }
        }
        Log.event(category: "coordinator", action: "lifecycle_end_held", attributes: held)
        Log.verbose("daemon", "end hold opened for \(context.bundleID) (consults teardown: \(consults))")
        // MIC20: the call UI is usually gone during a hold, so the AX mute probe backs off rather
        // than log an unreadable button once a second until the recording stops.
        coordinator.micGate.setEndHeld(true)
        Log.writeLine(
            "daemon",
            "holding a weak end for \(context.bundleID) and still recording: nothing definitive says the call is over (END17)"
        )
        // The recording is still running and the HUD would otherwise look like nothing happened.
        // Shown here rather than before the first consult so an end that confirms immediately
        // never flickers it.
        coordinator.hud.setConfirmingEnd(true)
    }

    /// One consult. Confirms on Teams' teardown for this recording, or leaves the hold open.
    ///
    /// `now` is a parameter so a test can drive the hold without sleeping through it; production
    /// always takes the default. An unreadable log is "no evidence" since END17, never a confirm.
    func consultTeardownOracle(now: Date = Date()) {
        assertMainQueue()
        guard let hold = holdPolicy.hold else { return }
        // END16 (G053): only a Teams hold asks Teams' line, so nothing else consults it.
        guard TeardownHoldPolicy.consultsTeardown(for: hold.context) else { return }
        let snapshot = coordinator.callTeardown.snapshot()
        if let edge = consultLedger.note(available: snapshot.available, newestTeardownAt: snapshot.lastTeardownAt) {
            var row: [String: Any] = [
                "bundle_id": hold.context.bundleID,
                "edge": edge.rawValue,
                "available": snapshot.available,
                "held_sec": now.timeIntervalSince(hold.startedAt),
                "consults": consultLedger.consults,
                "blind_consults": consultLedger.blindConsults,
            ]
            row.merge(teardownTailAttributes(snapshot, now: now, holdStartedAt: hold.startedAt)) { _, new in new }
            Log.event(category: "coordinator", action: "lifecycle_teardown_consult", attributes: row)
        }
        let verdict = holdPolicy.consult(
            now: now,
            lastTeardownAt: snapshot.available ? snapshot.lastTeardownAt : nil,
            recordingStartedAt: coordinator.audioRecorder.startedAt
        )
        guard case .confirm(let reason)? = verdict else { return }
        concludeTeardownHold(now: now, conclusion: .teardown)
        Log.verbose("daemon", "end hold confirmed by \(reason.rawValue) after \(Int(now.timeIntervalSince(hold.startedAt))) s")
        Log.event(category: "coordinator", action: "lifecycle_provisional_end_confirmed", attributes: [
            "bundle_id": hold.context.bundleID,
            "oracle": reason.rawValue,
            "held_sec": now.timeIntervalSince(hold.startedAt),
            "trimmed": pendingEndTrimAt != nil,
            "live_signal": coordinator.liveCallSignal.rawValue,
        ])
        coordinator.lifecycleCoord.confirmProvisionalEnd(evidence: PromotionEngine.teardownEvidence)
    }

    /// END16: how a hold resolved, for the `resolved` consult row.
    private static func resolutionLabel(_ conclusion: TeardownHoldPolicy.Conclusion) -> String {
        switch conclusion {
        case .engineEnd: return "engine_end"
        case .loneDwell: return "lone_dwell"
        case .teardown: return "teardown"
        case .stop: return "stop"
        }
    }

    /// END16: the watcher's view of Teams' log, for the hold rows. Times as ages, never raw stamps,
    /// like the rest of the hold's rows; `teardown_after_hold_start_sec` is negative for a teardown
    /// older than the hold.
    private func teardownTailAttributes(
        _ snapshot: CallTeardownWatcher.Snapshot, now: Date, holdStartedAt: Date? = nil
    ) -> [String: Any] {
        var attributes: [String: Any] = ["tail_offset": snapshot.tailOffset]
        if let size = snapshot.tailFileSize { attributes["tail_file_size"] = size }
        if let written = snapshot.logLastWrittenAt { attributes["log_written_sec_ago"] = now.timeIntervalSince(written) }
        if let teardown = snapshot.lastTeardownAt {
            attributes["teardown_age_sec"] = now.timeIntervalSince(teardown)
            if let holdStartedAt { attributes["teardown_after_hold_start_sec"] = teardown.timeIntervalSince(holdStartedAt) }
        }
        return attributes
    }

    /// The hold ended in an end, by whichever route. Its trim point becomes the cut `stopRecording`
    /// acts on: cut at stop under the regulated and NDA postures, suggested and kept everywhere else
    /// (END17). `TeardownHoldPolicy.trimPoint` leaves sub-second holds (a first-consult teardown
    /// confirm, meant to be the normal Teams path and rare in the field, END16) alone.
    func concludeTeardownHold(now: Date = Date(), conclusion: TeardownHoldPolicy.Conclusion) {
        assertMainQueue()
        guard holdPolicy.isOpen else { return }
        if let trimAt = holdPolicy.trimPoint(
            concludingAt: now,
            evidence: coordinator.lifecycleCoord.holdEvidence,
            conclusion: conclusion
        ) {
            pendingEndTrimAt = trimAt
        }
        releaseTeardownHold(conclusion: conclusion)
    }

    /// Drop the hold without concluding it. Called when the call comes back (the whole point) and
    /// on every path that leaves `.endingProvisional`, so a stale timer can never outlive its meeting.
    func releaseTeardownHold(rescued: Bool = false, conclusion: TeardownHoldPolicy.Conclusion? = nil) {
        assertMainQueue()
        guard let hold = holdPolicy.release() else { return }
        // END16: one row with the hold's consult counts, however it resolved, and how. A hold that
        // never consulted (not Teams) writes none.
        if consultLedger.consults > 0 {
            Log.event(category: "coordinator", action: "lifecycle_teardown_consult", attributes: [
                "bundle_id": hold.context.bundleID,
                "edge": "resolved",
                "held_sec": Date().timeIntervalSince(hold.startedAt),
                "consults": consultLedger.consults,
                "blind_consults": consultLedger.blindConsults,
                "resolution": conclusion.map(Self.resolutionLabel) ?? (rescued ? "reverted" : "released"),
            ])
        }
        consultLedger = TeardownConsultLedger()
        // MIC20: every way out of a hold, rescued or concluded, lets the probe read at full rate.
        coordinator.micGate.setEndHeld(false)
        // `cancelHoldTimer != nil` is the record of whether the holding state was ever shown. Without it,
        // an end that confirmed on its first consult would still push a `setConfirmingEnd(false)` at
        // a HUD that was never told true, which is a state change the surface has to handle for no
        // reason and which a test reads as the holding state having been entered.
        let wasShown = cancelHoldTimer != nil
        cancelHoldTimer?()
        cancelHoldTimer = nil
        if wasShown { coordinator.hud.setConfirmingEnd(false) }
        if rescued {
            Log.event(category: "coordinator", action: "lifecycle_end_hold_released", attributes: [
                "bundle_id": hold.context.bundleID,
                "held_sec": Date().timeIntervalSince(hold.startedAt),
            ])
            Log.writeLine(
                "daemon",
                "the call came back while its end was held - the recording was never stopped (END17)"
            )
        }
    }

    /// Tear down the lifecycle adapter + reset the engine. Wired to the
    /// state machine's idle transition so every idle path disengages once.
    /// END19 item 3: whether an end reaching the running source-less recording comes from an engage
    /// that predates it and never reached `.inMeeting` for it. False when nothing was engaged, or
    /// the commit time is unknown (a state set by hand), so those keep today's behaviour.
    private func ignoresEndForSourcelessRecording() -> Bool {
        guard let engagedAt = lifecycleEngagedAt, let committedAt = recordingCommittedAt else { return false }
        return engagedAt <= committedAt && !lifecycleReachedInMeetingThisRecording
    }

    /// END19 item 1: a discovery scan found no winner. Counted against the engage the last winner
    /// left behind; once it has gone `StaleEngageBound.scansWithoutSighting` scans unsighted while
    /// its engine is still `.idle`, it is torn down.
    func handleScanWithoutWinner() {
        assertMainQueue()
        guard coordinator.stateMachine.isAcceptingPrompts else { return }
        guard coordinator.lifecycleCoord.isEngaged else {
            staleEngage.clear()
            return
        }
        let engineIdle = coordinator.lifecycleCoord.current == .idle
        guard case .disengage(let bundleID, let engagedSec, let scans) =
            staleEngage.scanWithoutWinner(engineIdle: engineIdle, at: Date()) else { return }
        Log.event(category: "coordinator", action: "lifecycle_disengaged_stale", attributes: [
            "bundle_id": bundleID,
            "engaged_sec": engagedSec,
            "scans_without_sighting": scans,
        ])
        disengageLifecycle()
    }

    func disengageLifecycle() {
        assertMainQueue()
        staleEngage.clear()
        releaseTeardownHold()
        // PERF15: a discovery build still walking belongs to the session being torn down, so its
        // landing must not engage; the next discovery requests a fresh one.
        lifecycleBuild = nil
        coordinator.lifecycleCoord.disengage()
    }

    /// END20 (D075): `resolve`, or a title-less source once `deadline` passes, whichever is first.
    /// The deadline is a Dispatch timer, never `Task.sleep`: a bound built from tasks starves with
    /// the cooperative pool (CI8), and the read it bounds is the one that might be wedged. A read
    /// that lands late is dropped.
    static func resolveAppSource(
        from context: MeetingLifecycleContext,
        within deadline: TimeInterval,
        using resolve: @escaping @Sendable (MeetingLifecycleContext) async -> AppSource
    ) async -> AppSource {
        await withCheckedContinuation { (continuation: CheckedContinuation<AppSource, Never>) in
            let pending = OSAllocatedUnfairLock<CheckedContinuation<AppSource, Never>?>(initialState: continuation)
            @Sendable func finish(_ source: AppSource) -> Bool {
                let waiting = pending.withLock { state -> CheckedContinuation<AppSource, Never>? in
                    defer { state = nil }
                    return state
                }
                waiting?.resume(returning: source)
                return waiting != nil
            }
            Task { _ = finish(await resolve(context)) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
                if finish(appSource(from: context, title: nil)) {
                    Log.event(category: "coordinator", action: "prompt_title_deadline_passed", attributes: [
                        "bundle_id": context.bundleID,
                        "deadline_sec": deadline,
                    ])
                }
            }
        }
    }

    /// PERF15: `appSource(from:)` on `axWalkQueue`, awaited by the lifecycle consumer. GCD rather
    /// than a `Task`, because the title read is synchronous AX IPC and would hold a cooperative
    /// pool thread for as long as the client takes to answer (CI8).
    static func resolveAppSource(from context: MeetingLifecycleContext) async -> AppSource {
        await withCheckedContinuation { (continuation: CheckedContinuation<AppSource, Never>) in
            axWalkQueue.async {
                let title = MeetingTitleResolver.resolve(
                    bundleID: context.bundleID,
                    kind: context.kind == .browser ? .browser : .native,
                    pid: context.pid
                )
                continuation.resume(returning: appSource(from: context, title: title))
            }
        }
    }

    /// Bridge a lifecycle context back into an `AppSource` for the prompt +
    /// matcher: resolve the display name via `NSRunningApplication`, with the
    /// title `resolveAppSource` read for the matcher's title rules.
    static func appSource(from context: MeetingLifecycleContext, title: String?) -> AppSource {
        let kind: AppSourceKind = context.kind == .browser ? .browser : .native
        let displayName = NSRunningApplication(processIdentifier: context.pid)?
            .localizedName ?? context.bundleID
        return AppSource(
            bundleID: context.bundleID,
            displayName: displayName,
            kind: kind,
            meetingTitle: title
        )
    }
}
