import AVFoundation
import XCTest
@testable import MeetingPipe

/// The first constructible coverage of the daemon's session spine (ARCH4).
///
/// Until the `SessionHost` seam existed, nothing could build a
/// `MeetingSessionController`: it reached through `unowned let coordinator:
/// Coordinator`, whose init constructs ~18 AVFoundation / AppKit subsystems. So
/// every transition in the daemon, including the two invariants ARCHITECTURE.md
/// declares (never two `.recording`; `.stopping` always advances), was enforced
/// by `swift build` and nothing else. `MeetingSessionControllerTests`' own header
/// conceded it covered two static helpers.
///
/// These tests drive the real controller against `FakeSessionHost`, whose state
/// machine, consent store, and workflow store are the real types. The assertions
/// are on state the controller actually drove, not on a mock's expectations.
@MainActor
final class MeetingSessionControllerBranchTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arch4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func makeController(
        workflows: [Workflow] = []
    ) -> (MeetingSessionController, FakeSessionHost) {
        let host = FakeSessionHost(tempDir: tempDir, workflows: workflows)
        return (MeetingSessionController(coordinator: host), host)
    }

    private func source(_ bundleID: String = "us.zoom.xos") -> AppSource {
        AppSource(bundleID: bundleID, displayName: "Zoom")
    }

    /// `beginRecording` commits to a start, then does the work in a detached
    /// `Task`. Wait for a condition that Task establishes, bounded, rather than
    /// yielding a fixed number of times: a fixed yield count passes on an idle
    /// machine and flakes under load (it did, once, while the pipeline suite was
    /// saturating the CPU).
    private func waitUntil(
        _ predicate: () -> Bool,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 500_000)  // 0.5 ms
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// For the branches that return *before* spawning the Task. Nothing to await;
    /// a yield only proves the synchronous path already ran.
    private func settle() async {
        await Task.yield()
    }

    // MARK: - beginRecording: the permission gate

    func test_beginRecording_withoutMicPermission_refusesAndDeepLinksToPermissions() async {
        let (controller, host) = makeController()
        host.micAuthorizationStatus = .denied

        controller.beginRecording(source: source(), summaryMode: .auto)
        await settle()

        // A silent recording with an empty transcript is worse than no recording,
        // so the refusal is total: the recorder is never touched.
        XCTAssertEqual(host.recorderSpy.startCallCount, 0)
        XCTAssertEqual(host.notifierSpy.errors.count, 1)
        XCTAssertTrue(host.notifierSpy.errors[0].contains("Microphone permission"))
        // And it is actionable, not just an error string.
        XCTAssertEqual(host.menuPreferencesPermissionsCallCount, 1)
        XCTAssertEqual(host.statusBarSpy.idleCount, 1)
        XCTAssertEqual(host.stateMachine.current, .idle)
    }

    func test_beginRecording_withUndeterminedMicPermission_alsoRefuses() async {
        // Only `.authorized` starts a recording; `.notDetermined` must not be
        // mistaken for "probably fine".
        let (controller, host) = makeController()
        host.micAuthorizationStatus = .notDetermined

        controller.beginRecording(source: source(), summaryMode: .auto)
        await settle()

        XCTAssertEqual(host.recorderSpy.startCallCount, 0)
        XCTAssertEqual(host.stateMachine.current, .idle)
    }

    // MARK: - beginRecording: dry run

    func test_beginRecording_inDryRun_skipsRecorderAndHUDAndReturnsToIdle() async {
        let (controller, host) = makeController()
        host.dryRun = true

        controller.beginRecording(source: source(), summaryMode: .auto)
        await settle()

        // Detection ran; the recorder and HUD deliberately did not, so a workday
        // logs as detection-only signals.
        XCTAssertEqual(host.recorderSpy.startCallCount, 0)
        XCTAssertEqual(host.hudSpy.presentCount, 0)
        XCTAssertEqual(host.notifierSpy.recordingStarted.count, 0)
        XCTAssertEqual(host.statusBarSpy.idleCount, 1)
        XCTAssertEqual(host.stateMachine.current, .idle)
    }

    // MARK: - beginRecording: the second-press guard

    func test_beginRecording_ignoresASecondPressWhileAStartIsInFlight() async {
        // Five stacked `recorder.start()` calls froze the daemon on 2026-06-12.
        // The engine bring-up is async, so a second toggle press lands while the
        // first start is still resolving.
        let (controller, host) = makeController()
        host.recorderSpy.startBehaviour = .hang

        controller.beginRecording(source: source(), summaryMode: .auto)
        controller.beginRecording(source: source(), summaryMode: .auto)
        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ host.recorderSpy.startCallCount >= 1 }, "the first start to be entered")

        XCTAssertEqual(host.recorderSpy.startCallCount, 1)
    }

    func test_beginRecording_acceptsANewStartOnceTheFirstResolved() async {
        // The guard must not latch: a failed start has to leave the door open.
        let (controller, host) = makeController()
        host.recorderSpy.startBehaviour = .fail(MeetingRecorder.RecorderError.engineStartFailed("boom"))

        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ host.notifierSpy.errors.count == 1 }, "the failed start to resolve")
        XCTAssertEqual(host.recorderSpy.startCallCount, 1)

        host.recorderSpy.startBehaviour = .succeed
        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ host.recorderSpy.startCallCount == 2 }, "the second start")
    }

    // MARK: - beginRecording: failure routing

    func test_beginRecording_whenTheRecorderFails_notifiesAndReturnsToIdle() async {
        let (controller, host) = makeController()
        host.recorderSpy.startBehaviour = .fail(MeetingRecorder.RecorderError.engineStartFailed("boom"))

        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ host.notifierSpy.errors.count == 1 }, "the failure to be surfaced")

        XCTAssertTrue(host.notifierSpy.errors[0].contains("Could not start recording"))
        XCTAssertEqual(host.statusBarSpy.idleCount, 1)
        XCTAssertEqual(host.stateMachine.current, .idle)
        // A failed start arms the re-prompt cooldown, so a renegotiating headset
        // does not re-prompt in a loop.
        XCTAssertTrue(host.stateMachine.isCoolingDown(bundleID: "us.zoom.xos", cooldownSec: 60))
    }

    func test_beginRecording_manualFailure_armsNoCooldown() async {
        // A manual recording has no bundle to cool down; `recordingStartInFlight`
        // already bounds re-clicks there.
        let (controller, host) = makeController()
        host.recorderSpy.startBehaviour = .fail(MeetingRecorder.RecorderError.engineStartFailed("boom"))

        controller.beginRecording(source: nil, summaryMode: .auto)
        await waitUntil({ host.notifierSpy.errors.count == 1 }, "the failure to be surfaced")

        XCTAssertEqual(host.stateMachine.current, .idle)
    }

    // MARK: - beginRecording: the workflow override

    func test_beginRecording_honoursThePendingWorkflowOverrideAndClearsIt() async {
        var chosen = Workflow(name: "Client work")
        chosen.contextPrompt = "client"
        var other = Workflow(name: "Standup")
        other.contextPrompt = "standup"
        let (controller, host) = makeController(workflows: [other, chosen])

        controller.pendingWorkflowOverride = chosen.id
        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ !host.statusBarSpy.recordings.isEmpty }, "the recording to be announced")

        XCTAssertEqual(host.recorderSpy.startCallCount, 1)
        XCTAssertEqual(controller.activeWorkflow?.id, chosen.id)
        XCTAssertEqual(host.statusBarSpy.recordings.first?.workflow?.id, chosen.id)
        // The override is one-shot: it must not leak into the next meeting.
        XCTAssertNil(controller.pendingWorkflowOverride)
    }

    func test_beginRecording_startsRecordingStateAndPresentsTheHUD() async {
        let (controller, host) = makeController()

        controller.beginRecording(source: source(), summaryMode: .byo)
        await waitUntil({ !host.statusBarSpy.recordings.isEmpty }, "the recording to be announced")

        XCTAssertEqual(host.recorderSpy.startCallCount, 1)
        XCTAssertEqual(host.hudSpy.presentCount, 1)
        XCTAssertEqual(host.notifierSpy.recordingStarted.count, 1)
        XCTAssertEqual(host.statusBarSpy.recordings.count, 1)
        // The summary mode reaches the status bar intact: a BYO meeting must not
        // become an Anthropic auto-summary.
        XCTAssertEqual(host.statusBarSpy.recordings.first?.summaryMode, .byo)
        XCTAssertTrue(host.stateMachine.current.isRecording)
    }

    func test_beginRecording_passesTheLiveOutputDirAndVoiceProcessingToTheRecorder() async {
        let (controller, host) = makeController()
        host.liveVoiceProcessing = true

        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ host.recorderSpy.lastStartArgs != nil }, "the recorder to be started")

        XCTAssertEqual(host.recorderSpy.lastStartArgs?.outputDir, host.liveOutputDir)
        XCTAssertEqual(host.recorderSpy.lastStartArgs?.voiceProcessing, true)
    }

    // MARK: - AI9: the routing hint on the prompt

    /// Fill the host's correction store with `count` pairs for `bundleID`.
    private func teach(
        _ host: FakeSessionHost,
        _ count: Int,
        _ workflow: Workflow,
        bundleID: String = "us.zoom.xos",
        title: String? = nil
    ) {
        for _ in 0..<count {
            host.workflowCorrections.record(
                bundleID: bundleID, meetingTitle: title, workflow: workflow
            )
        }
    }

    func test_prompt_carriesNoSuggestionWhenNothingHasBeenCorrected() {
        let general = Workflow(name: "General", isDefault: true)
        let (controller, host) = makeController(workflows: [general])

        controller.handleMeetingStarted(source: source())

        XCTAssertEqual(host.promptSpy.presentCount, 1)
        XCTAssertNil(host.promptSpy.lastSuggestion)
        XCTAssertNil(controller.preselectedRoutingHint?.workflowID)
    }

    func test_prompt_carriesTheSuggestionOnceTheThresholdIsReached() {
        let general = Workflow(name: "General", isDefault: true)
        let client = Workflow(name: "Client work")
        let (controller, host) = makeController(workflows: [general, client])
        teach(host, WorkflowRoutingHint.minimumCorrections, client)

        controller.handleMeetingStarted(source: source())

        // The chip still gets what the rules resolved; the panel applies the
        // suggestion on top, so the two never disagree about which is which.
        XCTAssertEqual(host.promptSpy.lastWorkflow?.id, general.id)
        XCTAssertEqual(host.promptSpy.lastSuggestion?.workflowID, client.id)
        XCTAssertEqual(controller.preselectedRoutingHint?.workflowID, client.id)
    }

    /// The acceptance case end to end: three corrections, then Record without
    /// touching the chip, and the meeting is recorded under the corrected workflow.
    func test_beginRecording_afterAPreselection_recordsUnderTheSuggestedWorkflow() async {
        let general = Workflow(name: "General", isDefault: true)
        let client = Workflow(name: "Client work")
        let (controller, host) = makeController(workflows: [general, client])
        teach(host, WorkflowRoutingHint.minimumCorrections, client)

        controller.handleMeetingStarted(source: source())
        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ !host.statusBarSpy.recordings.isEmpty }, "the recording to be announced")

        XCTAssertEqual(controller.activeWorkflow?.id, client.id)
        XCTAssertNil(controller.preselectedRoutingHint, "the hint is one-shot, like the override")
    }

    func test_beginRecording_anExplicitPickOutranksThePreselection() async {
        let general = Workflow(name: "General", isDefault: true)
        let client = Workflow(name: "Client work")
        let (controller, host) = makeController(workflows: [general, client])
        teach(host, WorkflowRoutingHint.minimumCorrections, client)

        controller.handleMeetingStarted(source: source())
        // What the panel's Undo sends: an explicit pick of the rule-matched one.
        controller.setPendingWorkflowOverride(general.id)
        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ !host.statusBarSpy.recordings.isEmpty }, "the recording to be announced")

        XCTAssertEqual(controller.activeWorkflow?.id, general.id)
    }

    /// A hint armed for one meeting must not colour the next one. `pendingWorkflowOverride`
    /// is only cleared by a start, so a prompt that was skipped would otherwise
    /// leave the pre-selection lying around.
    func test_preselection_doesNotApplyToADifferentSource() async {
        let general = Workflow(name: "General", isDefault: true)
        let client = Workflow(name: "Client work")
        let (controller, host) = makeController(workflows: [general, client])
        teach(host, WorkflowRoutingHint.minimumCorrections, client, bundleID: "us.zoom.xos")

        controller.handleMeetingStarted(source: source("us.zoom.xos"))
        XCTAssertEqual(controller.preselectedRoutingHint?.workflowID, client.id)

        // A different app starts a meeting; the Zoom hint must not follow it.
        controller.beginRecording(source: source("com.microsoft.teams2"), summaryMode: .auto)
        await waitUntil({ !host.statusBarSpy.recordings.isEmpty }, "the recording to be announced")

        XCTAssertEqual(controller.activeWorkflow?.id, general.id)
    }

    /// The privacy direction: the hint is offered but never armed, so a Record
    /// click on an NDA-routed meeting cannot silently take it out of NDA.
    func test_ndaRoutedMeeting_isSuggestedButNotPreselected() {
        var confidential = Workflow(name: "Confidential")
        confidential.flags.ndaMode = true
        confidential.matchingRules = [WorkflowMatchingRule(bundleID: "us.zoom.xos")]
        let client = Workflow(name: "Client work")
        let (controller, host) = makeController(workflows: [confidential, client])
        teach(host, WorkflowRoutingHint.minimumCorrections + 1, client)

        controller.handleMeetingStarted(source: source())

        XCTAssertEqual(host.promptSpy.lastSuggestion?.workflowID, client.id)
        XCTAssertEqual(host.promptSpy.lastSuggestion?.preselects, false)
        XCTAssertNil(controller.preselectedRoutingHint)
    }

    // MARK: - handleMeetingStarted: prompt vs auto-consent

    func test_handleMeetingStarted_promptsWithTheLivePromptTimeout() {
        let (controller, host) = makeController()
        host.livePromptTimeoutSec = 17

        controller.handleMeetingStarted(source: source())

        XCTAssertEqual(host.promptSpy.presentCount, 1)
        XCTAssertEqual(host.promptSpy.lastAutoDismissAfter, 17)
        XCTAssertEqual(host.statusBarSpy.promptedSources.count, 1)
        XCTAssertTrue(host.stateMachine.current.isPrompting)
        // Prompting is not recording.
        XCTAssertEqual(host.recorderSpy.startCallCount, 0)
    }

    func test_handleMeetingStarted_autoConsentedAppRecordsWithoutPrompting() async {
        let (controller, host) = makeController()
        host.liveAutoConsentApps = ["us.zoom.xos"]

        controller.handleMeetingStarted(source: source())
        await waitUntil({ host.stateMachine.current.isRecording }, "auto-consent to start recording")

        XCTAssertEqual(host.promptSpy.presentCount, 0)
        XCTAssertEqual(host.recorderSpy.startCallCount, 1)
    }

    func test_handleMeetingStarted_withinTheRepromptCooldown_doesNothing() {
        let (controller, host) = makeController()
        host.stateMachine.recordCooldownEnd(bundleID: "us.zoom.xos")

        controller.handleMeetingStarted(source: source())

        // A lifecycle `.starting` queued just before disengage must not re-prompt
        // the meeting the user just skipped.
        XCTAssertEqual(host.promptSpy.presentCount, 0)
        XCTAssertEqual(host.recorderSpy.startCallCount, 0)
        XCTAssertEqual(host.stateMachine.current, .idle)
    }

    // MARK: - DET1: mic-in-use tier tag + mic-release stop

    func test_micInUse_recordingIsStoppedWhenItsMicIsReleased() async {
        let (controller, host) = makeController()
        let faceTime = AppSource(bundleID: "com.apple.FaceTime", displayName: "FaceTime")
        // A DET1 dwell prompts; recording that prompt tags it as a DET1 recording.
        controller.handleMicInUseDwell(faceTime)
        controller.beginRecording(source: faceTime, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current.isRecording }, "the DET1 recording to start")

        // The mic is no longer held by FaceTime (the call ended). The level check stops the
        // recording - a DET1 recording engages no lifecycle, so this is its reliable end.
        controller.handleMicBusyBundle(nil)
        await waitUntil({ !host.stateMachine.current.isRecording }, "the DET1 recording to stop on mic release")
    }

    func test_micInUse_staleTagDoesNotStopALaterWhitelistRecording() async {
        // Regression guard (found in re-review): a skipped DET1 prompt must not leave a stale tag
        // that mis-tags a later WHITELIST recording of the same bundle as DET1, which the
        // mic-release level check would then false-stop mid-call.
        let (controller, host) = makeController()
        let chrome = AppSource(bundleID: "com.google.Chrome", displayName: "Google Chrome")

        // 1) DET1 prompts for Chrome; the user skips (abandon, no recording).
        controller.handleMicInUseDwell(chrome)
        XCTAssertTrue(host.stateMachine.current.isPrompting)
        host.stateMachine.abandonPrompt(source: chrome)
        host.stateMachine.clearSuppression(bundleID: chrome.bundleID) // the 15s/60s suppression lapses

        // 2) A whitelist Google-Meet-in-Chrome is detected and recorded (same bundle). The whitelist
        //    handleMeetingStarted resets the one-shot tag, so this recording is NOT tagged DET1.
        controller.handleMeetingStarted(source: chrome)
        controller.beginRecording(source: chrome, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current.isRecording }, "the whitelist recording to start")

        // 3) The mic releases: a whitelist recording must survive (its own end path governs it).
        controller.handleMicBusyBundle(nil)
        await settle()
        XCTAssertTrue(host.stateMachine.current.isRecording,
                      "a whitelist recording must not be mis-tagged as DET1 and mic-release-stopped")
    }

    // MARK: - DET7: attach to the meeting the user skipped

    /// The whole task in one arrangement: a prompt was dismissed, discovery still sees the
    /// meeting, and the state machine is back at `.idle` (which is why `toggleManual`'s
    /// `.suppressed` branch never fires).
    private func skipThenSight(
        _ controller: MeetingSessionController,
        _ host: FakeSessionHost,
        _ src: AppSource
    ) {
        host.stateMachine.setPrompting(source: src)
        host.stateMachine.abandonPrompt(source: src)
        controller.handleDiscovery(src)
    }

    func test_latchedDiscoverySighting_cachesTheCandidateAndRefreshesIt() {
        let (controller, host) = makeController()
        let teams = source("com.microsoft.teams2")

        // Before the skip, a sighting engages the lifecycle and caches nothing: an
        // unlatched meeting is not a candidate for anything.
        controller.handleDiscovery(teams)
        XCTAssertNil(host.stateMachine.liveSuppressedCandidate())

        skipThenSight(controller, host, teams)
        XCTAssertEqual(host.stateMachine.liveSuppressedCandidate(), teams)

        // Every later sighting refreshes it, which is what keeps it alive for the call:
        // the display name of the newest sighting is the one that ends up on the menu row.
        let renamed = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")
        controller.handleDiscovery(renamed)
        XCTAssertEqual(host.stateMachine.liveSuppressedCandidate()?.displayName, "Microsoft Teams")
    }

    /// DET9's consequence at the surface that shows it. The menu bar's `Suppressed (<app>)` label
    /// and the "Record this <app> meeting" row both read the skip latch, so a latch that lapses
    /// during a mid-call stretch of scans with no confident winner takes DET7's whole attach
    /// affordance with it, while the call is still running. Walk the quiet discovery cadence
    /// across the 48 s gap the owner's log actually recorded on 2026-07-27.
    func test_cachedCandidate_survivesAMidCallStretchWithNoConfidentWinner() {
        let (controller, host) = makeController()
        let teams = source("com.microsoft.teams2")
        let sightedAt = Date()
        skipThenSight(controller, host, teams)

        let idle = DiscoveryScanCadence.discoveryDefault.idle
        for missedPolls in 1...4 {
            let now = sightedAt.addingTimeInterval(idle * Double(missedPolls))
            XCTAssertTrue(
                host.stateMachine.isSkipLatched(bundleID: teams.bundleID, now: now),
                "the menu bar drops back to Start Recording \(idle * Double(missedPolls)) s into a live call"
            )
            XCTAssertNotNil(
                host.stateMachine.liveSuppressedCandidate(now: now),
                "and the meeting the user skipped is no longer attachable, so a manual start records generic"
            )
        }
    }

    func test_cachedCandidate_clearsWhenTheLatchLapses() {
        let (controller, host) = makeController()
        let teams = source("com.microsoft.teams2")
        skipThenSight(controller, host, teams)
        XCTAssertNotNil(host.stateMachine.liveSuppressedCandidate())

        // Discovery stops seeing the meeting for a whole grace: the latch lapses and the stale
        // candidate goes with it. Otherwise a start hours later would attribute itself to a
        // meeting that ended, which is worse than recording generic.
        let afterGrace = Date().addingTimeInterval(DetectionStateMachine.skipLatchGraceSec + 1)
        XCTAssertNil(host.stateMachine.liveSuppressedCandidate(now: afterGrace))
        // And the drop is durable, not just a filtered read.
        XCTAssertNil(host.stateMachine.liveSuppressedCandidate())
    }

    func test_recordAttached_clearsSuppressionAndRecordsWithTheSource() async {
        let (controller, host) = makeController()
        let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")
        skipThenSight(controller, host, teams)

        controller.recordAttached(to: teams, trigger: "manual")
        await waitUntil({ host.stateMachine.current.isRecording }, "the attached recording to start")

        // The suppression the skip armed is gone (both halves), so nothing holds this start
        // off and a later `.starting` for the same meeting is not silently swallowed.
        XCTAssertFalse(host.stateMachine.isSkipLatched(bundleID: teams.bundleID))
        XCTAssertFalse(host.stateMachine.isCoolingDown(bundleID: teams.bundleID, cooldownSec: 60))
        XCTAssertEqual(host.promptSpy.dismissCount, 1, "any prompt remnant is dismissed")

        // It records *with* the source: that is what gives the meta sidecar an identity and
        // `armLifecycleLeaveButton` something to arm on.
        XCTAssertEqual(host.statusBarSpy.recordings.last?.source, teams)
        let meta = MeetingMetaSidecar.build(source: host.statusBarSpy.recordings.last?.source, workflow: nil)
        XCTAssertEqual(meta["source_bundle_id"] as? String, "com.microsoft.teams2")
        XCTAssertEqual(meta["source_display_name"] as? String, "Microsoft Teams")
    }

    func test_recordAttached_isIgnoredWhileAlreadyRecording() async {
        let (controller, host) = makeController()
        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ host.stateMachine.current.isRecording }, "the first recording to start")

        controller.recordAttached(to: source("com.microsoft.teams2"), trigger: "notification")
        await settle()

        XCTAssertEqual(host.recorderSpy.startCallCount, 1, "a later meeting must not stack a start")
    }

    func test_toggleManual_fromIdle_attachesToALiveCandidate() async {
        let (controller, host) = makeController()
        let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")
        skipThenSight(controller, host, teams)

        controller.toggleManual()
        await waitUntil({ host.stateMachine.current.isRecording }, "the manual recording to start")

        // The bug DET7 fixes: this used to be `beginRecording(source: nil)`, so the meeting
        // the user was sitting in recorded as an anonymous one.
        XCTAssertEqual(host.statusBarSpy.recordings.last?.source, teams)
    }

    func test_toggleManual_fromIdle_withoutACandidate_recordsGeneric() async {
        let (controller, host) = makeController()

        controller.toggleManual()
        await waitUntil({ host.stateMachine.current.isRecording }, "the manual recording to start")

        XCTAssertNil(host.statusBarSpy.recordings.last?.source,
                     "a truly idle manual start has nothing to attach to and stays generic")
    }

    func test_toggleManual_afterTheLatchLapses_recordsGeneric() async {
        let (controller, host) = makeController()
        let teams = source("com.microsoft.teams2")
        skipThenSight(controller, host, teams)
        // Read once past the grace so the stale candidate is dropped, exactly as the menu
        // row's read would have done when the user next opened it.
        _ = host.stateMachine.liveSuppressedCandidate(
            now: Date().addingTimeInterval(DetectionStateMachine.skipLatchGraceSec + 1)
        )

        controller.toggleManual()
        await waitUntil({ host.stateMachine.current.isRecording }, "the manual recording to start")

        XCTAssertNil(host.statusBarSpy.recordings.last?.source)
    }

    /// The `meetingpipe://record` verb's rule. `Coordinator.startRecordingViaAutomation`
    /// owns only the `.idle` guard (a Coordinator is not constructible in a test, ARCH4);
    /// the attach-or-generic decision it delegates to is this, shared with the hotkey.
    func test_startManual_fromAutomation_attachesToALiveCandidate() async {
        let (controller, host) = makeController()
        let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")
        skipThenSight(controller, host, teams)

        controller.startManual(summaryMode: .byo, trigger: "automation")
        await waitUntil({ host.stateMachine.current.isRecording }, "the automation recording to start")

        XCTAssertEqual(host.statusBarSpy.recordings.last?.source, teams)
        XCTAssertEqual(host.statusBarSpy.recordings.last?.summaryMode, .byo,
                       "attaching must not quietly rewrite the requested summary mode")
    }

    // MARK: - DET13: attach during the re-prompt cooldown

    /// Read every JSON row the daemon wrote into a redirected logs dir. The emitted line, not a
    /// re-spelling of it, the way `MeetingSourceScannerTests` reads DET11's.
    private func eventRows(in logs: URL) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    /// The asymmetry DET13 fixes. `handleDiscovery`'s skip-latch branch keeps its sighting and the
    /// `isCoolingDown` branch beside it was a bare `return`, so for the 60 s after a recording
    /// ended the same bundle produced neither a prompt nor a retained candidate.
    func test_coolingDownSighting_cachesTheCandidate() {
        let (controller, host) = makeController()
        let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")
        host.stateMachine.recordCooldownEnd(bundleID: teams.bundleID)

        controller.handleDiscovery(teams)

        XCTAssertEqual(host.stateMachine.liveSuppressedCandidate(), teams)
        // Nothing was dismissed here, so the branch must not borrow the skip latch: the call still
        // has to prompt normally once the cooldown lapses.
        XCTAssertFalse(host.stateMachine.isSkipLatched(bundleID: teams.bundleID))
    }

    /// The 2026-08-04 sequence end to end. A Teams recording ends at 12:32:41, the owner joins
    /// another call 22 s later (well inside the 60 s `repromptCooldownSec`, so the discovery
    /// sighting lands in the cooldown branch and no prompt is shown), and presses Record by hand at
    /// 12:33:03. Before DET13 that took `beginRecording(source: nil)`: `20260804-123303.meta.json`
    /// carries `source_bundle_id: null`, `armLifecycleLeaveButton` had nothing to arm on, and the
    /// recording ran 15 m 35 s of room audio until the owner noticed and stopped it by hand.
    func test_backToBackMeeting_manualStartAttachesInsteadOfRecordingHeadless() async {
        let (controller, host) = makeController()
        let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")
        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20260804-122739.wav")
        // The remote side was captured, so the stop path takes neither warning branch and never
        // reads the Screen Recording grant; this test is about the cooldown, not about coverage.
        host.recorderSpy.lastSystemFires = 1

        // 1) The first meeting records and ends. The real flush path is what arms the cooldown.
        controller.beginRecording(source: teams, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current.isRecording }, "the first meeting to record")
        controller.stopRecording(file: host.recorderSpy.fileToReturn, source: teams, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current == .idle }, "the flush to finish")
        XCTAssertTrue(host.stateMachine.isCoolingDown(bundleID: teams.bundleID, cooldownSec: 60))

        // 2) 22 s later the owner is in a second call and discovery produces a confident winner for
        //    the same bundle. Still inside the cooldown, so nothing prompts.
        controller.handleDiscovery(teams)
        XCTAssertEqual(host.promptSpy.presentCount, 0,
                       "the cooldown is load-bearing against END9's false-end re-prompt storms")

        // 3) The owner presses Record.
        controller.startManual(summaryMode: .auto, trigger: "manual")
        await waitUntil({ host.stateMachine.current.isRecording }, "the manual recording to start")

        XCTAssertEqual(host.statusBarSpy.recordings.last?.source, teams,
                       "a headless recording has no meeting to watch, so it runs until it is hand-stopped")
        let meta = MeetingMetaSidecar.build(source: host.statusBarSpy.recordings.last?.source, workflow: nil)
        XCTAssertEqual(meta["source_bundle_id"] as? String, "com.microsoft.teams2")
        XCTAssertEqual(meta["source_display_name"] as? String, "Microsoft Teams")
    }

    /// DET13's audit trail. The 2026-08-04 occurrence was unreadable from `events.jsonl` alone: the
    /// cooldown branch returned silently, so the log shows a 22 s hole with no `lifecycle starting`,
    /// no `prompt_shown`, and nothing saying why. One row per retention rather than one per poll,
    /// since discovery re-sights the same call every 3 to 12 s for the whole window.
    func test_coolingDownSighting_emitsOneRetainedEvent_andTheSkipLatchBranchEmitsNone() throws {
        let logs = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }

        let (controller, host) = makeController()
        let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")
        host.stateMachine.recordCooldownEnd(bundleID: teams.bundleID)

        controller.handleDiscovery(teams)
        controller.handleDiscovery(teams)  // the next poll, 3 to 12 s later
        controller.handleDiscovery(teams)

        let retained = eventRows(in: logs).filter { $0["action"] as? String == "cooldown_candidate_retained" }
        XCTAssertEqual(retained.count, 1, "one row per retention, not one per discovery poll")
        XCTAssertEqual(retained.first?["category"] as? String, "coordinator")
        XCTAssertEqual(retained.first?["bundle_id"] as? String, "com.microsoft.teams2")

        // The branch above it is untouched and stays silent. `abandonPrompt` arms the skip latch
        // AND the cooldown, so this is exactly the both-armed case, and DET7 already has its own
        // handle on that meeting: the skip-latch branch has to keep winning.
        let (skipController, skipHost) = makeController()
        skipHost.stateMachine.setPrompting(source: teams)
        skipHost.stateMachine.abandonPrompt(source: teams)
        skipController.handleDiscovery(teams)

        XCTAssertEqual(skipHost.stateMachine.liveSuppressedCandidate(), teams, "DET7's path still caches")
        let after = eventRows(in: logs).filter { $0["action"] as? String == "cooldown_candidate_retained" }
        XCTAssertEqual(after.count, 1, "a skip-latched sighting must still take the branch above")
    }

    /// UX10's timeout-skip keeps its loud banner; DET7 only added the silent one for an
    /// explicit dismissal, which is a different surface for a different event.
    func test_promptTimeout_notifiesWithTheTimedOutOrigin() async {
        let (controller, host) = makeController()
        host.livePromptTimeoutSec = 0.01
        let teams = source("com.microsoft.teams2")

        host.stateMachine.setPrompting(source: teams)
        controller.startPromptTimeout(for: teams)
        await waitUntil({ !host.notifierSpy.skipped.isEmpty }, "the timeout-skip notification")

        XCTAssertEqual(host.notifierSpy.skipped.last?.origin, .timedOut)
        XCTAssertEqual(host.statusBarSpy.suppressedSources.last, teams)
    }

    // MARK: - The invariant ARCHITECTURE.md declares

    func test_neverTwoRecordings_aSecondBeginWhileRecordingIsIgnored() async {
        let (controller, host) = makeController()

        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ host.stateMachine.current.isRecording }, "the first recording to start")

        // A second detection while already recording must not stack a start.
        controller.handleMeetingStarted(source: source("com.microsoft.teams2"))
        await settle()

        XCTAssertEqual(host.recorderSpy.startCallCount, 1)
        XCTAssertTrue(host.stateMachine.current.isRecording)
    }

    // MARK: - MIC14: off-the-record toggle

    func test_toggleOffTheRecord_whenIdle_isANoOp() async {
        let (controller, host) = makeController()
        controller.toggleOffTheRecord()
        await settle()
        XCTAssertTrue(host.recorderSpy.offTheRecordStates.isEmpty, "no recorder toggle when idle")
        XCTAssertTrue(host.hudSpy.offTheRecordStates.isEmpty, "no HUD change when idle")
    }

    func test_toggleOffTheRecord_whileRecording_drivesRecorderAndHUD() async {
        let (controller, host) = makeController()
        let file = tempDir.appendingPathComponent("rec.wav")
        host.stateMachine.setRecording(file: file, source: source(), summaryMode: .auto)

        controller.toggleOffTheRecord()   // on
        controller.toggleOffTheRecord()   // off
        await settle()

        // The toggle is idempotent per press and flips both the recorder and the HUD.
        XCTAssertEqual(host.recorderSpy.offTheRecordStates, [true, false])
        XCTAssertEqual(host.hudSpy.offTheRecordStates, [true, false])
    }

    // MARK: - FEAT8 / UX46: flag a moment

    /// The guard the HUD's new flag button inherits by sharing this entry point (UX46): pressing it
    /// when nothing is recording does nothing at all, exactly as the hotkey has always behaved.
    func test_flagMoment_whenIdle_isANoOp() async {
        let (controller, host) = makeController()
        controller.flagMoment()
        await settle()
        XCTAssertEqual(
            host.hudSpy.acknowledgedFlagCounts, [],
            "nothing was flagged, so nothing is acknowledged"
        )
    }

    /// UX73's core: the acknowledgement counts, and it counts up. FEAT8 acknowledged with a
    /// whole-panel opacity dip that said nothing about what had been recorded, so a press that
    /// registered and a press that did nothing looked identical after the animation ended.
    func test_flagMoment_whileRecording_acknowledgesWithTheRunningCount() async {
        let (controller, host) = makeController()
        host.stateMachine.setRecording(
            file: tempDir.appendingPathComponent("rec.wav"), source: source(), summaryMode: .auto
        )

        controller.flagMoment()
        controller.flagMoment()
        await settle()

        XCTAssertEqual(host.hudSpy.acknowledgedFlagCounts, [1, 2], "each press acknowledges its own number")
        XCTAssertEqual(host.hudSpy.flagCount, 2, "and the control is left showing the total")
    }

    /// A press the guard rejects must not advance the count either, or the badge starts claiming
    /// moments the sidecar will not contain. The idle no-op above proves the zero case; this proves
    /// the count does not drift once a recording is under way and then ends.
    func test_flagMoment_afterTheRecordingEnds_stopsCounting() async {
        let (controller, host) = makeController()
        host.stateMachine.setRecording(
            file: tempDir.appendingPathComponent("rec.wav"), source: source(), summaryMode: .auto
        )
        controller.flagMoment()
        await settle()

        host.stateMachine.setIdle()
        controller.flagMoment()
        await settle()

        XCTAssertEqual(
            host.hudSpy.acknowledgedFlagCounts, [1],
            "the second press was outside a recording, so it neither marked nor counted"
        )
    }

    /// The `:453` reset already dropped the marker batch per recording; this pins that the surface
    /// follows it, so a second meeting does not open with the first one's count still on the button.
    func test_flagCount_resetsOnTheNextRecording() async {
        let (controller, host) = makeController()
        host.stateMachine.setRecording(
            file: tempDir.appendingPathComponent("rec.wav"), source: source(), summaryMode: .auto
        )
        controller.flagMoment()
        controller.flagMoment()
        await settle()
        XCTAssertEqual(host.hudSpy.flagCount, 2)

        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ host.hudSpy.flagResetCount > 0 }, "the next recording to reset the flag count")

        XCTAssertEqual(host.hudSpy.flagCount, 0, "the new recording starts from an empty count")
    }
}

/// `AppState`'s cases carry associated values, so a test that only cares "which
/// state" would otherwise pattern-match five times over.
private extension AppState {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isPrompting: Bool {
        if case .prompting = self { return true }
        return false
    }
}
