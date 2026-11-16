import XCTest
@testable import MeetingPipeCore

final class PromotionEngineTests: XCTestCase {

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2",
        kind: .native,
        pid: 1234
    )

    private let browserContext = MeetingLifecycleContext(
        bundleID: "com.google.Chrome.app.fmgjjmmmlfnkbppncabfkddbjimcfncm",
        kind: .browser,
        pid: 7890
    )

    private func event(
        _ kind: PrimarySignalKind,
        _ state: PrimarySignalState,
        at: TimeInterval
    ) -> PrimarySignalEvent {
        PrimarySignalEvent(
            kind: kind,
            state: state,
            timestamp: Date(timeIntervalSince1970: at),
            context: teamsContext
        )
    }

    private func browserEvent(
        _ kind: PrimarySignalKind,
        _ state: PrimarySignalState,
        at: TimeInterval
    ) -> PrimarySignalEvent {
        PrimarySignalEvent(
            kind: kind,
            state: state,
            timestamp: Date(timeIntervalSince1970: at),
            context: browserContext
        )
    }

    func test_first_live_signal_promotes_to_starting() {
        let engine = PromotionEngine()
        let decision = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        XCTAssertEqual(decision?.verdict, .starting(context: teamsContext))
    }

    func test_confirm_recording_promotes_starting_to_in_meeting() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        let decision = engine.confirmRecording()
        XCTAssertEqual(decision?.verdict, .inMeeting(context: teamsContext))
    }

    func test_ended_signal_during_starting_promotes_straight_to_ended() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        let decision = engine.ingest(event(.shareableContentWindow, .ended, at: 1))
        XCTAssertEqual(
            decision?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "shareable_content_window_gone")
            )
        )
    }

    func test_lone_ax_leave_during_starting_holds_engine_live() {
        // START1/AUD-1: while the prompt is up (engine in `.starting`), a bare Leave-button
        // invalidation is the Teams compact-window re-render artifact, not a real end. It must
        // NOT drive the engine to a terminal `.ended` (which then absorbs every later signal and
        // wedges detection). The engine holds in `.starting`, so a Record press still arms it.
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        let held = engine.ingest(event(.axLeaveButton, .ended, at: 1))
        XCTAssertNil(held, "A lone ax-leave end during `.starting` is held, not promoted to `.ended`")
        // Engine is still live: confirming the recorder promotes to `.inMeeting`.
        let confirmed = engine.confirmRecording()
        XCTAssertEqual(confirmed?.verdict, .inMeeting(context: teamsContext))
    }

    func test_ax_leave_held_in_starting_does_not_block_a_reliable_end() {
        // A genuine pre-record end still terminates: the held ax-leave does not stop a reliable
        // signal (window-gone) from ending directly, so a slow prompt over a meeting that really
        // ended is still torn down.
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        XCTAssertNil(engine.ingest(event(.axLeaveButton, .ended, at: 1)))
        let decision = engine.ingest(event(.shareableContentWindow, .ended, at: 2))
        XCTAssertEqual(
            decision?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "shareable_content_window_gone")
            )
        )
    }

    func test_first_ended_signal_promotes_to_ending_provisional() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.confirmRecording()
        let decision = engine.ingest(event(.shareableContentWindow, .ended, at: 1))
        XCTAssertEqual(
            decision?.verdict,
            .endingProvisional(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "shareable_content_window_gone")
            )
        )
    }

    // MARK: - END17: weak ends hold, dwells confirm

    private let dwell = PromotionEngine.defaultConfirmDwell
    private let lone = PromotionEngine.defaultLoneDwell

    func test_the_dwells_are_the_pinned_values_END17() {
        XCTAssertEqual(PromotionEngine.defaultConfirmDwell, 60, "above DET8's 11.4 s and END15's mic-switch gap")
        XCTAssertEqual(PromotionEngine.defaultLoneDwell, 720, "the owner's 12 minute decision (2026-10-24)")
        XCTAssertLessThan(PromotionEngine.defaultLoneDwell, 900, "below the idle backstop, which stays the ceiling")
    }

    func test_only_an_app_quit_is_definitive_END17() {
        XCTAssertTrue(PrimarySignalKind.workspaceAppTerminated.isDefinitive)
        for kind in PrimarySignalKind.allCases where kind != .workspaceAppTerminated {
            XCTAssertFalse(kind.isDefinitive, "\(kind.rawValue) has chopped a live meeting and must hold")
        }
    }

    /// A weak cross-class pair used to end on arrival (END6's fast path). It holds now, and confirms
    /// once both signals have stayed ended for the confirm dwell.
    func test_a_weak_cross_class_pair_confirms_only_after_the_dwell_END17() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 1))
        XCTAssertNil(
            engine.ingest(event(.processAudioIsRunningInput, .ended, at: 1.5)),
            "a weak second signal is absorbed, not an end"
        )
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 1.5 + dwell - 0.1)), "the later signal has not dwelled yet")
        XCTAssertEqual(
            engine.tick(at: Date(timeIntervalSince1970: 1.5 + dwell))?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "shareable_content_window_gone",
                    confirmedBy: ["process_audio_is_running_input_false"]
                )
            )
        )
    }

    /// A lone weak end confirms on the lone dwell and says so in `confirmed_by`.
    func test_a_lone_weak_end_confirms_only_on_the_lone_dwell_END17() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 1))

        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 3)), "the old 2 s debounce ends nothing")
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 1 + dwell + 1)), "one class is not a pair")
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 1 + lone - 1)))
        XCTAssertEqual(
            engine.tick(at: Date(timeIntervalSince1970: 1 + lone))?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "shareable_content_window_gone", confirmedBy: ["lone_dwell"])
            )
        )
    }

    func test_leading_signal_flipping_back_to_live_reverts_to_in_meeting() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 1))
        let revert = engine.ingest(event(.shareableContentWindow, .live, at: 1.2))

        XCTAssertEqual(revert?.verdict, .inMeeting(context: teamsContext))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 1 + lone + 1)), "no dwell runs after a revert")
    }

    /// A signal re-reporting the state it is already in keeps its first stamp, so a repeated
    /// `.ended` cannot push a dwell out and a dwell measures how long it has stayed ended.
    func test_a_repeated_reading_keeps_its_first_stamp_END17() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 1))
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 2))
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 50))
        XCTAssertNotNil(
            engine.tick(at: Date(timeIntervalSince1970: 2 + dwell)),
            "the pair dwelled from the first reading, not the repeat"
        )
    }

    // MARK: - END15: an in-call microphone switch

    /// The 2026-10-22 sequence. The Leave button reads invalid while Teams reopens the new mic, Teams
    /// releases its input six seconds later and re-acquires it. Before END17 the release ended the
    /// call on the cross-class fast path; red against that engine.
    func test_a_mic_switch_with_the_leave_button_first_never_ends_END15() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 100))
        XCTAssertNil(engine.ingest(event(.processAudioIsRunningInput, .ended, at: 106)), "the release is not an end")
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 110)))
        XCTAssertEqual(
            engine.ingest(event(.processAudioIsRunningInput, .live, at: 112))?.verdict,
            .inMeeting(context: teamsContext),
            "the mic coming back reverts the hold"
        )
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 100 + lone + 1)))
    }

    /// The 2026-09-18 order: the mic is released first and the Leave button flickers inside the gap.
    func test_a_mic_switch_with_the_mic_first_never_ends_END15() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 100))
        XCTAssertNil(engine.ingest(event(.axLeaveButton, .ended, at: 102.5)))
        XCTAssertEqual(
            engine.ingest(event(.processAudioIsRunningInput, .live, at: 108))?.verdict,
            .inMeeting(context: teamsContext)
        )
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 100 + lone + 1)))
    }

    /// The genuine leave in the same shape: nothing returns, so the pair confirms once the dwell
    /// elapses, and `confirmed_by` still names process audio.
    func test_a_genuine_leave_in_the_same_shape_ends_after_the_dwell_END15() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 100))
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 106))
        XCTAssertEqual(
            engine.tick(at: Date(timeIntervalSince1970: 106 + dwell))?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "ax_leave_button_invalid",
                    confirmedBy: ["process_audio_is_running_input_false"]
                )
            )
        )
    }

    // MARK: - Browser (PD-3): no 120 s floor

    func test_a_browser_tab_away_for_ten_minutes_is_one_recording_END17() {
        let engine = PromotionEngine()
        _ = engine.ingest(browserEvent(.browserTabTitle, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(browserEvent(.browserTabTitle, .ended, at: 10))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 131)), "past the retired 120 s floor")
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 609)))
        XCTAssertEqual(
            engine.ingest(browserEvent(.browserTabTitle, .live, at: 610))?.verdict,
            .inMeeting(context: browserContext)
        )
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 2000)))
    }

    func test_a_browser_meeting_left_open_ends_on_the_lone_dwell_END17() {
        let engine = PromotionEngine()
        _ = engine.ingest(browserEvent(.browserTabTitle, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(browserEvent(.browserTabTitle, .ended, at: 10))
        XCTAssertEqual(
            engine.tick(at: Date(timeIntervalSince1970: 10 + lone))?.verdict,
            .ended(
                context: browserContext,
                reason: EndingReason(leadingSignal: "browser_tab_title_left_meet_pattern", confirmedBy: ["lone_dwell"])
            )
        )
    }

    /// A browser quit is definitive, so it ends a hold at once.
    func test_a_browser_quit_ends_at_once_during_a_hold_END17() {
        let engine = PromotionEngine()
        _ = engine.ingest(browserEvent(.browserTabTitle, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(browserEvent(.browserTabTitle, .ended, at: 10))
        let post = engine.ingest(browserEvent(.workspaceAppTerminated, .ended, at: 12))
        XCTAssertEqual(
            post?.verdict,
            .ended(
                context: browserContext,
                reason: EndingReason(
                    leadingSignal: "browser_tab_title_left_meet_pattern",
                    confirmedBy: ["workspace_app_terminated"]
                )
            )
        )
    }

    /// And with no hold open, a quit ends the recording without one.
    func test_a_browser_quit_ends_at_once_from_in_meeting_END17() {
        let engine = PromotionEngine()
        _ = engine.ingest(browserEvent(.browserTabTitle, .live, at: 0))
        _ = engine.confirmRecording()
        XCTAssertEqual(
            engine.ingest(browserEvent(.workspaceAppTerminated, .ended, at: 5))?.verdict,
            .ended(
                context: browserContext,
                reason: EndingReason(leadingSignal: "workspace_app_terminated", confirmedBy: [])
            )
        )
    }

    func test_event_for_different_context_is_ignored() {
        let engine = PromotionEngine()
        let other = MeetingLifecycleContext(bundleID: "us.zoom.xos", kind: .native, pid: 9999)
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        let decision = engine.ingest(PrimarySignalEvent(
            kind: .processAudioIsRunningInput,
            state: .ended,
            timestamp: Date(timeIntervalSince1970: 1),
            context: other
        ))
        XCTAssertNil(decision)
    }

    func test_ended_phase_swallows_further_signals() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 1))
        _ = engine.tick(at: Date(timeIntervalSince1970: 5))

        let post = engine.ingest(event(.processAudioIsRunningInput, .live, at: 6))
        XCTAssertNil(post, "Once ended, the engine ignores further events until reset")
    }

    func test_reset_returns_engine_to_idle() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        engine.reset()
        let decision = engine.ingest(event(.processAudioIsRunningInput, .live, at: 1))
        XCTAssertEqual(decision?.verdict, .starting(context: teamsContext))
    }

    // MARK: - TECH-END2 / END6: staleness-prone and correlated signals

    func test_lone_ax_leave_invalid_does_not_promote_before_the_lone_dwell() {
        // The confirmed 2026-06-09 repro: ax-leave goes transiently invalid on a screen-share
        // re-render. With nothing else ended it holds, and only the lone dwell can end it.
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.confirmRecording()
        let provisional = engine.ingest(event(.axLeaveButton, .ended, at: 1))
        XCTAssertEqual(
            provisional?.verdict,
            .endingProvisional(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "ax_leave_button_invalid")
            )
        )
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 4)))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 1 + lone - 1)))
        XCTAssertNotNil(engine.tick(at: Date(timeIntervalSince1970: 1 + lone)))
    }

    /// Teams' teardown line is the host's definitive evidence. It ends a held provisional at once and
    /// is recorded in `confirmedBy`.
    func test_a_teardown_confirm_promotes_a_held_provisional_END17() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 1))
        let decision = engine.confirmProvisionalEnd()
        XCTAssertEqual(
            decision?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "ax_leave_button_invalid",
                    confirmedBy: ["call_teardown_observed"]
                )
            )
        )
        XCTAssertNil(
            engine.tick(at: Date(timeIntervalSince1970: 1 + lone)),
            "Once confirmed-ended, a later tick must not re-emit"
        )
    }

    func test_confirm_is_noop_when_not_provisional() {
        // No provisional end in flight: confirming is a no-op (a concurrent revert or end already
        // moved the phase), so it can never fabricate an end out of .idle or .inMeeting.
        let engine = PromotionEngine()
        XCTAssertNil(engine.confirmProvisionalEnd(), "idle: nothing to confirm")
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.confirmRecording()
        XCTAssertNil(engine.confirmProvisionalEnd(), "in_meeting: nothing to confirm")
    }

    func test_correlated_window_gone_is_not_a_pair_with_ax_leave() {
        // END6/AUD-10: ax-leave + window-gone are one evidence class (a Teams share re-render
        // invalidates the Leave button and drops the call window together), so the pair never
        // satisfies the confirm dwell. This is the fix for the 2026-06-09 fragments-1-and-4 false end.
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 1))
        XCTAssertNil(engine.ingest(event(.shareableContentWindow, .ended, at: 1.3)))
        XCTAssertNil(
            engine.tick(at: Date(timeIntervalSince1970: 1.3 + dwell + 1)),
            "a correlated signal is not a cross-class pair"
        )
    }

    func test_ax_leave_provisional_reverts_to_in_meeting_when_control_returns() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 1))
        let revert = engine.ingest(event(.axLeaveButton, .live, at: 1.5))
        XCTAssertEqual(revert?.verdict, .inMeeting(context: teamsContext))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 1 + lone)), "No end after the control returns")
    }

    func test_window_gone_provisional_reverts_when_ax_leave_returns_healthy() {
        // END8: a minimized / other-Space native window makes ShareableContent report the window
        // gone, but the AX rescue re-walk finds the still-healthy Leave button and emits .live. A
        // different KIND in the SAME evidence class, so the hold reverts.
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 1))
        let revert = engine.ingest(event(.axLeaveButton, .live, at: 1.5))
        XCTAssertEqual(revert?.verdict, .inMeeting(context: teamsContext))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 1 + lone)))
    }

    func test_window_gone_provisional_reverts_when_process_audio_reports_live_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 1))
        let revert = engine.ingest(event(.processAudioIsRunningInput, .live, at: 1.5))
        XCTAssertEqual(revert?.verdict, .inMeeting(context: teamsContext))
        XCTAssertEqual(
            engine.takeVeto(),
            PromotionEngine.EndVeto(leading: .shareableContentWindow, vetoedBy: .processAudioIsRunningInput)
        )
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 1 + lone)), "No end while Teams holds the mic")
    }

    /// A cross-class `.live` from a signal that never went ended says nothing new about the call, so
    /// it leaves the hold alone.
    func test_a_cross_class_live_that_never_ended_leaves_the_hold_alone_END17() {
        let engine = PromotionEngine()
        _ = engine.ingest(browserEvent(.windowTitleLeftPattern, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(browserEvent(.windowTitleLeftPattern, .ended, at: 1))
        XCTAssertNil(engine.ingest(browserEvent(.shareableContentWindow, .live, at: 2)))
        XCTAssertTrue(engine.hasPendingEndDeadline)
    }

    func test_requiresCorroboration_covers_ax_leave_and_process_audio() {
        XCTAssertTrue(PrimarySignalKind.axLeaveButton.requiresCorroboration)
        // DET8's rail, and the condition its spike pre-registered for reviving the signal at all.
        XCTAssertTrue(PrimarySignalKind.processAudioIsRunningInput.requiresCorroboration)
        XCTAssertFalse(PrimarySignalKind.shareableContentWindow.requiresCorroboration)
        XCTAssertFalse(PrimarySignalKind.workspaceAppTerminated.requiresCorroboration)
        XCTAssertFalse(PrimarySignalKind.windowTitleLeftPattern.requiresCorroboration)
        XCTAssertFalse(PrimarySignalKind.browserTabTitle.requiresCorroboration)
    }

    func test_a_lone_process_audio_drop_holds_until_the_lone_dwell() {
        // DET8's object churn reads exactly like this: process audio leads with nothing else ended.
        // It neither ends on a short wait nor pairs with itself.
        let engine = PromotionEngine()
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 1))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 1 + dwell + 1)))
        XCTAssertNotNil(engine.tick(at: Date(timeIntervalSince1970: 1 + lone)))
    }

    func test_evidence_class_groups_only_correlated_reads() {
        // END6/AUD-10: ax-leave + window-gone share a class (correlated), and since the END14
        // amendment so do the two title reads. Every other signal is its own class.
        XCTAssertEqual(
            PrimarySignalKind.axLeaveButton.evidenceClass,
            PrimarySignalKind.shareableContentWindow.evidenceClass,
            "ax-leave and window-gone are the one correlated pair"
        )
        XCTAssertNotEqual(
            PrimarySignalKind.axLeaveButton.evidenceClass,
            PrimarySignalKind.processAudioIsRunningInput.evidenceClass
        )
        XCTAssertNotEqual(
            PrimarySignalKind.shareableContentWindow.evidenceClass,
            PrimarySignalKind.workspaceAppTerminated.evidenceClass
        )
        // END14 amendment (F158): the AX window title and the shareable-content tab title are
        // one PWA title read twice, so they are one class.
        XCTAssertEqual(
            PrimarySignalKind.windowTitleLeftPattern.evidenceClass,
            PrimarySignalKind.browserTabTitle.evidenceClass
        )
    }

    func test_window_title_and_shareable_content_pair_after_the_dwell() {
        // PWA path: the AX window-title signal leads, the shareable-content snapshot pairs with it.
        let engine = PromotionEngine()
        _ = engine.ingest(browserEvent(.windowTitleLeftPattern, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(browserEvent(.windowTitleLeftPattern, .ended, at: 10))
        XCTAssertNil(engine.ingest(browserEvent(.shareableContentWindow, .ended, at: 10.4)))
        XCTAssertEqual(
            engine.tick(at: Date(timeIntervalSince1970: 10.4 + dwell))?.verdict,
            .ended(
                context: browserContext,
                reason: EndingReason(
                    leadingSignal: "window_title_left_pattern",
                    confirmedBy: ["shareable_content_window_gone"]
                )
            )
        )
    }

    func test_new_browser_signal_kinds_have_stable_raw_values() {
        // The raw values surface verbatim in events.jsonl and the
        // dogfood report, so they are part of the contract.
        XCTAssertEqual(PrimarySignalKind.workspaceAppTerminated.rawValue, "workspace_app_terminated")
        XCTAssertEqual(PrimarySignalKind.windowTitleLeftPattern.rawValue, "window_title_left_pattern")
    }

    // MARK: - END13 / END14: a live process-audio reading vetoes

    /// The 2026-10-08 replay in `.inMeeting`. Teams dropped the ` | Microsoft Teams` title suffix,
    /// so the call window stopped matching and read as gone while Teams held the mic.
    func test_live_process_audio_vetoes_a_lone_window_gone_in_meeting_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        XCTAssertNil(engine.ingest(event(.shareableContentWindow, .ended, at: 1)))
        XCTAssertFalse(engine.hasPendingEndDeadline, "A vetoed end opens no hold")
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 1 + lone + 1)))
        XCTAssertEqual(
            engine.takeVeto(),
            PromotionEngine.EndVeto(leading: .shareableContentWindow, vetoedBy: .processAudioIsRunningInput)
        )
        XCTAssertNil(engine.takeVeto(), "A veto is reported once")
    }

    /// The 2026-09-04 shape: an ax-leave hold while Teams held the mic. It used to end on the
    /// host's 150 s cap; END13 moved that to a 7200 s ceiling, and END17 to no wall clock at all.
    func test_a_live_mic_blocks_both_dwells_END13() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 1872))
        for held in [160.8, lone, 7200.0, 7201.0] {
            XCTAssertNil(
                engine.tick(at: Date(timeIntervalSince1970: 1872 + held)),
                "\(held) s into the hold Teams still holds the mic"
            )
        }
    }

    /// The real end after a veto: Teams releases the mic, process audio leads, and the Leave button
    /// going invalid inside the hold pairs with it once both have dwelled. The window-gone remembered
    /// from minute zero is not that second class (END14 amendment, G024): it is 599 s older than
    /// the hold, so the pair waits for Leave's own edge. `confirmed_by` still lists every reading
    /// that stood ended, the stale one included.
    func test_real_end_after_a_veto_takes_the_process_audio_path_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 1))
        let provisional = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 600))
        XCTAssertEqual(
            provisional?.verdict,
            .endingProvisional(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "process_audio_is_running_input_false")
            )
        )
        XCTAssertNil(engine.ingest(event(.axLeaveButton, .ended, at: 600.4)))
        XCTAssertNil(
            engine.tick(at: Date(timeIntervalSince1970: 600 + dwell)),
            "the remembered window-gone is not a fresh second class"
        )
        XCTAssertEqual(
            engine.tick(at: Date(timeIntervalSince1970: 600.4 + dwell))?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "process_audio_is_running_input_false",
                    confirmedBy: ["ax_leave_button_invalid", "shareable_content_window_gone"]
                )
            )
        )
    }

    // MARK: - END14 amendment (F031, G024, F158): a class pairs only on a fresh, uncontradicted edge

    /// A class with a member reading live is contradicted, not ended: the window-gone inside the
    /// hold does not pair with the mic release while the Leave button reads healthy.
    func test_a_class_with_a_live_sibling_does_not_pair_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 100))
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 100.5))
        for held in [dwell, dwell + 1, dwell * 3, lone - 1] {
            XCTAssertNil(
                engine.tick(at: Date(timeIntervalSince1970: 100.5 + held)),
                "\(held) s on, the Leave button still says the call is up"
            )
        }
    }

    /// The audit's minimised-window shape with the Leave button never read: the window-gone was
    /// vetoed at minute 2 and remembered, and a 61 s mic drop at minute 22 must not pair with it.
    func test_a_stale_remembered_window_gone_does_not_pair_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        XCTAssertNil(engine.ingest(event(.shareableContentWindow, .ended, at: 120)))
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 1320))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 1320 + dwell)))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 1320 + 61)))
    }

    /// The same shape with the Leave button healthy throughout, as the audit wrote it.
    func test_a_stale_window_gone_with_a_healthy_leave_does_not_pair_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        XCTAssertNil(engine.ingest(event(.shareableContentWindow, .ended, at: 120)))
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 1320))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 1320 + dwell)))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 1320 + 61)))
    }

    /// The freshness allowance is the old 2 s debounce and no more: a window-gone 2.5 s before
    /// the mic release is remembered, not fresh.
    func test_a_window_gone_just_past_the_allowance_does_not_pair_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 57.5))
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 60))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 60 + dwell)))
    }

    /// A Leave button first read healthy inside a mic-led hold, after the window went, is a true
    /// contradiction: it was never declined, so the window-gone does not pair.
    func test_a_first_healthy_leave_inside_the_hold_contradicts_the_window_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 100))
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 110))
        XCTAssertNil(engine.ingest(event(.axLeaveButton, .live, at: 111)))
        XCTAssertNil(engine.takeDeclinedRevert(), "a cross-class first reading is left alone, not declined")
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 111 + dwell * 2)))
    }

    /// A declined healthy Leave contradicts a window edge that comes after it: only the class-mates
    /// that had already gone ended are exempt (END18's decline, not a blanket pass).
    func test_a_declined_leave_still_contradicts_a_later_window_gone_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 100))
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 101))
        XCTAssertNil(engine.ingest(event(.axLeaveButton, .live, at: 102)))
        XCTAssertNotNil(engine.takeDeclinedRevert())
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 103))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 103 + dwell * 2)))
    }

    /// A decline belongs to its hold. `states` outlives the hold, so a Leave reading declined in
    /// one hold must not stop contradicting the window-gone of the next.
    func test_a_decline_from_an_earlier_hold_does_not_carry_over_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 100))
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 101))
        XCTAssertNil(engine.ingest(event(.axLeaveButton, .live, at: 102)))
        XCTAssertNotNil(engine.takeDeclinedRevert())
        XCTAssertEqual(
            engine.ingest(event(.processAudioIsRunningInput, .live, at: 110))?.verdict,
            .inMeeting(context: teamsContext)
        )
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 200))
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 200.5))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 200.5 + dwell * 2)))
    }

    /// The sibling rule runs both ways: a call window still reading present contradicts a Leave
    /// button gone invalid beside it, so that pair waits for the lone dwell.
    func test_a_present_window_contradicts_an_invalid_leave_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 100))
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 100.3))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 100.3 + dwell)))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 100 + lone - 1)))
        XCTAssertEqual(
            engine.tick(at: Date(timeIntervalSince1970: 100 + lone))?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "process_audio_is_running_input_false",
                    confirmedBy: ["ax_leave_button_invalid", "lone_dwell"]
                )
            )
        )
    }

    /// One PWA title change is one root cause read twice (F158): the AX window title and the
    /// shareable-content snapshot match the same `titleMatchers`, so they do not pair.
    func test_the_two_title_reads_of_one_pwa_do_not_pair_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(browserEvent(.browserTabTitle, .live, at: 0))
        _ = engine.ingest(browserEvent(.windowTitleLeftPattern, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(browserEvent(.windowTitleLeftPattern, .ended, at: 10))
        _ = engine.ingest(browserEvent(.browserTabTitle, .ended, at: 10.2))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 10.2 + dwell)))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 10 + lone - 1)))
        XCTAssertEqual(
            engine.tick(at: Date(timeIntervalSince1970: 10 + lone))?.verdict,
            .ended(
                context: browserContext,
                reason: EndingReason(
                    leadingSignal: "window_title_left_pattern",
                    confirmedBy: ["browser_tab_title_left_meet_pattern", "lone_dwell"]
                )
            )
        )
    }

    /// With the two title reads one class, the tab title reading live again reverts a hold the
    /// window title led, as END8's same-class revert does for the Leave button and the window.
    func test_one_title_read_returning_reverts_a_hold_the_other_led_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(browserEvent(.browserTabTitle, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(browserEvent(.windowTitleLeftPattern, .ended, at: 10))
        XCTAssertEqual(
            engine.ingest(browserEvent(.browserTabTitle, .live, at: 12))?.verdict,
            .inMeeting(context: browserContext)
        )
    }

    /// The clean leave: the window goes a beat before Teams releases the mic. On the engine alone
    /// the pair confirms after the dwell; on the host Teams' teardown confirms it the moment the
    /// hold opens, so a clean Teams leave pays no added latency.
    func test_clean_leave_holds_on_the_mic_release_and_confirms_on_teardown_END17() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0.1))
        _ = engine.confirmRecording()
        XCTAssertNil(engine.ingest(event(.shareableContentWindow, .ended, at: 60)))
        XCTAssertEqual(
            engine.ingest(event(.processAudioIsRunningInput, .ended, at: 60.2))?.verdict,
            .endingProvisional(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "process_audio_is_running_input_false")
            )
        )
        XCTAssertEqual(
            engine.confirmProvisionalEnd()?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "process_audio_is_running_input_false",
                    confirmedBy: ["call_teardown_observed"]
                )
            )
        )
    }

    /// The prompt half of the incident: in `.starting` a lone window-gone ended the engine at once,
    /// which dismissed the record prompt roughly every 12 s on 2026-10-08 and 2026-10-09.
    func test_live_process_audio_holds_the_prompt_through_a_window_gone_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        XCTAssertNil(engine.ingest(event(.shareableContentWindow, .ended, at: 0.1)))
        XCTAssertEqual(engine.confirmRecording()?.verdict, .inMeeting(context: teamsContext))
    }

    /// A hang-up before the prompt is answered still ends: releasing the mic lifts the veto and the
    /// held window-gone ends `.starting`, so a later Record press cannot arm a dead meeting.
    func test_held_window_gone_ends_starting_once_the_mic_is_released_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        XCTAssertNil(engine.ingest(event(.shareableContentWindow, .ended, at: 1)))
        let decision = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 5))
        XCTAssertEqual(
            decision?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "shareable_content_window_gone",
                    confirmedBy: ["process_audio_is_running_input_false"]
                )
            )
        )
    }

    /// A window that comes back clears the held end, so a later mic release alone does not end it.
    func test_window_returning_in_starting_clears_the_held_end_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 1))
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 2))
        XCTAssertNil(
            engine.ingest(event(.processAudioIsRunningInput, .ended, at: 3)),
            "A lone process-audio drop still needs corroboration in `.starting`"
        )
    }

    /// An app quit is definitive and is never vetoed, even while the last mic reading was live.
    func test_workspace_termination_is_not_vetoed_by_live_process_audio_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        XCTAssertEqual(
            engine.ingest(event(.workspaceAppTerminated, .ended, at: 1))?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "workspace_app_terminated", confirmedBy: [])
            )
        )
        XCTAssertNil(engine.takeVeto())
    }

    /// A released mic is not a veto: window-gone after process audio has already ended keeps
    /// today's direct end, so the change only ever applies while the mic is actually held.
    func test_released_mic_does_not_veto_window_gone_END14() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        XCTAssertNil(engine.ingest(event(.processAudioIsRunningInput, .ended, at: 1)))
        let decision = engine.ingest(event(.shareableContentWindow, .ended, at: 2))
        XCTAssertEqual(
            decision?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "shareable_content_window_gone",
                    confirmedBy: ["process_audio_is_running_input_false"]
                )
            )
        )
    }

    // MARK: - END27: a reliable `.starting` end waits for the vetoer's first reading

    /// An engine for an adapter that publishes process audio, as the coordinator configures one.
    private func engineAwaitingVetoer() -> PromotionEngine {
        let engine = PromotionEngine()
        engine.reset(awaitingVetoer: true)
        return engine
    }

    /// The 2026-11-12 15:46:06 order: Leave healthy, the window's `initial` false 2 ms ahead of
    /// process audio's `initial` true. Before END27 the window-gone ended `.starting` with
    /// `confirmed_by` empty and the resume recorded on a terminal engine.
    func test_window_gone_before_process_audio_reports_does_not_end_starting_END27() {
        let engine = engineAwaitingVetoer()
        XCTAssertEqual(engine.ingest(event(.axLeaveButton, .live, at: 0.597))?.verdict, .starting(context: teamsContext))
        XCTAssertNil(engine.ingest(event(.shareableContentWindow, .ended, at: 0.614)), "held for process audio")
        XCTAssertTrue(engine.hasPendingEndDeadline, "the grace is a deadline, so the coordinator arms the tick")
        XCTAssertNil(engine.ingest(event(.processAudioIsRunningInput, .live, at: 0.616)))
        XCTAssertEqual(
            engine.takeVeto(),
            PromotionEngine.EndVeto(leading: .shareableContentWindow, vetoedBy: .processAudioIsRunningInput),
            "logged as the END14 veto it is, naming a reading that did read live"
        )
        XCTAssertFalse(engine.hasPendingEndDeadline)
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 100)), "a vetoed end has no deadline")
        XCTAssertEqual(engine.confirmRecording()?.verdict, .inMeeting(context: teamsContext))
    }

    /// The hang-up before the start finished (END14's case) still ends: process audio's first
    /// reading is a release, which lifts the held window-gone, and it leads.
    func test_window_gone_then_a_first_mic_release_ends_starting_END27() {
        let engine = engineAwaitingVetoer()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        XCTAssertNil(engine.ingest(event(.shareableContentWindow, .ended, at: 1)))
        XCTAssertEqual(
            engine.ingest(event(.processAudioIsRunningInput, .ended, at: 1.1))?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "shareable_content_window_gone",
                    confirmedBy: ["process_audio_is_running_input_false"]
                )
            )
        )
        XCTAssertNil(engine.takeVeto(), "nothing vetoed it")
    }

    /// A process audio that never reports (an unresolved object emits nothing, DET8) does not keep
    /// the end waiting for ever: past the grace the window-gone ends `.starting` as it used to.
    func test_window_gone_ends_starting_once_the_grace_passes_without_a_vetoer_END27() {
        let engine = engineAwaitingVetoer()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        XCTAssertNil(engine.ingest(event(.shareableContentWindow, .ended, at: 1)))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 1 + PromotionEngine.defaultVetoerGrace - 0.1)))
        XCTAssertEqual(
            engine.tick(at: Date(timeIntervalSince1970: 1 + PromotionEngine.defaultVetoerGrace))?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "shareable_content_window_gone", confirmedBy: [])
            )
        )
    }

    /// An ax-leave `.ended` arriving while the window-gone waits must not make it lead: the lead
    /// search re-checks the held ends, and the vetoer still has not reported.
    func test_ax_leave_does_not_lift_a_window_gone_held_for_the_vetoer_END27() {
        let engine = engineAwaitingVetoer()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        XCTAssertNil(engine.ingest(event(.shareableContentWindow, .ended, at: 0.1)))
        XCTAssertNil(engine.ingest(event(.axLeaveButton, .ended, at: 0.2)), "the vetoer has not reported yet")
        XCTAssertNil(engine.ingest(event(.processAudioIsRunningInput, .live, at: 0.3)))
        XCTAssertEqual(engine.confirmRecording()?.verdict, .inMeeting(context: teamsContext))
    }

    /// An adapter with no process audio (the browser tab-title path, Webex, Slack) is not awaited:
    /// its reliable end still ends `.starting` on arrival.
    func test_an_adapter_without_process_audio_still_ends_starting_on_its_own_lead_END27() {
        let engine = PromotionEngine()
        engine.reset(awaitingVetoer: false)
        _ = engine.ingest(browserEvent(.browserTabTitle, .live, at: 0))
        XCTAssertEqual(
            engine.ingest(browserEvent(.browserTabTitle, .ended, at: 1))?.verdict,
            .ended(
                context: browserContext,
                reason: EndingReason(leadingSignal: "browser_tab_title_left_meet_pattern", confirmedBy: [])
            )
        )
    }

    /// A definitive app quit is never held for the vetoer.
    func test_an_app_quit_in_starting_is_not_held_for_the_vetoer_END27() {
        let engine = engineAwaitingVetoer()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        XCTAssertEqual(
            engine.ingest(event(.workspaceAppTerminated, .ended, at: 1))?.verdict,
            .ended(context: teamsContext, reason: EndingReason(leadingSignal: "workspace_app_terminated", confirmedBy: []))
        )
    }

    /// The flag belongs to one engagement: a plain `reset()` (the coordinator's disengage) clears it.
    func test_reset_clears_the_vetoer_wait_END27() {
        let engine = engineAwaitingVetoer()
        engine.reset()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        XCTAssertNotNil(engine.ingest(event(.shareableContentWindow, .ended, at: 1)))
    }

    /// The resumed recording's whole life, `20261112-174606`: the start race, the recorder arming,
    /// then the 15:50:34 leave opening a hold that the remembered window-gone pairs with.
    func test_the_resume_race_then_the_leave_opens_a_hold_END27() {
        let engine = engineAwaitingVetoer()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0.597))
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 0.614))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0.616))
        _ = engine.confirmRecording()
        XCTAssertEqual(
            engine.ingest(event(.processAudioIsRunningInput, .ended, at: 268.737))?.verdict,
            .endingProvisional(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "process_audio_is_running_input_false", confirmedBy: [])
            )
        )
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 268.823))
        XCTAssertEqual(
            engine.tick(at: Date(timeIntervalSince1970: 268.823 + PromotionEngine.defaultConfirmDwell))?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "process_audio_is_running_input_false",
                    confirmedBy: ["ax_leave_button_invalid", "shareable_content_window_gone"]
                )
            )
        )
    }

    // MARK: - END18: levels, not edges

    /// The 2026-11-12 Zoom order (`20261112-170131`): Leave invalid under a live mic opens a hold,
    /// the mic releases 4.1 s later, the window goes 1.6 s after that, and a teardown read of the
    /// Leave button passes as healthy 2.4 s after that. Before END18 that reading reverted the hold
    /// and nothing reopened it; now the revert is declined and the pair confirms on its dwell.
    func test_a_returning_leave_after_the_mic_and_window_ended_does_not_revert_END18() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: -100))
        _ = engine.ingest(event(.shareableContentWindow, .live, at: -100))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.axLeaveButton, .live, at: -99))
        XCTAssertEqual(
            engine.ingest(event(.axLeaveButton, .ended, at: 0))?.verdict,
            .endingProvisional(context: teamsContext, reason: EndingReason(leadingSignal: "ax_leave_button_invalid"))
        )
        XCTAssertNil(engine.ingest(event(.processAudioIsRunningInput, .ended, at: 4.136)))
        XCTAssertNil(engine.ingest(event(.shareableContentWindow, .ended, at: 5.781)))
        XCTAssertNil(engine.ingest(event(.axLeaveButton, .live, at: 8.158)), "the revert is declined")
        XCTAssertEqual(
            engine.takeDeclinedRevert(),
            PromotionEngine.DeclinedRevert(
                leading: .axLeaveButton, reading: .axLeaveButton, endedClasses: [.processAudioIsRunningInput]
            )
        )
        XCTAssertTrue(engine.hasPendingEndDeadline, "the hold is still open")
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 5.781 + PromotionEngine.defaultConfirmDwell - 0.1)))
        XCTAssertEqual(
            engine.tick(at: Date(timeIntervalSince1970: 5.781 + PromotionEngine.defaultConfirmDwell))?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "ax_leave_button_invalid",
                    confirmedBy: ["process_audio_is_running_input_false", "shareable_content_window_gone"]
                )
            )
        )
    }

    /// A vetoer reading live still reverts unconditionally (END14), whatever else ended.
    func test_a_vetoer_returning_still_reverts_whatever_else_ended_END18() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 10))
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 12))
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 13))
        XCTAssertEqual(
            engine.ingest(event(.processAudioIsRunningInput, .live, at: 15))?.verdict,
            .inMeeting(context: teamsContext)
        )
        XCTAssertNil(engine.takeDeclinedRevert())
    }

    /// END8 still holds where nothing else ended: the Leave button reading live reverts a
    /// window-gone hold on an app with no process audio.
    func test_a_same_class_reading_reverts_when_nothing_else_ended_END18() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 10))
        XCTAssertEqual(engine.ingest(event(.axLeaveButton, .live, at: 10.5))?.verdict, .inMeeting(context: teamsContext))
        XCTAssertNil(engine.takeDeclinedRevert())
    }

    /// D029: a Leave-led hold that sat past the lone dwell under a live mic survives a 2 s mic blip.
    func test_a_long_hold_under_a_live_mic_survives_a_mic_blip_END18() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 0))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 800)), "the live mic vetoes")
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 800))
        for t in stride(from: 800.25, through: 802, by: 0.25) {
            XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: t)), "no end at \(t) inside the blip")
        }
        XCTAssertEqual(
            engine.ingest(event(.processAudioIsRunningInput, .live, at: 802))?.verdict,
            .inMeeting(context: teamsContext)
        )
    }

    /// A mic released and kept released ends the hold on the pair, a dwell after the release, not
    /// the instant the lone dwell (counted from the first doubt) would have allowed.
    func test_a_released_mic_confirms_a_dwell_after_the_release_not_at_once_END18() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 800))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 800.25)), "the pre-END18 lone dwell ended here")
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 859.9)))
        XCTAssertNotNil(engine.tick(at: Date(timeIntervalSince1970: 860)))
    }

    /// A declined revert restarts the lone dwell: with no pair possible it runs from that reading.
    func test_a_declined_revert_restarts_the_lone_dwell_END18() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: -1))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 0))
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 1))
        XCTAssertNil(engine.ingest(event(.axLeaveButton, .live, at: 300)))
        XCTAssertNotNil(engine.takeDeclinedRevert())
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: PromotionEngine.defaultLoneDwell + 1)), "anchored at 300 now")
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 300 + PromotionEngine.defaultLoneDwell - 0.1)))
        XCTAssertEqual(
            engine.tick(at: Date(timeIntervalSince1970: 300 + PromotionEngine.defaultLoneDwell))?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "process_audio_is_running_input_false", confirmedBy: ["lone_dwell"])
            )
        )
    }

    /// F002's engine half: a window-gone hold whose Leave button reads live in `states` (the rescue's
    /// emit never came) does not confirm on the lone dwell while nothing of another class ended.
    func test_a_hold_contradicted_by_its_own_class_does_not_lone_confirm_END18() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 10))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 10 + PromotionEngine.defaultLoneDwell * 2)))
        XCTAssertTrue(engine.hasPendingEndDeadline)
    }

    /// The other direction is not a contradiction: a window still matching after the Leave button
    /// went invalid (Webex's title matcher keeps matching its main window after a call) does not
    /// hold a real end past the lone dwell.
    func test_a_window_still_matching_does_not_hold_a_leave_led_end_END18() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 10))
        XCTAssertEqual(
            engine.tick(at: Date(timeIntervalSince1970: 10 + PromotionEngine.defaultLoneDwell))?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "ax_leave_button_invalid", confirmedBy: ["lone_dwell"])
            )
        )
    }

    // MARK: - END21 amendment: the second signal may lead the release by up to 30 s

    private func holdEvidence(windowGoneAt window: TimeInterval?, leaveGoneAt leave: TimeInterval?, micReleasedAt release: TimeInterval) -> HoldEvidence? {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        var steps: [(TimeInterval, PrimarySignalKind)] = [(release, .processAudioIsRunningInput)]
        if let window { steps.append((window, .shareableContentWindow)) }
        if let leave { steps.append((leave, .axLeaveButton)) }
        for (t, kind) in steps.sorted(by: { $0.0 < $1.0 }) {
            _ = engine.ingest(event(kind, .ended, at: t))
        }
        return engine.holdEvidence
    }

    func test_a_window_gone_just_before_the_release_backs_it_END21() {
        XCTAssertEqual(holdEvidence(windowGoneAt: 999.7, leaveGoneAt: nil, micReleasedAt: 1000)?.callWindowBacksRelease, true)
    }

    func test_a_leave_gone_seconds_before_the_release_backs_it_END21() {
        XCTAssertEqual(holdEvidence(windowGoneAt: nil, leaveGoneAt: 989, micReleasedAt: 1000)?.callWindowBacksRelease, true)
    }

    func test_a_window_gone_after_the_release_backs_it_END21() {
        XCTAssertEqual(holdEvidence(windowGoneAt: 1005, leaveGoneAt: nil, micReleasedAt: 1000)?.callWindowBacksRelease, true)
    }

    /// A window that went long before (minimised a minute earlier) does not back a later release.
    func test_a_window_gone_well_before_the_release_does_not_back_it_END21() {
        XCTAssertEqual(holdEvidence(windowGoneAt: 940, leaveGoneAt: nil, micReleasedAt: 1000)?.callWindowBacksRelease, false)
    }

    // MARK: - END29: a mic-led hold does not lone-confirm against a live call UI

    /// A headphone switch whose mic return never reaches the engine: the Leave button and the
    /// window read live throughout and nothing else ends, so the hold neither pairs nor runs out.
    func test_a_missed_mic_return_does_not_lone_confirm_while_the_leave_reads_live_END29() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        XCTAssertNotNil(engine.ingest(event(.processAudioIsRunningInput, .ended, at: 900)))
        for held in [dwell, lone, lone + 1, lone * 2] {
            XCTAssertNil(
                engine.tick(at: Date(timeIntervalSince1970: 900 + held)),
                "\(held) s after the switch the call UI still reads live"
            )
        }
        XCTAssertTrue(engine.hasPendingEndDeadline, "the hold stays open; the idle backstop is the ceiling")
    }

    /// The same hold once the Leave button goes: the refusal lifts and the lone dwell decides as
    /// before, counted from the release.
    func test_the_leave_going_invalid_lifts_the_refusal_END29() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 900))
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 930))
        XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: 900 + lone - 1)))
        XCTAssertEqual(
            engine.tick(at: Date(timeIntervalSince1970: 900 + lone))?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "process_audio_is_running_input_false",
                    confirmedBy: ["ax_leave_button_invalid", "lone_dwell"]
                )
            )
        )
    }

    /// And a real leave, the Leave button and the window both gone, still pairs on the dwell.
    func test_a_real_leave_after_the_release_still_pairs_END29() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.ingest(event(.shareableContentWindow, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 900))
        _ = engine.ingest(event(.axLeaveButton, .ended, at: 900.3))
        _ = engine.ingest(event(.shareableContentWindow, .ended, at: 900.5))
        XCTAssertEqual(
            engine.tick(at: Date(timeIntervalSince1970: 900.3 + dwell))?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "process_audio_is_running_input_false",
                    confirmedBy: ["ax_leave_button_invalid", "shareable_content_window_gone"]
                )
            )
        )
    }

    /// The minimised-window variant (2026-11-16): the window minimised under a live mic is vetoed
    /// and remembered, a switch 300 s later loses its return, and the Leave button reads live.
    /// END14's amendment stops the stale pair at T0 + 360 s; END29 stops the lone dwell after it.
    func test_a_minimised_window_and_a_missed_mic_return_do_not_end_the_call_END29() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.axLeaveButton, .live, at: 0))
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        XCTAssertNil(engine.ingest(event(.shareableContentWindow, .ended, at: 100)))
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 400))
        for at in [460.0, 400 + lone, 400 + lone * 2] {
            XCTAssertNil(engine.tick(at: Date(timeIntervalSince1970: at)), "no end at \(at) s")
        }
    }

    /// An app whose Leave button was never read is not refused: nothing contradicts the release,
    /// so a lone mic drop still ends on the lone dwell (the spec's recommended "no").
    func test_without_a_leave_reading_the_lone_dwell_still_runs_END29() {
        let engine = PromotionEngine()
        _ = engine.ingest(event(.processAudioIsRunningInput, .live, at: 0))
        _ = engine.confirmRecording()
        _ = engine.ingest(event(.processAudioIsRunningInput, .ended, at: 900))
        XCTAssertNotNil(engine.tick(at: Date(timeIntervalSince1970: 900 + lone)))
    }
}
