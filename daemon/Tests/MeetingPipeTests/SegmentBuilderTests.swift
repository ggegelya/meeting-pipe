import XCTest
@testable import MeetingPipe

final class SegmentBuilderTests: XCTestCase {

    func test_empty_tokens_returns_no_segments() {
        let segments = SegmentBuilder.build(tokens: [], speakers: [])
        XCTAssertEqual(segments, [])
    }

    func test_sentence_terminator_splits_segments() {
        let tokens = [
            AsrToken(text: "Hello", start: 0.0, end: 0.4),
            AsrToken(text: " world.", start: 0.4, end: 1.0),
            AsrToken(text: " Next", start: 1.05, end: 1.4),
            AsrToken(text: " up", start: 1.4, end: 1.9)
        ]
        let segments = SegmentBuilder.build(tokens: tokens, speakers: [])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Hello world.")
        XCTAssertEqual(segments[0].start, 0.0, accuracy: 0.0001)
        XCTAssertEqual(segments[0].end, 1.0, accuracy: 0.0001)
        XCTAssertEqual(segments[1].text, "Next up")
    }

    func test_long_gap_splits_segments() {
        // Two-token utterance with a 1.0 s gap that exceeds the 0.7 s default.
        let tokens = [
            AsrToken(text: "First", start: 0.0, end: 0.5),
            AsrToken(text: " second", start: 1.5, end: 2.0)
        ]
        let segments = SegmentBuilder.build(tokens: tokens, speakers: [])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "First")
        XCTAssertEqual(segments[1].text, "second")
    }

    func test_max_duration_splits_runaway_segment() {
        // Twenty-five tokens with no terminator and small gaps; the 20 s ceiling
        // must force a split before the segment runs unbounded.
        let tokens = (0..<25).map { i in
            AsrToken(text: " word\(i)", start: Double(i) * 1.0, end: Double(i) * 1.0 + 0.5)
        }
        let segments = SegmentBuilder.build(tokens: tokens, speakers: [])
        XCTAssertGreaterThan(segments.count, 1, "should split before the 20s ceiling")
        for seg in segments {
            XCTAssertLessThan(seg.end - seg.start, 21.0)
        }
    }

    func test_words_are_preserved_per_segment() {
        let tokens = [
            AsrToken(text: "A", start: 0.0, end: 0.1),
            AsrToken(text: " B.", start: 0.1, end: 0.2)
        ]
        let segments = SegmentBuilder.build(tokens: tokens, speakers: [])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].words.count, 2)
        XCTAssertEqual(segments[0].words[0].word, "A")
        XCTAssertEqual(segments[0].words[1].word, " B.")
    }

    func test_empty_tokens_are_dropped_by_default() {
        let tokens = [
            AsrToken(text: "Real", start: 0.0, end: 0.5),
            AsrToken(text: "  ", start: 0.5, end: 0.55),
            AsrToken(text: " text.", start: 0.55, end: 1.0)
        ]
        let segments = SegmentBuilder.build(tokens: tokens, speakers: [])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].words.count, 2)
    }

    func test_speaker_assignment_by_largest_overlap() {
        let segment = SegmentBuilder.assignSpeaker(
            segmentStart: 1.0,
            segmentEnd: 4.0,
            speakers: [
                SpeakerSpan(speakerId: "a", start: 0.0, end: 1.5),
                SpeakerSpan(speakerId: "b", start: 1.5, end: 4.0)
            ],
            fallback: "unknown"
        )
        // b overlaps 2.5s of the segment, a overlaps 0.5s.
        XCTAssertEqual(segment, "b")
    }

    func test_speaker_assignment_falls_back_when_no_overlap() {
        let segment = SegmentBuilder.assignSpeaker(
            segmentStart: 10.0,
            segmentEnd: 11.0,
            speakers: [
                SpeakerSpan(speakerId: "a", start: 0.0, end: 5.0)
            ],
            fallback: "speaker_unknown"
        )
        XCTAssertEqual(segment, "speaker_unknown")
    }

    func test_speaker_assignment_tie_breaks_by_earliest_start() {
        // Both spans contribute exactly 1.0s of overlap; the earlier span wins.
        let segment = SegmentBuilder.assignSpeaker(
            segmentStart: 2.0,
            segmentEnd: 4.0,
            speakers: [
                SpeakerSpan(speakerId: "late", start: 3.0, end: 5.0),
                SpeakerSpan(speakerId: "early", start: 1.0, end: 3.0)
            ],
            fallback: "x"
        )
        XCTAssertEqual(segment, "early")
    }

    // MARK: - coalesce (DIAR2)

    private func seg(
        _ text: String, _ start: Double, _ end: Double, _ speaker: String,
        words: [SidecarWord]? = nil
    ) -> SidecarSegment {
        SidecarSegment(
            start: start, end: end, text: text,
            words: words ?? [SidecarWord(word: text, start: start, end: end)],
            speaker: speaker
        )
    }

    func test_coalesce_empty_returns_empty() {
        XCTAssertEqual(SegmentBuilder.coalesce([]), [])
    }

    func test_coalesce_merges_adjacent_same_speaker_into_a_turn() {
        let input = [
            seg("Hello world.", 0.0, 1.0, "A",
                words: [SidecarWord(word: "Hello world.", start: 0.0, end: 1.0)]),
            seg("Next up", 1.1, 1.9, "A",
                words: [SidecarWord(word: " Next up", start: 1.1, end: 1.9)])
        ]
        let out = SegmentBuilder.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "Hello world. Next up")
        XCTAssertEqual(out[0].start, 0.0, accuracy: 1e-9)
        XCTAssertEqual(out[0].end, 1.9, accuracy: 1e-9)
        XCTAssertEqual(out[0].words.count, 2)
        XCTAssertEqual(out[0].speaker, "A")
    }

    func test_coalesce_keeps_different_speakers_separate() {
        let input = [
            seg("Hello.", 0.0, 1.0, "A"),
            seg("Hi there.", 1.1, 2.0, "B")
        ]
        XCTAssertEqual(SegmentBuilder.coalesce(input).count, 2)
    }

    func test_coalesce_respects_the_gap_threshold() {
        // Same speaker but a 2.0s pause exceeds the 1.2s merge gap: stays two turns.
        let input = [
            seg("First.", 0.0, 1.0, "A"),
            seg("Second.", 3.0, 4.0, "A")
        ]
        XCTAssertEqual(SegmentBuilder.coalesce(input).count, 2)
    }

    func test_coalesce_caps_a_long_monologue() {
        // Twenty 2s same-speaker segments with tiny gaps (~42s total) must split
        // at the 30s turn cap rather than becoming one wall of text.
        let input = (0..<20).map { i -> SidecarSegment in
            let start = Double(i) * 2.1
            return seg("word\(i).", start, start + 2.0, "A",
                       words: [SidecarWord(word: " word\(i).", start: start, end: start + 2.0)])
        }
        let out = SegmentBuilder.coalesce(input)
        XCTAssertGreaterThan(out.count, 1, "should split at the 30s turn cap")
        for turn in out {
            XCTAssertLessThanOrEqual(turn.end - turn.start, 30.0 + 1e-6)
        }
    }

    func test_coalesce_drops_standalone_punctuation_only_segments() {
        let input = [
            seg("Hello.", 0.0, 1.0, "A"),
            seg(".", 1.05, 1.3, "B"),
            seg("Bye.", 5.0, 6.0, "C")
        ]
        let out = SegmentBuilder.coalesce(input)
        XCTAssertEqual(out.map(\.speaker), ["A", "C"])
        XCTAssertFalse(out.contains { $0.text == "." })
    }

    func test_coalesce_merges_across_dropped_punctuation_without_injecting_it() {
        // A phantom "." between two same-speaker fragments is removed, and the
        // fragments then read as one turn WITHOUT the stray period folded in.
        let input = [
            seg("Hello", 0.0, 1.0, "A",
                words: [SidecarWord(word: "Hello", start: 0.0, end: 1.0)]),
            seg(".", 1.02, 1.2, "A",
                words: [SidecarWord(word: " .", start: 1.02, end: 1.2)]),
            seg("world", 1.25, 2.0, "A",
                words: [SidecarWord(word: " world", start: 1.25, end: 2.0)])
        ]
        let out = SegmentBuilder.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "Hello world")
    }

    func test_coalesce_keeps_a_short_real_interjection() {
        // "Yeah" between two other speakers is real speech, not noise: kept.
        let input = [
            seg("What do you think?", 0.0, 2.0, "A"),
            seg("Yeah", 2.1, 2.4, "B"),
            seg("I agree.", 2.5, 3.5, "A")
        ]
        let out = SegmentBuilder.coalesce(input)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[1].text, "Yeah")
    }

    func test_coalesce_treats_cyrillic_as_speech() {
        // hasSpeech is Unicode-aware, so a Cyrillic-only turn is not dropped.
        let out = SegmentBuilder.coalesce([seg("Привіт", 0.0, 1.0, "A")])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "Привіт")
    }
}
