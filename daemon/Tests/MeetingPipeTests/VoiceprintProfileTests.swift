import XCTest
@testable import MeetingPipe

final class VoiceprintProfileTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vp-\(UUID().uuidString).json")
    }

    func test_absent_file_reads_zero() {
        XCTAssertEqual(VoiceprintProfile.meetingsLearned(at: tempURL()), 0)
    }

    func test_reads_meeting_count_from_valid_profile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"schema_version":1,"embedding":[0.1,0.2,0.3],"meetings":4}"#
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(VoiceprintProfile.meetingsLearned(at: url), 4)
    }

    func test_malformed_or_unenrolled_reads_zero() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(VoiceprintProfile.meetingsLearned(at: url), 0)
        try #"{"embedding":[],"meetings":3}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(VoiceprintProfile.meetingsLearned(at: url), 0)  // empty embedding
        try #"{"embedding":[0.1],"meetings":0}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(VoiceprintProfile.meetingsLearned(at: url), 0)  // count 0
    }

    func test_reset_removes_file() throws {
        let url = tempURL()
        try #"{"embedding":[0.1],"meetings":2}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(VoiceprintProfile.meetingsLearned(at: url), 2)
        VoiceprintProfile.reset(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(VoiceprintProfile.meetingsLearned(at: url), 0)
    }

    /// STOR7 (SW-18): a failed removal of the biometric file is a failure, and the count stays.
    func test_a_reset_that_cannot_remove_the_file_fails_and_keeps_the_count() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("voiceprint.json")
        try #"{"embedding":[0.1],"meetings":2}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(dir.path, 0o500), 0)
        defer { chmod(dir.path, 0o700); try? FileManager.default.removeItem(at: dir) }

        guard case .failure = VoiceprintProfile.reset(at: url) else { return XCTFail("expected a failure") }
        XCTAssertEqual(VoiceprintProfile.meetingsLearned(at: url), 2)
    }

    func test_a_reset_with_nothing_to_remove_succeeds() {
        guard case .success = VoiceprintProfile.reset(at: tempURL()) else { return XCTFail("nothing to forget is success") }
    }
}
