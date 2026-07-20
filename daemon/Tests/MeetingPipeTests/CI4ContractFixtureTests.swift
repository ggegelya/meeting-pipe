import XCTest
@testable import MeetingPipe

/// CI4: the last three Swift-Python contracts, pinned by shared golden fixtures.
///
/// `<stem>.publish.json`, the `mp prefetch-model` progress JSONL, and the
/// `<stem>.speaker_labels.json` resolution each used to be asserted twice over,
/// once per tree, against expectations each tree authored itself. This suite's
/// old shape was the drift hole: `PipelineLauncherTests` pinned a Swift-authored
/// `{"state":"full","page_url":...}` string literal, so renaming `page_url` on
/// BOTH sides passed both suites and shipped a silently broken contract.
///
/// The fixtures here are generated from the shipping Python writers by
/// `scripts/gen_contract_fixtures.py` and read by both trees, so the two suites
/// can no longer agree with each other while disagreeing with reality. The
/// Python side (`pipeline/tests/test_ci4_contracts.py`) asserts the committed
/// files still match the generator's output; this side asserts the real Swift
/// readers still understand them. A deliberate writer change therefore breaks
/// the other tree's test, which is CI4's acceptance bar.
///
/// To regenerate after an intentional shape change:
/// `cd pipeline && uv run python ../scripts/gen_contract_fixtures.py`.
final class CI4ContractFixtureTests: XCTestCase {

    // MARK: - Fixture loading

    private func document(_ resource: String) throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: resource, withExtension: "json"),
            "missing fixture \(resource).json"
        )
        let obj = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        return try XCTUnwrap(obj as? [String: Any])
    }

    private func cases(_ resource: String) throws -> [[String: Any]] {
        try XCTUnwrap(try document(resource)["cases"] as? [[String: Any]])
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ci4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - <stem>.publish.json (PIPE1)

    func test_publish_result_golden() throws {
        let all = try cases("publish-result-golden")
        XCTAssertGreaterThanOrEqual(all.count, 4, "fixture went vacuous")

        for c in all {
            let name = c["name"] as? String ?? "?"
            let dir = try tempDir()
            let payload = try XCTUnwrap(c["payload"] as? [String: Any], name)
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: dir.appendingPathComponent("meeting.publish.json"))

            let result = try XCTUnwrap(
                PublishResult.load(stem: "meeting", in: dir),
                "\(name): PublishResult.load returned nil for a well-formed sidecar"
            )
            XCTAssertEqual(result.state, c["expected_state"] as? String, name)

            let expectedURL = c["expected_page_url"] as? String
            XCTAssertEqual(result.pageURL?.absoluteString, expectedURL, name)
        }
    }

    /// The exit-3 contract is a number shared with `publish_router`, not a shape,
    /// so it gets its own pin next to the sidecar it accompanies.
    func test_publish_failed_exit_code_matches_python() {
        XCTAssertEqual(PipelineLauncher.publishFailedExitCode, 3)
    }

    /// `state` is an opaque passthrough in `PublishResult`, but SIX Swift call
    /// sites compare it against bare literals (`MeetingRow`'s badge and its
    /// retry-vs-publish action, `AudioRetention.isSettled`, `LibraryScope`,
    /// `MeetingDetailView+Header`). A vocabulary change on the Python side would
    /// leave every one of them silently taking the else-branch, rendering a
    /// publish that landed nowhere as a clean success and letting the retention
    /// sweep treat it as settled. Nothing pinned that before CI4.
    func test_publish_state_vocabulary_is_exactly_what_swift_branches_on() throws {
        let contract = try XCTUnwrap(try document("publish-result-golden")["contract"] as? [String: Any])
        let states = Set(try XCTUnwrap(contract["publish_states"] as? [String]))

        XCTAssertEqual(states, ["full", "partial", "none"])

        // Pin the semantics too, not just the spelling: a state Swift does not
        // know is unsettled + needs-you, and only "full" is a finished publish.
        for state in states {
            let settled = AudioRetention.isSettled(status: .done, publishState: state)
            XCTAssertEqual(settled, state == "full", "isSettled disagrees for \(state)")
        }
    }

    /// A missing sidecar means "nothing published, nothing failed", never a
    /// fallback to a stale per-sink sidecar. Absence is a real state here.
    func test_publish_result_absent_reads_as_nil() throws {
        let dir = try tempDir()
        XCTAssertNil(PublishResult.load(stem: "meeting", in: dir))
    }

    // MARK: - mp prefetch-model progress JSONL

    func test_prefetch_progress_golden() throws {
        let all = try cases("prefetch-progress-golden")
        XCTAssertGreaterThanOrEqual(all.count, 4, "fixture went vacuous")

        for c in all {
            let name = c["name"] as? String ?? "?"
            let line = try XCTUnwrap(c["line"] as? String, name)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)

            let lineData = try XCTUnwrap(line.data(using: .utf8), name)
            let event = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: lineData) as? [String: Any], name
            )

            let supervisor = ModelDownloadSupervisor()
            supervisor.handleEvent(event)

            let modelId = expect["model_id"] as? String ?? ""
            switch expect["kind"] as? String {
            case "downloading":
                let downloaded = (expect["downloaded_bytes"] as? NSNumber)?.int64Value ?? -1
                let total = (expect["total_bytes"] as? NSNumber)?.int64Value ?? -1
                let progress = (expect["progress"] as? NSNumber)?.doubleValue
                guard case .downloading(let m, let p, let d, let t) = supervisor.state else {
                    return XCTFail("\(name): expected .downloading, got \(supervisor.state)")
                }
                XCTAssertEqual(m, modelId, name)
                XCTAssertEqual(d, downloaded, name)
                XCTAssertEqual(t, total, name)
                if let progress {
                    XCTAssertEqual(try XCTUnwrap(p, name), progress, accuracy: 1e-6, name)
                } else {
                    XCTAssertNil(p, name)
                }
            case "completed":
                guard case .completed(let m) = supervisor.state else {
                    return XCTFail("\(name): expected .completed, got \(supervisor.state)")
                }
                XCTAssertEqual(m, modelId, name)
            case "failed":
                guard case .failed(let m, let e) = supervisor.state else {
                    return XCTFail("\(name): expected .failed, got \(supervisor.state)")
                }
                XCTAssertEqual(m, modelId, name)
                XCTAssertEqual(e, expect["error"] as? String, name)
            default:
                XCTFail("\(name): fixture carries an expectation kind this suite cannot check")
            }
        }
    }

    /// The load-bearing half of the contract: no event Python emits may land in
    /// `handleEvent`'s `default` arm. One that does leaves the menu-bar title
    /// frozen on the previous state for the rest of a multi-minute download.
    func test_prefetch_no_emitted_event_is_ignored() throws {
        for c in try cases("prefetch-progress-golden") {
            let name = c["name"] as? String ?? "?"
            let line = try XCTUnwrap(c["line"] as? String, name)
            let lineData = try XCTUnwrap(line.data(using: .utf8), name)
            let event = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: lineData) as? [String: Any], name
            )
            let supervisor = ModelDownloadSupervisor()
            supervisor.handleEvent(event)
            XCTAssertNotEqual(
                supervisor.state, .idle,
                "\(name): ModelDownloadSupervisor ignored an event mp prefetch-model emits"
            )
        }
    }

    // MARK: - <stem>.speaker_labels.json resolution

    func test_speaker_overlay_golden() throws {
        let all = try cases("speaker-overlay-golden")
        XCTAssertGreaterThanOrEqual(all.count, 10, "fixture went vacuous")

        for c in all {
            let name = c["name"] as? String ?? "?"
            let dir = try tempDir()
            let sidecar = try XCTUnwrap(c["sidecar"] as? [String: Any], name)
            let data = try JSONSerialization.data(withJSONObject: sidecar)
            try data.write(to: SpeakerLabelStore.path(stem: "meeting", in: dir))

            let overlay = SpeakerLabelStore.read(stem: "meeting", in: dir)

            let expectedLabels = try XCTUnwrap(c["read_labels"] as? [String: String], name)
            XCTAssertEqual(overlay.labels, expectedLabels, "\(name): labels")

            // Python keys segments by a canonical decimal string, Swift by Int.
            let rawSegments = try XCTUnwrap(c["read_segments"] as? [String: String], name)
            let expectedSegments = Dictionary(
                uniqueKeysWithValues: rawSegments.compactMap { k, v in
                    Int(k).map { ($0, v) }
                }
            )
            XCTAssertEqual(rawSegments.count, expectedSegments.count, "\(name): unparsable key")
            XCTAssertEqual(overlay.segments, expectedSegments, "\(name): segments")

            let speakers = try XCTUnwrap(c["speakers"] as? [Any], name)
            let segments = speakers.enumerated().map { i, s in
                TranscriptSegment(
                    index: i, start: Double(i), end: Double(i) + 1, text: "line \(i)",
                    speakerID: s as? String
                )
            }
            let resolved = segments.map { SpeakerLabelStore.displayLabel(for: $0, using: overlay) }
            let expectedResolved = (c["resolved"] as? [Any] ?? []).map { $0 as? String }
            XCTAssertEqual(resolved, expectedResolved, "\(name): resolved labels")
        }
    }

    // MARK: - schema_version stamp

    /// The speaker-labels sidecar was the one cross-language sidecar carrying no
    /// version stamp. Both readers are fail-open on it, so this pins that it is
    /// written, not that it is enforced.
    func test_speaker_labels_sidecar_is_stamped() throws {
        let dir = try tempDir()
        try SpeakerLabelStore.setLabel("THEM-A", to: "Alice", stem: "meeting", in: dir)

        let url = SpeakerLabelStore.path(stem: "meeting", in: dir)
        let obj = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let dict = try XCTUnwrap(obj as? [String: Any])

        XCTAssertEqual(dict["schema_version"] as? Int, SpeakerLabelStore.schemaVersion)
        XCTAssertEqual(dict["labels"] as? [String: String], ["THEM-A": "Alice"])
    }

    /// Fail-open on the stamp: a sidecar from a newer build must still resolve
    /// rather than being rejected wholesale, matching `TranscriptCorrectionStore`.
    func test_speaker_labels_unknown_schema_version_still_reads() throws {
        let dir = try tempDir()
        let payload: [String: Any] = [
            "schema_version": 99,
            "labels": ["THEM-A": "Alice"],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: SpeakerLabelStore.path(stem: "meeting", in: dir))

        let overlay = SpeakerLabelStore.read(stem: "meeting", in: dir)
        XCTAssertEqual(overlay.labels, ["THEM-A": "Alice"])
    }

    /// An emptied overlay deletes the sidecar, so the stamp cannot resurrect an
    /// otherwise-empty file that would then read as "there are overrides".
    func test_speaker_labels_empty_overlay_deletes_the_sidecar() throws {
        let dir = try tempDir()
        let url = SpeakerLabelStore.path(stem: "meeting", in: dir)

        try SpeakerLabelStore.setLabel("THEM-A", to: "Alice", stem: "meeting", in: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try SpeakerLabelStore.removeLabel("THEM-A", stem: "meeting", in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
