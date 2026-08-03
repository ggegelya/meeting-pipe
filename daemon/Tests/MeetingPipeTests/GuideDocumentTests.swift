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

    /// A `#section` link works in a file and resolves to nothing in a window, so
    /// it is flattened to its label. A real destination is left alone for the
    /// view's inline parser to turn into a link.
    func test_same_document_links_flatten_and_real_links_survive() {
        XCTAssertEqual(D.flatten("see [recipe 2](#2-workflows) now"), "see recipe 2 now")
        XCTAssertEqual(D.flatten("see [the readme](../README.md)"), "see [the readme](../README.md)")
        XCTAssertEqual(D.flatten("[a](#x) and [b](#y)"), "a and b")
        XCTAssertEqual(D.flatten("an unclosed [bracket"), "an unclosed [bracket")
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
