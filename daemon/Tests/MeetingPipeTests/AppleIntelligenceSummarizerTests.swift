import XCTest
@testable import MeetingPipe

/// Unit coverage for the parts of `AppleIntelligenceSummarizer` that do not
/// require a live on-device model: JSON extraction, the byte-compatible write
/// path, the Markdown rendering, prompt construction, and availability gating.
/// The end-to-end model call is validated by on-device dogfood (TECH-SUM1-APPLE).
final class AppleIntelligenceSummarizerTests: XCTestCase {

    private let canonical = """
    {"title":"Sprint planning","summary":["Aligned scope"],"decisions":["Cut the spike"],\
    "actions":[{"task":"Doc","owner":"Heorhii","due":"2026-06-01","confidence":"high"},\
    {"task":"QA","owner":null,"due":null,"confidence":"low"}],"questions":["iOS?"],\
    "attendees":["Heorhii"],"detected_language":"uk"}
    """

    func test_parse_canonical_json() {
        let s = AppleIntelligenceSummarizer.parse(canonical)
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.title, "Sprint planning")
        XCTAssertEqual(s?.actions.count, 2)
        XCTAssertEqual(s?.actions.first?.owner, "Heorhii")
        XCTAssertNil(s?.actions.last?.owner)
        XCTAssertEqual(s?.detectedLanguage, "uk")
    }

    func test_parse_recovers_json_embedded_in_prose() {
        let text = "Sure, here is the summary:\n```json\n\(canonical)\n```\nHope that helps!"
        XCTAssertEqual(AppleIntelligenceSummarizer.parse(text)?.title, "Sprint planning")
    }

    func test_parse_garbage_returns_nil() {
        XCTAssertNil(AppleIntelligenceSummarizer.parse("there is no json here, sorry"))
    }

    func test_largest_json_object_picks_biggest_balanced() {
        let extracted = AppleIntelligenceSummarizer.largestJSONObject(in: "{} {\"a\":{\"b\":1}} {}")
        XCTAssertEqual(extracted, "{\"a\":{\"b\":1}}")
    }

    func test_write_round_trips_through_the_loader() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let md = dir.appendingPathComponent("20260516-0900.md")
        try "# transcript".write(to: md, atomically: true, encoding: .utf8)

        let summary = MeetingSummary(
            title: "Demo",
            summary: ["one", "two"],
            decisions: ["d"],
            actions: [MeetingSummary.ActionItem(task: "do it", owner: "Alex Chen", due: nil, confidence: "high")],
            questions: ["q?"],
            attendees: ["Alex Chen"],
            detectedLanguage: "en"
        )
        try AppleIntelligenceSummarizer.write(summary: summary, transcriptMD: md)

        let jsonURL = dir.appendingPathComponent("20260516-0900.summary.json")
        let mdURL = dir.appendingPathComponent("20260516-0900.summary.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mdURL.path))

        XCTAssertEqual(MeetingSummary.load(from: jsonURL), summary)
        let mdText = try String(contentsOf: mdURL, encoding: .utf8)
        XCTAssertTrue(mdText.contains("# Demo"))
        XCTAssertFalse(mdText.contains("\u{2014}"))  // no em-dash anywhere
    }

    func test_render_markdown_has_sections_and_uses_hyphen() {
        let summary = MeetingSummary(
            title: "T",
            summary: ["bullet"],
            decisions: ["a decision"],
            actions: [MeetingSummary.ActionItem(task: "x", owner: nil, due: "2026-01-01", confidence: "low")],
            questions: ["q"],
            attendees: [],
            detectedLanguage: nil
        )
        let md = AppleIntelligenceSummarizer.renderMarkdown(summary)
        XCTAssertTrue(md.contains("## Summary"))
        XCTAssertTrue(md.contains("## Decisions"))
        XCTAssertTrue(md.contains("## Action Items"))
        XCTAssertTrue(md.contains("## Open Questions"))
        XCTAssertTrue(md.contains("- due 2026-01-01"))
        XCTAssertFalse(md.contains("\u{2014}"))
    }

    func test_availability_reason_matches_is_available() {
        // On any host this should not crash; isAvailable is exactly the
        // negation of having a reason.
        XCTAssertEqual(AppleIntelligenceSummarizer.isAvailable,
                       AppleIntelligenceSummarizer.availabilityReason == nil)
    }

    func test_instructions_include_context_and_language_directive() {
        let withCtx = AppleIntelligenceSummarizer.instructions(teamContext: "ACME internal", summaryLanguage: "uk")
        XCTAssertTrue(withCtx.contains("ACME internal"))
        XCTAssertTrue(withCtx.contains("`uk`"))

        let auto = AppleIntelligenceSummarizer.instructions(teamContext: "", summaryLanguage: "auto")
        XCTAssertFalse(auto.contains("Team context"))
        XCTAssertTrue(auto.contains("SAME language"))
    }
}
