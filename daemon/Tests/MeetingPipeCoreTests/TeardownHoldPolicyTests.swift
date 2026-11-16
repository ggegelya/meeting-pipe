import XCTest
@testable import MeetingPipeCore

/// T8: the hold's decisions, lifted out of `MeetingSessionController` so they run on an injected
/// clock. `CallTeardownHoldTests` still pins the host's wiring (the timer, the HUD, the log rows);
/// these pin what the host used to decide inline with `Date()`: where the hold starts, that a
/// second provisional cannot move it, what a consult asks the oracle, and where the tail is cut.
final class TeardownHoldPolicyTests: XCTestCase {

    private let teams = MeetingLifecycleContext(bundleID: "com.microsoft.teams2", kind: .native, pid: 1234)
    private let browser = MeetingLifecycleContext(bundleID: "com.google.Chrome", kind: .browser, pid: 1234)

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func test_a_new_hold_is_stamped_at_the_injected_clock() {
        var policy = TeardownHoldPolicy()
        XCTAssertFalse(policy.isOpen)

        XCTAssertTrue(policy.open(context: teams, at: at(100)), "the first provisional opens a hold")

        XCTAssertEqual(policy.hold, TeardownHoldPolicy.Hold(context: teams, startedAt: at(100)))
    }

    /// The stamp is where the held tail starts, so a flapping signal re-entering must not move it
    /// later and shrink what gets trimmed.
    func test_re_entry_keeps_the_first_stamp() {
        var policy = TeardownHoldPolicy()
        policy.open(context: teams, at: at(100))

        XCTAssertFalse(policy.open(context: teams, at: at(130)), "a second provisional re-enters")

        XCTAssertEqual(policy.hold?.startedAt, at(100))
    }

    func test_a_consult_with_no_hold_asks_nothing() {
        let policy = TeardownHoldPolicy()
        XCTAssertNil(policy.consult(now: at(100), lastTeardownAt: at(100), recordingStartedAt: at(0)))
    }

    /// Teams' teardown line says nothing about a browser meeting, so a browser hold never consults.
    func test_a_browser_hold_never_consults_the_oracle() {
        var policy = TeardownHoldPolicy()
        policy.open(context: browser, at: at(100))
        XCTAssertNil(policy.consult(now: at(100), lastTeardownAt: at(99), recordingStartedAt: at(0)))
    }

    func test_a_teardown_inside_the_lookback_confirms_from_the_hold_stamp() {
        var policy = TeardownHoldPolicy()
        policy.open(context: teams, at: at(100))

        // The line leads the AX edge, so it may be up to `defaultLookbackSec` older than the stamp.
        let verdict = policy.consult(now: at(100), lastTeardownAt: at(98.7), recordingStartedAt: at(0))

        XCTAssertEqual(verdict, .confirm(reason: .teardownObserved))
    }

    /// Measured from the hold's own stamp, so a consult a minute in still holds when nothing landed.
    func test_no_teardown_holds_with_the_elapsed_time_since_the_stamp() {
        var policy = TeardownHoldPolicy()
        policy.open(context: teams, at: at(100))
        policy.open(context: teams, at: at(130))

        let verdict = policy.consult(now: at(160), lastTeardownAt: nil, recordingStartedAt: at(0))

        XCTAssertEqual(verdict, .hold(elapsedSec: 60))
    }

    /// END10 item 6, through the policy: a previous call's teardown cannot confirm this recording.
    func test_a_teardown_from_before_the_recording_started_does_not_confirm() {
        var policy = TeardownHoldPolicy()
        policy.open(context: teams, at: at(100))

        let verdict = policy.consult(now: at(100), lastTeardownAt: at(95), recordingStartedAt: at(97))

        XCTAssertEqual(verdict, .hold(elapsedSec: 0))
    }

    /// Sub-second holds are the normal Teams path (the teardown confirms on the first consult), and
    /// marking them for trimming would be churn.
    func test_a_hold_under_one_second_yields_no_trim_point() {
        var policy = TeardownHoldPolicy()
        policy.open(context: teams, at: at(100))
        XCTAssertNil(policy.trimPoint(concludingAt: at(100.99), evidence: nil, conclusion: .engineEnd))
    }

    /// With no process audio (browser, Webex, Slack, an unresolved mic) a pair, teardown or
    /// definitive end still cuts at the hold's first stamp, and re-entry does not move it.
    func test_without_process_audio_a_pair_end_trims_at_the_holds_stamp() {
        var policy = TeardownHoldPolicy()
        policy.open(context: teams, at: at(100))
        policy.open(context: teams, at: at(200))

        XCTAssertEqual(policy.trimPoint(concludingAt: at(101), evidence: nil, conclusion: .engineEnd), at(100))
        XCTAssertEqual(policy.trimPoint(concludingAt: at(820), evidence: nil, conclusion: .teardown), at(100), "re-entry did not move the cut")
    }

    func test_no_hold_has_no_trim_point() {
        XCTAssertNil(TeardownHoldPolicy().trimPoint(concludingAt: at(100), evidence: nil, conclusion: .engineEnd))
    }

    // MARK: - END21

    private func released(at release: TimeInterval, liveSince: Bool = false, windowSince: Bool = true) -> HoldEvidence {
        HoldEvidence(
            processAudio: .ended, releasedAt: at(release),
            liveSinceRelease: liveSince, callWindowEndedSinceRelease: windowSince
        )
    }

    /// G001: a Leave-invalid hold opened 31 minutes in under a live mic, the mic released at 60
    /// minutes, ended by the pair. The cut is the release, not the first doubt.
    func test_the_cut_is_the_mic_release_not_the_first_doubt() {
        var policy = TeardownHoldPolicy()
        policy.open(context: teams, at: at(31 * 60))
        XCTAssertEqual(
            policy.trimPoint(concludingAt: at(61 * 60), evidence: released(at: 60 * 60), conclusion: .engineEnd),
            at(60 * 60)
        )
    }

    func test_a_hold_concluding_while_the_mic_reads_live_trims_nothing() {
        var policy = TeardownHoldPolicy()
        policy.open(context: teams, at: at(100))
        let live = HoldEvidence(processAudio: .live, releasedAt: nil, liveSinceRelease: false, callWindowEndedSinceRelease: false)
        for conclusion in [TeardownHoldPolicy.Conclusion.engineEnd, .teardown, .loneDwell, .stop] {
            XCTAssertNil(policy.trimPoint(concludingAt: at(900), evidence: live, conclusion: conclusion), "\(conclusion)")
        }
    }

    /// F032, the owner's item 2: with no process audio a lone-dwell end trims nothing.
    func test_without_process_audio_a_lone_dwell_end_trims_nothing() {
        var policy = TeardownHoldPolicy()
        policy.open(context: teams, at: at(100))
        XCTAssertNil(policy.trimPoint(concludingAt: at(820), evidence: nil, conclusion: .loneDwell))
        let unresolved = HoldEvidence(processAudio: nil, releasedAt: nil, liveSinceRelease: false, callWindowEndedSinceRelease: false)
        XCTAssertNil(policy.trimPoint(concludingAt: at(820), evidence: unresolved, conclusion: .loneDwell))
    }

    /// The owner's item 3 rule for a stop inside a hold: the release, only when the mic still reads
    /// released, nothing read live since, and the Leave button or the window went after it.
    func test_a_stop_cuts_at_the_release_only_when_a_second_signal_backs_it() {
        var policy = TeardownHoldPolicy()
        policy.open(context: teams, at: at(100))
        XCTAssertEqual(policy.trimPoint(concludingAt: at(140), evidence: released(at: 104), conclusion: .stop), at(104), "a real end")
        XCTAssertNil(
            policy.trimPoint(concludingAt: at(106), evidence: released(at: 104, windowSince: false), conclusion: .stop),
            "a headphone switch drops only the mic"
        )
        XCTAssertNil(
            policy.trimPoint(concludingAt: at(140), evidence: released(at: 104, liveSince: true), conclusion: .stop),
            "something read live again after the release"
        )
        XCTAssertNil(policy.trimPoint(concludingAt: at(140), evidence: nil, conclusion: .stop), "no mic, no cut on a stop")
    }

    /// The cut is never earlier than the hold's own start.
    func test_a_release_before_the_hold_cuts_at_the_hold() {
        var policy = TeardownHoldPolicy()
        policy.open(context: teams, at: at(100))
        XCTAssertEqual(policy.trimPoint(concludingAt: at(200), evidence: released(at: 90), conclusion: .engineEnd), at(100))
    }

    func test_release_clears_all_state_and_returns_what_it_dropped() {
        var policy = TeardownHoldPolicy()
        policy.open(context: teams, at: at(100))

        XCTAssertEqual(policy.release(), TeardownHoldPolicy.Hold(context: teams, startedAt: at(100)))

        XCTAssertFalse(policy.isOpen)
        XCTAssertNil(policy.hold)
        XCTAssertNil(policy.trimPoint(concludingAt: at(900), evidence: nil, conclusion: .engineEnd))
        XCTAssertNil(policy.consult(now: at(900), lastTeardownAt: at(900), recordingStartedAt: at(0)))
        XCTAssertNil(policy.release(), "a second release has nothing to drop")
    }

    /// After a release the next provisional is a new hold with a new stamp, not a re-entry.
    func test_a_hold_after_a_release_is_stamped_anew() {
        var policy = TeardownHoldPolicy()
        policy.open(context: teams, at: at(100))
        policy.release()

        XCTAssertTrue(policy.open(context: teams, at: at(400)))
        XCTAssertEqual(policy.hold?.startedAt, at(400))
    }
}
