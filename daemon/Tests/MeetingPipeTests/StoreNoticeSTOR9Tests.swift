import XCTest
@testable import MeetingPipe

/// STOR9: what a store refused or quarantined reaches the owner, from Swift and from `mp`.
@MainActor
final class StoreNoticeSTOR9Tests: XCTestCase {
    override func tearDown() {
        StoreNotice.install(nil)
        super.tearDown()
    }

    func test_mp_notices_in_the_spawn_file_are_posted_and_the_file_is_removed() throws {
        var posted: [String] = []
        StoreNotice.install { posted.append($0) }
        let failure = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mp-failure-\(UUID().uuidString).json")
        let notices = PipelineLauncher.noticeURL(for: failure)
        XCTAssertEqual(notices.pathExtension, "notices")
        try "roster.json could not be parsed; it was moved to roster.json.corrupt-20261118-100000 beside it\n\n"
            .write(to: notices, atomically: true, encoding: .utf8)

        PipelineLauncher.deliverNotices(from: notices)
        XCTAssertTrue(StoreFiles.waitUntil { posted.count == 1 })
        XCTAssertTrue(posted.first?.contains("roster.json.corrupt-") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: notices.path))
    }

    func test_a_quarantine_posts_where_the_old_file_went() throws {
        var posted: [String] = []
        StoreNotice.install { posted.append($0) }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mp-stor9-notice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try StoreFiles.garbage.write(to: SpeakerLabelStore.path(stem: "m", in: dir))

        try SpeakerLabelStore.setLabel("THEM-A", to: "Alice", stem: "m", in: dir)
        XCTAssertTrue(StoreFiles.waitUntil { posted.count == 1 })
        XCTAssertTrue(posted.first?.contains("m.speaker_labels.json.corrupt-") == true)
    }

    func test_the_quarantine_name_matches_pythons() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mp-stor9-q-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.json")
        let when = Date(timeIntervalSince1970: 1_795_000_000)   // 2026-11-17 ... UTC
        try Data("a".utf8).write(to: url)
        let first = try StoreGuard.quarantine(url, now: when)
        try Data("b".utf8).write(to: url)
        let second = try StoreGuard.quarantine(url, now: when)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("x.json.corrupt-2026"))
        XCTAssertEqual(second.lastPathComponent, first.lastPathComponent + "-1", "a same-second collision gets -1")
    }

    func test_the_coordinator_installs_the_notice_handler() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe")
        let coordinator = try String(contentsOf: sources.appendingPathComponent("Coordinator.swift"), encoding: .utf8)
        XCTAssertTrue(coordinator.contains("        wireStoreNotices()\n"))
        let wiring = try String(contentsOf: sources.appendingPathComponent("Coordinator+LibraryRoot.swift"), encoding: .utf8)
        XCTAssertTrue(wiring.contains("StoreNotice.install { [weak self] message in self?.notifier.notifyStoreNotice(message) }"))
    }
}
