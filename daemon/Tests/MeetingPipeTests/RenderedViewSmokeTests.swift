import XCTest
@testable import MeetingPipe

/// Render smoke tests for the small SwiftUI views that used to be covered by
/// image snapshots (TECH-T2). Those rasterised each view to a PNG and pixel-
/// compared it to a committed reference; image rendering is not reproducible
/// across macOS / Xcode versions, so they failed on CI's runner and broke the
/// suite. These force each view's `body` to evaluate instead, catching a
/// construction / layout crash without depending on the renderer - the same
/// pure-logic approach as `CorrectionsTabTests`.
final class RenderedViewSmokeTests: XCTestCase {

    func test_statusPill_builds_for_every_kind() {
        let kinds: [MPStatusPill.Kind] = [
            .ready, .recording, .processing, .failed, .nda, .neutral, .warning,
        ]
        for kind in kinds {
            XCTAssertNotNil(MPStatusPill(kind: kind, label: "Status").body)
        }
    }

    func test_workflowChip_builds_with_and_without_color() {
        XCTAssertNotNil(WorkflowChip(name: "Client work", colorHex: "#0E8C82").body)
        XCTAssertNotNil(WorkflowChip(name: "Untagged", colorHex: nil).body)
    }

    @MainActor
    func test_storageSectionView_builds_before_the_first_scan_lands() throws {
        // The section renders with `stats == nil` for however long the disk scan
        // takes; the placeholder path has to be construction-safe.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-storage-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let view = StorageSectionView(
            store: try ConfigStore(configURL: dir.appendingPathComponent("config.toml")),
            workflowStore: WorkflowStore(directory: dir.appendingPathComponent("workflows"))
        )
        XCTAssertNotNil(view.body)
    }

    func test_summaryRenderedView_builds_for_populated_and_empty() {
        let summary = MeetingSummary(
            title: "Weekly sync",
            summary: ["Shipped the installer", "Cut scope on search"],
            decisions: ["Ship on Friday"],
            actions: [MeetingSummary.ActionItem(task: "Send release notes", owner: "Sam")],
            questions: ["Who owns the rollout?"]
        )
        XCTAssertNotNil(SummaryRenderedView(summary: summary).body)
        XCTAssertNotNil(SummaryRenderedView(summary: MeetingSummary()).body)
    }

    // TECH-FEAT6: the backend -> provenance-label map is a contract. The strings
    // "anthropic" / "local" / "apple_intelligence" must match what MeetingStore
    // reads from <stem>.run.json["backend"]; an unknown / nil backend hides the row.
    func test_provenanceLabel_maps_each_backend() {
        XCTAssertEqual(detailView(backend: "anthropic").provenanceLabel, "Claude (cloud)")
        XCTAssertEqual(detailView(backend: "local").provenanceLabel, "On-device (MLX)")
        XCTAssertEqual(detailView(backend: "apple_intelligence").provenanceLabel, "Apple Intelligence")
        XCTAssertNil(detailView(backend: nil).provenanceLabel)
        XCTAssertNil(detailView(backend: "something_new").provenanceLabel)
    }

    func test_provenanceTooltip_is_the_model_id_or_nil() {
        XCTAssertEqual(
            detailView(backend: "anthropic", modelId: "claude-opus-4-8").provenanceTooltip,
            "claude-opus-4-8"
        )
        XCTAssertNil(detailView(backend: "anthropic", modelId: nil).provenanceTooltip)
        XCTAssertNil(detailView(backend: "anthropic", modelId: "").provenanceTooltip)
    }

    private func detailView(backend: String?, modelId: String? = nil) -> MeetingDetailView {
        MeetingDetailView(meeting: Meeting(
            stem: "s", startedAt: Date(),
            audioURL: URL(fileURLWithPath: "/tmp/s.wav"),
            recordingsDir: URL(fileURLWithPath: "/tmp"),
            summaryTitle: nil, meetingTitle: nil,
            sourceBundleID: nil, sourceDisplayName: nil, sourceKind: nil,
            workflowName: nil, workflowColor: nil,
            durationSec: nil, backend: backend, modelId: modelId,
            status: .done, failureReason: nil, failureStage: nil,
            searchableText: ""
        ))
    }
}
