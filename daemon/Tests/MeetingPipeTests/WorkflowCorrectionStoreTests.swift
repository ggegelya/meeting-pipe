import XCTest
@testable import MeetingPipe

/// AI9: the durable half. The whole reason this file exists rather than a read
/// back over `events.jsonl` is that the log rotates, so a count derived from it
/// would shrink on its own.
final class WorkflowCorrectionStoreTests: XCTestCase {

    private var tempDir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wfcorrections-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        url = tempDir.appendingPathComponent("workflow_corrections.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// The writes hop to a private queue; drain it before reading the file back.
    private func flush(_ store: WorkflowCorrectionStore) {
        _ = store
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    func test_load_on_a_missing_file_is_empty_not_an_error() {
        let store = WorkflowCorrectionStore(url: url)
        store.load()
        XCTAssertTrue(store.corrections.isEmpty)
    }

    func test_records_and_survives_a_reload() throws {
        let workflow = Workflow(name: "Client work")
        let store = WorkflowCorrectionStore(url: url)
        store.load()
        XCTAssertTrue(store.record(
            bundleID: "com.microsoft.teams2",
            meetingTitle: "Acme weekly 07/24",
            workflow: workflow
        ))
        flush(store)

        let reloaded = WorkflowCorrectionStore(url: url)
        reloaded.load()
        XCTAssertEqual(reloaded.corrections.count, 1)
        XCTAssertEqual(reloaded.corrections.first?.bundleID, "com.microsoft.teams2")
        XCTAssertEqual(reloaded.corrections.first?.titleKey, "acme weekly")
        XCTAssertEqual(reloaded.corrections.first?.workflowID, workflow.id)
        XCTAssertEqual(reloaded.corrections.first?.workflowName, "Client work")
    }

    func test_a_source_less_meeting_is_refused_rather_than_stored_unreadable() {
        let store = WorkflowCorrectionStore(url: url)
        store.load()
        XCTAssertFalse(store.record(bundleID: "", meetingTitle: "Manual", workflow: Workflow(name: "Personal")))
        XCTAssertFalse(store.record(bundleID: "   ", meetingTitle: nil, workflow: Workflow(name: "Personal")))
        XCTAssertTrue(store.corrections.isEmpty)
    }

    func test_a_titleless_recording_still_records_on_the_bundle_tier() {
        let store = WorkflowCorrectionStore(url: url)
        store.load()
        XCTAssertTrue(store.record(bundleID: "us.zoom.xos", meetingTitle: nil, workflow: Workflow(name: "Client")))
        XCTAssertEqual(store.corrections.first?.titleKey, "")
    }

    func test_oldest_pairs_drop_past_the_cap() {
        let store = WorkflowCorrectionStore(url: url)
        store.load()
        let workflow = Workflow(name: "Client work")
        for i in 0...(WorkflowCorrectionStore.maxCorrections) {
            store.record(
                bundleID: "app.\(i)",
                meetingTitle: nil,
                workflow: workflow,
                at: Date(timeIntervalSince1970: TimeInterval(i))
            )
        }
        XCTAssertEqual(store.corrections.count, WorkflowCorrectionStore.maxCorrections)
        XCTAssertEqual(store.corrections.first?.bundleID, "app.1", "the oldest is what goes")
    }

    func test_a_corrupt_file_degrades_to_empty_instead_of_throwing() throws {
        try Data("{ not json".utf8).write(to: url)
        let store = WorkflowCorrectionStore(url: url)
        store.load()
        XCTAssertTrue(store.corrections.isEmpty)
    }

    /// The end-to-end shape AI9 promises: three real corrections for one app, and
    /// the next meeting from that app is suggested the corrected workflow.
    func test_store_feeds_the_hint() {
        let general = Workflow(name: "General", isDefault: true)
        let client = Workflow(name: "Client work")
        let store = WorkflowCorrectionStore(url: url)
        store.load()
        for _ in 0..<WorkflowRoutingHint.minimumCorrections {
            store.record(bundleID: "com.microsoft.teams2", meetingTitle: nil, workflow: client)
        }
        let suggestion = WorkflowRoutingHint.suggest(
            source: AppSource(bundleID: "com.microsoft.teams2", displayName: "Teams"),
            matched: general,
            corrections: store.corrections,
            workflows: [general, client]
        )
        XCTAssertEqual(suggestion?.workflowID, client.id)
    }
}
