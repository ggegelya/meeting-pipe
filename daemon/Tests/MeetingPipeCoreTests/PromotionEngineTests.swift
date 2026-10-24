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

    func test_evidence_class_groups_only_ax_leave_and_window_gone() {
        // END6/AUD-10: ONLY ax-leave + window-gone share a class (correlated). Every other
        // signal is its own class, so it still cross-corroborates exactly as before.
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
        XCTAssertNotEqual(
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

    /// The real end after a veto: Teams releases the mic, process audio leads, and the remembered
    /// window-gone pairs with it once both have dwelled.
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
        XCTAssertEqual(
            engine.tick(at: Date(timeIntervalSince1970: 600 + dwell))?.verdict,
            .ended(
                context: teamsContext,
                reason: EndingReason(
                    leadingSignal: "process_audio_is_running_input_false",
                    confirmedBy: ["ax_leave_button_invalid", "shareable_content_window_gone"]
                )
            )
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
}
