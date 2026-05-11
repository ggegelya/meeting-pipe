import XCTest
@testable import MeetingPipe

/// Pure-logic coverage for the Raw files tab's lister + classifier.
final class RawFilesTabTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-raw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    private func touch(_ url: URL, _ contents: String = "") throws {
        try contents.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    func test_lists_only_files_for_target_stem() throws {
        let dir = try tempDir()
        let stem = "20260511-143110"
        try touch(dir.appendingPathComponent("\(stem).wav"))
        try touch(dir.appendingPathComponent("\(stem).meta.json"))
        try touch(dir.appendingPathComponent("\(stem).summary.json"))
        try touch(dir.appendingPathComponent("20260511-150000.wav"))   // unrelated
        try touch(dir.appendingPathComponent("readme.txt"))            // unrelated

        let entries = RawFilesLister.list(stem: stem, in: dir)
        let names = entries.map(\.url.lastPathComponent)
        XCTAssertEqual(Set(names), Set([
            "\(stem).wav",
            "\(stem).meta.json",
            "\(stem).summary.json",
        ]))
    }

    func test_sorts_with_wav_first_then_canonical_kind_order() throws {
        let dir = try tempDir()
        let stem = "s"
        // Drop the sidecars in reverse — the lister must impose order.
        try touch(dir.appendingPathComponent("\(stem).run.json"))
        try touch(dir.appendingPathComponent("\(stem).summary.json"))
        try touch(dir.appendingPathComponent("\(stem).wav"))
        try touch(dir.appendingPathComponent("\(stem).json"))
        let entries = RawFilesLister.list(stem: stem, in: dir)
        XCTAssertEqual(entries.map(\.kind), [.wav, .transcript, .summaryJSON, .run])
    }

    func test_classify_recognizes_canonical_sidecars() {
        XCTAssertEqual(RawFilesLister.classify(name: "x.wav", stem: "x"), .wav)
        XCTAssertEqual(RawFilesLister.classify(name: "x.meta.json", stem: "x"), .meta)
        XCTAssertEqual(RawFilesLister.classify(name: "x.run.json", stem: "x"), .run)
        XCTAssertEqual(RawFilesLister.classify(name: "x.summary.json", stem: "x"), .summaryJSON)
        XCTAssertEqual(RawFilesLister.classify(name: "x.summary.md", stem: "x"), .summaryMarkdown)
        XCTAssertEqual(RawFilesLister.classify(name: "x.notion.json", stem: "x"), .notion)
        XCTAssertEqual(RawFilesLister.classify(name: "x.obsidian.json", stem: "x"), .obsidian)
        XCTAssertEqual(RawFilesLister.classify(name: "x.READY_FOR_MANUAL.md", stem: "x"), .readyForManual)
        XCTAssertEqual(RawFilesLister.classify(name: "x.json", stem: "x"), .transcript)
        XCTAssertEqual(RawFilesLister.classify(name: "x.md", stem: "x"), .markdownTranscript)
        XCTAssertEqual(RawFilesLister.classify(name: "x.something.weird", stem: "x"), .other)
    }

    func test_captures_size_and_modified_date() throws {
        let dir = try tempDir()
        let stem = "20260511-143110"
        let url = dir.appendingPathComponent("\(stem).wav")
        try touch(url, "1234567890")
        let entries = RawFilesLister.list(stem: stem, in: dir)
        XCTAssertEqual(entries.first?.sizeBytes, 10)
        XCTAssertNotNil(entries.first?.modified)
    }
}
