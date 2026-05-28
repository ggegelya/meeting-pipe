import XCTest
@testable import MeetingPipe

/// `MeetingSummary` is the typed mirror of the pipeline's summary schema
/// (`pipeline/src/mp/schemas.py`). These cases pin the decode contract: every
/// field decodes from the canonical JSON, a partial file is tolerated, and the
/// write bridge (`jsonObject()`) round-trips back to the same value.
final class MeetingSummaryTests: XCTestCase {

    /// Exactly the shape `mp summarize` writes to `<stem>.summary.json`.
    private let canonicalJSON = """
    {
      "title": "Sprint planning",
      "summary": ["Aligned scope for Q3", "Re-pinned the auth migration"],
      "decisions": ["Cut the spike from this release"],
      "actions": [
        {"task": "Write follow-up doc", "owner": "Heorhii", "due": "2026-06-01", "confidence": "high"},
        {"task": "Schedule QA sync", "owner": null, "due": null, "confidence": "low"}
      ],
      "questions": ["What about the iOS team?"],
      "attendees": ["Heorhii", "Lily"],
      "detected_language": "en"
    }
    """

    private func decode(_ json: String) throws -> MeetingSummary {
        try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
    }

    // MARK: every field renders

    func test_decodes_every_field_from_canonical_json() throws {
        let s = try decode(canonicalJSON)
        XCTAssertEqual(s.title, "Sprint planning")
        XCTAssertEqual(s.summary, ["Aligned scope for Q3", "Re-pinned the auth migration"])
        XCTAssertEqual(s.decisions, ["Cut the spike from this release"])
        XCTAssertEqual(s.questions, ["What about the iOS team?"])
        XCTAssertEqual(s.attendees, ["Heorhii", "Lily"])
        XCTAssertEqual(s.detectedLanguage, "en")
        XCTAssertEqual(s.actions.count, 2)
        XCTAssertEqual(s.actions[0], MeetingSummary.ActionItem(
            task: "Write follow-up doc", owner: "Heorhii", due: "2026-06-01", confidence: "high"
        ))
        XCTAssertEqual(s.actions[1].owner, nil)
        XCTAssertEqual(s.actions[1].due, nil)
        XCTAssertEqual(s.actions[1].confidence, "low")
    }

    // MARK: tolerance

    func test_empty_object_decodes_to_empty_defaults() throws {
        let s = try decode("{}")
        XCTAssertEqual(s.title, "")
        XCTAssertTrue(s.summary.isEmpty)
        XCTAssertTrue(s.decisions.isEmpty)
        XCTAssertTrue(s.actions.isEmpty)
        XCTAssertTrue(s.questions.isEmpty)
        XCTAssertTrue(s.attendees.isEmpty)
        XCTAssertNil(s.detectedLanguage)
    }

    func test_partial_object_keeps_present_fields() throws {
        let s = try decode("{\"title\":\"x\",\"summary\":[\"only this\"]}")
        XCTAssertEqual(s.title, "x")
        XCTAssertEqual(s.summary, ["only this"])
        XCTAssertTrue(s.decisions.isEmpty)
        XCTAssertNil(s.detectedLanguage)
    }

    func test_empty_detected_language_normalizes_to_nil() throws {
        let s = try decode("{\"detected_language\":\"\"}")
        XCTAssertNil(s.detectedLanguage)
    }

    func test_wrong_typed_field_falls_back_to_default() throws {
        // A malformed file (summary is a string, not an array) must not throw.
        let s = try decode("{\"title\":\"ok\",\"summary\":\"oops\"}")
        XCTAssertEqual(s.title, "ok")
        XCTAssertTrue(s.summary.isEmpty)
    }

    // MARK: write bridge round-trip

    func test_jsonObject_round_trips_through_decode() throws {
        let original = try decode(canonicalJSON)
        let rebuilt = try XCTUnwrap(MeetingSummary(jsonObject: original.jsonObject()))
        XCTAssertEqual(original, rebuilt)
    }

    func test_jsonObject_emits_snake_case_language_and_null_owner() throws {
        let s = MeetingSummary(
            title: "t",
            actions: [MeetingSummary.ActionItem(task: "do it")],
            detectedLanguage: nil
        )
        let obj = s.jsonObject()
        XCTAssertEqual(obj["detected_language"] as? String, "en", "nil language defaults to en on write")
        let actions = try XCTUnwrap(obj["actions"] as? [[String: Any]])
        XCTAssertTrue(actions[0]["owner"] is NSNull, "absent owner serializes as null, not a missing key")
        XCTAssertTrue(actions[0]["due"] is NSNull)
    }

    // MARK: disk load

    func test_load_from_disk_reads_summary_file() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("s.summary.json")
        try Data(canonicalJSON.utf8).write(to: url)
        let loaded = try XCTUnwrap(MeetingSummary.load(from: url))
        XCTAssertEqual(loaded.title, "Sprint planning")
        XCTAssertNil(MeetingSummary.load(from: dir.appendingPathComponent("missing.json")))
    }
}
