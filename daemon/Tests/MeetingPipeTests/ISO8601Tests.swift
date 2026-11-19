import XCTest
@testable import MeetingPipe

/// ARCH17: one ISO-8601 owner and one stem formatter.
final class ISO8601Tests: XCTestCase {

    /// 2026-07-11T14:32:05Z.
    private let base: TimeInterval = 1_783_780_325

    private func assertParses(_ s: String, to expected: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        guard let date = ISO8601.parse(s) else {
            return XCTFail("\(s) did not parse", file: file, line: line)
        }
        XCTAssertEqual(date.timeIntervalSince1970, expected, accuracy: 0.0005, s, file: file, line: line)
    }

    func test_parse_accepts_whole_seconds_and_every_fraction_length_with_z_or_offset() {
        assertParses("2026-07-11T14:32:05Z", to: base)
        assertParses("2026-07-11T14:32:05+00:00", to: base)
        assertParses("2026-07-11T14:32:05.123Z", to: base + 0.123)
        assertParses("2026-07-11T14:32:05.123456+00:00", to: base + 0.123)
        assertParses("2026-07-11T14:32:05.123456Z", to: base + 0.123)
        assertParses("2026-07-11T14:32:05.1+00:00", to: base + 0.1)
        assertParses("2026-07-11T16:32:05+02:00", to: base)
    }

    func test_parse_refuses_a_naive_timestamp_and_garbage() {
        XCTAssertNil(ISO8601.parse("2026-07-11T14:32:05.123456"))
        XCTAssertNil(ISO8601.parse("2026-07-11T14:32:05"))
        XCTAssertNil(ISO8601.parse("yesterday"))
        XCTAssertNil(ISO8601.parse(""))
    }

    func test_format_then_parse_round_trips_in_both_modes() {
        let d = Date(timeIntervalSince1970: base + 0.25)
        XCTAssertEqual(ISO8601.parse(ISO8601.format(d))?.timeIntervalSince1970, base)
        XCTAssertEqual(ISO8601.parse(ISO8601.format(d, fractional: true))!.timeIntervalSince1970, base + 0.25, accuracy: 0.0005)
    }

    /// Byte-identical to what `CorrectionStore` (`ISO8601DateFormatter()`, plain) and `Logger`
    /// (fractional) wrote before ARCH17, so no reader of an existing file sees a new shape.
    func test_format_matches_the_writers_it_replaced() {
        let d = Date(timeIntervalSince1970: base + 0.25)
        XCTAssertEqual(ISO8601.format(d), "2026-07-11T14:32:05Z")
        XCTAssertEqual(ISO8601.format(d, fractional: true), "2026-07-11T14:32:05.250Z")
        XCTAssertEqual(ISO8601.format(d), ISO8601DateFormatter().string(from: d))
        let logger = ISO8601DateFormatter()
        logger.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(ISO8601.format(d, fractional: true), logger.string(from: d))
    }

    func test_a_python_microsecond_run_timestamp_still_drives_the_names_changed_cue() {
        XCTAssertTrue(MeetingStore.namesChangedSinceSummary(
            overlayModified: Date(timeIntervalSince1970: 2_000),
            runTimestamp: "1970-01-01T00:16:39.123456+00:00"
        ))
        XCTAssertFalse(MeetingStore.namesChangedSinceSummary(
            overlayModified: Date(timeIntervalSince1970: 500),
            runTimestamp: "1970-01-01T00:16:39.123456+00:00"
        ))
    }

    func test_diagnostics_parses_a_python_microsecond_event_ts() throws {
        let obj: [String: Any] = ["ts": "2026-07-11T14:32:05.123456+00:00", "category": "pipeline", "action": "x"]
        let raw = String(data: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), encoding: .utf8)!
        let ev = DiagnosticsLog.parseLine(raw, id: 0)
        XCTAssertEqual(ev?.date?.timeIntervalSince1970 ?? 0, base + 0.123, accuracy: 0.0005)
    }

    // MARK: - Stem

    func test_the_stem_round_trips_through_its_reader_as_fifteen_ascii_characters() {
        let d = Date(timeIntervalSince1970: base + 0.75)
        let stem = MeetingFormatters.stemString(from: d)
        XCTAssertEqual(stem.count, 15)
        XCTAssertTrue(stem.allSatisfy { $0.isASCII })
        XCTAssertEqual(MeetingStore.parseStem(stem), Date(timeIntervalSince1970: base))
        XCTAssertEqual(MeetingFormatters.stem.locale.identifier, "en_US_POSIX")
        XCTAssertEqual(MeetingFormatters.stem.calendar.identifier, .gregorian)
    }

    // MARK: - Source fences

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func test_the_recorder_builds_no_formatter_of_its_own() throws {
        let src = try String(contentsOf: repoRoot().appendingPathComponent("daemon/Sources/MeetingPipe/MeetingRecorder.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("DateFormatter()"), "MeetingRecorder names stems through MeetingFormatters.stemString (ARCH17)")
        XCTAssertTrue(src.contains("MeetingFormatters.stemString(from:"))
    }

    func test_iso8601_formatters_are_built_only_in_the_owner() throws {
        let root = repoRoot()
        let dir = root.appendingPathComponent("daemon/Sources/MeetingPipe")
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return XCTFail("cannot walk daemon/Sources/MeetingPipe")
        }
        var walked = 0
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            walked += 1
            let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard path != "daemon/Sources/MeetingPipe/Util/ISO8601.swift" else { continue }
            for (i, line) in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && line.contains("ISO8601DateFormatter(") {
                offenders.append("\(path):\(i + 1)")
            }
        }
        XCTAssertGreaterThan(walked, 100, "the walk found almost nothing; re-point this fence")
        XCTAssertEqual(offenders, [], "build ISO-8601 timestamps through ISO8601.parse/format (ARCH17)")
    }
}
