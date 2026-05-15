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
}
