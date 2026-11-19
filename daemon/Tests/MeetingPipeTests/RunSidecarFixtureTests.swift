import XCTest
@testable import MeetingPipe

/// OBS8 (with OBS2, PIPE25, PIPE27): `MeetingStore` decodes the run sidecar the pipeline's
/// `corrections.write_run_sidecar` writes, over the generated `run-sidecar-golden.json`, and
/// the header's quality notes fire only above their thresholds.
final class RunSidecarFixtureTests: XCTestCase {

    private func cases() throws -> [String: [String: Any]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "run-sidecar-golden", withExtension: "json"))
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let list = try XCTUnwrap(doc["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(list.count, 4, "a vacuous fixture is not agreement")
        return Dictionary(uniqueKeysWithValues: list.map { ($0["name"] as! String, $0["payload"] as! [String: Any]) })
    }

    /// Writes each case as a real meeting's run sidecar and scans it the way the Library does.
    private func scanned() throws -> [String: Meeting] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("obs8-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var stemFor: [String: String] = [:]
        for (i, (name, payload)) in try cases().sorted(by: { $0.key < $1.key }).enumerated() {
            let stem = String(format: "20260101-0900%02d", i)
            stemFor[stem] = name
            try Data().write(to: dir.appendingPathComponent("\(stem).wav"))
            try Data(#"{"title":"x"}"#.utf8).write(to: dir.appendingPathComponent("\(stem).summary.json"))
            try JSONSerialization.data(withJSONObject: payload).write(to: dir.appendingPathComponent("\(stem).run.json"))
        }
        let store = MeetingStore(recordingsDir: dir)
        let exp = expectation(description: "scan")
        var captured: [Meeting] = []
        let cancel = store.$meetings.dropFirst().sink { captured = $0; exp.fulfill() }
        store.start()
        wait(for: [exp], timeout: 2.0)
        cancel.cancel()
        return Dictionary(uniqueKeysWithValues: captured.compactMap { m in stemFor[m.stem].map { ($0, m) } })
    }

    func test_every_key_the_header_reads_decodes_from_the_live_writer() throws {
        let byCase = try scanned()

        let bare = try XCTUnwrap(byCase["bare_anthropic_run"])
        XCTAssertEqual(bare.backend, "anthropic")
        XCTAssertNil(bare.tokenUsage)
        XCTAssertNil(bare.evidenceKept)
        XCTAssertNil(bare.cleanupSegments)

        let paid = try XCTUnwrap(byCase["cloud_run_with_usage_and_shares"])
        XCTAssertEqual(paid.tokenUsage, TokenUsage(input: 41_200, output: 2_310))
        XCTAssertEqual(paid.evidenceKept, 6)
        XCTAssertEqual(paid.evidenceDropped, 15)
        XCTAssertEqual(paid.cleanupSegmentsChanged, 40)
        XCTAssertEqual(paid.cleanupSegments, 120)

        let fell = try XCTUnwrap(byCase["auto_fell_back_to_local"])
        XCTAssertEqual(fell.fallbackFrom, "anthropic")
        XCTAssertEqual(fell.fallbackCause, "rejected_key")

        let apple = try XCTUnwrap(byCase["apple_language_substitution"])
        XCTAssertEqual(apple.fallbackFrom, "apple_intelligence")
        XCTAssertEqual(apple.fallbackLanguage, "uk")
    }

    func test_the_quality_notes_fire_above_half_and_a_quarter_only() {
        XCTAssertEqual(RunQualityNote.notes(evidenceKept: 6, evidenceDropped: 15, cleanupChanged: 40, cleanupSegments: 120).count, 2)
        XCTAssertTrue(RunQualityNote.notes(evidenceKept: 5, evidenceDropped: 5, cleanupChanged: 30, cleanupSegments: 120).isEmpty,
                      "exactly a half and exactly a quarter stay quiet")
        XCTAssertTrue(RunQualityNote.notes(evidenceKept: nil, evidenceDropped: nil, cleanupChanged: nil, cleanupSegments: nil).isEmpty)
        XCTAssertTrue(RunQualityNote.notes(evidenceKept: 0, evidenceDropped: 0, cleanupChanged: 0, cleanupSegments: 0).isEmpty)
        XCTAssertEqual(RunQualityNote.notes(evidenceKept: 1, evidenceDropped: 20, cleanupChanged: nil, cleanupSegments: nil).count, 1)
    }
}
