import XCTest
@testable import MeetingPipe

/// UX83: the owner's unnamed voice is `speaker_user` (or, before UX83, a raw numeric id with a
/// voiceprint), reads "You", is never counted as a roster match, and takes a name from
/// **Set your name…** carried through the speaker-label overlay.
final class OwnerNameTests: XCTestCase {

    private func seg(_ i: Int, _ speaker: String?) -> TranscriptSegment {
        TranscriptSegment(index: i, start: Double(i), end: Double(i) + 1, text: "line \(i)", speakerID: speaker)
    }

    // MARK: - Classification

    func test_a_raw_numeric_owner_with_a_voiceprint_is_you_not_a_roster_match() {
        // Before UX83 this voice classified `.roster` and inflated `rosterMatched`.
        let out = VoiceResolution.derive(
            cast: [CastMember(displayName: "1", assignKey: "1", isUnattributed: false),
                   CastMember(displayName: "Unknown A", assignKey: "THEM-A", isUnattributed: false)],
            voiceprintLabels: ["1", "THEM-A"], rosterNames: ["Rana"], userLabel: ""
        )
        XCTAssertEqual(out.voices.first?.origin, .you)
        XCTAssertEqual(out.rosterMatched, 0)
        XCTAssertEqual(out.unresolved, 1)
        XCTAssertTrue(out.voices.first?.isOwnerKey ?? false)
    }

    func test_the_reserved_label_is_you_with_or_without_a_voiceprint() {
        for prints: Set<String> in [["speaker_user"], []] {
            let out = VoiceResolution.derive(
                cast: [CastMember(displayName: "You", assignKey: "speaker_user", isUnattributed: false)],
                voiceprintLabels: prints, rosterNames: [], userLabel: ""
            )
            XCTAssertEqual(out.voices.first?.origin, .you)
            XCTAssertEqual(out.rosterMatched + out.namedHere + out.unresolved, 0)
        }
    }

    func test_a_numeric_label_with_no_voiceprint_is_not_the_owner() {
        XCTAssertFalse(OwnerName.isOwnerKey("2", voiceprintLabels: []))
        XCTAssertFalse(OwnerName.isOwnerKey("Rana", voiceprintLabels: ["Rana"]))
        XCTAssertTrue(OwnerName.isOwnerKey("12", voiceprintLabels: ["12"]))
    }

    // MARK: - Rendering

    func test_the_reserved_label_renders_as_you() {
        XCTAssertEqual(TranscriptDisplay.displayName(for: "speaker_user"), "You")
        XCTAssertEqual(TranscriptDisplay.displayName(for: "speaker_0"), "Speaker 1")
    }

    func test_cast_and_rows_render_an_old_numeric_owner_as_you_until_it_is_named() {
        let segs = [seg(0, "1"), seg(1, "THEM-A")]
        let cast = MeetingCast.members(segments: segs, overlay: .empty, voiceprintLabels: ["1", "THEM-A"])
        XCTAssertEqual(cast.map(\.displayName), ["You", "Unknown A"])
        XCTAssertEqual(cast.first?.assignKey, "1", "the overlay key stays the raw label Python reads")

        let row = MeetingCast.rowSpeaker(for: segs[0], overlay: .empty, voiceprintLabels: ["1", "THEM-A"])
        XCTAssertEqual(row.displayName, "You")
        XCTAssertEqual(row.actions, [], "no roster enroll, rename or forget on the owner from a row")

        let named = SpeakerLabelStore.Overlay(labels: ["1": "Alex"], segments: [:])
        let namedRow = MeetingCast.rowSpeaker(for: segs[0], overlay: named, voiceprintLabels: ["1"])
        XCTAssertEqual(namedRow.displayName, "Alex")
        XCTAssertEqual(namedRow.actions, [])
    }

    // MARK: - The chip

    func test_the_owner_chip_offers_set_your_name_and_a_baked_name_does_not() {
        let out = VoiceResolution.derive(
            cast: [CastMember(displayName: "You", assignKey: "speaker_user", isUnattributed: false)],
            voiceprintLabels: ["speaker_user"], rosterNames: [], userLabel: ""
        )
        let voice = try! XCTUnwrap(out.voices.first)
        XCTAssertEqual(VoiceResolutionBar.actions(for: voice), [.setYourName])
        XCTAssertEqual(VoiceResolutionBar.title(for: .setYourName), "Set your name\u{2026}")

        let baked = VoiceResolution.derive(
            cast: [CastMember(displayName: "Alex", assignKey: "Alex", isUnattributed: false)],
            voiceprintLabels: ["Alex"], rosterNames: [], userLabel: "Alex"
        )
        XCTAssertEqual(baked.voices.first?.origin, .you)
        XCTAssertEqual(VoiceResolutionBar.actions(for: baked.voices[0]), [])
    }

    // MARK: - The carry

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ux83-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func writeMeeting(_ stem: String, speakers: [String], voiceprints: [String], in dir: URL) throws {
        let segments = speakers.enumerated().map { i, s in
            ["start": Double(i), "end": Double(i) + 1, "text": "t\(i)", "speaker": s] as [String: Any]
        }
        try JSONSerialization.data(withJSONObject: ["segments": segments])
            .write(to: dir.appendingPathComponent("\(stem).json"))
        if !voiceprints.isEmpty {
            let emb = Dictionary(uniqueKeysWithValues: voiceprints.map { ($0, [0.1, 0.2]) })
            try JSONSerialization.data(withJSONObject: ["schema_version": 2, "embeddings": emb])
                .write(to: dir.appendingPathComponent("\(stem).embeddings.json"))
        }
    }

    func test_set_your_name_carries_into_past_meetings_without_overriding_a_choice_made_there() throws {
        let dir = try tempDir()
        try writeMeeting("20261101-090000", speakers: ["speaker_user", "THEM-A"], voiceprints: ["speaker_user", "THEM-A"], in: dir)
        try writeMeeting("20261102-090000", speakers: ["1", "THEM-A"], voiceprints: ["1", "THEM-A"], in: dir)   // pre-UX83
        try writeMeeting("20261103-090000", speakers: ["speaker_user", "speaker_other"], voiceprints: [], in: dir) // channel fallback
        try writeMeeting("20261104-090000", speakers: ["speaker_user"], voiceprints: ["speaker_user"], in: dir)
        _ = try SpeakerLabelStore.setLabel("speaker_user", to: "Boss", stem: "20261104-090000", in: dir)
        try writeMeeting("20261105-090000", speakers: ["Rana", "THEM-A"], voiceprints: ["Rana", "THEM-A"], in: dir)
        try writeMeeting("20261106-090000", speakers: ["speaker_user"], voiceprints: [], in: dir)

        let out = OwnerName.carry(name: "Alex", currentStem: "20261101-090000", in: dir, skip: ["20261106-090000"])

        XCTAssertEqual(out, RosterRename.Outcome(carried: 3, failed: 0))
        func labels(_ stem: String) -> [String: String] { SpeakerLabelStore.read(stem: stem, in: dir).labels }
        XCTAssertEqual(labels("20261101-090000"), ["speaker_user": "Alex"])
        XCTAssertEqual(labels("20261102-090000"), ["1": "Alex"])
        XCTAssertEqual(labels("20261103-090000"), ["speaker_user": "Alex"])
        XCTAssertEqual(labels("20261104-090000"), ["speaker_user": "Boss"], "a name chosen in that meeting stays")
        XCTAssertEqual(labels("20261105-090000"), [:], "a meeting with no unnamed owner is left alone")
        XCTAssertEqual(labels("20261106-090000"), [:], "a meeting being re-transcribed is skipped")
        // The transcript itself is never rewritten.
        let raw = try String(contentsOf: dir.appendingPathComponent("20261102-090000.json"), encoding: .utf8)
        XCTAssertTrue(raw.contains("\"1\""))
    }

    func test_in_the_meeting_clicked_set_your_name_replaces_an_earlier_name() throws {
        let dir = try tempDir()
        try writeMeeting("20261104-090000", speakers: ["speaker_user"], voiceprints: ["speaker_user"], in: dir)
        _ = try SpeakerLabelStore.setLabel("speaker_user", to: "Boss", stem: "20261104-090000", in: dir)
        _ = OwnerName.carry(name: "Alex", currentStem: "20261104-090000", in: dir)
        XCTAssertEqual(SpeakerLabelStore.read(stem: "20261104-090000", in: dir).labels, ["speaker_user": "Alex"])
    }

    func test_a_meeting_with_two_numeric_owner_keys_is_not_carried_into() throws {
        let dir = try tempDir()
        try writeMeeting("20261107-090000", speakers: ["1", "2"], voiceprints: ["1", "2"], in: dir)
        let out = OwnerName.carry(name: "Alex", currentStem: nil, in: dir)
        XCTAssertEqual(out.carried, 0)
        XCTAssertEqual(SpeakerLabelStore.read(stem: "20261107-090000", in: dir).labels, [:])
    }

    @MainActor
    func test_set_your_name_writes_summarization_user_label_and_refuses_an_unreadable_file() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("config.toml")
        try "[summarization]\nbackend = \"anthropic\"\n".write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(configURL: url)
        XCTAssertTrue(OwnerName.save("Alex", to: store))
        XCTAssertEqual(store.summarizationUserLabel, "Alex")

        let broken = dir.appendingPathComponent("broken.toml")
        try "[summarization\nbackend = ".write(to: broken, atomically: true, encoding: .utf8)
        let refusing = ConfigStore(configURL: broken)
        XCTAssertNotNil(refusing.parseError)
        XCTAssertFalse(OwnerName.save("Alex", to: refusing))
        XCTAssertEqual(refusing.summarizationUserLabel, "")
    }

    // MARK: - Onboarding

    func test_onboarding_prefills_from_the_account_name_and_saves_only_a_change() {
        XCTAssertEqual(OwnerNameDraft.initial(saved: "", accountName: "Alex Doe"), "Alex Doe")
        XCTAssertEqual(OwnerNameDraft.initial(saved: " Al ", accountName: "Alex Doe"), "Al", "an existing name is not replaced")
        XCTAssertEqual(OwnerNameDraft.toSave(draft: " Alex Doe ", saved: ""), "Alex Doe")
        XCTAssertNil(OwnerNameDraft.toSave(draft: "Al", saved: "Al"))
        XCTAssertNil(OwnerNameDraft.toSave(draft: "   ", saved: ""), "blank keeps You and writes nothing")
    }
}
