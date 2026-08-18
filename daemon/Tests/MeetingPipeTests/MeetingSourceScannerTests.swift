import XCTest
@testable import MeetingPipe

/// Tests for the decisions `MeetingSourceScanner` makes over an enumerated candidate list: the
/// browser-admission contract (START2/AUD-3), the control-walk gate (PERF6 + DET5), and the
/// Accessibility-denied blackout (DET11). Everything here is driven with explicit inputs; the
/// enumeration itself is the only half that needs a real workspace.
///
/// Browsers put the page title, never the URL, in the AX window title, so a plain-tab
/// Meet/Teams-web meeting can only be discovered by matching the page-title patterns the
/// browser lifecycle adapter owns. These pin that contract independently of which matcher
/// set the scanner happens to use, so a regression that drops browser discovery (the
/// pre-START2 "URL fragment vs title" mismatch, which made plain browser meetings
/// structurally undiscoverable) is caught here rather than in the field.
final class MeetingSourceScannerTests: XCTestCase {

    func test_plain_meet_tab_title_is_a_meeting_candidate() {
        // A Google Meet call in a plain Chrome/Safari tab: the window title is the page title
        // ("Meet - <code>"), never the URL. This is the START2 acceptance case.
        XCTAssertTrue(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Meet - abc-defg-hij"))
    }

    func test_teams_web_tab_title_is_a_meeting_candidate() {
        XCTAssertTrue(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Standup | Microsoft Teams"))
    }

    func test_ordinary_browser_page_title_is_not_a_meeting_candidate() {
        XCTAssertFalse(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Acme Inc - Mail"))
        XCTAssertFalse(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Inbox (12) - Gmail"))
    }

    func test_page_titled_meeting_is_not_a_meeting_candidate() {
        // Regression (2026-06-30 false prompt): switching to a Jira board for a project literally named
        // "Level 10 Meeting" popped the Record prompt. The browser matchers keyed off the bare word
        // "meeting" (Teams stem) and "meet" + "-" (Meet), so any page title containing them admitted a
        // zero-corroboration browser candidate. These are ordinary pages, not meetings, and a browser
        // title stands alone in the scorer, so the page word alone must never admit a candidate.
        XCTAssertFalse(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Level 10 Meeting board - Jira"))
        XCTAssertFalse(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "[L10M-1074] Auth rework - Level 10 Meeting - Jira"))
        XCTAssertFalse(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Meeting notes - Notion"))
        XCTAssertFalse(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "1:1 Meeting agenda - Google Docs"))
        XCTAssertFalse(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Weekly Meeting - Confluence"))
    }

    func test_genuine_browser_meeting_titles_stay_discoverable() {
        // The tightening must not regress real plain-tab meetings: Meet keys off the meeting code,
        // Teams web off the "Microsoft Teams" brand, Webex off "webex", Slack off "huddle".
        XCTAssertTrue(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Meet - abc-defg-hij"))
        XCTAssertTrue(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Weekly sync | Microsoft Teams"))
        XCTAssertTrue(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Webex Meeting - Acme"))
        XCTAssertTrue(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Huddle - #engineering"))
    }

    // MARK: - DET6: the plain-browser admission gate

    /// The URL fragments the production registry ships, so these cases run against the same list
    /// `enumerateCandidates` passes in rather than a convenient invention.
    private let productionURLFragments = [
        "meet.google.com",
        "teams.microsoft.com",
        "teams.live.com",
        "zoom.us/j/",
        "zoom.us/wc/",
        "webex.com/meet",
        "webex.com/wbxmjs",
    ]

    private func admission(_ titles: String...) -> MeetingSourceScanner.BrowserAdmission {
        MeetingSourceScanner.decideBrowserAdmission(
            windowTitles: titles,
            urlFragments: productionURLFragments
        )
    }

    // Unconditional: a Google Meet tab is the one product that clears this gate today, and it must
    // keep clearing it under every branch of DET6's verdict tree. Both forms of the strong matcher.

    func test_meet_room_code_title_is_admitted() {
        XCTAssertEqual(admission("Meet - abc-defg-hij"), .admit)
    }

    func test_meet_google_com_title_is_admitted() {
        // Two routes reach `.admit` for this one string and both are real: `meet.google.com` is a
        // registered URL fragment AND the `googleMeet` strong matcher's host branch.
        XCTAssertEqual(admission("meet.google.com/abc-defg-hij"), .admit)
    }

    // Unconditional: the END5 regression fence. A page ABOUT these products is not a meeting, and
    // must stay rejected whichever branch DET6's measurement takes. If a later widening of
    // `strongTitleMatchers` makes this admit, that widening is wrong, not this test.

    func test_doc_title_about_meeting_products_is_never_admitted() {
        XCTAssertNotEqual(admission("Webex vs Zoom Comparison"), .admit)
        XCTAssertNotEqual(admission("Microsoft Teams vs Slack - buyer's guide"), .admit)
        XCTAssertNotEqual(admission("How to run a good huddle - Notion"), .admit)
    }

    // PRE-VERDICT. The three brand-token cases below pin what the gate does TODAY, which is refuse.
    // That is the state DET6 was filed against, not the intended end state: whether a live browser
    // call in Teams / Webex / Slack is admitted is answered by the owner-run probe
    // (`daemon/scripts/det6-browser-url-probe.swift`) against the verdict tree in
    // `docs/spikes/det6-browser-url-readability.md`. Expect these to change when it lands. They are
    // here so the refusal is a decision the suite states out loud, rather than a silent `continue`
    // nobody can see.

    func test_bare_microsoft_teams_title_is_refused_pre_verdict() {
        XCTAssertEqual(
            admission("Weekly sync | Microsoft Teams"),
            .weakTitleOnly(matchedTitle: "Weekly sync | Microsoft Teams")
        )
    }

    func test_bare_webex_title_is_refused_pre_verdict() {
        XCTAssertEqual(
            admission("Webex Meeting - Acme"),
            .weakTitleOnly(matchedTitle: "Webex Meeting - Acme")
        )
    }

    func test_bare_huddle_title_is_refused_pre_verdict() {
        XCTAssertEqual(
            admission("Huddle - #engineering"),
            .weakTitleOnly(matchedTitle: "Huddle - #engineering")
        )
    }

    /// The two refusals are different facts and the gate has to tell them apart: an ordinary browser
    /// window is a clean miss and stays silent, while a weakly-matching one is a refusal that gets
    /// an event. Collapsing them would drown the signal in one line per browser per poll, all day.
    func test_an_ordinary_browser_window_is_not_a_refusal() {
        XCTAssertEqual(admission("Inbox (12) - Gmail"), .noMeetingSignal)
        XCTAssertEqual(admission(), .noMeetingSignal)
    }

    /// The URL-fragment disjunct is still live code, and this is the only shape that reaches it: a
    /// browser that puts the URL in its window title. DET6 exists because no shipping browser does,
    /// which is why this case is synthetic and the ones above are not.
    func test_a_url_fragment_in_the_window_title_admits_without_a_strong_title() {
        XCTAssertEqual(admission("teams.microsoft.com/l/meetup-join/19:meeting"), .admit)
        XCTAssertEqual(admission("zoom.us/j/8675309"), .admit)
    }

    /// Zoom-in-browser is refused one step earlier than the other three, and for a different reason:
    /// `defaultTitleMatchers` carries no Zoom entry at all, so a Zoom web-client tab is not even a
    /// weak match and produces no event. Pinned so the asymmetry is not mistaken for a bug in the
    /// refusal path; closing it is part of DET6's measured change.
    func test_zoom_web_client_title_is_not_even_a_weak_match() {
        XCTAssertEqual(admission("Zoom Meeting"), .noMeetingSignal)
    }

    /// One window refusing does not decide the process: a browser holds many tabs, and a strong
    /// title anywhere admits the whole browser. This is the multi-window OR the inline guards had.
    func test_a_strong_title_in_any_window_admits_the_browser() {
        XCTAssertEqual(
            admission("Weekly sync | Microsoft Teams", "Inbox - Gmail", "Meet - abc-defg-hij"),
            .admit
        )
    }

    /// The refusal reports the title that actually matched, not the first window the browser
    /// happened to return, or the event names the wrong page.
    func test_the_refusal_names_the_title_that_matched() {
        XCTAssertEqual(
            admission("Inbox - Gmail", "Standup | Microsoft Teams"),
            .weakTitleOnly(matchedTitle: "Standup | Microsoft Teams")
        )
    }

    // MARK: - DET6: the refusal is visible in the event log

    /// The emitted line, not a re-spelling of it: this is the function `emitRejectedBrowserTabs`
    /// calls, writing through the real `Log.event` into a redirected logs dir (the DET11 shape).
    func test_refused_browser_tab_emits_browser_tab_rejected() throws {
        let fm = FileManager.default
        let logs = fm.temporaryDirectory
            .appendingPathComponent("mp-det6-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: logs) }
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }

        let scanner = MeetingSourceScanner()
        let result = scanner.scan(
            candidates: [],
            axTrusted: true,
            rejectedBrowserTabs: [
                MeetingSourceScanner.RejectedBrowserTab(
                    bundleID: "com.google.Chrome",
                    displayName: "Google Chrome",
                    title: "Weekly sync | Microsoft Teams",
                    reason: MeetingSourceScanner.RejectedBrowserTab.weakTitleOnly
                )
            ]
        )
        MeetingDiscoveryWatcher.logRejectedBrowserTabs(result.rejectedBrowserTabs)

        let rows = try String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let refused = rows.filter { $0["action"] as? String == "browser_tab_rejected" }

        XCTAssertEqual(refused.count, 1, "a refused browser tab must not be silent")
        XCTAssertEqual(refused.first?["category"] as? String, "detector")
        XCTAssertEqual(refused.first?["bundle_id"] as? String, "com.google.Chrome")
        XCTAssertEqual(refused.first?["title"] as? String, "Weekly sync | Microsoft Teams")
        XCTAssertEqual(refused.first?["reason"] as? String, "weak_title_only")
        XCTAssertEqual(refused.first?["kind"] as? String, "browser")
    }

    /// The refusal rides beside the scoring decisions rather than through them: a refused tab is not
    /// a candidate, so it must not appear in `droppedCandidates`, must not count toward
    /// `candidateCount`, and must not invent a winner.
    func test_a_refused_browser_tab_is_not_a_candidate() {
        let scanner = MeetingSourceScanner()
        let result = scanner.scan(
            candidates: [],
            axTrusted: true,
            rejectedBrowserTabs: [
                MeetingSourceScanner.RejectedBrowserTab(
                    bundleID: "com.google.Chrome",
                    displayName: "Google Chrome",
                    title: "Webex Meeting - Acme",
                    reason: MeetingSourceScanner.RejectedBrowserTab.weakTitleOnly
                )
            ]
        )
        XCTAssertNil(result.winner)
        XCTAssertEqual(result.candidateCount, 0)
        XCTAssertTrue(result.droppedCandidates.isEmpty)
        XCTAssertTrue(result.unreadableNatives.isEmpty)
        XCTAssertEqual(result.rejectedBrowserTabs.map(\.title), ["Webex Meeting - Acme"])
    }

    // MARK: - PERF6 + DET5: control-button AX-walk gate

    func test_idle_backgrounded_app_in_a_multi_native_scan_skips_the_control_walk() {
        // The hot case PERF6 protects (Teams backgrounded, no call, another native also running):
        // no meeting-titled window, not frontmost, not the lone native -> walk skipped.
        XCTAssertFalse(MeetingSourceScanner.shouldWalkControlAX(
            titleMatch: false,
            isFrontmost: false, isLoneNative: false, bundleID: "com.microsoft.teams2"))
    }

    func test_meeting_titled_window_admits_the_control_walk() {
        XCTAssertTrue(MeetingSourceScanner.shouldWalkControlAX(
            titleMatch: true,
            isFrontmost: false, isLoneNative: false, bundleID: "com.microsoft.teams2"))
    }

    // DET2 (2026-07-20) removed the `processAudioActive` precondition from the walk gate, so the
    // test that pinned "active process audio admits the walk" is gone with it: the read is
    // permanently dead, and that admission could never occur. The remaining cases below are the
    // ones that actually fire.

    func test_lone_native_walks_even_with_a_renamed_window() {
        // DET5 acceptance: a Zoom build that dropped "Zoom Meeting" from its title (titleMatch
        // false) is the only native running, so its control walk still runs and the
        // leave/mute/toolbar signals can carry it to a prompt.
        XCTAssertTrue(MeetingSourceScanner.shouldWalkControlAX(
            titleMatch: false,
            isFrontmost: false, isLoneNative: true, bundleID: "us.zoom.xos"))
    }

    func test_frontmost_native_walks_even_without_a_title_match() {
        // The user is actively looking at the meeting window; walk it even when its title was
        // renamed and another native idles in the background.
        XCTAssertTrue(MeetingSourceScanner.shouldWalkControlAX(
            titleMatch: false,
            isFrontmost: true, isLoneNative: false, bundleID: "us.zoom.xos"))
    }

    // MARK: - DET11: the Accessibility-denied blackout is observable

    private func native(_ bundleID: String, signals: MeetingSourceCandidate.Signals = .init())
        -> MeetingSourceCandidate {
        MeetingSourceCandidate(
            source: AppSource(bundleID: bundleID, displayName: "Teams", kind: .native),
            signals: signals
        )
    }

    /// The whole defect in one assertion: Teams is running, Accessibility is denied, so every
    /// signal is false, the scorer drops the candidate as zero-evidence, and nothing was emitted.
    /// `droppedCandidates` cannot cover it (it is built from candidates that already carry a
    /// signal), so a real meeting produced no `winner`, no drop and no line in `events.jsonl`
    /// while four user-facing surfaces said the only cost was a late auto-stop.
    func test_ax_denied_native_is_dropped_and_reported_rather_than_silent() {
        let scanner = MeetingSourceScanner()
        let result = scanner.scan(
            candidates: [native("com.microsoft.teams2")],
            axTrusted: false
        )

        XCTAssertNil(result.winner, "a zero-signal native must not win; that half is correct")
        XCTAssertTrue(
            result.droppedCandidates.isEmpty,
            "the drop is invisible to DET5's list by construction - that is why DET11 exists"
        )
        XCTAssertEqual(result.unreadableNatives.map(\.source.bundleID), ["com.microsoft.teams2"])
    }

    /// The emitted line, not a re-spelling of it: this is the function `emitUnreadableNatives`
    /// calls, writing through the real `Log.event` into a redirected logs dir.
    func test_ax_denied_native_emits_candidate_unreadable() throws {
        let fm = FileManager.default
        let logs = fm.temporaryDirectory
            .appendingPathComponent("mp-det11-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: logs) }
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }

        let scanner = MeetingSourceScanner()
        let result = scanner.scan(
            candidates: [native("com.microsoft.teams2")],
            axTrusted: false
        )
        MeetingDiscoveryWatcher.logUnreadableNatives(result.unreadableNatives)

        let rows = try String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let unreadable = rows.filter { $0["action"] as? String == "candidate_unreadable" }

        XCTAssertEqual(unreadable.count, 1, "a running native under a denied grant must not be silent")
        XCTAssertEqual(unreadable.first?["category"] as? String, "detector")
        XCTAssertEqual(unreadable.first?["bundle_id"] as? String, "com.microsoft.teams2")
        XCTAssertEqual(unreadable.first?["reason"] as? String, "accessibility_untrusted")
    }

    /// The grant being present is the whole difference: the same zero-signal native with AX
    /// trusted is an idle app in the dock, which is a clean miss and must stay silent.
    func test_ax_trusted_zero_signal_native_is_not_reported_unreadable() {
        let scanner = MeetingSourceScanner()
        let result = scanner.scan(
            candidates: [native("com.microsoft.teams2")],
            axTrusted: true
        )
        XCTAssertTrue(result.unreadableNatives.isEmpty)
    }

    /// A native that DID produce a signal is readable by definition, so it belongs to the DET5
    /// drop path and must not be double-reported here. (Reachable only in the window between a
    /// revoked grant and the next scan, since AX trust is cached per process at launch.)
    func test_a_native_with_a_signal_is_not_reported_unreadable() {
        let scanner = MeetingSourceScanner()
        let result = scanner.scan(
            candidates: [native("com.microsoft.teams2", signals: .init(titleMatch: true))],
            axTrusted: false
        )
        XCTAssertTrue(result.unreadableNatives.isEmpty)
    }

    /// Browsers are absent from the report rather than exempt from the problem: their branch
    /// `guard axTrusted` before enqueueing, so under a denied grant there is no browser candidate
    /// to name. Pinned so a later reader does not "fix" the omission by widening the filter.
    func test_only_natives_are_reported_unreadable() {
        let scanner = MeetingSourceScanner()
        let browser = MeetingSourceCandidate(
            source: AppSource(bundleID: "com.google.Chrome", displayName: "Chrome", kind: .browser),
            signals: .init()
        )
        let result = scanner.scan(
            candidates: [browser],
            axTrusted: false
        )
        XCTAssertTrue(result.unreadableNatives.isEmpty)
    }

    func test_webex_always_walks_even_without_a_cheap_signal() {
        // Webex must not be gated on title alone (ultrasound device discovery keeps its mic open,
        // which is why it was carved out of the old process-audio probe; the always-walk exemption
        // outlived that probe deliberately).
        XCTAssertTrue(MeetingSourceScanner.shouldWalkControlAX(
            titleMatch: false,
            isFrontmost: false, isLoneNative: false, bundleID: "com.cisco.webexmeetingsapp"))
        XCTAssertTrue(MeetingSourceScanner.shouldWalkControlAX(
            titleMatch: false,
            isFrontmost: false, isLoneNative: false, bundleID: "com.cisco.spark"))
    }
}
