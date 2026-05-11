import XCTest
@testable import MeetingPipe

/// Pure-logic coverage for the drag-out markdown bundle builder. The
/// drag pasteboard itself can't be exercised in unit tests, but the
/// builder produces the file the drop target ends up with — so a
/// regression here would break the user-visible behaviour.
final class MeetingDragItemTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    private func write(_ url: URL, _ contents: String) throws {
        try contents.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    func test_build_prefers_summary_markdown_when_present() throws {
        let dir = try tempDir()
        let stem = "s"
        try write(dir.appendingPathComponent("\(stem).summary.md"), "# Hand-written")
        // Even if the JSON exists, the .md wins because the pipeline
        // already rendered it the way the user expects to share it.
        let summary: [String: Any] = ["title": "JSON title"]
        let data = try JSONSerialization.data(withJSONObject: summary)
        try data.write(to: dir.appendingPathComponent("\(stem).summary.json"))

        let body = MeetingMarkdownBundle.build(stem: stem, in: dir)
        XCTAssertTrue(body.contains("# Hand-written"))
        XCTAssertFalse(body.contains("JSON title"))
    }

    func test_build_renders_summary_json_when_no_markdown() throws {
        let dir = try tempDir()
        let stem = "s"
        let summary: [String: Any] = [
            "title": "Sprint review",
            "summary": ["Burned down 80%", "Carryover light"],
            "decisions": ["Cut spike"],
            "actions": [
                ["task": "Email Lily", "owner": "Heorhii", "due": "Friday"],
            ],
            "questions": ["What about NDA mode?"],
            "attendees": ["A", "B"],
        ]
        let data = try JSONSerialization.data(withJSONObject: summary)
        try data.write(to: dir.appendingPathComponent("\(stem).summary.json"))

        let body = MeetingMarkdownBundle.build(stem: stem, in: dir)
        XCTAssertTrue(body.contains("# Sprint review"))
        XCTAssertTrue(body.contains("- Burned down 80%"))
        XCTAssertTrue(body.contains("1. Cut spike"))
        XCTAssertTrue(body.contains("- Email Lily (owner: Heorhii, due: Friday)"))
        XCTAssertTrue(body.contains("Open questions"))
        XCTAssertTrue(body.contains("A, B"))
    }

    func test_build_appends_transcript_when_present() throws {
        let dir = try tempDir()
        let stem = "s"
        try write(dir.appendingPathComponent("\(stem).summary.md"), "# Stub")
        try write(dir.appendingPathComponent("\(stem).md"), "Speaker 1: Hello.\nSpeaker 2: Hi.")
        let body = MeetingMarkdownBundle.build(stem: stem, in: dir)
        XCTAssertTrue(body.contains("# Stub"))
        XCTAssertTrue(body.contains("## Transcript"))
        XCTAssertTrue(body.contains("Speaker 1: Hello."))
    }

    func test_build_falls_back_to_placeholder_when_nothing_on_disk() throws {
        let dir = try tempDir()
        let body = MeetingMarkdownBundle.build(stem: "20260512-1200", in: dir)
        XCTAssertTrue(body.contains("# 20260512-1200"))
        XCTAssertTrue(body.contains("No summary on disk"))
    }

    func test_writeBundleToTemp_produces_readable_file_under_temp() throws {
        let dir = try tempDir()
        let stem = "drag-stem"
        try write(dir.appendingPathComponent("\(stem).summary.md"), "# Bundle")
        let meeting = Meeting(
            stem: stem,
            startedAt: Date(),
            wavURL: dir.appendingPathComponent("\(stem).wav"),
            recordingsDir: dir,
            summaryTitle: nil, meetingTitle: nil,
            sourceBundleID: nil, sourceDisplayName: nil, sourceKind: nil,
            workflowName: nil, workflowColor: nil,
            durationSec: nil, backend: nil, modelId: nil,
            status: .done
        )
        let item = MeetingDragItem(meeting: meeting)
        let url = try item.writeBundleToTemp()
        XCTAssertEqual(url.lastPathComponent, "meetingpipe-\(stem).md")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("# Bundle"))
    }
}
