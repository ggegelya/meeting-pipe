import XCTest
@testable import MeetingPipe

/// SEC22 item 5: when audio retention drops a meeting's audio, `<stem>.embeddings.json`
/// keeps its label keys and loses its voice vectors (owner's decision, 2026-11-26). The
/// shape is a cross-tree contract, pinned by `embeddings-voiceprints-dropped-golden.json`,
/// which `pipeline/tests/test_sec22_voiceprints_dropped.py` runs every Python reader over.
final class EmbeddingsVoiceprintsDroppedTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-sec22-emb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    struct Case {
        let name: String
        let before: [String: Any]
        let after: [String: Any]
        let labels: Set<String>
        let enrollableBefore: Set<String>
    }

    static func cases() throws -> [Case] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "embeddings-voiceprints-dropped-golden", withExtension: "json"),
            "missing fixture embeddings-voiceprints-dropped-golden.json"
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let raw = try XCTUnwrap(root["cases"] as? [[String: Any]])
        return try raw.map { c in
            Case(
                name: try XCTUnwrap(c["name"] as? String),
                before: try XCTUnwrap(c["before"] as? [String: Any]),
                after: try XCTUnwrap(c["after"] as? [String: Any]),
                labels: Set(try XCTUnwrap(c["labels"] as? [String])),
                enrollableBefore: Set(try XCTUnwrap(c["enrollable_before"] as? [String]))
            )
        }
    }

    private func write(_ obj: [String: Any], stem: String) throws {
        try JSONSerialization.data(withJSONObject: obj)
            .write(to: dir.appendingPathComponent("\(stem).embeddings.json"))
    }

    private func read(stem: String) throws -> NSDictionary {
        let data = try Data(contentsOf: dir.appendingPathComponent("\(stem).embeddings.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func test_the_fixture_is_not_vacuous() throws {
        let all = try Self.cases()
        XCTAssertGreaterThanOrEqual(all.count, 3)
        XCTAssertTrue(all.contains { !$0.enrollableBefore.isEmpty }, "a case must start with real vectors")
    }

    func test_dropping_voiceprints_rewrites_before_into_exactly_after() throws {
        for c in try Self.cases() {
            try write(c.before, stem: c.name)
            _ = try MeetingStore.dropVoiceprints(stem: c.name, in: dir)
            XCTAssertEqual(try read(stem: c.name), c.after as NSDictionary, c.name)
        }
    }

    func test_the_rewrite_reports_whether_it_removed_a_vector() throws {
        for c in try Self.cases() {
            try write(c.before, stem: c.name)
            let expected: MeetingStore.VoiceprintDrop = c.enrollableBefore.isEmpty ? .nothingToDrop : .dropped
            XCTAssertEqual(try MeetingStore.dropVoiceprints(stem: c.name, in: dir), expected, c.name)
        }
    }

    func test_an_already_stripped_file_is_not_rewritten() throws {
        let c = try XCTUnwrap(try Self.cases().first { $0.enrollableBefore.isEmpty })
        try write(c.before, stem: "m")
        let url = dir.appendingPathComponent("m.embeddings.json")
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(try MeetingStore.dropVoiceprints(stem: "m", in: dir), .nothingToDrop)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "nothing to drop means byte-identical")
    }

    func test_the_rewrite_is_owner_only_even_over_a_world_readable_file() throws {
        let c = try XCTUnwrap(try Self.cases().first { !$0.enrollableBefore.isEmpty })
        try write(c.before, stem: "m")
        let url = dir.appendingPathComponent("m.embeddings.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let old = umask(0o022)
        defer { umask(old) }
        XCTAssertEqual(try MeetingStore.dropVoiceprints(stem: "m", in: dir), .dropped)
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(mode & 0o777, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(leftovers, ["m.embeddings.json"], "no temp file is left behind")
    }

    func test_a_missing_file_has_nothing_to_drop_and_an_unparsable_one_is_left_alone() throws {
        XCTAssertEqual(try MeetingStore.dropVoiceprints(stem: "absent", in: dir), .nothingToDrop)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("absent.embeddings.json").path))

        let url = dir.appendingPathComponent("bad.embeddings.json")
        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(try MeetingStore.dropVoiceprints(stem: "bad", in: dir), .unreadable)
        XCTAssertEqual(try Data(contentsOf: url), Data("{not json".utf8), "never replaced")
    }

    func test_the_parse_keeps_every_label_and_marks_the_dropped_ones() throws {
        for c in try Self.cases() {
            let after = MeetingStore.embeddingsSidecar(from: c.after)
            XCTAssertEqual(after.voiceprintLabels, c.labels, c.name)
            XCTAssertEqual(after.droppedVoiceprints, c.labels, c.name)
            XCTAssertEqual(after.enrollableLabels, [], "\(c.name): nothing on a stripped file can enroll")

            let before = MeetingStore.embeddingsSidecar(from: c.before)
            XCTAssertEqual(before.voiceprintLabels, c.labels, c.name)
            XCTAssertEqual(before.enrollableLabels, c.enrollableBefore, c.name)
        }
    }

    func test_near_misses_survive_but_suggest_nothing_without_a_vector() throws {
        let c = try XCTUnwrap(try Self.cases().first { $0.after["near_misses"] != nil })
        let sidecar = MeetingStore.embeddingsSidecar(from: c.after)
        XCTAssertEqual(sidecar.nearMisses, ["THEM-A": "Rana"])
        let out = VoiceResolution.derive(
            cast: [CastMember(displayName: "THEM-A", assignKey: "THEM-A", isUnattributed: false)],
            voiceprintLabels: sidecar.voiceprintLabels,
            droppedVoiceprints: sidecar.droppedVoiceprints,
            nearMisses: sidecar.nearMisses,
            rosterNames: ["Rana"],
            userLabel: "Heorhii"
        )
        XCTAssertNil(out.voices[0].suggestedName, "a near miss is only offered for a voice that can enroll")
    }

    /// The reason the labels stay: a meeting finalized before UX83 keeps the owner on a raw
    /// numeric id, recognised only through the sidecar's keys, and a drop policy reaches the
    /// oldest meetings first.
    func test_a_pre_ux83_owner_still_reads_as_you_after_the_strip() throws {
        let c = try XCTUnwrap(try Self.cases().first { $0.labels.contains("1") })
        try write(c.before, stem: "m")
        _ = try MeetingStore.dropVoiceprints(stem: "m", in: dir)
        let labels = MeetingStore.embeddingsSidecar(stem: "m", in: dir).voiceprintLabels
        XCTAssertTrue(OwnerName.isOwnerKey("1", voiceprintLabels: labels))
    }
}
