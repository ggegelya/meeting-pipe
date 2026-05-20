import XCTest
@testable import MeetingPipe

/// Pure-logic tests for `MeetingSourceScorer` (TECH-C15).
///
/// The scorer is the load-bearing unit behind multi-source attribution:
/// the detector enumerates concurrently-running candidates and asks the
/// scorer which one is "really in a meeting". These tests pin the
/// scoring weights, threshold, distinct-signal floor, sticky bonus and
/// tie-break semantics with synthetic signal tuples so a future
/// re-weighting can't silently regress.
///
/// Real AX / CoreAudio / NSWorkspace probes live in the Detector layer
/// and are runtime-verified during dogfood; they are out of scope here.
final class MeetingSourceScorerTests: XCTestCase {

    // MARK: - Fixtures

    private let teamsBundle = "com.microsoft.teams2"
    private let chromeBundle = "com.google.Chrome"
    private let zoomBundle = "us.zoom.xos"

    private func teams(signals: MeetingSourceCandidate.Signals = .init()) -> MeetingSourceCandidate {
        MeetingSourceCandidate(
            source: AppSource(bundleID: teamsBundle, displayName: "Microsoft Teams", kind: .native),
            signals: signals
        )
    }

    private func chrome(signals: MeetingSourceCandidate.Signals = .init()) -> MeetingSourceCandidate {
        MeetingSourceCandidate(
            source: AppSource(bundleID: chromeBundle, displayName: "Chrome", kind: .browser),
            signals: signals
        )
    }

    private func zoom(signals: MeetingSourceCandidate.Signals = .init()) -> MeetingSourceCandidate {
        MeetingSourceCandidate(
            source: AppSource(bundleID: zoomBundle, displayName: "Zoom", kind: .native),
            signals: signals
        )
    }

    // MARK: - Weight semantics

    func test_score_sums_individual_weights() {
        let signals = MeetingSourceCandidate.Signals(
            callingControlsToolbar: true,  // +4
            leaveButton: true,             // +3
            muteButton: true,              // +2
            titleMatch: true,              // +2
            processAudioActive: true,      // +3
            shareableContentActive: true   // +2
        )
        XCTAssertEqual(MeetingSourceScorer.score(signals, isStickyLast: false), 16)
    }

    func test_sticky_bonus_adds_one_when_lastWinner_matches() {
        let signals = MeetingSourceCandidate.Signals(leaveButton: true)  // +3
        XCTAssertEqual(MeetingSourceScorer.score(signals, isStickyLast: false), 3)
        XCTAssertEqual(MeetingSourceScorer.score(signals, isStickyLast: true), 4)
    }

    func test_distinctSignalCount_does_not_include_sticky_bonus() {
        // 2 distinct signals, regardless of how many "true" flags appear.
        let signals = MeetingSourceCandidate.Signals(
            callingControlsToolbar: true,
            leaveButton: true
        )
        XCTAssertEqual(MeetingSourceScorer.distinctSignalCount(signals), 2)
    }

    // MARK: - Threshold + distinct-signal floor

    func test_below_threshold_returns_nil() {
        // titleMatch alone is 2 points - below the 5 floor.
        var candidates = [teams(signals: .init(titleMatch: true))]
        XCTAssertNil(MeetingSourceScorer.pickBest(&candidates, lastWinner: nil))
    }

    func test_at_threshold_with_only_one_distinct_signal_returns_nil() {
        // Single signal cleared above threshold by itself? Not possible
        // with current weights, but pin the distinct-signal floor
        // semantics regardless. Sticky bonus alone cannot push to win.
        // Two-signal floor protects against a stale sticky bias
        // resurrecting a candidate with no real evidence.
        var candidates = [teams(signals: .init(callingControlsToolbar: true))]
        // 4 + sticky 1 = 5, but only 1 distinct signal.
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: AppSource(
            bundleID: "com.microsoft.teams2", displayName: "Teams"
        ))
        XCTAssertNil(winner)
    }

    func test_score_exactly_at_threshold_with_two_signals_returns_winner() {
        // leave (3) + mute (2) = 5, two distinct signals - clears floors.
        var candidates = [teams(signals: .init(leaveButton: true, muteButton: true))]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.bundleID, "com.microsoft.teams2")
        XCTAssertEqual(winner?.score, 5)
    }

    func test_empty_candidate_list_returns_nil() {
        var candidates: [MeetingSourceCandidate] = []
        XCTAssertNil(MeetingSourceScorer.pickBest(&candidates, lastWinner: nil))
    }

    // MARK: - Picking between candidates

    func test_higher_score_wins_against_lower_score() {
        // Teams: full meeting (toolbar + leave + mute + title + audio) = 14
        // Chrome: just titleMatch + audio = 5
        var candidates = [
            teams(signals: .init(
                callingControlsToolbar: true,
                leaveButton: true,
                muteButton: true,
                titleMatch: true,
                processAudioActive: true
            )),
            chrome(signals: .init(titleMatch: true, processAudioActive: true)),
        ]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.bundleID, "com.microsoft.teams2")
    }

    /// The motivating scenario for TECH-C15: 2026-05-20 incident.
    /// Teams running with only a shell window (no Calling controls,
    /// no leave / mute button visible, no process audio); user is
    /// actually in a Google Meet via Chrome (meeting controls toolbar
    /// shows, title matches, process audio active).
    /// The scorer must pick Chrome despite Teams being "first" in
    /// enumeration order.
    func test_2026_05_20_incident_scorer_picks_chrome_over_teams_shell() {
        var candidates = [
            // Teams: shell only. No buttons, no toolbar, no audio,
            // no title. Worst case for the previous first-match logic.
            teams(signals: .init()),
            // Chrome: Meet tab with the full UI rendered.
            chrome(signals: .init(
                callingControlsToolbar: true,
                titleMatch: true,
                processAudioActive: true
            )),
        ]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.bundleID, "com.google.Chrome")
        XCTAssertEqual(winner?.source.kind, .browser)
    }

    func test_no_candidate_above_threshold_returns_nil_even_with_three_competitors() {
        var candidates = [
            teams(signals: .init(titleMatch: true)),     // 2
            chrome(signals: .init(titleMatch: true)),    // 2
            zoom(signals: .init(muteButton: true)),      // 2
        ]
        XCTAssertNil(MeetingSourceScorer.pickBest(&candidates, lastWinner: nil))
    }

    // MARK: - Sticky bonus

    func test_sticky_bonus_breaks_a_tie() {
        // Teams: leave + mute = 5, two distinct.
        // Zoom:  leave + mute = 5, two distinct.
        // Tie. Sticky bonus to Zoom (last winner) lifts it to 6.
        var candidates = [
            teams(signals: .init(leaveButton: true, muteButton: true)),
            zoom(signals: .init(leaveButton: true, muteButton: true)),
        ]
        let winner = MeetingSourceScorer.pickBest(
            &candidates,
            lastWinner: AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")
        )
        XCTAssertEqual(winner?.source.bundleID, "us.zoom.xos")
        XCTAssertEqual(winner?.score, 6)
    }

    func test_sticky_bonus_cannot_lift_below_threshold_candidate() {
        // Teams: titleMatch only = 2. Sticky bonus = 3. Still below 5.
        var candidates = [teams(signals: .init(titleMatch: true))]
        let winner = MeetingSourceScorer.pickBest(
            &candidates,
            lastWinner: AppSource(bundleID: "com.microsoft.teams2", displayName: "Teams")
        )
        XCTAssertNil(winner)
    }

    func test_sticky_bonus_does_not_apply_when_lastWinner_is_nil() {
        // Teams: leave (3) + mute (2) = 5.
        var candidates = [teams(signals: .init(leaveButton: true, muteButton: true))]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.score, 5)
    }

    func test_sticky_bonus_does_not_apply_to_different_bundle() {
        // Teams: leave (3) + mute (2) = 5.
        // lastWinner is Zoom; no bonus for Teams.
        var candidates = [teams(signals: .init(leaveButton: true, muteButton: true))]
        let winner = MeetingSourceScorer.pickBest(
            &candidates,
            lastWinner: AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")
        )
        XCTAssertEqual(winner?.score, 5)
    }

    // MARK: - In-progress meeting beats a transient candidate

    func test_higher_scorer_wins_against_lower_scorer_even_with_sticky() {
        // Teams: full call (toolbar + leave + mute + title + audio) = 14.
        // Zoom: just title (2). Even with sticky (3) Zoom can't win.
        var candidates = [
            teams(signals: .init(
                callingControlsToolbar: true,
                leaveButton: true,
                muteButton: true,
                titleMatch: true,
                processAudioActive: true
            )),
            zoom(signals: .init(titleMatch: true)),
        ]
        let winner = MeetingSourceScorer.pickBest(
            &candidates,
            lastWinner: AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")
        )
        XCTAssertEqual(winner?.source.bundleID, "com.microsoft.teams2")
    }

    // MARK: - Score is recorded on the winning candidate

    func test_winner_score_field_reflects_computed_score() {
        var candidates = [
            teams(signals: .init(
                callingControlsToolbar: true,  // 4
                leaveButton: true              // 3
            ))
        ]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.score, 7)
        // Note: distinct signal count is 2 (the two true flags), so the
        // candidate qualifies regardless of the sum being 7.
    }

    // MARK: - Edge cases

    func test_all_signals_false_with_sticky_does_not_win() {
        var candidates = [teams(signals: .init())]
        let winner = MeetingSourceScorer.pickBest(
            &candidates,
            lastWinner: AppSource(bundleID: "com.microsoft.teams2", displayName: "Teams")
        )
        XCTAssertNil(winner)
    }

    func test_browser_with_only_titleMatch_alone_does_not_win() {
        // A background Meet tab open while user uses a different app
        // shouldn't trigger detection. titleMatch alone (2) + nothing
        // else is below threshold.
        var candidates = [chrome(signals: .init(titleMatch: true))]
        XCTAssertNil(MeetingSourceScorer.pickBest(&candidates, lastWinner: nil))
    }

    func test_browser_with_titleMatch_plus_meeting_controls_wins() {
        // Active Google Meet: meeting controls toolbar visible + title
        // matches. 4 + 2 = 6, two distinct signals - clears.
        var candidates = [chrome(signals: .init(
            callingControlsToolbar: true,
            titleMatch: true
        ))]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.bundleID, "com.google.Chrome")
        XCTAssertEqual(winner?.score, 6)
    }
}
