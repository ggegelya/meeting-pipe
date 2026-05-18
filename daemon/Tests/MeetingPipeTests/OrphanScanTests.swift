import XCTest
@testable import MeetingPipe

/// Pure detection logic: an in-memory `[stem: [URL]]` plus a real
/// filesystem fixture. Locks in:
///   - A well-formed stem with a wav and sidecars is NOT an orphan.
///   - A stem whose only `.wav` has a non-parseable name is reported
///     as `wavsWithoutRow`.
///   - A stem with sidecars but no `.wav` is reported as
///     `rowsWithoutWav`, sorted by stem and with sidecars sorted by
///     filename for stable output.
///   - An empty directory is empty in, empty out.
///   - The doctor probe message lists counts plus a sample of stems.
final class OrphanScanTests: XCTestCase {

    private let dir = URL(fileURLWithPath: "/tmp/orphan-scan-fixture")

    private func u(_ name: String) -> URL { dir.appendingPathComponent(name) }

    // MARK: - detect (pure)

    func test_well_formed_stem_with_wav_and_sidecars_is_not_an_orphan() {
        let stems: [String: [URL]] = [
            "20260301-101500": [
                u("20260301-101500.wav"),
                u("20260301-101500.meta.json"),
                u("20260301-101500.json"),
            ]
        ]
        let report = OrphanScan.detect(stems: stems)
        XCTAssertTrue(report.isEmpty, "well-formed stem should not surface")
    }

    func test_wav_with_unparseable_stem_is_reported() {
        let stems: [String: [URL]] = [
            "manual-notes": [u("manual-notes.wav")],
        ]
        let report = OrphanScan.detect(stems: stems)
        XCTAssertEqual(report.wavsWithoutRow.count, 1)
        XCTAssertEqual(report.wavsWithoutRow.first?.stem, "manual-notes")
        XCTAssertTrue(report.rowsWithoutWav.isEmpty)
    }

    func test_stem_without_wav_but_with_sidecars_is_reported() {
        let stems: [String: [URL]] = [
            "20260308-090000": [
                u("20260308-090000.meta.json"),
                u("20260308-090000.summary.json"),
            ]
        ]
        let report = OrphanScan.detect(stems: stems)
        XCTAssertEqual(report.rowsWithoutWav.count, 1)
        let row = report.rowsWithoutWav.first!
        XCTAssertEqual(row.stem, "20260308-090000")
        XCTAssertEqual(row.sidecars.map { $0.lastPathComponent },
                       ["20260308-090000.meta.json", "20260308-090000.summary.json"])
        XCTAssertTrue(report.wavsWithoutRow.isEmpty)
    }

    func test_stem_with_neither_wav_nor_sidecars_is_ignored() {
        let stems: [String: [URL]] = [
            "20260308-090000": [],
        ]
        let report = OrphanScan.detect(stems: stems)
        XCTAssertTrue(report.isEmpty)
    }

    func test_results_are_sorted_for_deterministic_reporting() {
        let stems: [String: [URL]] = [
            "20260308-090000": [u("20260308-090000.meta.json")],
            "20260301-101500": [u("20260301-101500.summary.json")],
        ]
        let report = OrphanScan.detect(stems: stems)
        XCTAssertEqual(report.rowsWithoutWav.map { $0.stem },
                       ["20260301-101500", "20260308-090000"])
    }

    // MARK: - scan (filesystem-backed)

    func test_scan_against_real_directory_surfaces_seeded_orphans() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "OrphanScanTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data().write(to: root.appendingPathComponent("20260301-101500.wav"))
        try Data().write(to: root.appendingPathComponent("20260301-101500.meta.json"))
        try Data().write(to: root.appendingPathComponent("20260308-090000.meta.json"))
        try Data().write(to: root.appendingPathComponent("manual-notes.wav"))

        let report = OrphanScan.scan(directory: root)
        XCTAssertEqual(report.wavsWithoutRow.map { $0.stem }, ["manual-notes"])
        XCTAssertEqual(report.rowsWithoutWav.map { $0.stem }, ["20260308-090000"])
    }

    func test_scan_against_missing_directory_is_empty() {
        let missing = URL(fileURLWithPath: "/tmp/orphan-scan-this-does-not-exist-\(UUID())")
        XCTAssertTrue(OrphanScan.scan(directory: missing).isEmpty)
    }

    // MARK: - Doctor probe message

    func test_doctor_message_lists_counts_for_both_kinds() {
        let report = OrphanScan.Report(
            wavsWithoutRow: [
                .init(stem: "manual-notes", url: u("manual-notes.wav")),
            ],
            rowsWithoutWav: [
                .init(stem: "20260308-090000",
                      sidecars: [u("20260308-090000.meta.json")]),
            ]
        )
        let msg = DoctorCommand.formatOrphanMessage(report, dir: dir)
        XCTAssertTrue(msg.contains("1 wav(s) the library can't index"))
        XCTAssertTrue(msg.contains("manual-notes"))
        XCTAssertTrue(msg.contains("1 stem(s) with sidecars but no wav"))
        XCTAssertTrue(msg.contains("20260308-090000"))
        XCTAssertTrue(msg.contains(dir.path))
    }

    func test_doctor_message_truncates_long_lists_with_ellipsis() {
        let many = (1...8).map { i in
            OrphanScan.WavWithoutRow(
                stem: "weird-\(i)",
                url: u("weird-\(i).wav")
            )
        }
        let report = OrphanScan.Report(wavsWithoutRow: many, rowsWithoutWav: [])
        let msg = DoctorCommand.formatOrphanMessage(report, dir: dir)
        XCTAssertTrue(msg.contains("8 wav(s)"))
        XCTAssertTrue(msg.contains("…"), "should truncate when count > 5")
    }
}
