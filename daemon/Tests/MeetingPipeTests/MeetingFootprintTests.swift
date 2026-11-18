import XCTest
@testable import MeetingPipe
import MeetingPipeTestSupport

/// STOR7: what a delete locates (the sink sidecars are read before they go), what it trashes, and
/// what it reports. Every file lives under one temp root; the trash is a folder there, never the
/// real one.
final class MeetingFootprintTests: XCTestCase {
    private var root: URL!
    private var lib: URL { root.appendingPathComponent("raw") }
    private var published: URL { root.appendingPathComponent("published") }
    private var vault: URL { root.appendingPathComponent("vault") }
    private var corrections: URL { root.appendingPathComponent("corrections") }
    private var originals: URL { root.appendingPathComponent("originals") }
    private var trashDir: URL { root.appendingPathComponent("trash") }
    private let stem = "20261118-101500"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stor7-\(UUID().uuidString)")
        for d in [lib, published, vault.appendingPathComponent("Meetings"), vault.appendingPathComponent("_attachments"), corrections, originals, trashDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ url: URL, _ text: String = "x") throws -> URL {
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeJSON(_ name: String, _ obj: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: obj).write(to: lib.appendingPathComponent(name))
    }

    private var listing: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil)) ?? []
    }

    private func locate(roots: [URL]? = nil) -> MeetingFootprint {
        MeetingFootprint.locate(stem: stem, listing: listing, correctionsDir: corrections,
                                publishedRoots: roots ?? [published, vault])
    }

    /// A published meeting: library files, a filesystem copy, an Obsidian note and attachment.
    private func seedPublished() throws {
        try write(lib.appendingPathComponent("\(stem).wav"))
        try write(lib.appendingPathComponent("\(stem).summary.json"))
        let summary = try write(published.appendingPathComponent("\(stem).summary.md"))
        let actions = try write(published.appendingPathComponent("\(stem).actions.json"))
        try writeJSON("\(stem).filesystem.json", ["summary_path": summary.path, "actions_path": actions.path])
        let note = try write(vault.appendingPathComponent("Meetings/\(stem) Budget review.md"))
        try write(vault.appendingPathComponent("_attachments/\(stem).wav"))
        try writeJSON("\(stem).obsidian.json", ["note_path": note.path, "vault": vault.path, "attachment_rel": "_attachments/\(stem).wav"])
    }

    // MARK: - locate

    func test_a_filesystem_sidecar_locates_both_published_paths() throws {
        try seedPublished()
        let names = Set(locate().publishedCopies.map(\.lastPathComponent))
        XCTAssertTrue(names.isSuperset(of: ["\(stem).summary.md", "\(stem).actions.json"]))
    }

    func test_an_obsidian_sidecar_locates_its_note_and_attachment() throws {
        try seedPublished()
        let names = Set(locate().publishedCopies.map(\.lastPathComponent))
        XCTAssertTrue(names.contains("\(stem) Budget review.md"))
        XCTAssertTrue(names.contains("\(stem).wav"))
        XCTAssertEqual(locate().publishedCopies.count, 4)
    }

    func test_a_corrections_file_is_found() throws {
        try write(lib.appendingPathComponent("\(stem).wav"))
        try write(corrections.appendingPathComponent("\(stem).json"))
        XCTAssertEqual(locate().corrections?.lastPathComponent, "\(stem).json")
    }

    func test_no_sidecar_yields_no_published_paths_and_no_corrections() throws {
        try write(lib.appendingPathComponent("\(stem).wav"))
        let footprint = locate()
        XCTAssertEqual(footprint.rawFiles.count, 1)
        XCTAssertTrue(footprint.publishedCopies.isEmpty)
        XCTAssertNil(footprint.corrections)
        XCTAssertTrue(footprint.kept.isEmpty)
    }

    /// The one place a delete could reach outside the library: a path read from a sidecar is
    /// trashed only when it is under today's sink folder and named for this stem.
    func test_a_copy_outside_the_sink_folders_or_misnamed_is_kept_not_trashed() throws {
        try write(lib.appendingPathComponent("\(stem).wav"))
        let elsewhere = try write(root.appendingPathComponent("\(stem).summary.md"))
        let misnamed = try write(published.appendingPathComponent("someone-else.actions.json"))
        try writeJSON("\(stem).filesystem.json", ["summary_path": elsewhere.path, "actions_path": misnamed.path])
        let footprint = locate()
        XCTAssertTrue(footprint.publishedCopies.isEmpty)
        XCTAssertEqual(footprint.kept, [.unverifiedCopy(.filesystem), .unverifiedCopy(.filesystem)])
    }

    func test_a_dotdot_path_cannot_climb_out_of_a_root() {
        let sneaky = URL(fileURLWithPath: published.path + "/../\(stem).summary.md")
        XCTAssertFalse(MeetingFootprint.isUnder(sneaky, roots: [published]))
        XCTAssertFalse(MeetingFootprint.isUnder(published, roots: [published]))
        XCTAssertFalse(MeetingFootprint.isUnder(URL(fileURLWithPath: "/etc/hosts"), roots: [URL(fileURLWithPath: "/")]))
    }

    /// A pre-PIPE31 note named by title alone cannot be proved this meeting's.
    func test_a_title_only_obsidian_note_is_kept() throws {
        try write(lib.appendingPathComponent("\(stem).wav"))
        let note = try write(vault.appendingPathComponent("Meetings/Budget review.md"))
        try writeJSON("\(stem).obsidian.json", ["note_path": note.path, "vault": vault.path])
        let footprint = locate()
        XCTAssertTrue(footprint.publishedCopies.isEmpty)
        XCTAssertEqual(footprint.kept, [.unverifiedCopy(.obsidian)])
    }

    func test_an_unreadable_sidecar_is_could_not_locate_not_no_copies() throws {
        try write(lib.appendingPathComponent("\(stem).wav"))
        try write(lib.appendingPathComponent("\(stem).filesystem.json"), "{ not json")
        XCTAssertEqual(locate().kept, [.unreadableSidecar(.filesystem)])
    }

    func test_notion_and_lan_sidecars_are_named_as_staying() throws {
        try write(lib.appendingPathComponent("\(stem).wav"))
        try writeJSON("\(stem).notion.json", ["page_id": "abc"])
        try writeJSON("\(stem).lan.json", ["summary_path": "/Volumes/meetings/x.md"])
        let footprint = locate()
        XCTAssertEqual(Set(footprint.kept), [.notionPage, .networkCopy])
        XCTAssertTrue(footprint.confirmText.contains("the Notion page and the copy on your network share"))
    }

    func test_the_merge_scope_locates_raw_files_only() throws {
        try seedPublished()
        try write(corrections.appendingPathComponent("\(stem).json"))
        let footprint = MeetingFootprint.locate(stem: stem, listing: listing, correctionsDir: corrections,
                                                publishedRoots: [published, vault], derived: false)
        XCTAssertFalse(footprint.rawFiles.isEmpty)
        XCTAssertTrue(footprint.publishedCopies.isEmpty)
        XCTAssertNil(footprint.corrections)
    }

    // MARK: - the confirm

    func test_the_confirm_names_what_goes_and_what_stays() throws {
        try seedPublished()
        try write(corrections.appendingPathComponent("\(stem).json"))
        let text = locate().confirmText
        XCTAssertFalse(text.contains("Every file"))
        XCTAssertTrue(text.contains("the 4 published local copies"))
        XCTAssertTrue(text.contains("your grading of its summary"))
        XCTAssertTrue(text.contains("Voice samples learned from it, digests that quote it, and backups that contain it stay."))
        XCTAssertTrue(text.hasSuffix(LibraryDialogs.trashRecoveryNote))
    }

    func test_the_batch_confirm_sums_the_footprints_and_names_what_stays() {
        var a = MeetingFootprint(); a.publishedCopies = [URL(fileURLWithPath: "/p/a.summary.md")]
        var b = MeetingFootprint(); b.kept = [.notionPage]; b.corrections = URL(fileURLWithPath: "/c/b.json")
        let text = MeetingFootprint.batchConfirmText([a, b])
        XCTAssertTrue(text.contains("with 1 published local copy and their summary gradings"))
        XCTAssertTrue(text.contains("the Notion page"))
        XCTAssertTrue(text.contains("Voice samples learned from them, digests that quote them, and backups that contain them stay."))
    }

    // MARK: - softDeleteMeeting

    private func service(trash: @escaping (URL) throws -> Void, prune: @escaping ([String]) -> Void = { _ in }) -> MeetingLibraryService {
        MeetingLibraryService(
            outputDir: { [unowned self] in self.lib },
            launcher: FakePipelineDriver(),
            notifyError: { _ in },
            enqueue: { _, _, _ in },
            originalsDir: { [unowned self] in self.originals },
            correctionsDir: { [unowned self] in self.corrections },
            publishedRoots: { [unowned self] in [self.published, self.vault] },
            trash: trash,
            pruneSearchIndex: prune
        )
    }

    private func moveToTrash(_ url: URL) throws {
        try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
    }

    private func lastRow(_ action: String) throws -> [String: Any]? {
        let text = try String(contentsOf: root.appendingPathComponent("logs/events.jsonl"), encoding: .utf8)
        return text.split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .last { $0["action"] as? String == action }
    }

    func test_delete_trashes_corrections_and_local_published_copies_and_counts_them() throws {
        try seedPublished()
        try write(corrections.appendingPathComponent("\(stem).json"))
        let svc = service(trash: moveToTrash)
        guard case .success = svc.softDeleteMeeting(stem: stem) else { return XCTFail("expected success") }

        XCTAssertFalse(FileManager.default.fileExists(atPath: corrections.appendingPathComponent("\(stem).json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: published.appendingPathComponent("\(stem).summary.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.appendingPathComponent("Meetings/\(stem) Budget review.md").path))
        let row = try XCTUnwrap(lastRow("meeting_deleted"))
        XCTAssertEqual(row["files_count"] as? Int, 4)
        XCTAssertEqual(row["files_trashed"] as? Int, 9)
        XCTAssertEqual(row["files_failed"] as? Int, 0)
        XCTAssertEqual(row["corrections_trashed"] as? Bool, true)
        XCTAssertEqual(row["published_trashed"] as? Int, 4)
    }

    func test_a_sidecar_pointing_at_a_vanished_copy_does_not_fail_the_delete() throws {
        try write(lib.appendingPathComponent("\(stem).wav"))
        try writeJSON("\(stem).filesystem.json", ["summary_path": published.appendingPathComponent("\(stem).summary.md").path])
        guard case .success = service(trash: moveToTrash).softDeleteMeeting(stem: stem) else {
            return XCTFail("a copy already gone is not a failure")
        }
        XCTAssertEqual(try lastRow("meeting_deleted")?["published_trashed"] as? Int, 0)
    }

    /// SW-18: the row used to report every matched file as gone after a loop that swallowed failures.
    func test_one_failed_trash_is_counted_and_returned() throws {
        try write(lib.appendingPathComponent("\(stem).wav"))
        try write(lib.appendingPathComponent("\(stem).summary.json"))
        let svc = service(trash: { [unowned self] url in
            if url.lastPathComponent.hasSuffix(".wav") { throw CocoaError(.fileWriteNoPermission) }
            try self.moveToTrash(url)
        })
        guard case .failure = svc.softDeleteMeeting(stem: stem) else { return XCTFail("expected the failure back") }
        let row = try XCTUnwrap(lastRow("meeting_deleted"))
        XCTAssertEqual(row["files_count"] as? Int, 2)
        XCTAssertEqual(row["files_trashed"] as? Int, 1)
        XCTAssertEqual(row["files_failed"] as? Int, 1)
    }

    /// A published note's name is its title slug (SEC38): a failed trash logs its kind, never the name.
    func test_a_failed_published_trash_does_not_log_the_note_name() throws {
        try seedPublished()
        let svc = service(trash: { [unowned self] url in
            if url.lastPathComponent.contains("Budget review") { throw CocoaError(.fileWriteNoPermission) }
            try self.moveToTrash(url)
        })
        _ = svc.softDeleteMeeting(stem: stem)
        let text = try String(contentsOf: root.appendingPathComponent("logs/events.jsonl"), encoding: .utf8)
        XCTAssertFalse(text.contains("Budget review"))
        XCTAssertEqual(try lastRow("trash_failed")?["kind"] as? String, "published")
    }

    func test_a_batch_of_deletes_in_one_turn_is_one_prune() throws {
        for s in ["a1", "a2", "a3"] { try write(lib.appendingPathComponent("\(s).wav")) }
        var calls: [[String]] = []
        let svc = service(trash: moveToTrash, prune: { calls.append($0) })
        for s in ["a1", "a2", "a3"] { _ = svc.softDeleteMeeting(stem: s) }
        XCTAssertTrue(calls.isEmpty, "the prune waits for the turn to end")
        let done = expectation(description: "main turn")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(calls, [["a1", "a2", "a3"]])
    }

    func test_the_merge_cleanup_scope_leaves_published_copies_and_prunes_nothing() throws {
        try seedPublished()
        var calls: [[String]] = []
        let svc = service(trash: moveToTrash, prune: { calls.append($0) })
        guard case .success = svc.softDeleteMeeting(stem: stem, derived: false) else { return XCTFail() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: published.appendingPathComponent("\(stem).summary.md").path))
        let done = expectation(description: "main turn")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(calls.isEmpty)
    }

    /// A filesystem sink pointed at the library folder: its files are library entries already, so
    /// they are trashed once, and the delete does not fail on a second move of the same file.
    func test_a_sink_folder_that_is_the_library_is_not_trashed_twice() throws {
        try write(lib.appendingPathComponent("\(stem).wav"))
        let summary = try write(lib.appendingPathComponent("\(stem).summary.md"))
        try writeJSON("\(stem).filesystem.json", ["summary_path": summary.path])
        let footprint = MeetingFootprint.locate(stem: stem, listing: listing, correctionsDir: nil, publishedRoots: [lib])
        XCTAssertTrue(footprint.publishedCopies.isEmpty)
        let svc = MeetingLibraryService(
            outputDir: { [unowned self] in self.lib }, launcher: FakePipelineDriver(),
            notifyError: { _ in }, enqueue: { _, _, _ in },
            originalsDir: { [unowned self] in self.originals },
            publishedRoots: { [unowned self] in [self.lib] }, trash: moveToTrash
        )
        guard case .success = svc.softDeleteMeeting(stem: stem) else { return XCTFail("one move per file") }
    }

    /// The pipeline records resolved paths; a root written through a symlink still matches.
    func test_a_root_reached_through_a_symlink_still_matches() throws {
        let link = root.appendingPathComponent("published-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: published)
        let copy = published.resolvingSymlinksInPath().appendingPathComponent("\(stem).summary.md")
        XCTAssertTrue(MeetingFootprint.isUnder(copy, roots: [link]))
    }

    func test_local_publish_roots_skip_empty_and_slash() {
        let roots = LocalPublishRoots.roots(filesystemOutputDir: "~/Documents/Meetings/published", obsidianVaultPath: "")
        XCTAssertEqual(roots.count, 1)
        XCTAssertTrue(roots[0].path.hasSuffix("Documents/Meetings/published"))
        XCTAssertTrue(LocalPublishRoots.roots(filesystemOutputDir: "/", obsidianVaultPath: "").isEmpty)
    }

    /// The seams default to "look nowhere" so a test cannot reach the owner's real data; this pins
    /// that the app wires them (the "ships green and never runs" rule).
    func test_the_coordinator_wires_the_delete_seams() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe/Coordinator.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("correctionsDir: { try? CorrectionStore.directory() }"))
        XCTAssertTrue(src.contains("publishedRoots: {"))
        XCTAssertTrue(src.contains("pruneSearchIndex: { [weak self] stems in self?.launcher.pruneSearchIndex(stems: stems) }"))
    }
}
