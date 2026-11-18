import XCTest
@testable import MeetingPipe

/// UX101: nothing assigned `.recording` outside the row's pill, and the scan aged a live stem to
/// `.failed` past `staleProcessingThresholdSec`, so Status: Recording never matched and two hours
/// into a meeting Needs you, Status: Failed and the row's Reprocess treated it as failed. G038,
/// folded in: Kept local hid the lifecycle of a zero-egress row.
final class LiveRecordingStatusUX101Tests: XCTestCase {

    // MARK: - Fixtures

    private let liveStem = "20240501-090000"   // far older than the 2 h window
    private let otherStem = "20240502-090000"

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ux101-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func touch(_ url: URL) throws {
        try Data("x".utf8).write(to: url)
    }

    private func make(_ stem: String, status: Meeting.Status) -> Meeting {
        Meeting(
            stem: stem,
            startedAt: Date(timeIntervalSince1970: 1_714_550_400),
            audioURL: URL(fileURLWithPath: "/tmp/\(stem).wav"),
            recordingsDir: URL(fileURLWithPath: "/tmp"),
            summaryTitle: nil, meetingTitle: nil, sourceBundleID: nil, sourceDisplayName: nil,
            sourceKind: nil, workflowName: nil, workflowColor: nil, durationSec: nil,
            backend: nil, modelId: nil, status: status, failureReason: nil, failureStage: nil,
            searchableText: ""
        )
    }

    /// What the Library derives from: an owned stem past the window, and a finished meeting.
    private func scannedCorpus(owned: Set<String>) throws -> [Meeting] {
        let dir = try tempDir()
        try touch(dir.appendingPathComponent("\(liveStem).wav"))
        let store = MeetingStore(recordingsDir: dir)
        return store.performScan(directory: dir, ownedStems: owned)
    }

    // MARK: - The scan's age rule

    func test_an_owned_stem_past_the_window_is_not_aged_into_failed() throws {
        let rows = try scannedCorpus(owned: [liveStem])
        XCTAssertEqual(rows.first(where: { $0.stem == liveStem })?.status, .processing)
    }

    /// Released with no sidecar, the same stem ages to `.failed` as before: the owned row was
    /// never cached, so the first scan after the release re-decides it.
    func test_the_same_stem_released_ages_to_failed_as_before() throws {
        let dir = try tempDir()
        try touch(dir.appendingPathComponent("\(liveStem).wav"))
        let store = MeetingStore(recordingsDir: dir)
        XCTAssertEqual(store.performScan(directory: dir, ownedStems: [liveStem]).first?.status, .processing)
        XCTAssertEqual(store.performScan(directory: dir, ownedStems: []).first?.status, .failed)
    }

    // MARK: - The overlay every reader sees

    func test_status_recording_returns_the_live_stem_and_nothing_else() {
        let corpus = LiveRecordingOverlay.apply(
            [make(liveStem, status: .processing), make(otherStem, status: .done)], live: liveStem)
        var filter = MeetingFilter()
        filter.status = .recording
        XCTAssertEqual(MeetingFilterEngine.apply(filter, to: corpus).map(\.stem), [liveStem])
    }

    func test_a_live_stem_is_not_failed_not_needs_you_and_offers_no_reprocess() throws {
        // Even if a scan without ownership aged it (the window between start and the UI mirror).
        let corpus = LiveRecordingOverlay.apply(
            [make(liveStem, status: .failed), make(otherStem, status: .done)], live: liveStem)
        var failed = MeetingFilter()
        failed.status = .failed
        XCTAssertTrue(MeetingFilterEngine.apply(failed, to: corpus).isEmpty)
        let context = LibraryScope.Context(workflows: [])
        XCTAssertFalse(corpus.contains { LibraryScope.needsYou.includes($0, in: context) })
        XCTAssertEqual(ScopeCounts.build(meetings: corpus, workflows: []).needsYou, 0)
        // The row's Reprocess gate is `meeting.status == .failed` on the row it is handed.
        XCTAssertNotEqual(corpus.first(where: { $0.stem == liveStem })?.status, .failed)
    }

    func test_a_saved_folder_holding_status_recording_lists_the_live_stem() {
        var filter = MeetingFilter()
        filter.status = .recording
        let folder = SavedSearch(name: "Live", filter: filter)
        let corpus = LiveRecordingOverlay.apply(
            [make(liveStem, status: .processing), make(otherStem, status: .done)], live: liveStem)
        XCTAssertEqual(folder.apply(to: corpus, workflows: []).map(\.stem), [liveStem])
        XCTAssertEqual(ScopeCounts.build(meetings: corpus, workflows: [], savedSearches: [folder]).perSaved[folder.id], 1)
    }

    func test_nothing_recording_leaves_the_corpus_untouched() {
        let corpus = [make(liveStem, status: .failed)]
        XCTAssertEqual(LiveRecordingOverlay.apply(corpus, live: nil).map(\.status), [.failed])
        XCTAssertEqual(LiveRecordingOverlay.apply(corpus, live: "gone").map(\.status), [.failed])
    }

    /// The Library derives from the overlaid corpus, not from the store's raw list.
    func test_the_list_and_the_counts_derive_from_the_overlay() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let list = try String(contentsOf: root.appendingPathComponent("Sources/MeetingPipe/LibraryListView.swift"), encoding: .utf8)
        XCTAssertTrue(list.contains("let corpus = LiveRecordingOverlay.apply(store.meetings, live: libraryModel.liveRecordingStem)"))
        XCTAssertFalse(list.contains("scoped = store.meetings"), "every scope branch reads the overlaid corpus")
        let window = try String(contentsOf: root.appendingPathComponent("Sources/MeetingPipe/LibraryWindow.swift"), encoding: .utf8)
        XCTAssertTrue(window.contains("let meetings = LiveRecordingOverlay.apply(meetingStore.meetings, live: model.liveRecordingStem)"))
        let coordinator = try String(contentsOf: root.appendingPathComponent("Sources/MeetingPipe/Coordinator.swift"), encoding: .utf8)
        XCTAssertTrue(coordinator.contains("libraryModel.meetingStore.ownedStems = {"),
                      "the scan's exemption only works if the Coordinator wires the recorder in")
    }

    // MARK: - G038: Kept local beside the lifecycle

    func test_a_zero_egress_row_keeps_its_lifecycle_pill() {
        for status: Meeting.Status in [.failed, .empty, .manualPasteReady] {
            let lifecycle = MeetingStatusPill.decide(status: status, publishState: nil, emptyReason: nil, failureReason: nil)
            XCTAssertNotEqual(lifecycle.kind, .nda, "\(status) must not read as Kept local")
            XCTAssertNotEqual(lifecycle.label, "Kept local")
            XCTAssertEqual(MeetingStatusPill.keptLocal(.ndaWorkflow)?.label, "Kept local",
                           "the Kept local pill shows beside it")
        }
    }

    func test_kept_local_help_names_the_flag_that_set_it() {
        var nda = make("a", status: .failed)
        nda.workflowNDAMode = true
        var regulated = make("b", status: .failed)
        regulated.regulatedMode = true
        var unreadable = make("c", status: .failed)
        unreadable.metaUnreadable = true
        XCTAssertEqual(KeptLocalReason.of(nda), .ndaWorkflow)
        XCTAssertEqual(KeptLocalReason.of(regulated), .regulatedMode)
        XCTAssertEqual(KeptLocalReason.of(unreadable), .unreadableSidecar)
        XCTAssertNil(KeptLocalReason.of(make("d", status: .done)))
        let helps = [nda, regulated, unreadable].compactMap { MeetingStatusPill.keptLocal(KeptLocalReason.of($0))?.help }
        XCTAssertEqual(Set(helps).count, 3, "three flags, three different explanations")
        XCTAssertEqual(MeetingStatusPill.keptLocal(.ndaWorkflow)?.help, "On this Mac by design (NDA workflow).")
    }

    /// `KeptLocalReason` covers exactly the flags `isZeroEgress` reads.
    func test_kept_local_reason_matches_zero_egress() {
        for (n, r, u) in [(false, false, false), (true, false, false), (false, true, false), (false, false, true), (true, true, true)] {
            var m = make("s", status: .done)
            m.workflowNDAMode = n
            m.regulatedMode = r
            m.metaUnreadable = u
            XCTAssertEqual(KeptLocalReason.of(m) != nil, m.isZeroEgress)
        }
    }
}
