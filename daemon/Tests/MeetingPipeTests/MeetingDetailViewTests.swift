import XCTest
@testable import MeetingPipe

/// The relative-path helper underpins the `obsidian://open` URL the
/// detail header builds. Hard to drive via the SwiftUI view but trivial
/// to cover at the helper level.
final class MeetingDetailViewTests: XCTestCase {

    func test_relativePath_strips_vault_prefix() {
        let vault = URL(fileURLWithPath: "/Users/me/Vault")
        let note = URL(fileURLWithPath: "/Users/me/Vault/Meetings/2026/note.md")
        XCTAssertEqual(
            PublishURLs.relativePath(of: note, from: vault),
            "Meetings/2026/note.md"
        )
    }

    func test_relativePath_returns_nil_for_unrelated_paths() {
        let vault = URL(fileURLWithPath: "/Users/me/Vault")
        let note = URL(fileURLWithPath: "/tmp/other.md")
        XCTAssertNil(PublishURLs.relativePath(of: note, from: vault))
    }

    func test_relativePath_returns_nil_when_file_equals_base() {
        let vault = URL(fileURLWithPath: "/Users/me/Vault")
        XCTAssertNil(PublishURLs.relativePath(of: vault, from: vault))
    }

    func test_relativePath_handles_trailing_slashes() {
        // Both forms standardize to the same path components.
        let vault = URL(fileURLWithPath: "/Users/me/Vault/")
        let note = URL(fileURLWithPath: "/Users/me/Vault/Meetings/n.md")
        XCTAssertEqual(
            PublishURLs.relativePath(of: note, from: vault),
            "Meetings/n.md"
        )
    }

    // MARK: - UX41 names-changed cue

    /// Source of a file in the daemon target. A SwiftUI header is not observable
    /// headlessly, so these two fences pin their claims where they are decided,
    /// the way `SummaryLayoutTests` pins the chrome band.
    private func daemonSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The cue renders in the caption slot beside "Summary edited locally", it
    /// is gated on the derived flag rather than on anything it recomputes
    /// itself, and it carries the affordance that fixes what it reports. A cue
    /// with no fix beside it is the shape UX41 exists to avoid: the owner
    /// already had to know that a rename does not reach the summary.
    func test_the_names_changed_cue_sits_in_the_caption_slot_with_its_fix() throws {
        let header = try daemonSource("Sources/MeetingPipe/MeetingDetailView+Header.swift")
        XCTAssertTrue(
            header.contains("if meeting.namesChangedSinceSummary { namesChangedCaption }"),
            "the cue is driven by the scan-derived flag, not by a second staleness rule in the view"
        )
        guard let start = header.range(of: "var namesChangedCaption: some View"),
              let end = header.range(of: "\n    /// Publish-state line",
                                     range: start.upperBound ..< header.endIndex) else {
            return XCTFail("namesChangedCaption no longer exists under that name; re-point this fence")
        }
        let body = String(header[start.lowerBound ..< end.lowerBound])
        XCTAssertTrue(body.contains("Text(\"Speaker names changed after this summary.\")"),
                      "the cue says what happened, in the caption register")
        XCTAssertTrue(body.contains("reSummarizeItems"),
                      "the fix is one click, through the shared engine list")
        XCTAssertFalse(body.contains("MPColors.fgFaint"),
                       "an actionable line does not ship at ~2.8:1; fgSubtle clears the 4.5 floor")
    }

    /// UX29's honesty has to come free. Both entry points into a re-summarize
    /// render one list, so an NDA meeting's cue cannot offer a cloud path the
    /// clamp forbids while the `...` menu over it disables the same row.
    func test_both_re_summarize_entry_points_render_one_list() throws {
        let header = try daemonSource("Sources/MeetingPipe/MeetingDetailView+Header.swift")
        guard let start = header.range(of: "var reSummarizeItems: some View"),
              let end = header.range(of: "\n    /// Whether the cloud engine",
                                     range: start.upperBound ..< header.endIndex) else {
            return XCTFail("reSummarizeItems no longer exists under that name; re-point this fence")
        }
        let items = String(header[start.lowerBound ..< end.lowerBound])
        XCTAssertTrue(items.contains("state.cloudEnabled"),
                      "the shared list is the one place the clamp is applied")
        XCTAssertTrue(items.contains("state.caption"),
                      "and the one place the reason is shown")
        // Two callers, one list. A second literal engine pair anywhere in the
        // header would be the drift this seam exists to prevent.
        XCTAssertEqual(
            header.components(separatedBy: "SummarizationEngine.anthropic.qualified").count - 1, 2,
            "the cloud engine is named once in the shared list, plus its accessibility label"
        )
    }

    // MARK: - Publish-URL reload (UX53)

    private func makePublishDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ux53-publish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func writeNotionSidecar(stem: String, in dir: URL, pageURL: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["page_url": pageURL])
        try data.write(to: PublishURLs.notionPath(stem: stem, in: dir), options: .atomic)
    }

    /// The guard that keeps the store-revision reload cheap: two reads with
    /// nothing written in between are the same, so a rescan caused by another
    /// meeting's publish never re-parses this meeting's sidecars.
    func test_publish_fingerprint_is_stable_when_no_sidecar_changed() throws {
        let dir = try makePublishDir()
        let stem = "20260501-090000"
        try writeNotionSidecar(stem: stem, in: dir, pageURL: "https://notion.so/a")

        XCTAssertEqual(
            PublishURLs.fingerprint(stem: stem, in: dir),
            PublishURLs.fingerprint(stem: stem, in: dir)
        )
    }

    /// The republish case itself. The sidecar keeps its name and is rewritten in
    /// place, so the fingerprint has to move on content alone or the header keeps
    /// offering the previous run's page. The modification date is set explicitly
    /// rather than raced, since two writes in one test can land inside a single
    /// timestamp.
    func test_publish_fingerprint_moves_when_the_notion_sidecar_is_rewritten() throws {
        let dir = try makePublishDir()
        let stem = "20260501-091500"
        try writeNotionSidecar(stem: stem, in: dir, pageURL: "https://notion.so/first")
        let before = PublishURLs.fingerprint(stem: stem, in: dir)

        try writeNotionSidecar(stem: stem, in: dir, pageURL: "https://notion.so/second")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: PublishURLs.notionPath(stem: stem, in: dir).path
        )

        XCTAssertNotEqual(before, PublishURLs.fingerprint(stem: stem, in: dir))
    }

    /// Why the fingerprint spans both sidecars rather than the Notion one alone:
    /// a workflow that publishes only to Obsidian writes only that file, and a
    /// guard watching the other would skip exactly the reload it exists to allow.
    func test_publish_fingerprint_moves_when_only_the_obsidian_sidecar_is_written() throws {
        let dir = try makePublishDir()
        let stem = "20260501-093000"
        try writeNotionSidecar(stem: stem, in: dir, pageURL: "https://notion.so/a")
        let before = PublishURLs.fingerprint(stem: stem, in: dir)

        let data = try JSONSerialization.data(withJSONObject: [
            "vault": "/Users/me/Vault", "note_path": "/Users/me/Vault/n.md",
        ])
        try data.write(to: PublishURLs.obsidianPath(stem: stem, in: dir), options: .atomic)

        XCTAssertNotEqual(before, PublishURLs.fingerprint(stem: stem, in: dir))
    }

    /// A meeting that has never published fingerprints cleanly rather than
    /// throwing, so the guard is safe on a row with no publish sidecars at all.
    func test_publish_fingerprint_of_an_unpublished_meeting_is_all_absent() throws {
        let dir = try makePublishDir()
        XCTAssertEqual(PublishURLs.fingerprint(stem: "nothing-here", in: dir), [nil, nil])
    }

    /// UX53's acceptance, pinned where the decision is rather than on the
    /// rendering: the header's publish-target reload keys on the store's revision
    /// as well as the stem. Keyed on the stem alone it never re-ran, which is the
    /// UX52 signature surviving one file over: a finished republish refreshed the
    /// publish-state line (the scan rebuilds `Meeting`) and left the Open button
    /// beside it a run behind.
    func test_the_publish_url_reload_is_keyed_on_the_store_revision() throws {
        let detail = try daemonSource("Sources/MeetingPipe/MeetingDetailView.swift")
        XCTAssertTrue(
            detail.contains(".task(id: PublishURLsReloadKey(stem: meeting.stem, revision: store.revision))"),
            "the reload re-runs on a rescan, not only on a stem change"
        )
        XCTAssertTrue(
            detail.contains("@ObservedObject var store: MeetingStore"),
            "the store is observed, not read through the library model, or the bump changes nothing"
        )
        XCTAssertTrue(
            detail.contains("if publishURLsLoadedForStem == stem, loadedPublishFingerprint == fingerprint { return }"),
            "an unrelated rescan is a no-op rather than two JSON parses"
        )
    }
}
