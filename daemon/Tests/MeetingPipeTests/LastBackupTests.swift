import XCTest
@testable import MeetingPipe

/// STOR3: the read-only `.last-backup.json` reader behind the Preferences ▸ Storage
/// age line. Pinned so the Python writer (`mp backup`) and this reader stay in step on
/// the marker's shape and the ISO-8601 timestamp Python emits.
final class LastBackupTests: XCTestCase {

    private func writeMarker(_ json: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("last-backup-\(UUID().uuidString).json")
        try? Data(json.utf8).write(to: url)
        return url
    }

    func test_reads_a_valid_marker_with_microsecond_fraction() {
        // The exact shape `datetime.now(timezone.utc).isoformat()` produces.
        let url = writeMarker(#"{"at":"2026-07-11T14:32:05.123456+00:00","archive":"/tmp/b.tar.gz","bytes":123,"audio_included":true}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let info = LastBackup.read(at: url)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.audioIncluded, true)
    }

    func test_missing_file_reads_nil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).json")
        XCTAssertNil(LastBackup.read(at: url))
        XCTAssertNil(LastBackup.ageDescription(at: url))
    }

    func test_malformed_json_reads_nil() {
        let url = writeMarker("not json at all")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(LastBackup.read(at: url))
    }

    func test_missing_at_field_reads_nil() {
        let url = writeMarker(#"{"archive":"/tmp/b.tar.gz","audio_included":true}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(LastBackup.read(at: url))
    }

    func test_age_description_counts_days() {
        let url = writeMarker(#"{"at":"2026-07-08T09:00:00+00:00","archive":"/tmp/b.tar.gz","audio_included":true}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let now = ISO8601DateFormatter().date(from: "2026-07-11T09:00:00Z")!
        XCTAssertEqual(LastBackup.ageDescription(now: now, at: url), "Last backup 3 days ago")
    }

    func test_age_description_today_notes_missing_audio() {
        let url = writeMarker(#"{"at":"2026-07-11T08:00:00+00:00","archive":"/tmp/b.tar.gz","audio_included":false}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let now = ISO8601DateFormatter().date(from: "2026-07-11T20:00:00Z")!
        XCTAssertEqual(LastBackup.ageDescription(now: now, at: url), "Last backup today, without recordings")
    }

    func test_age_description_singular_day() {
        let url = writeMarker(#"{"at":"2026-07-10T09:00:00+00:00","archive":"/tmp/b.tar.gz","audio_included":true}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let now = ISO8601DateFormatter().date(from: "2026-07-11T09:00:00Z")!
        XCTAssertEqual(LastBackup.ageDescription(now: now, at: url), "Last backup 1 day ago")
    }
}
