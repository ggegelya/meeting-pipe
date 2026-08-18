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

    func test_skip_latch_facade_round_trips() {
        let m = DetectionStateMachine()
        XCTAssertFalse(m.isSkipLatched(bundleID: Self.teams.bundleID))
        m.armSkipLatch(bundleID: Self.teams.bundleID)
        XCTAssertTrue(m.isSkipLatched(bundleID: Self.teams.bundleID))
        // Per-bundle: arming Teams doesn't latch Zoom.
        XCTAssertFalse(m.isSkipLatched(bundleID: "us.zoom.xos"))
    }

    func test_refreshSkipLatch_is_noop_when_unarmed() {
        let m = DetectionStateMachine()
        // A routine discovery sighting of a never-skipped meeting must not latch it.
        m.refreshSkipLatch(bundleID: Self.teams.bundleID)
        XCTAssertFalse(m.isSkipLatched(bundleID: Self.teams.bundleID))
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
        // The old constant was the right answer to the old poll, which is exactly why a literal
        // was the wrong shape: 15 was never wrong, it just stopped being 5 polls.
        XCTAssertEqual(DetectionStateMachine.skipLatchGrace(idlePollSec: 3), 15, accuracy: 0.001)
        XCTAssertEqual(DetectionStateMachine.skipLatchGrace(idlePollSec: 12), 60, accuracy: 0.001)
    }

    /// Drive the latch at the *idle* cadence, one poll at a time, with every scan finding no
    /// confident winner. That is the 2026-07-27 shape from the owner's own log: a skipped Teams
    /// call went 48 s between confident winners while it was plainly still running, because the
    /// AX control walk found no Leave, Mute or toolbar the whole time (Teams' compact /
    /// backgrounded call UI). Nothing refreshes the latch across any of these polls and it has to
    /// hold anyway, or the prompt re-opens over the live meeting and the menu bar's
    /// `Suppressed (<app>)` label - DET7's only handle on the still-running call - collapses with it.
    func test_skipLatch_survives_a_stretch_of_polls_that_find_no_confident_winner() {
        let m = DetectionStateMachine()
        let idle = DiscoveryScanCadence.discoveryDefault.idle
        let skippedAt = Date()
        m.armSkipLatch(bundleID: Self.teams.bundleID)

        for missedPolls in 1...4 {
            let elapsed = idle * Double(missedPolls)
            XCTAssertTrue(
                m.isSkipLatched(bundleID: Self.teams.bundleID, now: skippedAt.addingTimeInterval(elapsed)),
                "the latch lapsed \(elapsed) s in (\(missedPolls) missed polls), mid-call"
            )
        }
    }

    /// The other half, and the reason the grace cannot simply be made enormous: a latch that never
    /// lapses silently swallows every later meeting in the same app, which is a missed recording
    /// rather than a spurious prompt.
    func test_skipLatch_still_lapses_once_discovery_has_stopped_seeing_the_meeting() {
        let m = DetectionStateMachine()
        let skippedAt = Date()
        m.armSkipLatch(bundleID: Self.teams.bundleID)
        XCTAssertFalse(
            m.isSkipLatched(
                bundleID: Self.teams.bundleID,
                now: skippedAt.addingTimeInterval(DetectionStateMachine.skipLatchGraceSec + 1)
            )
        )
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
        m.armSkipLatch(bundleID: Self.teams.bundleID)
        // Explicit "record now" (manual hotkey / "Always for {App}") wipes every suppression.
        m.clearSuppression(bundleID: Self.teams.bundleID)
        XCTAssertFalse(m.isCoolingDown(bundleID: Self.teams.bundleID, cooldownSec: 60))
        XCTAssertFalse(m.isSkipLatched(bundleID: Self.teams.bundleID))
    }

    // MARK: - DET7: the suppressed-meeting candidate

    func test_suppressed_candidate_is_returned_while_the_latch_holds() {
        let m = DetectionStateMachine()
        m.armSkipLatch(bundleID: Self.teams.bundleID)
        m.noteSuppressedCandidate(Self.teams)
        XCTAssertEqual(m.liveSuppressedCandidate(), Self.teams)
    }

    func test_suppressed_candidate_lapses_with_its_latch_and_is_dropped() {
        let m = DetectionStateMachine()
        m.armSkipLatch(bundleID: Self.teams.bundleID)
        m.noteSuppressedCandidate(Self.teams)
        // Discovery stopped refreshing the latch: past the grace, the meeting is over and
        // the candidate is not something a start should attribute itself to.
        let afterGrace = Date().addingTimeInterval(DetectionStateMachine.skipLatchGraceSec + 1)
        XCTAssertNil(m.liveSuppressedCandidate(now: afterGrace))
        // The lapsed read drops it, so nothing has to run a timer to expire it.
        XCTAssertNil(m.liveSuppressedCandidate())
    }

    func test_clearSuppression_also_drops_the_candidate() {
        let m = DetectionStateMachine()
        m.armSkipLatch(bundleID: Self.teams.bundleID)
        m.noteSuppressedCandidate(Self.teams)
        // An explicit start consumed it; leaving it cached would let a *second* start
        // minutes later re-attach to a meeting nothing is watching any more.
        m.clearSuppression(bundleID: Self.teams.bundleID)
        XCTAssertNil(m.liveSuppressedCandidate())
    }

    func test_clearSuppression_for_another_bundle_leaves_the_candidate() {
        let m = DetectionStateMachine()
        m.armSkipLatch(bundleID: Self.teams.bundleID)
        m.noteSuppressedCandidate(Self.teams)
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

        m.noteSuppressedCandidate(Self.teams)

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
        m.noteSuppressedCandidate(Self.teams, at: seenAt)
        XCTAssertEqual(m.liveSuppressedCandidate(now: seenAt), Self.teams)

        let afterGrace = seenAt.addingTimeInterval(DetectionStateMachine.suppressedCandidateGraceSec + 1)
        XCTAssertNil(m.liveSuppressedCandidate(now: afterGrace))
        // And the drop is durable, not just a filtered read, so nothing runs a timer to expire it.
        XCTAssertNil(m.liveSuppressedCandidate())
    }

    /// DET9's rule applied to the second latch, which is the bug this task must not repeat. The
    /// grace is the poll it exists to bridge rather than a number: DET9's was a hardcoded 15
    /// justified as "5x the 3 s poll", and it silently decayed to 1.25 polls when PERF6 moved the
    /// quiet poll to 12 s. It is deliberately the same width as the skip latch's, because both are
    /// refreshed by the same confident-winner sighting and both have to clear the same measured
    /// control blackout (48 s on 2026-07-27, 21-33 s in END9).
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
            "one sighting rule, so widening one grace has to widen the other"
        )
    }

    /// Both suppression branches write the same slot now, so this pins the half DET13 must not
    /// touch: retaining a cooling-down sighting arms no skip latch, so once the 60 s cooldown
    /// lapses the meeting prompts normally. Arming one here would swallow the call for its whole
    /// lifetime, which is a missed recording rather than the missed prompt DET13 fixes.
    func test_retaining_a_cooldown_candidate_arms_no_skip_latch() {
        let m = DetectionStateMachine()
        m.recordCooldownEnd(bundleID: Self.teams.bundleID)
        m.noteSuppressedCandidate(Self.teams)
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
