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

    private let webexBundle = "com.cisco.webexmeetingsapp"

    /// Webex carries `hasAudioLeg: false`, so it keeps DET4's single-corroborator bar rather than
    /// DET5's two-signal bar. The flag is named after the process-audio probe DET2 removed; see its
    /// declaration for why the behaviour it gates outlived the probe.
    private func webex(signals: MeetingSourceCandidate.Signals = .init()) -> MeetingSourceCandidate {
        MeetingSourceCandidate(
            source: AppSource(bundleID: webexBundle, displayName: "Webex", kind: .native),
            signals: signals,
            hasAudioLeg: false
        )
    }

    /// A Chromium "installed PWA" admitted as a `.browser`. Its per-install bundle ID is in no fixed
    /// list, so the scanner enumerates it by `localizedName`; a name-only admission carries
    /// `titleMatch == false` (START3/AUD-4), distinct from a plain browser tab vetted by its title/URL.
    private func meetPWA(signals: MeetingSourceCandidate.Signals = .init()) -> MeetingSourceCandidate {
        MeetingSourceCandidate(
            source: AppSource(
                bundleID: "com.google.Chrome.app.fmgjjmmmlfnkbppncabfkddbjimcfncm",
                displayName: "Google Meet", kind: .browser
            ),
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
            shareableContentActive: true   // +2
        )
        XCTAssertEqual(MeetingSourceScorer.score(signals, isStickyLast: false), 13)
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
                titleMatch: true
            )),
            chrome(signals: .init(titleMatch: true)),
        ]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.bundleID, "com.microsoft.teams2")
    }

    /// The motivating scenario for TECH-C15: 2026-05-20 incident.
    /// Teams running with a shell window (a chat window whose title
    /// passes the recognizer, so titleMatch is true - the realistic
    /// case, since a Teams shell always has SOME window). The user is
    /// actually in a Google Meet via Chrome (meeting controls toolbar
    /// shows, title matches). Both are genuine contenders, so the
    /// threshold path runs; Chrome's far higher score wins.
    func test_2026_05_20_incident_scorer_picks_chrome_over_teams_shell() {
        var candidates = [
            // Teams shell: a chat window passes the recognizer = 2.
            teams(signals: .init(titleMatch: true)),
            // Chrome: Meet tab with the full UI rendered = 4 + 2 = 6.
            chrome(signals: .init(
                callingControlsToolbar: true,
                titleMatch: true
            )),
        ]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.bundleID, "com.google.Chrome")
        XCTAssertEqual(winner?.source.kind, .browser)
    }

    func test_multiple_weak_natives_with_no_confident_signal_returns_nil() {
        // Contested scan, no trustworthy browser and no confident native: a title-only native and a
        // single-stale-control native both fall short (a title alone and a lone mute are not
        // confident live-call evidence, DET5), so the scorer returns nil rather than guess.
        // (Pre-DET5 this was three competitors incl. a title-matched browser; that now resolves to
        // the browser via the trustworthy-title exemption, covered separately.)
        var candidates = [
            teams(signals: .init(titleMatch: true)),     // 2, title only
            zoom(signals: .init(muteButton: true)),      // 2, single stale-prone control
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
        // Teams: full call (toolbar + leave + mute + title) = 11.
        // Zoom: just title (2). Even with sticky (3) Zoom can't win.
        var candidates = [
            teams(signals: .init(
                callingControlsToolbar: true,
                leaveButton: true,
                muteButton: true,
                titleMatch: true
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
        // A lone browser with a GENUINE meeting-pattern tab title is returned
        // even at score 2 (START2). The scanner only sets a browser's
        // `titleMatch` after a window matched a meeting URL fragment or the
        // browser title patterns, so it is vetted evidence, not a permissive
        // window-title-recognizer guess. This trustworthy-title case is the
        // counterpart of the name-only PWA admission below, which carries
        // `titleMatch == false` and must show a corroborator (START3/AUD-4).
        var candidates = [chrome(signals: .init(titleMatch: true))]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.bundleID, "com.google.Chrome")
    }

    func test_single_name_only_pwa_without_corroborator_raises_no_prompt() {
        // START3/AUD-4: a meeting-named PWA idling on its landing page is admitted
        // as a browser by `localizedName` alone, so it carries no real `titleMatch`
        // (the scanner now passes the honest `false`) and no in-call signal. With no
        // vetted title and nothing to corroborate, it is dropped as a zero-evidence
        // candidate, so an idle PWA never raises a "record this meeting?" prompt.
        var candidates = [meetPWA(signals: .init())]
        XCTAssertNil(MeetingSourceScorer.pickBest(&candidates, lastWinner: nil))
    }

    func test_single_name_only_pwa_with_corroborator_wins() {
        // The same name-only PWA, but genuinely in a call: the AX walk found a Leave
        // button. That is an in-call corroborator, so the lone browser is returned
        // even though it has no title match. The corroboration gate now treats a
        // name-only browser exactly like a native (START3/AUD-4); a vetted title
        // would have stood alone, but app-name-only admission does not.
        //
        // This fixture used process audio as the corroborator until DET2 removed that
        // signal (2026-07-20). A control-AX signal is the honest replacement: the walk
        // gate admits a frontmost PWA, so leave/mute/toolbar are the corroborators a
        // browser candidate can still actually carry.
        var candidates = [meetPWA(signals: .init(leaveButton: true))]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.kind, .browser)
        XCTAssertEqual(winner?.source.displayName, "Google Meet")
    }

    // MARK: - DET5: trustworthy-browser exemption carried into contested scans

    func test_contested_title_matched_browser_beats_a_title_only_native() {
        // The filed regression: an idle Teams window with a popped-out chat (titleMatch on the
        // chat, no in-call corroborator) must not suppress a real Meet call in Chrome. Both score
        // 2, so it is a contested scan; the browser's title is trustworthy, the native's is not,
        // so the browser wins instead of the scan going nil. (Pre-DET5 this returned nil.)
        var candidates = [
            teams(signals: .init(titleMatch: true)),     // native, chat-window title only
            chrome(signals: .init(titleMatch: true)),    // browser, genuine meeting title
        ]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.bundleID, chromeBundle)
    }

    func test_contested_corroborated_native_still_beats_the_browser() {
        // A native with a REAL in-call corroborator (Leave button) at an equal-or-higher score is
        // a genuine rival, so the exemption yields and the native wins on the normal threshold.
        var candidates = [
            teams(signals: .init(leaveButton: true, titleMatch: true)),  // 5, corroborated
            chrome(signals: .init(titleMatch: true)),                    // 2, title only
        ]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.bundleID, teamsBundle)
    }

    func test_contested_single_stale_control_does_not_block_the_browser() {
        // Review finding: a single control on a native (a stale hub mute toggle, a lingering
        // post-call Leave button) is NOT confident evidence of a live call, so it must not suppress
        // a real title-only browser meeting (a silent missed recording). Only the calling-controls
        // toolbar or >= 2 distinct signals make a native a genuine rival, so the browser wins here.
        var candidates = [
            chrome(signals: .init(titleMatch: true)),    // 2, genuine meeting title
            zoom(signals: .init(muteButton: true)),      // 2, single stale-prone control
        ]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.bundleID, chromeBundle)
    }

    func test_contested_confident_native_still_blocks_the_exemption() {
        // But a native with the calling-controls toolbar (which non-meeting shells never carry) is
        // a confident rival at an equal-or-higher score, so it blocks the exemption; nothing then
        // clears the threshold floor, so the scan is inconclusive (nil) rather than handed to the
        // browser.
        var candidates = [
            chrome(signals: .init(titleMatch: true)),           // 2, title only
            zoom(signals: .init(callingControlsToolbar: true)), // 4, confident (toolbar)
        ]
        XCTAssertNil(MeetingSourceScorer.pickBest(&candidates, lastWinner: nil))
    }

    // MARK: - DET5: a lone native needs confident evidence, not a single stale control

    func test_lone_native_single_stale_control_raises_no_prompt() {
        // DET5's walk-gate now runs the control walk on an idle frontmost/lone app, so a single
        // lingering control must not prompt. A lone Zoom showing only a stale Leave button (no
        // toolbar, no second signal) is not a confident live call.
        var candidates = [zoom(signals: .init(leaveButton: true))]
        XCTAssertNil(MeetingSourceScorer.pickBest(&candidates, lastWinner: nil))
    }

    func test_lone_native_toolbar_alone_still_wins() {
        // The calling-controls toolbar is the exception: non-meeting shell windows never carry it,
        // so it alone confirms a live call even without a second signal (preserves the pre-DET5
        // single-toolbar contract).
        var candidates = [zoom(signals: .init(callingControlsToolbar: true))]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.bundleID, zoomBundle)
    }

    func test_lone_webex_single_control_still_records() {
        // Regression guard (found in re-review): Webex has no audio leg and an unreliable toolbar
        // label, so a real Webex call may expose only the Leave button. The raised confident-native
        // bar must NOT apply to it, or a real Webex meeting is silently dropped. Both a lone Leave
        // and a lone Mute keep DET4's single-corroborator detection.
        for signals in [MeetingSourceCandidate.Signals(leaveButton: true),
                        MeetingSourceCandidate.Signals(muteButton: true)] {
            var candidates = [webex(signals: signals)]
            let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
            XCTAssertEqual(winner?.source.bundleID, webexBundle,
                           "lone Webex with a single control must still record")
        }
    }

    func test_contested_webex_single_control_does_not_block_a_real_browser() {
        // The lenient bar is lone-only: in a contested scan the rival check stays strict for every
        // native, so a single Webex Leave button does not suppress a real title-only browser
        // meeting (it would in DET4). The browser wins.
        var candidates = [
            chrome(signals: .init(titleMatch: true)),   // 2, genuine meeting title
            webex(signals: .init(leaveButton: true)),   // 3, single control, no audio leg
        ]
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: nil)
        XCTAssertEqual(winner?.source.bundleID, chromeBundle)
    }

    func test_contested_exemption_is_title_gated() {
        // A browser with no real title match (a name-only PWA admission carries titleMatch==false,
        // START3) gets no exemption, so a weak contest against a title-only native stays nil.
        var candidates = [
            teams(signals: .init(titleMatch: true)),             // 2
            chrome(signals: .init(shareableContentActive: true)), // 2, NOT title-matched
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
