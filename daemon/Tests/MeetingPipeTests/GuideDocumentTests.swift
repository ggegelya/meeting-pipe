import XCTest
@testable import MeetingPipe

/// DOC11. Two halves, and the second is the one that matters.
///
/// The parser half pins the block kinds `docs/GUIDE.md` uses, because a guide
/// that renders as one undifferentiated wall is not a guide.
///
/// The fence half pins the chain the menu item depends on end to end: the
/// document exists in the repo, it carries the ten recipe areas the task asked
/// for, the install scripts copy it into the app bundle, and the status-bar menu
/// has a row wired to the action that opens it. Every link there is invisible at
/// runtime until a user clicks Guide… and gets an apology, which is exactly the
/// class of miss DOC9 spent a sweep cleaning up.
final class GuideDocumentTests: XCTestCase {

    private typealias D = GuideDocument

    // MARK: - Parsing

    func test_headings_carry_their_level() {
        XCTAssertEqual(D.parse("# One"), [.heading(level: 1, text: "One")])
        XCTAssertEqual(D.parse("## Two"), [.heading(level: 2, text: "Two")])
        XCTAssertEqual(D.parse("### Three"), [.heading(level: 3, text: "Three")])
    }

    /// Wrapped prose is one block, not one per source line, or every paragraph
    /// would render with its author's line breaks baked in.
    func test_consecutive_lines_join_into_one_paragraph() {
        XCTAssertEqual(
            D.parse("alpha\nbeta\n\ngamma"),
            [.paragraph("alpha beta"), .paragraph("gamma")]
        )
    }

    func test_bullets_and_numbered_items() {
        XCTAssertEqual(D.parse("- first\n- second"), [.bullet("first"), .bullet("second")])
        XCTAssertEqual(
            D.parse("1. first\n2. second"),
            [.numbered(index: 1, text: "first"), .numbered(index: 2, text: "second")]
        )
    }

    /// A sentence with a full stop in it is not a numbered item. The naive
    /// "split on the first dot" rule would turn most of the guide into a list.
    func test_a_sentence_is_not_a_numbered_item() {
        XCTAssertEqual(
            D.parse("A digest is a review. It shows commitments."),
            [.paragraph("A digest is a review. It shows commitments.")]
        )
    }

    func test_pipe_table() {
        let md = """
            | Key | Does |
            | --- | --- |
            | `⌃⌥M` | Start or stop |
            | `⌃⌥F` | Flag a moment |
            """
        XCTAssertEqual(D.parse(md), [
            .table(headers: ["Key", "Does"],
                   rows: [["`⌃⌥M`", "Start or stop"], ["`⌃⌥F`", "Flag a moment"]])
        ])
    }

    /// The separator row is required. Without that check a paragraph that merely
    /// starts with a pipe would be eaten as a one-row table.
    func test_pipes_without_a_separator_row_stay_visible() {
        let parsed = D.parse("| not | a table |\n| still | not |")
        XCTAssertEqual(parsed, [.paragraph("| not | a table |"), .paragraph("| still | not |")])
    }

    func test_horizontal_rule() {
        XCTAssertEqual(D.parse("a\n\n---\n\nb"), [.paragraph("a"), .rule, .paragraph("b")])
    }

    /// A link the window cannot follow is flattened to its label. DOC11 applied
    /// that to same-document anchors; DOC13 widened it to every unresolvable
    /// shape, because `../README.md` has the identical property and fails worse
    /// (it looks like a working cross-reference). A real destination is left
    /// alone for the view's inline parser to turn into a link.
    func test_unfollowable_links_flatten_and_real_links_survive() {
        XCTAssertEqual(D.flatten("see [recipe 2](#2-workflows) now"), "see recipe 2 now")
        XCTAssertEqual(D.flatten("[a](#x) and [b](#y)"), "a and b")
        XCTAssertEqual(D.flatten("an unclosed [bracket"), "an unclosed [bracket")

        // The four shapes DOC13 was filed over, plus the bare relative path.
        XCTAssertEqual(D.flatten("see [the readme](../README.md)"), "see the readme")
        XCTAssertEqual(D.flatten("[`SETUP.md`](./SETUP.md) helps"), "`SETUP.md` helps")
        XCTAssertEqual(D.flatten("[Moving](../README.md#moving-to-a-new-mac)"), "Moving")
        XCTAssertEqual(D.flatten("[docs](docs/GUIDE.md)"), "docs")

        // Something the system can actually open survives whole.
        XCTAssertEqual(
            D.flatten("[the repo](https://github.com/x/y)"),
            "[the repo](https://github.com/x/y)"
        )
    }

    /// The predicate under the rule above, stated directly: an allowlist of
    /// destinations the window can open, not a list of shapes to reject.
    /// Rejecting shapes is exactly how DOC11 caught the anchor case and left the
    /// four repo paths beside it standing.
    func test_only_openable_schemes_can_be_followed() {
        for followable in ["https://x.test", "http://x.test", "mailto:a@b.test"] {
            XCTAssertTrue(D.canFollow(followable), "\(followable) should survive as a link")
        }
        for dead in ["#anchor", "./SETUP.md", "../README.md", "docs/GUIDE.md", "GUIDE.md", ""] {
            XCTAssertFalse(D.canFollow(dead), "\(dead) resolves to nothing in a window")
        }
    }

    // MARK: - Repo-only blocks

    /// One file, two readers: a contributor in a checkout and a user in a
    /// window. What only serves the first is marked and never reaches the
    /// second.
    func test_repo_only_blocks_are_dropped() {
        let md = """
            visible before

            \(D.repoOnlyOpen)
            ## Contents

            - [a](#a)
            \(D.repoOnlyClose)

            visible after
            """
        XCTAssertEqual(D.parse(md), [.paragraph("visible before"), .paragraph("visible after")])
    }

    /// An unclosed block swallows the rest of the document. That is the safe
    /// direction (contributor content stays out) and the loud one, since
    /// `test_the_shipped_guide_balances_its_repo_only_markers` fails on the
    /// authoring mistake that causes it.
    func test_an_unclosed_repo_only_block_runs_to_the_end() {
        XCTAssertEqual(
            D.parse("kept\n\n\(D.repoOnlyOpen)\n\ndropped\n\nalso dropped"),
            [.paragraph("kept")]
        )
    }

    /// A close with no open is skipped rather than falling through as a
    /// paragraph, so the marker never renders as literal text in the window.
    func test_a_stray_close_marker_never_renders() {
        XCTAssertEqual(D.parse("\(D.repoOnlyClose)\n\nbody"), [.paragraph("body")])
    }

    // MARK: - Section breaks

    /// `---` immediately above a `## Section` is dropped: the heading already is
    /// the break, and the hairline landing a few points above it is most of what
    /// made this read as a rendered markdown file rather than an application.
    func test_a_rule_above_a_section_heading_is_dropped() {
        XCTAssertEqual(
            D.parse("a\n\n---\n\n## Two\n\nb"),
            [.paragraph("a"), .heading(level: 2, text: "Two"), .paragraph("b")]
        )
    }

    /// Only that adjacency. Between two paragraphs, or above any other heading
    /// level, the rule is the only separator there is and stays.
    func test_other_rules_survive() {
        XCTAssertEqual(D.parse("a\n\n---\n\nb"), [.paragraph("a"), .rule, .paragraph("b")])
        XCTAssertEqual(
            D.parse("a\n\n---\n\n### Three"),
            [.paragraph("a"), .rule, .heading(level: 3, text: "Three")]
        )
    }

    // MARK: - The rail's current section

    /// The reader is in the section whose heading they most recently passed, so
    /// the mark is the last heading at or above the top band.
    func test_current_section_is_the_last_heading_passed() {
        let sections = [
            D.Section(title: "One", blockIndex: 4),
            D.Section(title: "Two", blockIndex: 40),
            D.Section(title: "Three", blockIndex: 90),
        ]
        // Scrolled into the second: its heading is just above the top, the third
        // is still far below.
        XCTAssertEqual(
            D.currentSection(offsets: [4: -900, 40: -20, 90: 600], sections: sections),
            40
        )
        // At the very bottom, every heading has gone past.
        XCTAssertEqual(
            D.currentSection(offsets: [4: -2000, 40: -1400, 90: -200], sections: sections),
            90
        )
    }

    /// Above the first heading, in the guide's opening paragraphs, the rail
    /// still marks the first section. Deliberately not literal: a rail with no
    /// mark at all reads as broken on open.
    func test_current_section_leads_with_the_first_before_any_has_passed() {
        let sections = [D.Section(title: "One", blockIndex: 4), D.Section(title: "Two", blockIndex: 40)]
        XCTAssertEqual(D.currentSection(offsets: [4: 300, 40: 900], sections: sections), 4)
        XCTAssertEqual(D.currentSection(offsets: [:], sections: sections), 4)
        XCTAssertNil(D.currentSection(offsets: [:], sections: []))
    }

    func test_sections_are_the_level_two_headings_in_order() {
        let blocks = D.parse("# Title\n\nintro\n\n## One\n\nbody\n\n### Sub\n\n## Two")
        XCTAssertEqual(D.sections(of: blocks).map(\.title), ["One", "Two"])
        // The index has to address the heading itself; the rail scrolls to it.
        for section in D.sections(of: blocks) {
            XCTAssertEqual(blocks[section.blockIndex], .heading(level: 2, text: section.title))
        }
    }

    // MARK: - The shipped guide

    func test_the_guide_exists_and_parses_into_blocks() throws {
        let blocks = D.parse(try guideMarkdown())
        XCTAssertGreaterThan(blocks.count, 100, "docs/GUIDE.md parsed to almost nothing")
        XCTAssertTrue(blocks.contains { if case .table = $0 { return true } else { return false } },
                      "the hotkey and retention tables should parse as tables")
    }

    /// The ten recipe areas DOC11 asked for. Matched on a keyword rather than a
    /// full title, so rewording a heading is free and dropping an area is not.
    func test_the_guide_carries_the_ten_recipe_areas() throws {
        let titles = D.sections(of: D.parse(try guideMarkdown()))
            .map { $0.title.lowercased() }
        for area in ["recording", "workflow", "vocabulary", "voices",
                     "finding", "ask", "weekly", "safe", "hotkeys", "wrong"] {
            XCTAssertTrue(titles.contains { $0.contains(area) },
                          "docs/GUIDE.md has no section covering '\(area)'")
        }
    }

    // MARK: - No repo-shaped reference reaches the window (DOC13)

    /// The defect DOC13 was filed over: the shipped guide linked four repository
    /// paths, and the reader was told the real reference lived in a file the app
    /// cannot open, on a path that only means something inside a checkout.
    ///
    /// Pinned over the document rather than promised in review, because the
    /// class keeps coming back: DOC11 solved the same problem one case narrower
    /// (same-document anchors) and stopped, and these four were sitting beside
    /// the code that flattened those.
    func test_no_repo_shaped_link_survives_into_the_window() throws {
        let targets = D.parse(try guideMarkdown()).flatMap { linkTargets(in: text(of: $0)) }
        for target in targets {
            XCTAssertFalse(target.contains("../"),
                           "docs/GUIDE.md renders a link to '\(target)', which is a path into a git checkout")
            XCTAssertFalse(target.lowercased().hasSuffix(".md"),
                           "docs/GUIDE.md renders a link to '\(target)', a file the app cannot open")
        }
    }

    /// The same fence over the source outside the repo-only markers, because the
    /// check above would pass on a repo path parked inside a marked block: it
    /// would never render, and it would still be sitting in the file as the
    /// shape the next edit copies. Neither half is redundant. The first catches
    /// a link the renderer would show, the second catches the habit.
    func test_the_guide_source_outside_repo_only_blocks_names_no_file() throws {
        let source = try renderedSource()
        for shape in ["../", ".md", "](./"] {
            XCTAssertFalse(source.contains(shape),
                           "docs/GUIDE.md carries '\(shape)' outside a repo-only block")
        }
    }

    /// The four instances named in DOC13's Context, by their literal text, plus
    /// the fifth the sweep found beside them (the glossary pointer in the words
    /// section). Spelled out rather than left to the shape checks above so a
    /// regression names itself.
    func test_the_links_doc13_was_filed_over_are_gone() throws {
        let source = try guideMarkdown()
        for gone in [
            "](./SETUP.md)",
            "](../README.md)",
            "](../README.md#moving-to-a-new-mac)",
            "](../README.md#troubleshooting)",
            "](../ARCHITECTURE.md#glossary)",
        ] {
            XCTAssertFalse(source.contains(gone), "docs/GUIDE.md still links '\(gone)'")
        }
    }

    /// An unclosed `repo-only` block swallows the rest of the document, which is
    /// the right way for the parser to fail and a terrible way for the guide to
    /// ship. This is the check that turns that into a red suite.
    func test_the_shipped_guide_balances_its_repo_only_markers() throws {
        var depth = 0
        for (offset, raw) in try guideMarkdown().components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == D.repoOnlyOpen {
                depth += 1
                XCTAssertEqual(depth, 1, "docs/GUIDE.md:\(offset + 1): repo-only blocks do not nest")
            }
            if line == D.repoOnlyClose {
                depth -= 1
                XCTAssertEqual(depth, 0, "docs/GUIDE.md:\(offset + 1): close marker with no open")
            }
        }
        XCTAssertEqual(depth, 0, "docs/GUIDE.md leaves a repo-only block open, which drops the rest of the guide")
    }

    // MARK: - The chain behind the menu item

    /// The menu row exists and is wired to the action that opens the window.
    /// SwiftUI and NSMenu construction are not observable headlessly, so this is
    /// pinned in source, the way `AutomationReferenceTests` pins the Advanced
    /// pane and `SummaryLayoutTests` pins the tab underline.
    func test_the_status_bar_menu_carries_a_guide_row() throws {
        let controller = try repoFile("daemon/Sources/MeetingPipe/StatusBarController.swift")
        XCTAssertTrue(controller.contains("\"Guide…\""),
                      "the status-bar menu must carry a Guide row")
        XCTAssertTrue(controller.contains("Coordinator.menuOpenGuide"),
                      "the Guide row must be wired to menuOpenGuide")

        let actions = try repoFile("daemon/Sources/MeetingPipe/Coordinator+MenuActions.swift")
        XCTAssertTrue(actions.contains("func menuOpenGuide"),
                      "menuOpenGuide has to exist for the row's selector to resolve")
        XCTAssertTrue(actions.contains("guideWindow.show()"),
                      "menuOpenGuide must open the guide window")
    }

    /// The document only reaches the app because the install scripts copy it, and
    /// that copy is silent when it stops happening: the window falls back to the
    /// missing-copy message and nothing else complains.
    func test_the_install_scripts_put_the_guide_in_the_bundle() throws {
        for script in ["scripts/install.sh", "scripts/rebuild.sh"] {
            let text = try repoFile(script)
            XCTAssertTrue(text.contains("docs/GUIDE.md"),
                          "\(script) must copy docs/GUIDE.md into the app bundle")
            XCTAssertTrue(text.contains("Resources/GUIDE.md"),
                          "\(script) must land the guide where Bundle.main looks for it")
        }
    }

    /// The reader looks for `GUIDE.md`; the scripts write `GUIDE.md`. Pinning the
    /// name in one place is what keeps a rename from breaking the window quietly.
    func test_the_resource_name_matches_what_the_scripts_write() {
        XCTAssertEqual(D.resourceName, "GUIDE")
    }

    // MARK: - Helpers

    private func guideMarkdown() throws -> String {
        try repoFile("docs/GUIDE.md")
    }

    /// The guide's source with every repo-only block removed: exactly the text
    /// the window is handed, before any parsing.
    private func renderedSource() throws -> String {
        var kept: [String] = []
        var inside = false
        for raw in try guideMarkdown().components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == D.repoOnlyOpen { inside = true; continue }
            if line == D.repoOnlyClose { inside = false; continue }
            if !inside { kept.append(raw) }
        }
        return kept.joined(separator: "\n")
    }

    /// The prose a block renders, for the link sweep. `.rule` carries none.
    private func text(of block: D.Block) -> String {
        switch block {
        case .heading(_, let t), .paragraph(let t), .bullet(let t), .numbered(_, let t):
            return t
        case .table(let headers, let rows):
            return (headers + rows.flatMap { $0 }).joined(separator: " ")
        case .rule:
            return ""
        }
    }

    /// Every markdown link destination in a string: the `x` of `[label](x)`.
    private func linkTargets(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\]\(([^)]*)\)"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    /// A file relative to the repository root.
    private func repoFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
            .deletingLastPathComponent()   // repo root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
