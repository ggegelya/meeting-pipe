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

    // MARK: - PIPE6: deterministic unsupported-language recovery

    func test_unsupported_language_error_is_recognized() {
        // The framework surfaces the rejection as a message; a few phrasings map.
        let framework = NSError(domain: "FoundationModels", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "An unsupported language or locale was used.",
        ])
        XCTAssertTrue(AppleIntelligenceError.isUnsupportedLanguageError(framework))
        let alt = NSError(domain: "x", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "This language is not supported by the model.",
        ])
        XCTAssertTrue(AppleIntelligenceError.isUnsupportedLanguageError(alt))
        // Unrelated failures must not be misclassified (they stay same-backend retryable).
        let timeout = NSError(domain: "x", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "The request timed out.",
        ])
        XCTAssertFalse(AppleIntelligenceError.isUnsupportedLanguageError(timeout))
    }

    func test_unsupported_language_is_deterministic_and_carries_the_marker() {
        let err = AppleIntelligenceError.unsupportedLanguage("Ukrainian")
        XCTAssertTrue(err.isDeterministicBackendFailure)
        // The reason the Library reads carries the shared marker, so a failed row
        // recognizes it as backend-switch-recoverable.
        XCTAssertTrue((err.errorDescription ?? "").localizedCaseInsensitiveContains(
            AppleIntelligenceError.unsupportedLanguageMarker))
        // Other Apple errors are NOT deterministic backend failures.
        XCTAssertFalse(AppleIntelligenceError.parseFailed("x").isDeterministicBackendFailure)
        XCTAssertFalse(AppleIntelligenceError.emptyTranscript.isDeterministicBackendFailure)
    }

    func test_meeting_recognizes_backend_switch_recoverable_failure() {
        // The Meeting computed flag matches the marker the error stamps into the
        // reason (producer/consumer share the constant), so the two cannot drift.
        let recoverable = AppleIntelligenceError.unsupportedLanguage("uk").errorDescription!
        XCTAssertTrue(failedMeeting(reason: recoverable).failureSuggestsLocalReSummarize)
        XCTAssertFalse(failedMeeting(reason: "network timeout").failureSuggestsLocalReSummarize)
        XCTAssertFalse(failedMeeting(reason: nil).failureSuggestsLocalReSummarize)
    }

    private func failedMeeting(reason: String?) -> Meeting {
        Meeting(
            stem: "20260707-1500",
            startedAt: Date(timeIntervalSince1970: 0),
            audioURL: URL(fileURLWithPath: "/tmp/20260707-1500.wav"),
            recordingsDir: URL(fileURLWithPath: "/tmp"),
            summaryTitle: nil,
            meetingTitle: nil,
            sourceBundleID: nil,
            sourceDisplayName: nil,
            sourceKind: nil,
            workflowName: nil,
            workflowColor: nil,
            durationSec: nil,
            backend: nil,
            modelId: nil,
            status: .failed,
            failureReason: reason,
            failureStage: "pipeline",
            searchableText: ""
        )
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

    // LOCAL3: the hierarchical reduce batches partials so no reduce call
    // concatenates more than `reduceBatch` of them. The async generate() needs
    // the on-device model, so the pure partition invariant is what we pin here.
    func test_batched_partitions_into_bounded_groups() {
        let groups = AppleIntelligenceSummarizer.batched(Array(0..<10), size: 4)
        XCTAssertEqual(groups, [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9]])
        XCTAssertTrue(groups.allSatisfy { $0.count <= 4 })
    }

    func test_batched_group_smaller_than_size_is_single_group() {
        XCTAssertEqual(AppleIntelligenceSummarizer.batched([1, 2], size: 4), [[1, 2]])
    }

    func test_batched_empty_is_empty() {
        XCTAssertTrue(AppleIntelligenceSummarizer.batched([Int](), size: 4).isEmpty)
    }

    func test_default_map_window_is_cyrillic_safe() {
        // The 3200-char window overflowed the 4096-token context on Ukrainian;
        // the Cyrillic-safe default must stay at (or below) 1000 chars.
        XCTAssertLessThanOrEqual(AppleIntelligenceSummarizer().maxWindowChars, 1000)
    }

    func test_instructions_include_context_and_language_directive() {
        let withCtx = AppleIntelligenceSummarizer.instructions(teamContext: "ACME internal", summaryLanguage: "uk")
        XCTAssertTrue(withCtx.contains("ACME internal"))
        XCTAssertTrue(withCtx.contains("`uk`"))

        let auto = AppleIntelligenceSummarizer.instructions(teamContext: "", summaryLanguage: "auto")
        XCTAssertFalse(auto.contains("Team context"))
        XCTAssertTrue(auto.contains("SAME language"))
    }

    // LOCAL7: the language directive is forceful and applies to every field, not
    // a one-line aside the system model was ignoring on Ukrainian.
    func test_language_directive_is_forceful_and_field_wide() {
        let forced = AppleIntelligenceSummarizer.languageDirective("uk")
        XCTAssertTrue(forced.contains("`uk`"))
        XCTAssertTrue(forced.contains("non-negotiable"))
        XCTAssertTrue(forced.contains("EVERY string value"))

        let auto = AppleIntelligenceSummarizer.languageDirective("auto")
        XCTAssertTrue(auto.contains("SAME language"))
        XCTAssertTrue(auto.contains("do not switch to English or Russian"))
    }

    // LOCAL8 viability fixes: the system model ignored the bullet cap (~11 vs 5)
    // and echoed raw dialogue on short meetings; both instruction sets restate them.
    func test_instructions_cap_bullets_and_forbid_echo() {
        let s = AppleIntelligenceSummarizer.instructions(teamContext: "", summaryLanguage: "auto")
        XCTAssertTrue(s.contains("at most 5 summary bullets"))
        XCTAssertTrue(s.lowercased().contains("never echo"))

        let reduce = AppleIntelligenceSummarizer.reduceInstructions(summaryLanguage: "auto")
        XCTAssertTrue(reduce.contains("at most 5 summary bullets"))
    }
}
