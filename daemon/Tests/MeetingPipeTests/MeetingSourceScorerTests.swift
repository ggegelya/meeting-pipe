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

    // MARK: - Single-contender path

    func test_single_native_contender_with_only_titleMatch_is_rejected() {
        // The Issue 3 false-prompt fix. A native meeting app idling
        // with just a chat or calendar window trips `titleMatch` (the
        // window-title recognizer is permissive), but that is not a
        // meeting. With no corroborating in-call signal the lone
        // contender is rejected, so discovery never engages and no
        // "record this meeting?" prompt is raised.
        var candidates = [teams(signals: .init(titleMatch: true))]
        XCTAssertNil(MeetingSourceScorer.pickBest(&candidates, lastWinner: nil))
    }

    func test_single_native_contender_with_corroborating_signal_wins() {
        // A real native call: `titleMatch` plus a leave button. The
        // leave button is genuine in-call evidence, so the lone
        // contender is returned.
        var candidates = [teams(signals: .init(leaveButton: true, titleMatch: true))]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.bundleID, "com.microsoft.teams2")
    }

    func test_single_contender_with_one_signal_wins() {
        // A single corroborating in-call signal is enough for a lone
        // contender: a calling-controls toolbar only renders inside an
        // active call, so it stands on its own without `titleMatch`.
        var candidates = [teams(signals: .init(callingControlsToolbar: true))]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.bundleID, "com.microsoft.teams2")
    }

    func test_score_exactly_at_threshold_with_two_signals_returns_winner() {
        // leave (3) + mute (2) = 5, two distinct signals.
        var candidates = [teams(signals: .init(leaveButton: true, muteButton: true))]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.bundleID, "com.microsoft.teams2")
        XCTAssertEqual(winner?.score, 5)
    }

    func test_empty_candidate_list_returns_nil() {
        var candidates: [MeetingSourceCandidate] = []
        XCTAssertNil(MeetingSourceScorer.pickBest(&candidates, lastWinner: nil))
    }

    // MARK: - Idle-app filtering

    func test_idle_meeting_apps_with_no_signal_are_filtered() {
        // Teams in a real call (leave button visible) alongside Slack +
        // Zoom auto-started on login but idle (zero signals). Slack and
        // Zoom are dropped as non-contenders, leaving Teams the sole
        // contender, which is returned.
        var candidates = [
            teams(signals: .init(leaveButton: true, titleMatch: true)),
            MeetingSourceCandidate(
                source: AppSource(bundleID: "com.tinyspeck.slackmacgap",
                                   displayName: "Slack", kind: .native),
                signals: .init()
            ),
            zoom(signals: .init()),
        ]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.bundleID, "com.microsoft.teams2")
    }

    func test_all_candidates_idle_returns_nil() {
        // No app shows any in-meeting signal. Nothing to detect.
        var candidates = [
            teams(signals: .init()),
            zoom(signals: .init()),
        ]
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
    /// Teams running with a shell window (a chat window whose title
    /// passes the recognizer, so titleMatch is true - the realistic
    /// case, since a Teams shell always has SOME window). The user is
    /// actually in a Google Meet via Chrome (meeting controls toolbar
    /// shows, title matches, process audio active). Both are genuine
    /// contenders, so the threshold path runs; Chrome's far higher
    /// score wins.
    func test_2026_05_20_incident_scorer_picks_chrome_over_teams_shell() {
        var candidates = [
            // Teams shell: a chat window passes the recognizer = 2.
            teams(signals: .init(titleMatch: true)),
            // Chrome: Meet tab with the full UI rendered = 4 + 2 + 3 = 9.
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

    func test_sticky_bonus_cannot_lift_below_threshold_in_multi_contender() {
        // Two contenders, so the threshold applies. Teams: titleMatch
        // (2) + sticky (1) = 3. Zoom: titleMatch (2). Neither clears 5,
        // so the sticky bonus cannot resurrect a low-evidence winner.
        var candidates = [
            teams(signals: .init(titleMatch: true)),
            zoom(signals: .init(titleMatch: true)),
        ]
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

    func test_browser_with_only_titleMatch_is_returned_as_sole_contender() {
        // A lone browser with a meeting-pattern tab title is returned
        // even at score 2. Browsers are exempt from the native
        // corroborating-signal rule: the scanner only enumerates a
        // browser after one of its windows already matched a meeting
        // URL fragment, so a browser's `titleMatch` is URL-vetted, not
        // a permissive window-title-recognizer guess.
        var candidates = [chrome(signals: .init(titleMatch: true))]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.bundleID, "com.google.Chrome")
    }

    func test_multi_contender_all_below_threshold_returns_nil() {
        // Two genuine contenders, neither clearing the threshold: a
        // real ambiguity the scorer cannot resolve. Return nil rather
        // than guess - guessing "first" was the pre-scorer bug.
        var candidates = [
            teams(signals: .init(titleMatch: true)),     // 2
            chrome(signals: .init(titleMatch: true)),    // 2
        ]
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
