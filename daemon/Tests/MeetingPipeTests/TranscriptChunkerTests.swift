import XCTest
@testable import MeetingPipe

/// `TranscriptChunker` is the Swift mirror of `pipeline/src/mp/chunking.py`
/// (TECH-SUM1-PRIMITIVE). These cases mirror `test_chunking.py` so the two
/// implementations stay in parity: same window count, same coverage contract,
/// same overlap and carry behaviour.
final class TranscriptChunkerTests: XCTestCase {

    private func transcript(words: Int, prefix: String = "w") -> String {
        (0..<words).map { "\(prefix)\($0)" }.joined(separator: " ")
    }

    func test_sixty_minute_transcript_makes_about_four_windows() {
        let t = String(repeating: "lorem ipsum dolor sit amet ", count: 1100)  // ~30k chars
        XCTAssertGreaterThan(t.count, 29000)
        let windows = TranscriptChunker.windows(t, maxChars: 8000, overlapChars: 200)
        XCTAssertEqual(windows.count, 4)
        XCTAssertTrue(windows.allSatisfy { $0.text.count <= 8000 })
        XCTAssertTrue(windows.first!.isFirst)
        XCTAssertFalse(windows.first!.isLast)
        XCTAssertTrue(windows.last!.isLast)
        XCTAssertFalse(windows.last!.isFirst)
    }

    func test_every_word_appears_in_at_least_one_window() {
        let t = transcript(words: 2000)
        let original = Set(t.split(separator: " ").map(String.init))
        var covered = Set<String>()
        for window in TranscriptChunker.windows(t, maxChars: 200, overlapChars: 20) {
            covered.formUnion(window.text.split(separator: " ").map(String.init))
        }
        XCTAssertTrue(original.isSubset(of: covered))
    }

    func test_consecutive_windows_overlap() {
        let t = transcript(words: 2000)
        let windows = TranscriptChunker.windows(t, maxChars: 200, overlapChars: 40)
        XCTAssertGreaterThan(windows.count, 1)
        for (prev, next) in zip(windows, windows.dropFirst()) {
            XCTAssertTrue(prev.text.contains(String(next.text.prefix(10))))
        }
    }

    func test_empty_transcript_yields_no_windows() {
        XCTAssertEqual(TranscriptChunker.windows("", maxChars: 100).count, 0)
    }

    func test_short_transcript_is_single_window() {
        let windows = TranscriptChunker.windows("just a few words", maxChars: 8000)
        XCTAssertEqual(windows.count, 1)
        XCTAssertTrue(windows[0].isFirst && windows[0].isLast)
        XCTAssertEqual(windows[0].text, "just a few words")
        XCTAssertEqual(windows[0].index, 0)
    }

    func test_prompt_prepends_carry_only_when_supplied() {
        let window = TranscriptChunker.windows("a b c d e", maxChars: 8000).first!
        XCTAssertEqual(TranscriptChunker.prompt(for: window, carrySummary: nil), window.text)
        let withCarry = TranscriptChunker.prompt(for: window, carrySummary: "earlier we agreed X")
        XCTAssertTrue(withCarry.hasPrefix(TranscriptChunker.carryHeader))
        XCTAssertTrue(withCarry.contains("earlier we agreed X"))
        XCTAssertTrue(withCarry.hasSuffix(window.text))
    }
}
