import AppKit
import XCTest
@testable import MeetingPipe

/// FEAT16: the clipboard share, pinned on both halves of the owner's ask.
///
/// Every test here runs against a scratch `NSPasteboard(name:)`, per AUTO4: a test
/// has no business overwriting what the owner last copied, and `.general` appears
/// nowhere in this file.
/// T7 source fence (pins implementation): test_the_actions_menu_routes_both_shares_through_toolbarAction asserts MeetingDetailView+Header calls toolbarAction and copyRichText for each surface. Missing seam: an inspectable SwiftUI menu, or the menu built from a model.
final class RichTextShareTests: XCTestCase {

    private var boards: [NSPasteboard] = []

    override func tearDown() {
        for board in boards { board.releaseGlobally() }
        boards = []
        super.tearDown()
    }

    private func scratchBoard(_ name: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("mp.feat16.\(name).\(UUID().uuidString)"))
        boards.append(board)
        return board
    }

    private func summary() -> MeetingSummary {
        MeetingSummary(
            title: "Weekly sync",
            summary: ["Shipped the **installer**", "Cut scope on search"],
            decisions: ["Ship on Friday"],
            actions: [MeetingSummary.ActionItem(task: "Send release notes", owner: "Sam")],
            questions: ["Who owns the rollout?"],
            attendees: ["Sam", "Ada"]
        )
    }

    // MARK: - The whole contract in one assertion

    /// Three flavors, one item. This is the entire feature: the receiver takes the
    /// richest flavor it understands and Paste and Match Style reads the plain one,
    /// so a missing flavor is a silently broken paste rather than a degraded one.
    func test_a_summary_share_leaves_all_three_flavors_on_one_item() throws {
        let board = scratchBoard("three-flavors")
        XCTAssertTrue(RichTextShare.write(MeetingShare.summaryDocument(summary()), to: board))

        XCTAssertEqual(board.pasteboardItems?.count, 1,
                       "the three flavors have to ride one item, or a receiver sees three separate copies")
        let item = try XCTUnwrap(board.pasteboardItems?.first)
        XCTAssertFalse(item.string(forType: .html)?.isEmpty ?? true, "no .html flavor")
        XCTAssertFalse(item.string(forType: .string)?.isEmpty ?? true, "no .string flavor")
        XCTAssertFalse(item.data(forType: .rtf)?.isEmpty ?? true, "no .rtf flavor")
        XCTAssertTrue(try XCTUnwrap(item.data(forType: .rtf)).starts(with: Array("{\\rtf".utf8)),
                      "the .rtf flavor is not RTF")
    }

    /// The half a rich-only implementation silently breaks. Cmd+Shift+V reads this
    /// flavor, so it has to be prose rather than markdown source: no `##`, no `**`.
    func test_the_plain_flavor_is_the_readable_rendering() throws {
        let board = scratchBoard("plain")
        RichTextShare.write(MeetingShare.summaryDocument(summary()), to: board)
        let plain = try XCTUnwrap(board.string(forType: .string))

        XCTAssertTrue(plain.contains("Weekly sync"))
        XCTAssertTrue(plain.contains("Shipped the installer"), "bold markers survived into the plain flavor")
        XCTAssertTrue(plain.contains("Summary"), "the section heading is gone, not just its markers")
        XCTAssertTrue(plain.contains("- Cut scope on search"), "list markers read as lists in plain text and should stay")
        XCTAssertFalse(plain.contains("#"), "a heading marker reached the plain flavor")
        XCTAssertFalse(plain.contains("**"), "a bold marker reached the plain flavor")
        XCTAssertFalse(plain.contains("_Language"), "an italic marker reached the plain flavor")
        XCTAssertFalse(plain.contains("<"), "the plain flavor is carrying markup")
    }

    /// The rich half: structure has to arrive as markup, not as escaped characters.
    func test_the_html_flavor_carries_structure_rather_than_markers() throws {
        let board = scratchBoard("html")
        RichTextShare.write(MeetingShare.summaryDocument(summary()), to: board)
        let html = try XCTUnwrap(board.string(forType: .html))

        XCTAssertTrue(html.contains("<h1>Weekly sync</h1>"), "the title is not a heading")
        XCTAssertTrue(html.contains("<h2>Summary</h2>"), "a section is not a heading")
        XCTAssertTrue(html.contains("<strong>installer</strong>"), "bold did not become strong")
        XCTAssertTrue(html.contains("<ul>"), "the bullets are not a list")
        XCTAssertTrue(html.contains("<li>"), "the bullets are not list items")
        XCTAssertTrue(html.contains("<ol>"), "numbered decisions are not an ordered list")
        XCTAssertFalse(html.contains("## "), "a heading marker reached the HTML flavor as text")
        XCTAssertFalse(html.contains("**"), "a bold marker reached the HTML flavor as text")
    }

    /// Prose is escaped, so a `<` somebody said cannot open a tag in the receiver.
    func test_prose_is_escaped_before_it_becomes_markup() {
        let html = RichTextShare.bodyHTML(markdown: "- a < b && c > d")
        XCTAssertTrue(html.contains("a &lt; b &amp;&amp; c &gt; d"), html)
    }

    /// `_snake_case_` names are not emphasis, and the guard that stops that is the
    /// one thing about the inline rule worth pinning on its own.
    func test_underscores_inside_a_word_are_not_emphasis() {
        XCTAssertEqual(RichTextShare.inlineHTML("read some_file_name now"), "read some_file_name now")
        XCTAssertEqual(RichTextShare.inlineHTML("read _this_ now"), "read <em>this</em> now")
    }

    // MARK: - The trap: what is on disk is not what the reader sees

    /// The transcript share renders the reader's speaker names.
    ///
    /// This is the test that fails against the obvious implementation. `speaker_0`
    /// and `THEM-A` are internal ids that never appear on screen, and a name given
    /// in the app lives in the overlay rather than in `<stem>.json`, so anything
    /// that reads the file and renders it copies all three raw.
    func test_the_transcript_share_renders_the_readers_speaker_names() throws {
        let segments = [
            TranscriptSegment(index: 0, start: 0, end: 2, text: "Morning.", speakerID: "speaker_0"),
            TranscriptSegment(index: 1, start: 2, end: 4, text: "Morning.", speakerID: "THEM-A"),
            TranscriptSegment(index: 2, start: 4, end: 6, text: "Let us start.", speakerID: "THEM-B"),
        ]
        let overlay = SpeakerLabelStore.Overlay(labels: ["THEM-B": "Anisha"], segments: [:])
        let lines = MeetingShare.lines(segments: segments, overlay: overlay, voiceprintLabels: [])
        XCTAssertEqual(lines.map(\.speaker), ["Speaker 1", "Unknown A", "Anisha"])

        let board = scratchBoard("transcript-names")
        RichTextShare.write(MeetingShare.transcriptDocument(title: "Standup", lines: lines), to: board)
        let item = try XCTUnwrap(board.pasteboardItems?.first)
        let html = try XCTUnwrap(item.string(forType: .html))
        let plain = try XCTUnwrap(item.string(forType: .string))
        let rtf = try XCTUnwrap(item.data(forType: .rtf))
        let rtfText = try XCTUnwrap(
            NSAttributedString(rtf: rtf, documentAttributes: nil)?.string
        )

        for flavor in [html, plain, rtfText] {
            XCTAssertTrue(flavor.contains("Speaker 1"), "missing the reader's name for speaker_0")
            XCTAssertTrue(flavor.contains("Unknown A"), "missing the reader's name for THEM-A")
            XCTAssertTrue(flavor.contains("Anisha"), "missing the name given in the app")
            XCTAssertFalse(flavor.contains("speaker_0"), "a raw diarization id reached the clipboard")
            XCTAssertFalse(flavor.contains("THEM-"), "a raw cluster label reached the clipboard")
        }
    }

    /// A per-line reassignment moves a line's speaker without touching
    /// `<stem>.json` either, so the resolution has to be `MeetingCast.rowSpeaker`
    /// rather than `segment.speakerID`.
    func test_a_per_line_reassignment_moves_the_shared_speaker() {
        let segments = [
            TranscriptSegment(index: 0, start: 0, end: 2, text: "Mine.", speakerID: "THEM-A"),
        ]
        let overlay = SpeakerLabelStore.Overlay(labels: [:], segments: [0: "Sudip"])
        let lines = MeetingShare.lines(segments: segments, overlay: overlay, voiceprintLabels: [])
        XCTAssertEqual(lines.map(\.speaker), ["Sudip"])
    }

    /// A text edit is an overlay too. Driven end to end through the loader, because
    /// the composition is what carries the overlay: the renderer alone cannot tell
    /// a corrected line from an original one.
    func test_a_text_correction_held_as_an_overlay_appears_in_the_shared_text() throws {
        let dir = try temporaryDirectory()
        let stem = "20260817-101500"
        try """
        {"language": "en", "segments": [
          {"start": 0.0, "end": 2.0, "text": "we use cube kernetes", "speaker": "speaker_0"}
        ]}
        """.write(to: dir.appendingPathComponent("\(stem).json"), atomically: true, encoding: .utf8)
        _ = try TranscriptCorrectionStore.upsert(
            segmentIndex: 0,
            pipelineOriginal: "we use cube kernetes",
            edited: "we use Kubernetes",
            stem: stem,
            in: dir
        )

        let document = try XCTUnwrap(
            MeetingShare.document(.transcript, stem: stem, title: "Standup", in: dir)
        )
        XCTAssertTrue(document.plain.contains("we use Kubernetes"), document.plain)
        XCTAssertFalse(document.plain.contains("cube kernetes"), "the un-corrected text was shared")
        XCTAssertTrue(document.html.contains("we use Kubernetes"), document.html)
        XCTAssertFalse(document.html.contains("cube kernetes"), "the un-corrected text was shared")
        // And the same read resolves the display name, not the raw id.
        XCTAssertTrue(document.plain.contains("Speaker 1"), document.plain)
    }

    /// Nothing on disk is `nil`, not an empty document: the caller reports it rather
    /// than leaving the owner's previous copy on the clipboard to be pasted as this
    /// meeting's.
    func test_a_meeting_with_neither_document_yields_nothing_to_copy() throws {
        let dir = try temporaryDirectory()
        XCTAssertNil(MeetingShare.document(.summary, stem: "20260817-101500", title: "x", in: dir))
        XCTAssertNil(MeetingShare.document(.transcript, stem: "20260817-101500", title: "x", in: dir))
    }

    /// A transcript that parsed to no usable lines is nothing to copy too, not a
    /// document holding only a title.
    func test_an_empty_transcript_yields_nothing_to_copy() throws {
        let dir = try temporaryDirectory()
        let stem = "20260817-101500"
        try #"{"language": "en", "segments": []}"#
            .write(to: dir.appendingPathComponent("\(stem).json"), atomically: true, encoding: .utf8)
        XCTAssertNil(MeetingShare.document(.transcript, stem: stem, title: "Standup", in: dir))
    }

    // MARK: - The event

    /// The share logs `detail` / `toolbar_action` naming the meeting, like every
    /// other item in that menu. Driven through the header's own `toolbarAction`
    /// rather than asserted in source, so this pins the emission and not a spelling.
    @MainActor
    func test_the_share_emits_its_detail_toolbar_action_event() throws {
        let dir = try temporaryDirectory()
        let logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }

        let stem = "20260817-101500"
        let view = MeetingDetailView(
            store: MeetingStore(recordingsDir: dir),
            meeting: Meeting(
                stem: stem,
                startedAt: Date(),
                audioURL: nil,
                recordingsDir: dir,
                summaryTitle: nil, meetingTitle: nil,
                sourceBundleID: nil, sourceDisplayName: nil, sourceKind: nil,
                workflowName: nil, workflowColor: nil,
                durationSec: nil, backend: nil, modelId: nil,
                status: .done,
                failureReason: nil, failureStage: nil,
                searchableText: ""
            )
        )
        var ran = 0
        for surface in MeetingShare.Surface.allCases {
            view.toolbarAction(surface.rawValue) { ran += 1 }
        }
        XCTAssertEqual(ran, 2)

        let rows = try String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["category"] as? String == "detail" }
        XCTAssertEqual(rows.map { $0["action"] as? String }, ["toolbar_action", "toolbar_action"])
        XCTAssertEqual(rows.map { $0["item"] as? String },
                       ["copy_summary_rich", "copy_transcript_rich"])
        XCTAssertEqual(rows.map { $0["stem"] as? String }, [stem, stem])
    }

    /// And the menu really routes through it. The event above proves `toolbarAction`
    /// emits; only the source can show that the two new items go through it rather
    /// than calling the copy directly, since SwiftUI menu content is not observable
    /// headlessly (the AUTO4 precedent).
    func test_the_actions_menu_routes_both_shares_through_toolbarAction() throws {
        let header = try daemonSource("Sources/MeetingPipe/MeetingDetailView+Header.swift")
        for surface in MeetingShare.Surface.allCases {
            XCTAssertTrue(
                header.contains("toolbarAction(MeetingShare.Surface.\(surface).rawValue)"),
                "\(surface) is not routed through toolbarAction, so it emits no detail event"
            )
        }
        XCTAssertTrue(header.contains("copyRichText(.summary)"))
        XCTAssertTrue(header.contains("copyRichText(.transcript)"))
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-feat16-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Source of a file in the daemon target, the `AutomationReferenceTests` helper.
    private func daemonSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
