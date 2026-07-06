import XCTest
@testable import MeetingPipe

/// Retention policy + sweep for the kept full recordings (ADR 0016 / MIC13).
/// `decideReap` is pure and covered exhaustively; `sweep` gets one end-to-end
/// check against a temp directory.
final class OriginalsReaperTests: XCTestCase {

    private func candidate(_ name: String, ageSeconds: TimeInterval, bytes: Int, now: Date) -> OriginalsReaper.Candidate {
        OriginalsReaper.Candidate(
            url: URL(fileURLWithPath: "/originals/\(name)"),
            sizeBytes: bytes,
            modified: now.addingTimeInterval(-ageSeconds)
        )
    }

    // MARK: - decideReap (pure)

    func test_reaps_copies_past_the_age_window() {
        let now = Date()
        let fresh = candidate("fresh.wav", ageSeconds: 5 * 24 * 3600, bytes: 1, now: now)
        let stale = candidate("stale.wav", ageSeconds: 40 * 24 * 3600, bytes: 1, now: now)
        let doomed = OriginalsReaper.decideReap(candidates: [fresh, stale], now: now)
        XCTAssertEqual(doomed, [stale.url])
    }

    func test_keeps_everything_within_age_and_size() {
        let now = Date()
        let a = candidate("a.wav", ageSeconds: 1 * 24 * 3600, bytes: 1_000, now: now)
        let b = candidate("b.wav", ageSeconds: 2 * 24 * 3600, bytes: 1_000, now: now)
        let doomed = OriginalsReaper.decideReap(
            candidates: [a, b], now: now, maxAge: 30 * 24 * 3600, maxTotalBytes: 1_000_000
        )
        XCTAssertTrue(doomed.isEmpty)
    }

    func test_reaps_oldest_first_when_over_the_size_cap() {
        let now = Date()
        // All within the age window; total 300 over a 150 cap, so the two oldest go.
        let oldest = candidate("oldest.wav", ageSeconds: 3 * 3600, bytes: 100, now: now)
        let middle = candidate("middle.wav", ageSeconds: 2 * 3600, bytes: 100, now: now)
        let newest = candidate("newest.wav", ageSeconds: 1 * 3600, bytes: 100, now: now)
        let doomed = OriginalsReaper.decideReap(
            candidates: [newest, oldest, middle], now: now, maxAge: 30 * 24 * 3600, maxTotalBytes: 150
        )
        XCTAssertEqual(Set(doomed), Set([oldest.url, middle.url]), "oldest-first until under the cap")
        XCTAssertFalse(doomed.contains(newest.url), "the freshest recovery copy survives")
    }

    func test_age_and_size_combine() {
        let now = Date()
        let stale = candidate("stale.wav", ageSeconds: 40 * 24 * 3600, bytes: 100, now: now)
        let big1 = candidate("big1.wav", ageSeconds: 3 * 3600, bytes: 100, now: now)
        let big2 = candidate("big2.wav", ageSeconds: 1 * 3600, bytes: 100, now: now)
        // stale reaped by age; survivors big1+big2 = 200 over a 100 cap, so the
        // oldest survivor (big1) is reaped and the freshest (big2) is kept.
        let doomed = OriginalsReaper.decideReap(
            candidates: [stale, big1, big2], now: now, maxAge: 30 * 24 * 3600, maxTotalBytes: 100
        )
        XCTAssertTrue(doomed.contains(stale.url))
        XCTAssertTrue(doomed.contains(big1.url))
        XCTAssertFalse(doomed.contains(big2.url))
    }

    func test_empty_input_reaps_nothing() {
        XCTAssertTrue(OriginalsReaper.decideReap(candidates: [], now: Date()).isEmpty)
    }

    // MARK: - sweep (temp dir)

    func test_sweep_deletes_only_the_stale_copy() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-reaper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()

        let fresh = dir.appendingPathComponent("fresh.wav")
        let stale = dir.appendingPathComponent("stale.wav")
        try Data("x".utf8).write(to: fresh)
        try Data("x".utf8).write(to: stale)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-2 * 24 * 3600)], ofItemAtPath: fresh.path)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-45 * 24 * 3600)], ofItemAtPath: stale.path)

        let reaped = OriginalsReaper.sweep(in: dir, now: now)
        XCTAssertEqual(reaped, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "a fresh copy is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "a copy past the window is reaped")
    }

    func test_sweep_absent_directory_is_a_noop() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-reaper-absent-\(UUID().uuidString)")
        XCTAssertEqual(OriginalsReaper.sweep(in: dir, now: Date()), 0)
    }
}
