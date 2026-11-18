import XCTest
@testable import MeetingPipe

/// PIPE55: `Meeting.displayTitle` against `Fixtures/title-precedence-golden.json`, the file Python's `test_title_precedence.py` reads for `apply_meeting_title`. Both trees must pick the same source, so a rename reaches every sink and the Library cannot show one title while the notes carry another.
final class TitlePrecedenceTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("title-precedence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func assertOK(_ r: Result<Void, UserTitleStore.WriteError>, file: StaticString = #filePath, line: UInt = #line) {
        if case .failure(let e) = r { XCTFail("write failed: \(e)", file: file, line: line) }
    }

    private func cases() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/title-precedence-golden.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return try XCTUnwrap(obj?["cases"] as? [[String: Any]])
    }

    private func scan(stem: String) throws -> Meeting {
        let store = MeetingStore(recordingsDir: dir)
        let exp = expectation(description: "scan")
        var captured: [Meeting] = []
        let cancel = store.$meetings.dropFirst().sink { captured = $0; exp.fulfill() }
        store.start()
        wait(for: [exp], timeout: 3.0)
        cancel.cancel()
        return try XCTUnwrap(captured.first { $0.stem == stem })
    }

    func test_displayTitle_matches_the_golden() throws {
        for (i, c) in try cases().enumerated() {
            let stem = String(format: "20261118-10%04d", i)
            try Data("RIFF".utf8).write(to: dir.appendingPathComponent("\(stem).wav"))
            var meta: [String: Any] = ["schema_version": 6]
            if let t = c["user_title"] as? String { meta["user_title"] = t }
            if let t = c["meeting_title"] as? String { meta["meeting_title"] = t }
            try JSONSerialization.data(withJSONObject: meta)
                .write(to: dir.appendingPathComponent("\(stem).meta.json"))
            if let t = c["summary_title"] as? String {
                try JSONSerialization.data(withJSONObject: ["title": t])
                    .write(to: dir.appendingPathComponent("\(stem).summary.json"))
            }
            let row = try scan(stem: stem)
            let name = c["name"] as? String ?? "?"
            if let expected = c["expected"] as? String {
                XCTAssertEqual(row.displayTitle, expected, name)
            } else {
                // No title at all and no source: the label is the raw stem.
                XCTAssertEqual(row.displayTitle, stem, name)
            }
        }
    }

    func test_user_title_is_searchable_so_the_shown_title_finds_the_row() {
        let text = MeetingStore.buildSearchableText(
            userTitle: "Hallway chat", meetingTitle: "Captured", sourceDisplayName: nil, summary: nil)
        XCTAssertTrue(text.contains("hallway chat"))
    }

    func test_write_sets_and_clears_user_title_without_touching_other_keys() throws {
        let stem = "20261118-100000"
        let url = dir.appendingPathComponent("\(stem).meta.json")
        try Data(#"{"meeting_title":"Captured","workflow_nda_mode":true,"schema_version":5}"#.utf8).write(to: url)
        assertOK(UserTitleStore.write(title: "Renamed", stem: stem, in: dir))
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(obj["user_title"] as? String, "Renamed")
        XCTAssertEqual(obj["meeting_title"] as? String, "Captured")
        XCTAssertEqual(obj["workflow_nda_mode"] as? Bool, true)
        assertOK(UserTitleStore.write(title: "", stem: stem, in: dir))
        obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNil(obj["user_title"])
    }

    func test_write_with_no_sidecar_creates_one_and_clearing_creates_nothing() throws {
        let stem = "20261118-110000"
        let url = dir.appendingPathComponent("\(stem).meta.json")
        assertOK(UserTitleStore.write(title: "", stem: stem, in: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        assertOK(UserTitleStore.write(title: "Renamed", stem: stem, in: dir))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(obj["user_title"] as? String, "Renamed")
    }

    /// SEC25's shape: a sidecar that exists but cannot be read is never rebuilt from empty, because the rename would then overwrite `workflow_nda_mode` and the source.
    func test_write_refuses_over_an_unreadable_sidecar() throws {
        let stem = "20261118-120000"
        let url = dir.appendingPathComponent("\(stem).meta.json")
        let garbage = Data("{not json".utf8)
        try garbage.write(to: url)
        if case .failure(let e) = UserTitleStore.write(title: "Renamed", stem: stem, in: dir) {
            XCTAssertEqual(e, .metaUnreadable)
        } else {
            XCTFail("a sidecar that cannot be read must refuse")
        }
        XCTAssertEqual(try Data(contentsOf: url), garbage)
    }

    /// The rename never touches `summary.json`, so a re-summarize that rewrites it cannot undo the rename.
    func test_write_leaves_summary_json_alone() throws {
        let stem = "20261118-130000"
        let summary = dir.appendingPathComponent("\(stem).summary.json")
        let bytes = Data(#"{"title":"Generated"}"#.utf8)
        try bytes.write(to: summary)
        assertOK(UserTitleStore.write(title: "Renamed", stem: stem, in: dir))
        XCTAssertEqual(try Data(contentsOf: summary), bytes)
    }

    /// The Summary editor's title field is a rename: `user_title` gets what was typed, and the summary written back keeps the generated title, so a re-summarize cannot undo it.
    func test_editor_save_with_a_changed_title_is_a_rename_and_keeps_the_generated_title() throws {
        let s = MeetingSummary(title: "Typed by owner", summary: ["a"], decisions: [], actions: [],
                               questions: [], attendees: [], detectedLanguage: "en", extraSections: [], evidence: [:])
        let split = UserTitleStore.splitEditorTitle(corrected: s, generatedTitle: "Generated")
        XCTAssertEqual(split.rename, "Typed by owner")
        XCTAssertEqual(split.live.title, "Generated")
        XCTAssertEqual(split.live.summary, ["a"], "every other field is the edited one")
    }

    func test_editor_save_with_the_title_unchanged_or_blank_renames_nothing() {
        for typed in ["Generated", "  Generated ", "", "   "] {
            let s = MeetingSummary(title: typed, summary: [], decisions: [], actions: [],
                                   questions: [], attendees: [], detectedLanguage: nil, extraSections: [], evidence: [:])
            XCTAssertNil(UserTitleStore.splitEditorTitle(corrected: s, generatedTitle: "Generated").rename, "\"\(typed)\"")
        }
    }
}
