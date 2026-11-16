import XCTest
@testable import MeetingPipe

/// Locks in the post-extraction contract for `DetectionStateMachine`:
/// the typed transitions, the embedded cooldown facade, the prompt
/// timeout timer, and the idle-transition callback that the Coordinator
/// hooks for deferred config refreshes.
final class DetectionStateMachineTests: XCTestCase {

    private static let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Teams")

    // MARK: - Transitions

    func test_starts_idle_and_accepts_prompts() {
        let m = DetectionStateMachine()
        XCTAssertEqual(m.current, .idle)
        XCTAssertTrue(m.isAcceptingPrompts)
    }

    func test_setPrompting_blocks_further_prompts() {
        let m = DetectionStateMachine()
        m.setPrompting(source: Self.teams)
        if case .prompting(let s) = m.current {
            XCTAssertEqual(s, Self.teams)
        } else {
            XCTFail("expected .prompting, got \(m.current)")
        }
        XCTAssertFalse(m.isAcceptingPrompts)
    }

    func test_setRecording_and_setStopping_carry_payload() {
        let m = DetectionStateMachine()
        let url = URL(fileURLWithPath: "/tmp/x.wav")
        m.setRecording(file: url, source: Self.teams, summaryMode: .auto)
        if case .recording(let f, let s, let mode) = m.current {
            XCTAssertEqual(f, url)
            XCTAssertEqual(s, Self.teams)
            XCTAssertEqual(mode, .auto)
        } else {
            XCTFail("expected .recording, got \(m.current)")
        }
        m.setStopping(file: url, source: Self.teams, summaryMode: .auto)
        if case .stopping = m.current {} else {
            XCTFail("expected .stopping")
        }
    }

    // MARK: - Idle callback

    func test_setIdle_fires_onIdleTransition_each_time() {
        let m = DetectionStateMachine()
        var fired = 0
        m.onIdleTransition = { fired += 1 }
        m.setPrompting(source: Self.teams)
        XCTAssertEqual(fired, 0)
        m.setIdle()
        XCTAssertEqual(fired, 1)
        m.setPrompting(source: Self.teams)
        m.setIdle()
        XCTAssertEqual(fired, 2)
    }

    // MARK: - Abandon prompt (skip / prompt-timeout / force-stop-while-prompting)

    func test_abandonPrompt_returns_to_idle_and_cools_down_only_that_bundle() {
        let m = DetectionStateMachine()
        var idleFired = 0
        m.onIdleTransition = { idleFired += 1 }
        m.setPrompting(source: Self.teams)
        XCTAssertFalse(m.isAcceptingPrompts)

        m.abandonPrompt(source: Self.teams)

        // Back to idle so a meeting in *another* app is still detected. The old
        // `.suppressed` blocked all detection until a corroborated lifecycle end
        // that the Teams compact-window artifact never produced, wedging detection
        // for the rest of the meeting (the bug this regression guards).
        XCTAssertTrue(m.isAcceptingPrompts, "abandonPrompt returns to idle")
        // The idle hook fires so the Coordinator disengages the lifecycle adapter
        // (and its 1 Hz Leave-button poll), instead of leaking it.
        XCTAssertEqual(idleFired, 1)
        // Only the skipped bundle is cooled down; a different app is not.
        XCTAssertTrue(m.isCoolingDown(bundleID: Self.teams.bundleID, cooldownSec: 60))
        XCTAssertFalse(m.isCoolingDown(bundleID: "us.zoom.xos", cooldownSec: 60))
    }

    func test_abandonPrompt_cancels_the_pending_prompt_timeout() {
        let m = DetectionStateMachine()
        m.setPrompting(source: Self.teams)
        var fired = false
        m.startPromptTimeout(for: Self.teams, timeoutSec: 0.05) { fired = true }
        m.abandonPrompt(source: Self.teams)
        let exp = expectation(description: "wait past the scheduled fire")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(fired, "abandonPrompt cancels the timeout; the timer must not fire after it")
    }

    // MARK: - Cooldown facade

    func test_cooldown_facade_round_trips() {
        let m = DetectionStateMachine()
        XCTAssertFalse(m.isCoolingDown(bundleID: "us.zoom.xos", cooldownSec: 60))
        m.recordCooldownEnd(bundleID: "us.zoom.xos")
        XCTAssertTrue(m.isCoolingDown(bundleID: "us.zoom.xos", cooldownSec: 60))
        m.clearCooldown(bundleID: "us.zoom.xos")
        XCTAssertFalse(m.isCoolingDown(bundleID: "us.zoom.xos", cooldownSec: 60))
    }

    // MARK: - Skip-latch facade

    /// A settable clock for the span and timeout tests.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 2_000_000)
        func advance(_ sec: TimeInterval) { now = now.addingTimeInterval(sec) }
    }

    private static let teamsLive = SkippedMeetingLatch.Reading(processAudio: true)
    private static let teamsBothAbsent = SkippedMeetingLatch.Reading(processAudio: false)
    private static let teamsUnknown = SkippedMeetingLatch.Reading(processAudio: nil)

    func test_skip_latch_facade_round_trips() {
        let m = DetectionStateMachine()
        XCTAssertFalse(m.isSkipLatched(bundleID: Self.teams.bundleID))
        m.armSkipLatch(source: Self.teams)
        XCTAssertTrue(m.isSkipLatched(bundleID: Self.teams.bundleID))
        // Per-bundle: arming Teams doesn't latch Zoom.
        XCTAssertFalse(m.isSkipLatched(bundleID: "us.zoom.xos"))
    }

    func test_a_scan_reading_never_latches_a_bundle_nobody_skipped() {
        let m = DetectionStateMachine()
        // A routine discovery sighting of a never-skipped meeting must not latch it.
        m.noteScanReadings([Self.teams.bundleID: Self.teamsLive])
        XCTAssertFalse(m.isPromptHeld(bundleID: Self.teams.bundleID))
    }

    // MARK: - DET9: the grace is measured in discovery polls, not wall-clock taste

    /// The regression in one assert. The grace was a literal 15 justified in its own comment as
    /// "5x the MeetingDiscoveryWatcher 3 s poll"; PERF6 backed the quiet poll off to 12 s and
    /// nothing failed, so the justification decayed to 1.25 polls in silence. Derived from the
    /// cadence, it moves with it.
    func test_skipLatchGrace_is_derived_from_the_live_discovery_poll() {
        XCTAssertEqual(
            DetectionStateMachine.skipLatchGraceSec,
            DiscoveryScanCadence.discoveryDefault.idle * DetectionStateMachine.skipLatchGracePolls,
            accuracy: 0.001,
            "the grace has to be a multiple of the poll it exists to bridge, or the next cadence change re-opens DET9"
        )
        XCTAssertEqual(DetectionStateMachine.skipLatchGrace(idlePollSec: 3), 15, accuracy: 0.001)
        XCTAssertEqual(DetectionStateMachine.skipLatchGrace(idlePollSec: 12), 60, accuracy: 0.001)
    }

    /// DET9's 2026-07-27 shape, re-read for DET18: a skipped Teams call went 48 s between
    /// confident winners while plainly live. With the microphone reading true the span holds
    /// however long the controls stay dark (D016, D067 closed in the same change).
    func test_skipLatch_holds_while_the_microphone_reads_true_with_no_confident_winner() {
        let clock = Clock()
        let m = DetectionStateMachine(clock: { clock.now })
        m.armSkipLatch(source: Self.teams)
        for _ in 1...20 {
            clock.advance(DiscoveryScanCadence.discoveryDefault.idle)
            m.noteScanReadings([Self.teams.bundleID: Self.teamsLive])
        }
        XCTAssertTrue(m.isSkipLatched(bundleID: Self.teams.bundleID), "four minutes of a live microphone is one call")
    }

    /// An unresolved microphone read is ignorance, not absence (DET8 measured a client
    /// re-registering mid-call). The hold rides it out for DET9's measured grace, then lapses.
    func test_skipLatch_rides_out_unknown_reads_for_the_grace_then_lapses() {
        let clock = Clock()
        let m = DetectionStateMachine(clock: { clock.now })
        m.armSkipLatch(source: Self.teams)
        for _ in 1...4 {
            clock.advance(DiscoveryScanCadence.discoveryDefault.idle)
            m.noteScanReadings([Self.teams.bundleID: Self.teamsUnknown])
            XCTAssertTrue(m.isSkipLatched(bundleID: Self.teams.bundleID), "an unknown read is not an end")
        }
        clock.advance(DiscoveryScanCadence.discoveryDefault.idle)
        let ended = m.noteScanReadings([Self.teams.bundleID: Self.teamsUnknown])
        XCTAssertFalse(m.isSkipLatched(bundleID: Self.teams.bundleID))
        XCTAssertEqual(ended.map(\.source), [Self.teams])
    }

    /// Time the scans were gated (a 30 s prompt for another app, a recording) is not silence:
    /// one gap adds at most one idle poll.
    func test_time_outside_idle_does_not_count_against_the_hold() {
        let clock = Clock()
        let m = DetectionStateMachine(clock: { clock.now })
        m.armSkipLatch(source: Self.teams)
        clock.advance(600)
        m.noteScanReadings([Self.teams.bundleID: Self.teamsUnknown])
        XCTAssertTrue(m.isSkipLatched(bundleID: Self.teams.bundleID))
    }

    /// Acceptance: an explicit Skip still latches, and the latch clears when the span-end input
    /// fires (the microphone reads off and the app is not the scan's winner), so a second
    /// same-bundle sighting after it prompts. The cooldown the skip armed goes with it.
    func test_skipLatch_clears_on_a_both_absent_poll_and_takes_the_cooldown_with_it() {
        let m = DetectionStateMachine()
        m.setPrompting(source: Self.teams)
        m.abandonPrompt(source: Self.teams)
        XCTAssertTrue(m.isSkipLatched(bundleID: Self.teams.bundleID))
        m.noteScanReadings([Self.teams.bundleID: Self.teamsBothAbsent])
        XCTAssertTrue(m.isSkipLatched(bundleID: Self.teams.bundleID), "one absent read is the poll of grace")
        m.noteScanReadings([Self.teams.bundleID: Self.teamsBothAbsent])
        XCTAssertFalse(m.isSkipLatched(bundleID: Self.teams.bundleID))
        XCTAssertFalse(m.isCoolingDown(bundleID: Self.teams.bundleID, cooldownSec: 60),
                       "the span ended, so the next call in the same app prompts normally")
    }

    /// A blip of the microphone read while the call's controls are still found is not an end.
    func test_a_microphone_blip_with_a_confident_winner_keeps_the_hold() {
        let m = DetectionStateMachine()
        m.armSkipLatch(source: Self.teams)
        m.noteScanReadings([Self.teams.bundleID: .init(processAudio: false, isWinner: true)])
        XCTAssertTrue(m.isSkipLatched(bundleID: Self.teams.bundleID))
    }

    /// DET8 measured a client re-registering mid-call, and DET9 a stretch with the controls hidden:
    /// one off read in that stretch, with a live read after it, is not an end.
    func test_a_single_absent_read_followed_by_a_live_one_keeps_the_hold() {
        let m = DetectionStateMachine()
        m.armSkipLatch(source: Self.teams)
        m.noteScanReadings([Self.teams.bundleID: Self.teamsBothAbsent])
        m.noteScanReadings([Self.teams.bundleID: Self.teamsLive])
        m.noteScanReadings([Self.teams.bundleID: Self.teamsBothAbsent])
        XCTAssertTrue(m.isSkipLatched(bundleID: Self.teams.bundleID), "the streak resets on a live read")
    }

    /// A Teams that is not enumerated at all has quit.
    func test_a_native_missing_from_the_scan_ends_its_span() {
        let m = DetectionStateMachine()
        m.armSkipLatch(source: Self.teams)
        m.noteScanReadings([:])
        XCTAssertFalse(m.isSkipLatched(bundleID: Self.teams.bundleID))
    }

    /// A browser's span is its meeting title: a page retitling itself is not an end (D005), so
    /// only DET9's grace of ignorance lapses it.
    func test_a_browser_hold_lives_on_its_title_and_has_no_positive_end() {
        let clock = Clock()
        let m = DetectionStateMachine(clock: { clock.now })
        let chrome = AppSource(bundleID: "com.google.Chrome", displayName: "Chrome", kind: .browser)
        m.armSkipLatch(source: chrome)
        clock.advance(12)
        m.noteScanReadings([:])
        XCTAssertTrue(m.isSkipLatched(bundleID: chrome.bundleID))
        clock.advance(12)
        m.noteScanReadings([chrome.bundleID: .init(titleMatch: true)])
        for _ in 1...4 {
            clock.advance(12)
            m.noteScanReadings([:])
        }
        XCTAssertTrue(m.isSkipLatched(bundleID: chrome.bundleID))
        clock.advance(12)
        m.noteScanReadings([:])
        XCTAssertFalse(m.isSkipLatched(bundleID: chrome.bundleID))
    }

    /// DET1 mic-tier sources are never scanner candidates; they live on the mic-busy span.
    func test_a_mic_tier_hold_lives_on_the_mic_busy_span() {
        let m = DetectionStateMachine()
        let slack = AppSource(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack")
        m.armSkipLatch(source: slack, liveness: .micBusy)
        m.noteScanReadings([:])
        XCTAssertTrue(m.isSkipLatched(bundleID: slack.bundleID), "a scan says nothing about a mic-tier call")
        m.noteMicBusy(bundleID: slack.bundleID)
        XCTAssertTrue(m.isSkipLatched(bundleID: slack.bundleID))
        m.noteMicBusy(bundleID: nil)
        XCTAssertFalse(m.isSkipLatched(bundleID: slack.bundleID))
    }

    // MARK: - DET18: the timeout's offer

    /// Acceptance: a prompt timeout with action `skip` leaves `isCoolingDown` and `isSkipLatched`
    /// false for the bundle and keeps the source as the attachable candidate.
    func test_a_timeout_offer_arms_no_cooldown_and_no_latch_and_keeps_the_source() {
        let m = DetectionStateMachine()
        m.setPrompting(source: Self.teams)
        m.offerPrompt(source: Self.teams)
        XCTAssertEqual(m.current, .idle)
        XCTAssertFalse(m.isCoolingDown(bundleID: Self.teams.bundleID, cooldownSec: 60))
        XCTAssertFalse(m.isSkipLatched(bundleID: Self.teams.bundleID))
        XCTAssertTrue(m.isOffered(bundleID: Self.teams.bundleID))
        XCTAssertEqual(m.liveSuppressedCandidate(), Self.teams)
    }

    func test_an_offer_goes_with_its_span_and_takes_the_candidate_with_it() {
        let m = DetectionStateMachine()
        m.setPrompting(source: Self.teams)
        m.offerPrompt(source: Self.teams)
        m.noteScanReadings([Self.teams.bundleID: Self.teamsBothAbsent])
        let ended = m.noteScanReadings([Self.teams.bundleID: Self.teamsBothAbsent])
        XCTAssertEqual(ended.first?.mode, .offered)
        XCTAssertFalse(m.isPromptHeld(bundleID: Self.teams.bundleID))
        XCTAssertNil(m.liveSuppressedCandidate())
    }

    func test_clearSuppression_drops_an_offer() {
        let m = DetectionStateMachine()
        m.setPrompting(source: Self.teams)
        m.offerPrompt(source: Self.teams)
        m.clearSuppression(bundleID: Self.teams.bundleID)
        XCTAssertFalse(m.isPromptHeld(bundleID: Self.teams.bundleID))
        XCTAssertNil(m.liveSuppressedCandidate())
    }

    // MARK: - DET18: hover pauses the timer that acts

    private final class ManualScheduler {
        var pending: [(delay: TimeInterval, action: () -> Void, cancelled: Bool)] = []
        func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
            pending.append((delay, action, false))
            let index = pending.count - 1
            return { [weak self] in self?.pending[index].cancelled = true }
        }
        var live: [(delay: TimeInterval, action: () -> Void, cancelled: Bool)] { pending.filter { !$0.cancelled } }
    }

    /// Acceptance: hovering at 20 s and leaving at 50 s fires the timeout at 60 s, not 30 s.
    func test_hover_pauses_the_acting_timer_and_carries_the_remaining_time() {
        let clock = Clock()
        let scheduler = ManualScheduler()
        let m = DetectionStateMachine(scheduler: scheduler.schedule, clock: { clock.now })
        let startedAt = clock.now
        m.setPrompting(source: Self.teams)
        var firedAt: Date?
        m.startPromptTimeout(for: Self.teams, timeoutSec: 30) { firedAt = clock.now }
        XCTAssertEqual(scheduler.live.map(\.delay), [30])

        clock.advance(20)
        m.pausePromptTimeout()
        XCTAssertEqual(scheduler.live.map(\.delay), [DetectionStateMachine.maxPromptPauseSec],
                       "the 30 s timer must not survive the hover; only the pause's cap is armed")
        XCTAssertTrue(m.isPromptTimeoutPaused)

        clock.advance(30)
        m.resumePromptTimeout()
        XCTAssertEqual(scheduler.live.map(\.delay), [10], "10 s were left when the pointer arrived")

        clock.advance(10)
        scheduler.live.first?.action()
        let fired = expectation(description: "the timeout acts")
        DispatchQueue.main.async { fired.fulfill() }
        wait(for: [fired], timeout: 1)
        XCTAssertEqual(firedAt.map { $0.timeIntervalSince(startedAt) }, 60)
    }

    /// Pause and resume are idempotent, so hover and an open menu can overlap.
    func test_pause_and_resume_are_idempotent() {
        let clock = Clock()
        let scheduler = ManualScheduler()
        let m = DetectionStateMachine(scheduler: scheduler.schedule, clock: { clock.now })
        m.setPrompting(source: Self.teams)
        m.startPromptTimeout(for: Self.teams, timeoutSec: 30) {}
        m.pausePromptTimeout()
        m.pausePromptTimeout()
        m.resumePromptTimeout()
        m.resumePromptTimeout()
        XCTAssertEqual(scheduler.live.map(\.delay), [30])
    }

    /// A pause cannot hold the prompt up forever: the cap resumes it.
    func test_a_pause_is_capped() {
        let clock = Clock()
        let scheduler = ManualScheduler()
        let m = DetectionStateMachine(scheduler: scheduler.schedule, clock: { clock.now })
        m.setPrompting(source: Self.teams)
        m.startPromptTimeout(for: Self.teams, timeoutSec: 30) {}
        clock.advance(5)
        m.pausePromptTimeout()
        clock.advance(DetectionStateMachine.maxPromptPauseSec)
        scheduler.live.first?.action()
        let resumed = expectation(description: "the cap resumes")
        DispatchQueue.main.async { resumed.fulfill() }
        wait(for: [resumed], timeout: 1)
        XCTAssertFalse(m.isPromptTimeoutPaused)
        XCTAssertEqual(scheduler.live.map(\.delay), [25])
    }

    /// A fire already queued when the timer was paused in the same turn does not act.
    func test_a_fire_queued_before_a_pause_does_not_act() {
        let scheduler = ManualScheduler()
        let m = DetectionStateMachine(scheduler: scheduler.schedule)
        m.setPrompting(source: Self.teams)
        var fired = false
        m.startPromptTimeout(for: Self.teams, timeoutSec: 30) { fired = true }
        let fire = scheduler.live.first?.action
        fire?()
        m.pausePromptTimeout()
        let drained = expectation(description: "main drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertFalse(fired)
    }

    func test_abandonPrompt_arms_both_the_cooldown_and_the_skip_latch() {
        let m = DetectionStateMachine()
        m.setPrompting(source: Self.teams)
        m.abandonPrompt(source: Self.teams)
        // The fixed cooldown guards the immediate post-skip window...
        XCTAssertTrue(m.isCoolingDown(bundleID: Self.teams.bundleID, cooldownSec: 60))
        // ...and the liveness latch holds the prompt off for the rest of the meeting, so the
        // 60 s cooldown lapsing mid-call can no longer re-prompt the skipped meeting.
        XCTAssertTrue(m.isSkipLatched(bundleID: Self.teams.bundleID))
    }

    func test_clearSuppression_drops_both_the_cooldown_and_the_skip_latch() {
        let m = DetectionStateMachine()
        m.recordCooldownEnd(bundleID: Self.teams.bundleID)
        m.armSkipLatch(source: Self.teams)
        // Explicit "record now" (manual hotkey / "Always for {App}") wipes every suppression.
        m.clearSuppression(bundleID: Self.teams.bundleID)
        XCTAssertFalse(m.isCoolingDown(bundleID: Self.teams.bundleID, cooldownSec: 60))
        XCTAssertFalse(m.isSkipLatched(bundleID: Self.teams.bundleID))
    }

    // MARK: - DET7: the suppressed-meeting candidate

    func test_suppressed_candidate_is_returned_while_the_latch_holds() {
        let m = DetectionStateMachine()
        m.armSkipLatch(source: Self.teams)
        m.noteSuppressedCandidate(Self.teams, origin: .skipLatch)
        XCTAssertEqual(m.liveSuppressedCandidate(), Self.teams)
    }

    func test_suppressed_candidate_lapses_with_its_latch_and_is_dropped() {
        let m = DetectionStateMachine()
        m.armSkipLatch(source: Self.teams)
        m.noteSuppressedCandidate(Self.teams, origin: .skipLatch)
        // DET18: the call's span ended: the meeting is over and the candidate is not something a
        // start should attribute itself to.
        m.noteScanReadings([Self.teams.bundleID: Self.teamsBothAbsent])
        m.noteScanReadings([Self.teams.bundleID: Self.teamsBothAbsent])
        XCTAssertNil(m.liveSuppressedCandidate())
    }

    func test_clearSuppression_also_drops_the_candidate() {
        let m = DetectionStateMachine()
        m.armSkipLatch(source: Self.teams)
        m.noteSuppressedCandidate(Self.teams, origin: .skipLatch)
        // An explicit start consumed it; leaving it cached would let a *second* start
        // minutes later re-attach to a meeting nothing is watching any more.
        m.clearSuppression(bundleID: Self.teams.bundleID)
        XCTAssertNil(m.liveSuppressedCandidate())
    }

    func test_clearSuppression_for_another_bundle_leaves_the_candidate() {
        let m = DetectionStateMachine()
        m.armSkipLatch(source: Self.teams)
        m.noteSuppressedCandidate(Self.teams, origin: .skipLatch)
        m.clearSuppression(bundleID: "us.zoom.xos")
        XCTAssertEqual(m.liveSuppressedCandidate(), Self.teams,
                       "suppression is per-bundle; clearing Zoom must not forget the Teams call")
    }

    // MARK: - DET13: the cooldown-suppressed candidate

    /// The 2026-08-04 incident in one arrangement. A recording for this bundle just ended, so the
    /// re-prompt cooldown is armed and the discovery sighting of the call the owner joined 22 s
    /// later lands in that branch instead of prompting. The sighting is still proof of what is
    /// running, and a manual Record during that minute has to be able to attach to it: before
    /// DET13 the branch dropped it, the start fell through to `beginRecording(source: nil)`, and
    /// the recording carried no app identity and therefore no AX end anchor.
    func test_candidate_noted_during_a_cooldown_is_attachable() {
        let m = DetectionStateMachine()
        m.recordCooldownEnd(bundleID: Self.teams.bundleID)
        XCTAssertTrue(m.isCoolingDown(bundleID: Self.teams.bundleID, cooldownSec: 60))
        // Nobody dismissed a prompt here, the previous meeting simply ended, so there is no skip
        // latch for the candidate to ride and DET7's gate alone would return nil.
        XCTAssertFalse(m.isSkipLatched(bundleID: Self.teams.bundleID))

        m.noteSuppressedCandidate(Self.teams, origin: .cooldown)

        XCTAssertEqual(m.liveSuppressedCandidate(), Self.teams,
                       "a cooling-down sighting is the only handle on the call the owner just joined")
    }

    /// The other half, and the reason the lifetime is bounded at all: a candidate that never
    /// expires lets a manual start minutes later attribute itself to a call that has ended, which
    /// is the misattribution DET9's comment names.
    func test_cooldown_candidate_lapses_once_discovery_stops_seeing_it() {
        let m = DetectionStateMachine()
        m.recordCooldownEnd(bundleID: Self.teams.bundleID)
        let seenAt = Date()
        m.noteSuppressedCandidate(Self.teams, origin: .cooldown, at: seenAt)
        XCTAssertEqual(m.liveSuppressedCandidate(now: seenAt), Self.teams)

        let afterGrace = seenAt.addingTimeInterval(DetectionStateMachine.cooldownCandidateGraceSec + 1)
        XCTAssertNil(m.liveSuppressedCandidate(now: afterGrace))
        // And the drop is durable, not just a filtered read, so nothing runs a timer to expire it.
        XCTAssertNil(m.liveSuppressedCandidate())
    }

    /// DET9's rule applied to the second latch, which is the bug this task must not repeat. The
    /// grace is the poll it exists to bridge rather than a number: DET9's was a hardcoded 15
    /// justified as "5x the 3 s poll", and it silently decayed to 1.25 polls when PERF6 moved the
    /// quiet poll to 12 s. The skip latch's width is the one that has to clear the measured
    /// control blackout (48 s on 2026-07-27, 21-33 s in END9), because that blackout is a fact
    /// about calls the latch has already proven live.
    func test_suppressedCandidateGrace_is_derived_from_the_live_discovery_poll() {
        XCTAssertEqual(
            DetectionStateMachine.suppressedCandidateGraceSec,
            DiscoveryScanCadence.discoveryDefault.idle * DetectionStateMachine.skipLatchGracePolls,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DetectionStateMachine.suppressedCandidateGraceSec,
            DetectionStateMachine.skipLatchGraceSec,
            accuracy: 0.001,
            "the skip-latch candidate rides its latch, so the two must not drift apart"
        )
    }

    // MARK: - DET14: the cooldown candidate gets a shorter life than the latched one

    /// The same DET9 rule, applied to the grace DET14 split off. It is derived from the live
    /// cadence rather than written as a number, so the next `DiscoveryScanCadence` change carries
    /// it instead of silently decaying the way DET9's hardcoded 15 did.
    func test_cooldownCandidateGrace_is_derived_from_the_live_discovery_poll() {
        XCTAssertEqual(
            DetectionStateMachine.cooldownCandidateGraceSec,
            DiscoveryScanCadence.discoveryDefault.idle * DetectionStateMachine.cooldownCandidateGracePolls,
            accuracy: 0.001
        )
    }

    /// The asymmetry is the point, so it is pinned rather than left to the two derivations
    /// happening to differ. A skip-latched call is known live; a cooling-down one is not, and the
    /// cooldown window opens on an *end*, which is exactly when a call may have just finished.
    func test_the_cooldown_grace_is_shorter_than_the_latched_one() {
        XCTAssertLessThan(
            DetectionStateMachine.cooldownCandidateGraceSec,
            DetectionStateMachine.suppressedCandidateGraceSec,
            "a cooling-down sighting carries weaker evidence than a latched one and must not outlive it"
        )
        // Still wide enough to bridge one ordinary quiet poll, which is the DET9 bug: a single
        // scan finding no confident winner must not drop a call that is still up.
        XCTAssertGreaterThan(
            DetectionStateMachine.cooldownCandidateGraceSec,
            DiscoveryScanCadence.discoveryDefault.idle,
            "one quiet poll finding no confident winner must not be enough to drop it"
        )
    }

    /// The regression this split exists for. The owner's Teams call ended on 2026-08-19 and the
    /// menu kept offering "Record this Microsoft Teams meeting"; the ceiling was about two
    /// minutes, since the cooldown branch refreshes the sighting for 60 s after the end and the
    /// candidate then lived a further 60 s from that last write. At the old grace this read is
    /// still the live call; at DET14's it is nil.
    func test_a_cooldown_candidate_is_gone_well_before_the_old_grace() {
        let m = DetectionStateMachine()
        m.recordCooldownEnd(bundleID: Self.teams.bundleID)
        let seenAt = Date()
        m.noteSuppressedCandidate(Self.teams, origin: .cooldown, at: seenAt)

        let atOldGrace = seenAt.addingTimeInterval(DetectionStateMachine.suppressedCandidateGraceSec - 1)
        XCTAssertNil(
            m.liveSuppressedCandidate(now: atOldGrace),
            "this is the read that kept the stale row on the menu"
        )
    }

    /// The half DET14 must not break: inside its own grace the cooling-down sighting is still the
    /// handle a manual start attaches to, which is the whole of DET13.
    func test_a_cooldown_candidate_is_still_attachable_inside_its_own_grace() {
        let m = DetectionStateMachine()
        m.recordCooldownEnd(bundleID: Self.teams.bundleID)
        let seenAt = Date()
        m.noteSuppressedCandidate(Self.teams, origin: .cooldown, at: seenAt)

        let inside = seenAt.addingTimeInterval(DetectionStateMachine.cooldownCandidateGraceSec - 1)
        XCTAssertEqual(m.liveSuppressedCandidate(now: inside), Self.teams)
    }

    /// A latched candidate keeps DET7's full width, so the split cannot be read as a general
    /// tightening. Past the cooldown grace and well inside the latch's, this is still attachable.
    func test_a_latched_candidate_keeps_the_full_grace() {
        let m = DetectionStateMachine()
        m.armSkipLatch(source: Self.teams)
        let seenAt = Date()
        m.noteSuppressedCandidate(Self.teams, origin: .skipLatch, at: seenAt)

        let pastCooldownGrace = seenAt.addingTimeInterval(DetectionStateMachine.cooldownCandidateGraceSec + 1)
        XCTAssertEqual(
            m.liveSuppressedCandidate(now: pastCooldownGrace),
            Self.teams,
            "the latch is the stronger liveness oracle and DET14 does not touch it"
        )
    }

    // MARK: - DET14: a confirmed end drops the candidate at once

    /// The grace is an upper bound on ignorance. A lifecycle end is the positive signal it stands
    /// in for, so it should not have to be waited out.
    func test_a_confirmed_end_drops_the_candidate_without_waiting_out_the_grace() {
        let m = DetectionStateMachine()
        m.recordCooldownEnd(bundleID: Self.teams.bundleID)
        m.noteSuppressedCandidate(Self.teams, origin: .cooldown)
        XCTAssertEqual(m.liveSuppressedCandidate(), Self.teams)

        m.noteMeetingEnded(bundleID: Self.teams.bundleID)
        XCTAssertNil(m.liveSuppressedCandidate())
    }

    /// It drops a latched candidate too. The latch is evidence the call was live, not evidence it
    /// still is, and the end is newer information than the sighting that armed it.
    func test_a_confirmed_end_drops_a_latched_candidate_too() {
        let m = DetectionStateMachine()
        m.armSkipLatch(source: Self.teams)
        m.noteSuppressedCandidate(Self.teams, origin: .skipLatch)
        XCTAssertEqual(m.liveSuppressedCandidate(), Self.teams)

        m.noteMeetingEnded(bundleID: Self.teams.bundleID)
        XCTAssertNil(m.liveSuppressedCandidate())
    }

    /// Per-bundle, like every other suppression read here: a Zoom call ending says nothing about
    /// the Teams one the owner is still in.
    func test_an_end_for_another_bundle_leaves_the_candidate() {
        let m = DetectionStateMachine()
        m.recordCooldownEnd(bundleID: Self.teams.bundleID)
        m.noteSuppressedCandidate(Self.teams, origin: .cooldown)

        m.noteMeetingEnded(bundleID: "us.zoom.xos")
        XCTAssertEqual(m.liveSuppressedCandidate(), Self.teams)
    }

    /// What keeps this clear of DET13's false-end rescue: the clear is not sticky, so the next
    /// confident sighting writes the candidate straight back. Measured on 2026-08-19, a
    /// provisional end fired at 10:40:19, the recording stopped at 10:40:22, discovery had
    /// re-populated the candidate by 10:40:24, and the owner restarted by hand at 10:40:26.
    func test_a_false_end_is_undone_by_the_next_sighting() {
        let m = DetectionStateMachine()
        m.recordCooldownEnd(bundleID: Self.teams.bundleID)
        m.noteSuppressedCandidate(Self.teams, origin: .cooldown)
        m.noteMeetingEnded(bundleID: Self.teams.bundleID)
        XCTAssertNil(m.liveSuppressedCandidate())

        m.noteSuppressedCandidate(Self.teams, origin: .cooldown)
        XCTAssertEqual(
            m.liveSuppressedCandidate(),
            Self.teams,
            "the call was still up, so the very next poll has to make it attachable again"
        )
    }

    /// Both suppression branches write the same slot now, so this pins the half DET13 must not
    /// touch: retaining a cooling-down sighting arms no skip latch, so once the 60 s cooldown
    /// lapses the meeting prompts normally. Arming one here would swallow the call for its whole
    /// lifetime, which is a missed recording rather than the missed prompt DET13 fixes.
    func test_retaining_a_cooldown_candidate_arms_no_skip_latch() {
        let m = DetectionStateMachine()
        m.recordCooldownEnd(bundleID: Self.teams.bundleID)
        m.noteSuppressedCandidate(Self.teams, origin: .cooldown)
        XCTAssertFalse(m.isSkipLatched(bundleID: Self.teams.bundleID))
    }

    // MARK: - Pending config refresh

    func test_pending_refresh_is_idempotent_and_idle_gated() {
        let m = DetectionStateMachine()
        XCTAssertFalse(m.consumePendingConfigRefreshIfIdle())
        m.markConfigRefreshPending()
        // Not idle yet — mid-recording — refresh stays pending.
        m.setRecording(
            file: URL(fileURLWithPath: "/tmp/x.wav"),
            source: Self.teams,
            summaryMode: .auto
        )
        XCTAssertFalse(m.consumePendingConfigRefreshIfIdle())
        // Back to idle — consumes once.
        m.setIdle()
        XCTAssertTrue(m.consumePendingConfigRefreshIfIdle())
        // Already consumed — repeat call returns false.
        XCTAssertFalse(m.consumePendingConfigRefreshIfIdle())
    }

    // MARK: - Prompt timeout

    func test_prompt_timeout_fires_only_when_still_prompting_same_source() {
        let m = DetectionStateMachine()
        m.setPrompting(source: Self.teams)
        let exp = expectation(description: "timeout fires")
        var fired = false
        m.startPromptTimeout(for: Self.teams, timeoutSec: 0.05) {
            fired = true
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        XCTAssertTrue(fired)
    }

    func test_prompt_timeout_cancelled_does_not_fire() {
        let m = DetectionStateMachine()
        m.setPrompting(source: Self.teams)
        var fired = false
        m.startPromptTimeout(for: Self.teams, timeoutSec: 0.05) { fired = true }
        m.cancelPromptTimeout()
        // Wait a hair past the scheduled fire to confirm it's been cancelled.
        let exp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(fired)
    }

    func test_prompt_timeout_skipped_when_state_changed() {
        let m = DetectionStateMachine()
        m.setPrompting(source: Self.teams)
        var fired = false
        m.startPromptTimeout(for: Self.teams, timeoutSec: 0.05) { fired = true }
        m.setIdle()
        let exp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(fired, "Timer fired but state had left .prompting")
    }

    // MARK: - Label helper

    func test_label_is_stable_for_jsonl_events() {
        XCTAssertEqual(DetectionStateMachine.label(.idle), "idle")
        XCTAssertEqual(DetectionStateMachine.label(.prompting(source: Self.teams)), "prompting")
        XCTAssertEqual(DetectionStateMachine.label(.suppressed(source: Self.teams)), "suppressed")
        XCTAssertEqual(
            DetectionStateMachine.label(.recording(
                file: URL(fileURLWithPath: "/tmp/x.wav"),
                source: Self.teams,
                summaryMode: .auto
            )),
            "recording"
        )
        XCTAssertEqual(
            DetectionStateMachine.label(.stopping(
                file: URL(fileURLWithPath: "/tmp/x.wav"),
                source: Self.teams,
                summaryMode: .auto
            )),
            "stopping"
        )
    }
}
