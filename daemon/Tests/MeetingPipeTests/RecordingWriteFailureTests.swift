import XCTest
@testable import MeetingPipe

/// REC19 item 3: the stop notification names the disk only when the disk is full.
///
/// REC3's handler said "the disk may be full" on every write-failure force-stop. The failure it
/// was written for (the 4 GiB RIFF cap) does not happen on macOS 27.2, so a message that blames
/// the disk with space to spare sends the owner after the wrong thing.
final class RecordingWriteFailureTests: XCTestCase {

    private typealias W = RecordingWriteFailure

    func test_free_space_under_the_threshold_is_a_full_disk_and_names_it() {
        let d = W.decide(channel: "system", freeBytes: 120_000_000, volumeName: "Macintosh HD")
        XCTAssertEqual(d.cause, .diskFull)
        XCTAssertEqual(d.channel, "system")
        XCTAssertEqual(d.freeBytes, 120_000_000)
        XCTAssertTrue(d.message.contains("Macintosh HD"), d.message)
        XCTAssertTrue(d.message.contains("is full"), d.message)
        XCTAssertTrue(d.message.contains("free"), "the message names the free space: \(d.message)")
    }

    func test_a_full_disk_with_no_readable_name_still_says_disk() {
        let d = W.decide(channel: "mic", freeBytes: 0, volumeName: nil)
        XCTAssertEqual(d.cause, .diskFull)
        XCTAssertTrue(d.message.lowercased().contains("disk"), d.message)
    }

    func test_ample_space_never_mentions_the_disk() {
        let d = W.decide(channel: "system", freeBytes: 50_000_000_000, volumeName: "Macintosh HD")
        XCTAssertEqual(d.cause, .unknown)
        XCTAssertFalse(d.message.lowercased().contains("disk"), d.message)
        XCTAssertFalse(d.message.contains("Macintosh HD"), d.message)
        XCTAssertTrue(d.message.contains("Run doctor"), "points at the in-app doctor: \(d.message)")
    }

    /// Unreadable is not empty: a free space that could not be read must not blame the disk.
    func test_unreadable_free_space_is_unknown() {
        let d = W.decide(channel: "mic", freeBytes: nil, volumeName: nil)
        XCTAssertEqual(d.cause, .unknown)
        XCTAssertNil(d.freeBytes)
        XCTAssertFalse(d.message.lowercased().contains("disk"), d.message)
    }

    func test_the_threshold_boundary() {
        let t = W.diskFullThresholdBytes
        XCTAssertEqual(W.decide(channel: "mic", freeBytes: t - 1, volumeName: nil).cause, .diskFull)
        XCTAssertEqual(W.decide(channel: "mic", freeBytes: t, volumeName: nil).cause, .unknown)
    }

    /// The `cause` attribute on `recorder` / `recording_error`, as CONVENTIONS documents it.
    func test_cause_raw_values_are_the_event_attribute() {
        XCTAssertEqual(W.Cause.diskFull.rawValue, "disk_full")
        XCTAssertEqual(W.Cause.unknown.rawValue, "unknown")
    }

    /// Owner's choice (2026-11-12): the smaller of the two readings, so purgeable space counted
    /// by the important-usage key cannot hide a full disk; either alone when the other is
    /// unreadable; nil (so `unknown`) when neither reads.
    func test_free_space_is_the_smaller_reading_and_falls_back_to_either() {
        XCTAssertEqual(W.effectiveFreeBytes(importantUsage: 40_000_000_000, available: 200_000_000), 200_000_000)
        XCTAssertEqual(W.effectiveFreeBytes(importantUsage: 300_000_000, available: 900_000_000), 300_000_000)
        XCTAssertEqual(W.effectiveFreeBytes(importantUsage: nil, available: 200_000_000), 200_000_000)
        XCTAssertEqual(W.effectiveFreeBytes(importantUsage: 300_000_000, available: nil), 300_000_000)
        XCTAssertNil(W.effectiveFreeBytes(importantUsage: nil, available: nil))
        // The purgeable case end to end: lots of purgeable space, little actually free.
        let free = W.effectiveFreeBytes(importantUsage: 40_000_000_000, available: 200_000_000)
        XCTAssertEqual(W.decide(channel: "system", freeBytes: free, volumeName: "Macintosh HD").cause, .diskFull)
    }

    func test_free_space_reads_for_a_real_directory() {
        let space = W.freeSpace(at: FileManager.default.temporaryDirectory)
        XCTAssertNotNil(space.freeBytes)
    }
}
