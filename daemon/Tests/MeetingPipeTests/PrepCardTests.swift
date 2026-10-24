import XCTest
@testable import MeetingPipe

/// CAL2. Two surfaces under test: the pure projection (`PrepCard.make`), which
/// decides whether there is anything worth showing at all, and the disk scan
/// (`PrepCardStore.scan`), which decides which meeting the card is about. The
/// view's geometry is checked against its own metrics so the panel can never
/// animate to a frame the content does not fill.
/// T7 source fence (pins implementation): test_the_fade_mask_follows_the_scrolled_bounds_origin asserts updatePrepFade in MeetingPromptWindow sets `grad.frame = clip.bounds` with no `origin: .zero`. Missing seam: the mask frame as a pure function, or a live panel test.
final class PrepCardTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prepcard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    private func write(stem: String, workflowID: String?, workflowName: String?,
                       summary: [String: Any]?) throws {
        var meta: [String: Any] = ["source_bundle_id": "com.microsoft.teams2"]
        if let workflowID { meta["workflow_id"] = workflowID }
        if let workflowName { meta["workflow_name"] = workflowName }
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: dir.appendingPathComponent("\(stem).meta.json"))
        if let summary {
            try JSONSerialization.data(withJSONObject: summary)
                .write(to: dir.appendingPathComponent("\(stem).summary.json"))
        }
    }

    private func summary(title: String, points: [String], decisions: [String] = [],
                         actions: [[String: Any]] = []) -> [String: Any] {
        ["title": title, "summary": points, "decisions": decisions, "actions": actions]
    }

    private func decoded(_ object: [String: Any]) throws -> MeetingSummary {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(MeetingSummary.self, from: data)
    }

    private let started = Date(timeIntervalSince1970: 1_784_000_000)

    // MARK: - Projection

    func test_make_caps_points_and_actions_and_counts_the_rest() throws {
        let model = try decoded(summary(
            title: "Weekly sync",
            points: ["one", "two", "three", "four"],
            actions: [
                ["task": "Send SOW", "owner": "Georgy", "due": "2026-07-25"],
                ["task": "Book room"],
                ["task": "Draft plan"],
                ["task": "Chase invoice"],
                ["task": "Already done", "resolved": true],
                ["task": "Legacy done", "done": true],
                ["task": "   "],
            ]
        ))
        let card = try XCTUnwrap(PrepCard.make(
            workflowName: "Client work", stem: "20260720-143000",
            startedAt: started, summary: model
        ))
        XCTAssertEqual(card.title, "Weekly sync")
        XCTAssertEqual(card.points, ["one", "two", "three"])
        XCTAssertEqual(card.actions.map(\.task), ["Send SOW", "Book room", "Draft plan"])
        XCTAssertEqual(card.actions[0].owner, "Georgy")
        XCTAssertEqual(card.actions[0].due, "2026-07-25")
        XCTAssertNil(card.actions[1].owner)
        // Resolved, legacy-done and blank rows are not open actions, so 1 remains.
        XCTAssertEqual(card.moreActions, 1)
    }

    func test_make_falls_back_to_decisions_when_the_recap_is_empty() throws {
        let model = try decoded(summary(title: "Design call", points: [],
                                        decisions: ["Ship on Friday"]))
        let card = try XCTUnwrap(PrepCard.make(
            workflowName: "W", stem: "20260720-143000", startedAt: started, summary: model
        ))
        XCTAssertEqual(card.points, ["Ship on Friday"])
    }

    func test_make_is_nil_when_there_is_nothing_to_say() throws {
        let model = try decoded(summary(title: "Standup", points: [], decisions: [],
                                        actions: [["task": "Done", "resolved": true]]))
        XCTAssertNil(PrepCard.make(workflowName: "W", stem: "20260720-143000",
                                   startedAt: started, summary: model))
    }

    func test_make_falls_back_to_the_stem_when_the_summary_has_no_title() throws {
        let model = try decoded(["summary": ["only this"]])
        let card = try XCTUnwrap(PrepCard.make(
            workflowName: "W", stem: "20260720-143000", startedAt: started, summary: model
        ))
        XCTAssertEqual(card.title, "20260720-143000")
        XCTAssertTrue(card.actions.isEmpty)
    }

    // MARK: - Scan

    func test_scan_picks_the_newest_meeting_of_that_workflow() throws {
        let id = UUID().uuidString
        try write(stem: "20260701-090000", workflowID: id, workflowName: "Client work",
                  summary: summary(title: "Kickoff", points: ["old"]))
        try write(stem: "20260715-090000", workflowID: id, workflowName: "Client work",
                  summary: summary(title: "Review", points: ["new"]))
        try write(stem: "20260716-090000", workflowID: UUID().uuidString,
                  workflowName: "Personal", summary: summary(title: "Dentist", points: ["other"]))

        let card = try XCTUnwrap(PrepCardStore.scan(
            recordingsDir: dir, workflowID: id, workflowName: "Client work"
        ))
        XCTAssertEqual(card.stem, "20260715-090000")
        XCTAssertEqual(card.points, ["new"])
    }

    func test_scan_matches_by_id_across_a_rename() throws {
        let id = UUID().uuidString
        // Recorded under the old name; the workflow has since been renamed.
        try write(stem: "20260715-090000", workflowID: id, workflowName: "Old name",
                  summary: summary(title: "Review", points: ["still mine"]))
        let card = try XCTUnwrap(PrepCardStore.scan(
            recordingsDir: dir, workflowID: id, workflowName: "New name"
        ))
        XCTAssertEqual(card.points, ["still mine"])
        // And the card is labelled with the workflow you are about to record under.
        XCTAssertEqual(card.workflowName, "New name")
    }

    func test_scan_falls_back_to_the_name_when_the_sidecar_predates_workflow_id() throws {
        try write(stem: "20260715-090000", workflowID: nil, workflowName: "Client work",
                  summary: summary(title: "Review", points: ["legacy"]))
        let card = try XCTUnwrap(PrepCardStore.scan(
            recordingsDir: dir, workflowID: UUID().uuidString, workflowName: "Client work"
        ))
        XCTAssertEqual(card.points, ["legacy"])
    }

    func test_scan_falls_through_a_last_meeting_with_nothing_to_recap() throws {
        let id = UUID().uuidString
        try write(stem: "20260701-090000", workflowID: id, workflowName: "Client work",
                  summary: summary(title: "Kickoff", points: ["real content"]))
        try write(stem: "20260715-090000", workflowID: id, workflowName: "Client work",
                  summary: summary(title: "No speech", points: []))
        let card = try XCTUnwrap(PrepCardStore.scan(
            recordingsDir: dir, workflowID: id, workflowName: "Client work"
        ))
        XCTAssertEqual(card.stem, "20260701-090000")
    }

    func test_scan_skips_unsummarized_and_malformed_meetings() throws {
        let id = UUID().uuidString
        try write(stem: "20260716-090000", workflowID: id, workflowName: "Client work",
                  summary: nil)                                   // recorded, not yet summarized
        try "nope".write(to: dir.appendingPathComponent("20260717-090000.meta.json"),
                         atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("20260717-090000.summary.json"),
                       atomically: true, encoding: .utf8)
        try write(stem: "not-a-stem", workflowID: id, workflowName: "Client work",
                  summary: summary(title: "Bad stem", points: ["ignored"]))
        XCTAssertNil(PrepCardStore.scan(recordingsDir: dir, workflowID: id,
                                        workflowName: "Client work"))
    }

    func test_scan_returns_nil_for_a_workflow_with_no_meetings() throws {
        try write(stem: "20260715-090000", workflowID: UUID().uuidString,
                  workflowName: "Client work", summary: summary(title: "Review", points: ["a"]))
        XCTAssertNil(PrepCardStore.scan(recordingsDir: dir, workflowID: UUID().uuidString,
                                        workflowName: "Personal"))
        XCTAssertNil(PrepCardStore.scan(recordingsDir: dir.appendingPathComponent("gone"),
                                        workflowID: UUID().uuidString, workflowName: "Any"))
    }

    // MARK: - Elapsed phrasing

    func test_elapsed_buckets() {
        let cal = Calendar(identifier: .gregorian)
        func at(_ y: Int, _ m: Int, _ d: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: 9))!
        }
        let meeting = at(2026, 7, 20)
        func bucket(_ now: Date) -> RelativeMeetingDateFormatter.Elapsed {
            RelativeMeetingDateFormatter.elapsed(for: meeting, now: now, calendar: cal)
        }
        XCTAssertEqual(bucket(at(2026, 7, 20)), .today)
        XCTAssertEqual(bucket(at(2026, 7, 21)), .yesterday)
        XCTAssertEqual(bucket(at(2026, 7, 23)), .days(3))
        XCTAssertEqual(bucket(at(2026, 8, 10)), .weeks(3))
        XCTAssertEqual(bucket(at(2026, 11, 20)), .months(4))
        // A stem in the future (clock skew) reads as today, never a negative gap.
        XCTAssertEqual(bucket(at(2026, 7, 19)), .today)
    }

    // MARK: - Card view geometry

    func test_card_height_grows_with_each_section() throws {
        let base = PrepCard(workflowName: "W", stem: "20260720-143000", startedAt: started,
                            title: "T", points: ["a"], actions: [], moreActions: 0)
        let withPoints = PrepCard(workflowName: "W", stem: "20260720-143000", startedAt: started,
                                  title: "T", points: ["a", "b"], actions: [], moreActions: 0)
        let withActions = PrepCard(
            workflowName: "W", stem: "20260720-143000", startedAt: started, title: "T",
            points: ["a"], actions: [PrepCard.Action(task: "x", owner: nil, due: nil)],
            moreActions: 0
        )
        let withMore = PrepCard(
            workflowName: "W", stem: "20260720-143000", startedAt: started, title: "T",
            points: ["a"], actions: [PrepCard.Action(task: "x", owner: nil, due: nil)],
            moreActions: 2
        )
        XCTAssertGreaterThan(PrepCardView.height(for: withPoints, width: cardWidth), PrepCardView.height(for: base, width: cardWidth))
        XCTAssertGreaterThan(PrepCardView.height(for: withActions, width: cardWidth), PrepCardView.height(for: base, width: cardWidth))
        XCTAssertGreaterThan(PrepCardView.height(for: withMore, width: cardWidth),
                             PrepCardView.height(for: withActions, width: cardWidth))
    }

    func test_card_height_covers_the_lowest_row() throws {
        let card = PrepCard(
            workflowName: "Client work", stem: "20260720-143000", startedAt: started,
            title: "Weekly sync", points: ["a", "b", "c"],
            actions: [PrepCard.Action(task: "x", owner: "Georgy", due: "2026-07-25"),
                      PrepCard.Action(task: "y", owner: nil, due: nil)],
            moreActions: 2
        )
        let layout = PrepCardView.layout(for: card, width: cardWidth)
        let lowest = layout.moreTop ?? layout.actionTops.last ?? layout.titleTop
        XCTAssertGreaterThan(layout.height, lowest,
                             "the card must be taller than the top of its last row")
        XCTAssertEqual(layout.pointTops.count, 3)
        XCTAssertEqual(layout.actionTops.count, 2)
        XCTAssertEqual(PrepCardView.height(for: card, width: cardWidth), layout.height)
    }

    // MARK: - Panel height clamp (UX34)

    /// The pill band the card hangs under. Passed in explicitly so the decision
    /// stays checkable without a panel; it mirrors `MeetingPromptWindow.panelHeight`.
    private let pillHeight: CGFloat = 64

    /// The panel width the card wraps at (UX47), mirroring
    /// `MeetingPromptWindow.panelWidth` the same way.
    private let cardWidth: CGFloat = 600

    private func sizedCard(points: Int, actions: Int, more: Int = 0) -> PrepCard {
        PrepCard(
            workflowName: "Client work", stem: "20260720-143000", startedAt: started,
            title: "Weekly sync",
            points: (0..<points).map { "point \($0)" },
            actions: (0..<actions).map { PrepCard.Action(task: "task \($0)", owner: nil, due: nil) },
            moreActions: more
        )
    }

    func test_no_card_leaves_the_panel_at_the_pill() {
        // The "Last time" button is collapsed to zero width in this state, so the
        // disclosure is unreachable and the panel must never leave 64pt.
        let out = PrepDisclosure.decide(card: nil, expanded: true, pillHeight: pillHeight,
                                        maxCardHeight: PrepCardView.maxCardHeight, width: cardWidth)
        XCTAssertEqual(out.panelHeight, pillHeight)
        XCTAssertEqual(out.cardHeight, 0)
        XCTAssertEqual(out.contentHeight, 0)
        XCTAssertFalse(out.scrolls)
    }

    func test_collapsing_returns_to_the_pill_however_tall_the_card_is() {
        let full = sizedCard(points: PrepCard.maxPoints, actions: PrepCard.maxActions, more: 2)
        let out = PrepDisclosure.decide(card: full, expanded: false, pillHeight: pillHeight,
                                        maxCardHeight: PrepCardView.maxCardHeight, width: cardWidth)
        XCTAssertEqual(out.panelHeight, pillHeight)
        XCTAssertEqual(out.cardHeight, 0)
        XCTAssertFalse(out.scrolls, "a collapsed card is not a scrolling one")
    }

    func test_a_partial_card_under_the_cap_gets_what_it_needs_and_does_not_scroll() {
        let small = sizedCard(points: 2, actions: 0)
        let content = PrepCardView.height(for: small, width: cardWidth)
        XCTAssertLessThan(content, PrepCardView.maxCardHeight)

        let out = PrepDisclosure.decide(card: small, expanded: true, pillHeight: pillHeight,
                                        maxCardHeight: PrepCardView.maxCardHeight, width: cardWidth)
        XCTAssertEqual(out.cardHeight, content)
        XCTAssertEqual(out.panelHeight, pillHeight + content)
        XCTAssertFalse(out.scrolls)
    }

    func test_a_full_card_is_clamped_and_scrolls() {
        let full = sizedCard(points: PrepCard.maxPoints, actions: PrepCard.maxActions, more: 2)
        let content = PrepCardView.height(for: full, width: cardWidth)
        XCTAssertGreaterThan(content, PrepCardView.maxCardHeight)

        let out = PrepDisclosure.decide(card: full, expanded: true, pillHeight: pillHeight,
                                        maxCardHeight: PrepCardView.maxCardHeight, width: cardWidth)
        XCTAssertEqual(out.cardHeight, PrepCardView.maxCardHeight)
        XCTAssertEqual(out.contentHeight, content, "the document keeps its full height")
        XCTAssertEqual(out.panelHeight, pillHeight + PrepCardView.maxCardHeight)
        XCTAssertTrue(out.scrolls)
        // The 4x jump this task exists to remove: unclamped this panel was ~260pt.
        XCTAssertLessThan(out.panelHeight, pillHeight + content)
    }

    func test_the_cap_shows_the_head_and_slices_the_first_action_row() throws {
        // A tripwire on the derivation rather than a magic number: `maxCardHeight`
        // is built out of the row metrics, so a chrome change moves it and this
        // fails, which is the moment to re-check the panel's budget.
        XCTAssertEqual(PrepCardView.maxCardHeight, 123)

        let full = sizedCard(points: PrepCard.maxPoints, actions: PrepCard.maxActions, more: 2)
        let out = PrepDisclosure.decide(card: full, expanded: true, pillHeight: pillHeight,
                                        maxCardHeight: PrepCardView.maxCardHeight, width: cardWidth)
        XCTAssertLessThanOrEqual(out.panelHeight, 190, "the expanded panel stays small")

        let layout = PrepCardView.layout(for: full, width: cardWidth)
        // Everything the cap was sized around is visible without scrolling: the
        // title, every recap point, and the eyebrow that says actions follow.
        XCTAssertEqual(layout.pointTops.count, PrepCard.maxPoints)
        XCTAssertLessThan(layout.pointTops.last!, out.cardHeight)
        XCTAssertLessThan(try XCTUnwrap(layout.eyebrowTop), out.cardHeight)
        // The first action row starts inside the viewport and the second does not,
        // so the cut lands mid-row. UX34 leaned on that slice as the scroll cue;
        // the owner read it as broken (UX47), so the cue is the bottom fade now
        // and this assertion only pins the viewport geometry for short rows.
        XCTAssertLessThan(layout.actionTops[0], out.cardHeight)
        XCTAssertGreaterThan(layout.actionTops[1], out.cardHeight)
    }

    // MARK: - Wrapped rows (UX47)

    private var longPoint: String {
        "Maharsh's local environment fails to redirect to the dashboard after "
        + "FusionAuth callback, it redirects to the local login page instead, and "
        + "the second attempt prompted for email and password as expected."
    }

    func test_a_long_point_wraps_and_grows_the_card_while_short_cards_are_unchanged() {
        let short = sizedCard(points: 2, actions: 1)
        // Short strings never wrap, so the measured layout must equal the layout
        // at a width where wrapping is impossible: the self-calibrating row gap
        // is what keeps every pre-wrap height byte-identical.
        XCTAssertEqual(PrepCardView.height(for: short, width: cardWidth),
                       PrepCardView.height(for: short, width: 10_000))

        let long = PrepCard(workflowName: "W", stem: "20260730-120000", startedAt: started,
                            title: "T", points: [longPoint], actions: [], moreActions: 0)
        XCTAssertGreaterThan(PrepCardView.height(for: long, width: cardWidth),
                             PrepCardView.height(for: long, width: 10_000),
                             "a long point must wrap taller at the panel width")
    }

    func test_wrapped_tops_stay_ordered_and_inside_the_height() {
        let card = PrepCard(
            workflowName: "W", stem: "20260730-120000", startedAt: started, title: "T",
            points: [longPoint, "short", longPoint],
            actions: [PrepCard.Action(task: longPoint, owner: "THEM-A", due: nil)],
            moreActions: 1
        )
        let layout = PrepCardView.layout(for: card, width: cardWidth)
        let tops = layout.pointTops + [layout.eyebrowTop!] + layout.actionTops + [layout.moreTop!]
        XCTAssertEqual(tops, tops.sorted(), "wrapped rows must not overlap")
        XCTAssertEqual(Set(tops).count, tops.count, "no two rows share a top")
        XCTAssertGreaterThan(layout.height, layout.moreTop!,
                             "the card is taller than the top of its last row")
        // The first long point pushes the second row further down than a
        // single-line row ever could.
        XCTAssertGreaterThan(layout.pointTops[1] - layout.pointTops[0], 18)
    }

    /// The promoted 2026-07-30 probe, kept as the regression fence. Before the
    /// width was anchored, this exact card laid out 879pt wide in a 600pt panel:
    /// bullets at maxX 773/867/823 against the 588 inset and the right-aligned
    /// date off-panel at 867. Layout is real AppKit here, no window needed.
    @MainActor
    func test_labels_stay_inside_the_panel_width() {
        let card = PrepCard(
            workflowName: "Personal", stem: "20260729-160013", startedAt: started,
            title: "FusionAuth Local Login Redirect Issue Debugging",
            points: [
                longPoint,
                "THEM-A identified a likely misconfiguration: valid audiences not set for the module CPI, and back-office FusionAuth auth left enabled unnecessarily.",
                "Dhanisa's machine reportedly works fine, making the issue specific to Maharsh's local setup.",
            ],
            actions: [PrepCard.Action(
                task: "Investigate why the FusionAuth callback token cannot be stored locally, causing redirect to local login page instead of dashboard",
                owner: "THEM-A", due: nil
            )],
            moreActions: 2
        )
        let view = PrepCardView(card: card, now: started, width: 600)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 600),
            view.heightAnchor.constraint(
                equalToConstant: PrepCardView.height(for: card, width: 600)
            ),
        ])
        view.layoutSubtreeIfNeeded()

        var wrapped = 0
        var rightAligned: NSTextField?
        for case let field as NSTextField in view.subviews {
            // Constraints position the ALIGNMENT rect; an NSTextField's frame
            // extends ~2pt past it on each side, so measure the rect the layout
            // actually controls. (The broken numbers were frames too, at 773,
            // 867 and 823, so the fence catches the regression either way.)
            let aligned = field.alignmentRect(forFrame: field.frame)
            XCTAssertLessThanOrEqual(
                aligned.maxX, 600 - 12 + 0.5,
                "'\(field.stringValue.prefix(30))' escapes the inset; the 879pt regression is back"
            )
            if field.frame.height > 22 { wrapped += 1 }
            if field.alignment == .right { rightAligned = field }
        }
        XCTAssertGreaterThanOrEqual(wrapped, 3, "the long bullets and the action must actually wrap")
        let date = rightAligned
        XCTAssertNotNil(date, "the relative-day label exists")
        if let date {
            let aligned = date.alignmentRect(forFrame: date.frame)
            XCTAssertGreaterThan(aligned.minX, 300, "the date sits at the card's top right")
            XCTAssertLessThanOrEqual(aligned.maxX, 600 - 12 + 0.5,
                                     "the date is on-panel, which it was not under UX34")
        }
    }

    // MARK: - Fade rule (UX47)

    func test_the_fade_shows_only_while_content_remains_below() {
        // Fits its viewport: nothing to reveal, no fade.
        XCTAssertFalse(PrepDisclosure.fadeVisible(contentHeight: 100, viewport: 123, offsetY: 0))
        // Scrolled to the top of an overflowing card: fade.
        XCTAssertTrue(PrepDisclosure.fadeVisible(contentHeight: 196, viewport: 123, offsetY: 0))
        // Mid-scroll: still more below.
        XCTAssertTrue(PrepDisclosure.fadeVisible(contentHeight: 196, viewport: 123, offsetY: 60))
        // At the bottom: the last row reads complete.
        XCTAssertFalse(PrepDisclosure.fadeVisible(contentHeight: 196, viewport: 123, offsetY: 73))
        // Within the 2pt slop of the bottom: same.
        XCTAssertFalse(PrepDisclosure.fadeVisible(contentHeight: 196, viewport: 123, offsetY: 71.5))
        // No card at all.
        XCTAssertFalse(PrepDisclosure.fadeVisible(contentHeight: 0, viewport: 0, offsetY: 0))
    }

    func test_the_fade_band_is_a_fixed_height_not_a_fraction() {
        // 26 of 123 leaves the top 79% opaque; the band must stay 26pt whatever
        // the viewport, so a taller card does not fade a taller slab.
        let at123 = PrepDisclosure.fadeLocations(viewport: 123, fadeHeight: 26)
        XCTAssertEqual(at123.count, 3)
        XCTAssertEqual(at123[0], 0)
        XCTAssertEqual(at123[2], 1)
        XCTAssertEqual((1 - at123[1]) * 123, 26, accuracy: 0.01)

        let at246 = PrepDisclosure.fadeLocations(viewport: 246, fadeHeight: 26)
        XCTAssertEqual((1 - at246[1]) * 246, 26, accuracy: 0.01,
                       "the band is points, not a proportion of the viewport")

        // Degenerate inputs stay inside [0, 1] rather than producing a negative
        // stop, which Core Animation rejects.
        for loc in PrepDisclosure.fadeLocations(viewport: 10, fadeHeight: 26) {
            XCTAssertTrue((0...1).contains(loc), "stop \(loc) escapes [0,1]")
        }
        XCTAssertEqual(PrepDisclosure.fadeLocations(viewport: 0, fadeHeight: 26)[1], 0)
    }

    /// The 2026-07-30 regression, and the reason this fence is source-level: a
    /// mask is positioned in its layer's coordinate space, and a clip view's
    /// bounds *origin* is what moves when the card scrolls. Anchored at
    /// `origin: .zero` the mask stayed over the document's first screenful while
    /// the viewport moved down, so everything past it had no mask coverage and
    /// rendered fully transparent: the owner saw an empty card below the second
    /// bullet, with the eyebrow and actions unreachable however far they
    /// scrolled. Not observable without a live panel, so it is pinned here.
    func test_the_fade_mask_follows_the_scrolled_bounds_origin() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/MeetingPipe/MeetingPromptWindow.swift"),
            encoding: .utf8
        )
        guard let fade = source.range(of: "private func updatePrepFade") else {
            return XCTFail("updatePrepFade no longer exists under that name; re-point this fence")
        }
        guard let end = source.range(of: "private func teardownPrepFade",
                                     range: fade.upperBound ..< source.endIndex) else {
            return XCTFail("teardownPrepFade no longer follows it; re-point this fence")
        }
        // Comments stripped first: the body explains the regression in prose that
        // quotes the very literal being banned, and a fence that reads its own
        // commentary is no fence at all.
        let body = source[fade.lowerBound ..< end.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let slashes = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex ..< slashes.lowerBound])
            }
            .joined(separator: "\n")

        XCTAssertTrue(body.contains("grad.frame = clip.bounds"),
                      "the mask must take the clip's full bounds, origin included")
        XCTAssertFalse(body.contains("origin: .zero"),
                       "a zero-origin mask stops covering the viewport the moment the card scrolls")
    }

    func test_action_line_degrades_as_fields_go_missing() {
        XCTAssertEqual(
            PrepCardView.actionLine(PrepCard.Action(task: "Send SOW", owner: "Georgy",
                                                    due: "2026-07-25")),
            "Send SOW  ·  Georgy  ·  due 2026-07-25"
        )
        XCTAssertEqual(
            PrepCardView.actionLine(PrepCard.Action(task: "Send SOW", owner: nil,
                                                    due: "2026-07-25")),
            "Send SOW  ·  due 2026-07-25"
        )
        XCTAssertEqual(
            PrepCardView.actionLine(PrepCard.Action(task: "Send SOW", owner: nil, due: nil)),
            "Send SOW"
        )
    }
}
