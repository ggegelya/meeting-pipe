import XCTest
@testable import MeetingPipe

/// UX90: which banner a run that exited 0 gets. A paste-bundle skip used to fall through to
/// "Meeting processed / Nothing was published" while the meeting waited for a paste.
final class DoneRouteTests: XCTestCase {

    func test_a_paste_bundle_with_no_summary_takes_the_paste_branch() {
        XCTAssertEqual(DoneRoute.decide(emptyReason: nil, hasPasteBundle: true, hasSummary: false), .pasteReady)
    }

    func test_the_empty_marker_wins_over_a_paste_bundle() {
        XCTAssertEqual(DoneRoute.decide(emptyReason: .noSpeech, hasPasteBundle: true, hasSummary: false),
                       .empty(.noSpeech))
    }

    func test_a_bundle_beside_a_summary_is_an_ordinary_done() {
        XCTAssertEqual(DoneRoute.decide(emptyReason: nil, hasPasteBundle: true, hasSummary: true), .done)
        XCTAssertEqual(DoneRoute.decide(emptyReason: nil, hasPasteBundle: false, hasSummary: true), .done)
    }

    func test_probe_reads_the_files() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mp-doneroute-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stem = "20260511-143110"
        XCTAssertEqual(DoneRoute.probe(stem: stem, in: dir), .done)
        try Data("x".utf8).write(to: dir.appendingPathComponent("\(stem).READY_FOR_MANUAL.md"))
        XCTAssertEqual(DoneRoute.probe(stem: stem, in: dir), .pasteReady)
    }
}
