import XCTest
@testable import MeetingPipe

/// SEC12's assisted move. The refusals matter more than the move: a library moved
/// out from under a live recording is a lost meeting.
final class LibraryMoverTests: XCTestCase {

    private var home: URL!
    private var library: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-mover-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        library = home.appendingPathComponent("Meetings/raw", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ relativePath: String, to root: URL? = nil, bytes: Int = 8) throws {
        let url = (root ?? library).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: bytes).write(to: url)
    }

    private func destination() throws -> URL {
        let url = home.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A settled meeting: a recording with a terminal sidecar.
    private func writeSettledMeeting(stem: String = "20260101-120000") throws {
        try write("\(stem).wav", bytes: 100)
        try write("\(stem).summary.json", bytes: 2)
    }

    // MARK: inFlightReason

    func test_a_live_recording_blocks_the_move() throws {
        try write("20260101-120000.mic.wav")
        XCTAssertEqual(
            LibraryMover.inFlightReason(in: library), "a recording is in progress"
        )
    }

    func test_a_processing_meeting_blocks_the_move() throws {
        // A recording, no terminal sidecar, inside the staleness window.
        let stem = MeetingFormatters.stem.string(from: Date().addingTimeInterval(-60))
        try write("\(stem).wav")
        XCTAssertEqual(
            LibraryMover.inFlightReason(in: library), "a meeting is still being processed"
        )
    }

    func test_a_stale_orphan_does_not_block_the_move() throws {
        // Past the staleness window it reads as `.failed`, not in-flight. It would
        // block the move forever otherwise.
        let stem = MeetingFormatters.stem.string(from: Date().addingTimeInterval(-4 * 60 * 60))
        try write("\(stem).wav")
        // Since STOR16 the window runs from the newest write, so a real orphan is old on disk too.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-4 * 60 * 60)],
            ofItemAtPath: library.appendingPathComponent("\(stem).wav").path
        )
        XCTAssertNil(LibraryMover.inFlightReason(in: library))
    }

    /// STOR16: every `.mic.wav` is tested, not the first one listed. Directory order is
    /// unspecified, so the stale orphan is made to sort first by name and by age.
    func test_a_stale_mic_listed_first_does_not_hide_a_live_capture() throws {
        let stale = library.appendingPathComponent("20200101-000000.mic.wav")
        try Data([0]).write(to: stale)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: stale.path
        )
        try write("20260101-120000.mic.wav")
        let entries = try FileManager.default.contentsOfDirectory(
            at: library, includingPropertiesForKeys: [.contentModificationDateKey]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(entries.first?.lastPathComponent, "20200101-000000.mic.wav")
        XCTAssertEqual(MeetingStore.freshCaptureIntermediate(in: entries)?.lastPathComponent, "20260101-120000.mic.wav")
        XCTAssertEqual(LibraryMover.inFlightReason(in: library), "a recording is in progress")
    }

    /// STOR16: a 2.5 h meeting that stopped a minute ago is mid-pipeline although it started
    /// outside the 2 h window.
    func test_a_long_meeting_just_stopped_is_still_processing() throws {
        let stem = MeetingFormatters.stem.string(from: Date().addingTimeInterval(-2.5 * 60 * 60))
        try write("\(stem).wav")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60)],
            ofItemAtPath: library.appendingPathComponent("\(stem).wav").path
        )
        XCTAssertEqual(LibraryMover.inFlightReason(in: library), "a meeting is still being processed")
    }

    func test_a_settled_library_is_not_in_flight() throws {
        try writeSettledMeeting()
        XCTAssertNil(LibraryMover.inFlightReason(in: library))
    }

    func test_a_stale_mic_intermediate_does_not_block_the_move() throws {
        let url = library.appendingPathComponent("20260101-120000.mic.wav")
        try Data([0]).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: url.path
        )
        XCTAssertNil(LibraryMover.inFlightReason(in: library))
    }

    // MARK: plan

    func test_plan_refuses_while_a_recording_is_in_progress() throws {
        try write("20260101-120000.mic.wav")
        XCTAssertThrowsError(
            try LibraryMover.plan(source: library, destinationParent: try destination(), home: home)
        ) { error in
            XCTAssertEqual(error as? LibraryMover.MoveError, .busy("a recording is in progress"))
        }
    }

    func test_plan_refuses_a_destination_that_is_also_synced() throws {
        try writeSettledMeeting()
        let synced = home.appendingPathComponent("Library/CloudStorage/Dropbox-Personal", isDirectory: true)
        try FileManager.default.createDirectory(at: synced, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try LibraryMover.plan(source: library, destinationParent: synced, home: home)
        ) { error in
            XCTAssertEqual(error as? LibraryMover.MoveError, .destinationIsSynced("Dropbox"))
        }
    }

    func test_plan_refuses_an_occupied_destination() throws {
        try writeSettledMeeting()
        let dest = try destination()
        try FileManager.default.createDirectory(
            at: dest.appendingPathComponent("raw"), withIntermediateDirectories: true
        )
        XCTAssertThrowsError(
            try LibraryMover.plan(source: library, destinationParent: dest, home: home)
        ) { error in
            XCTAssertEqual(error as? LibraryMover.MoveError, .destinationOccupied("raw"))
        }
    }

    func test_plan_counts_files_and_bytes_including_the_digests_sibling() throws {
        try writeSettledMeeting()                              // 100 + 2 bytes, 2 files
        let digests = home.appendingPathComponent("Meetings/digests", isDirectory: true)
        try write("2026-W01.md", to: digests, bytes: 50)       // 1 file

        let plan = try LibraryMover.plan(
            source: library, destinationParent: try destination(), home: home
        )
        XCTAssertEqual(plan.fileCount, 3)
        XCTAssertEqual(plan.bytes, 152)
        XCTAssertNotNil(plan.digestsSource)
        XCTAssertEqual(plan.destination.lastPathComponent, "raw")
    }

    func test_plan_omits_digests_when_there_are_none() throws {
        try writeSettledMeeting()
        let plan = try LibraryMover.plan(
            source: library, destinationParent: try destination(), home: home
        )
        XCTAssertNil(plan.digestsSource)
    }

    // MARK: execute

    func test_execute_moves_the_recordings_and_the_digests() throws {
        try writeSettledMeeting()
        let digests = home.appendingPathComponent("Meetings/digests", isDirectory: true)
        try write("2026-W01.md", to: digests)

        let dest = try destination()
        let plan = try LibraryMover.plan(source: library, destinationParent: dest, home: home)
        try LibraryMover.execute(plan)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("raw/20260101-120000.wav").path))
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("raw/20260101-120000.summary.json").path))
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("digests/2026-W01.md").path))
        XCTAssertFalse(fm.fileExists(atPath: library.path), "the source is gone, not copied")
    }

    func test_the_moved_library_is_no_longer_reported_as_synced() throws {
        // The acceptance criterion: the move yields a working library at a root
        // the detector is happy with.
        try writeSettledMeeting()
        let dest = try destination()
        let plan = try LibraryMover.plan(source: library, destinationParent: dest, home: home)
        try LibraryMover.execute(plan)
        XCTAssertNil(CloudSyncDetector.detect(path: plan.destination, home: home))
    }
}
