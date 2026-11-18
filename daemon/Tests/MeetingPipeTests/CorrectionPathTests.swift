import XCTest
@testable import MeetingPipe

/// LOCAL26: a new correction record names the meeting's files in the current library, not the
/// run sidecar's absolute paths, which a library move or a cross-path restore leaves stale.
final class CorrectionPathTests: XCTestCase {
    func test_the_current_library_wins_over_a_stale_stored_path() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("local26-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = "/Volumes/OldLibrary/raw/m.md"

        // Not in this library: the stored path is the hint, and with none, this library's path.
        XCTAssertEqual(CorrectionStore.currentPath(stored: stale, stem: "m", suffix: ".md", in: dir), stale)
        XCTAssertEqual(CorrectionStore.currentPath(stored: nil, stem: "m", suffix: ".md", in: dir),
                       dir.appendingPathComponent("m.md").path)

        try Data("t".utf8).write(to: dir.appendingPathComponent("m.md"))
        XCTAssertEqual(CorrectionStore.currentPath(stored: stale, stem: "m", suffix: ".md", in: dir),
                       dir.appendingPathComponent("m.md").path)

        let model = CorrectionViewModel(stem: "m", recordingsDir: dir,
                                        runMeta: ["transcript_path": stale], originalSummary: MeetingSummary())
        XCTAssertEqual(model.transcriptPath, dir.appendingPathComponent("m.md").path)
    }
}
