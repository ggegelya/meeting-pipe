import XCTest
@testable import MeetingPipe

/// END17's keep-then-trim, the reading half: a held end keeps its tail in the WAV and the words
/// stop where the hold began.
final class HeldEndTrimTests: XCTestCase {

    private func word(_ text: String, _ start: Double) -> SidecarWord {
        SidecarWord(word: text, start: start, end: start + 0.4)
    }

    private func sidecar() -> TranscriptSidecar {
        TranscriptSidecar(
            language: "en",
            segments: [
                SidecarSegment(start: 0, end: 4, text: "Hello there", words: [word(" Hello", 0), word(" there", 1)], speaker: "S1"),
                SidecarSegment(start: 95, end: 105, text: "Thanks bye all", words: [word(" Thanks", 95), word(" bye", 99), word(" all", 102)], speaker: "S2"),
                SidecarSegment(start: 130, end: 140, text: "hold music", words: [word(" hold", 130), word(" music", 131)], speaker: "S3"),
            ],
            audioPath: "/tmp/m.wav",
            audioSeconds: 840,
            model: "parakeet",
            backend: "fluidaudio",
            diarization: true,
            diarizationFailed: false,
            diarizationFailureReason: nil,
            streaming: false,
            finalized: false,
            speakerEmbeddings: ["S1": [0.1], "S2": [0.2], "S3": [0.3]]
        )
    }

    func test_the_tail_is_left_out_and_a_straddling_segment_is_cut_at_its_words() {
        let trimmed = HeldEndTrim.apply(sidecar(), at: 100)
        XCTAssertEqual(trimmed.segments.count, 2, "nothing after the trim point survives")
        XCTAssertEqual(trimmed.segments[1].text, "Thanks bye")
        XCTAssertEqual(trimmed.segments[1].words.count, 2)
        XCTAssertEqual(trimmed.segments[1].end, 100)
        XCTAssertEqual(trimmed.audioSeconds, 840, "the file still has the tail, so its length is unchanged")
    }

    /// A voice heard only in the tail must not be enrolled or matched from it.
    func test_a_voiceprint_heard_only_in_the_tail_is_dropped() {
        let trimmed = HeldEndTrim.apply(sidecar(), at: 100)
        XCTAssertEqual(trimmed.speakerEmbeddings?.keys.sorted(), ["S1", "S2"])
    }

    func test_a_trim_past_the_last_word_changes_nothing() {
        XCTAssertEqual(HeldEndTrim.apply(sidecar(), at: 500), sidecar())
    }

    func test_the_key_reads_as_a_positive_number_only() {
        XCTAssertEqual(HeldEndTrim.trimSeconds(meta: [HeldEndTrim.metaKey: 2531.5]), 2531.5)
        XCTAssertEqual(HeldEndTrim.trimSeconds(meta: [HeldEndTrim.metaKey: 90]), 90)
        XCTAssertNil(HeldEndTrim.trimSeconds(meta: [HeldEndTrim.metaKey: 0]))
        XCTAssertNil(HeldEndTrim.trimSeconds(meta: [HeldEndTrim.metaKey: "90"]))
        XCTAssertNil(HeldEndTrim.trimSeconds(meta: [:]))
    }

    func test_the_meta_beside_the_audio_is_read_by_stem() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("end17-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"held_end_trim_sec": 61}"#.write(to: dir.appendingPathComponent("20261024-1000.meta.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(HeldEndTrim.trimSeconds(forAudio: dir.appendingPathComponent("20261024-1000.wav")), 61)
        XCTAssertNil(HeldEndTrim.trimSeconds(forAudio: dir.appendingPathComponent("20261024-1100.wav")))
    }

    func test_the_caption_counts_the_trimmed_minutes_rounding_up() {
        XCTAssertEqual(
            HeldEndTrim.caption(trimSec: 600, durationSec: 1320),
            "Trimmed 12 min after the call ended. The recording still has it."
        )
        XCTAssertEqual(
            HeldEndTrim.caption(trimSec: 600, durationSec: 620),
            "Trimmed 1 min after the call ended. The recording still has it.",
            "a 20 s tail never reads as 0 min"
        )
    }
}
