import Combine
import XCTest
@testable import MeetingPipe

/// UX29: the "Re-summarize with ..." menu may only offer what it can deliver.
///
/// The clamp under test here is the communication, never the guarantee: an NDA
/// workflow and global regulated mode both force the local backend in the
/// pipeline (`effective_backend`) and strip the cloud key from the child env
/// (`PipelineLauncher.cloudSecretPolicy`), and neither is touched. What is new
/// is that the menu stops claiming otherwise.
final class ReSummarizeMenuTests: XCTestCase {

    // MARK: - Enabled when nothing clamps

    func test_cloud_is_offered_on_an_ordinary_meeting() {
        let state = ReSummarizeMenu.resolve(workflowNDA: false, regulatedMode: false)
        XCTAssertTrue(state.cloudEnabled)
        XCTAssertNil(state.caption)
        XCTAssertFalse(state.offersWorkflowChange, "nothing to escape from")
        XCTAssertEqual(
            state.accessibilityLabel(for: "Anthropic (cloud)"),
            "Anthropic (cloud)",
            "an enabled item announces itself and nothing else"
        )
    }

    // MARK: - Disabled with a reason

    func test_an_nda_workflow_disables_cloud_and_says_why() {
        // The exact 2026-07-23 case: two clicks on "Re-summarize with Anthropic",
        // local Qwen output both times, no surface saying the substitution
        // happened or why.
        let state = ReSummarizeMenu.resolve(workflowNDA: true, regulatedMode: false)
        XCTAssertFalse(state.cloudEnabled)
        XCTAssertEqual(state.caption, "NDA workflow: summaries stay on this Mac")
    }

    func test_regulated_mode_disables_cloud_and_names_itself() {
        let state = ReSummarizeMenu.resolve(workflowNDA: false, regulatedMode: true)
        XCTAssertFalse(state.cloudEnabled)
        XCTAssertEqual(state.caption, "Regulated mode: summaries stay on this Mac")
    }

    func test_the_disabled_reason_rides_the_voiceover_label() {
        // A disabled control announces no reason on its own, so a caption the
        // sighted user reads next to it has to be in the label too.
        let state = ReSummarizeMenu.resolve(workflowNDA: true, regulatedMode: false)
        let label = state.accessibilityLabel(for: "Anthropic (cloud)")
        XCTAssertEqual(
            label,
            "Anthropic (cloud), unavailable. NDA workflow: summaries stay on this Mac"
        )
    }

    // MARK: - Which escape hatch is honest

    func test_an_nda_workflow_offers_the_reassign_flow() {
        // Reassigning is the designed way out, and it confirms the NDA crossing
        // explicitly; it is the path the owner took by hand.
        let state = ReSummarizeMenu.resolve(workflowNDA: true, regulatedMode: false)
        XCTAssertTrue(state.offersWorkflowChange)
    }

    func test_regulated_mode_does_not_offer_a_workflow_change() {
        // Regulated mode clamps every workflow, so pointing at the reassign flow
        // would point at a door that opens onto a wall.
        let state = ReSummarizeMenu.resolve(workflowNDA: false, regulatedMode: true)
        XCTAssertFalse(state.offersWorkflowChange)
    }

    func test_regulated_mode_wins_over_an_nda_workflow() {
        // Both apply: the wider clamp has to be the one reported, or the caption
        // promises an escape the wider one forbids.
        let state = ReSummarizeMenu.resolve(workflowNDA: true, regulatedMode: true)
        XCTAssertEqual(state.clamp, .regulatedMode)
        XCTAssertFalse(state.offersWorkflowChange)
    }

    // MARK: - Derived from the meta the row already has

    func test_the_state_comes_from_the_meeting_sidecar_flags() throws {
        // No new state: `workflow_nda_mode` and `regulated_mode` are already in
        // `<stem>.meta.json`, already read by `MeetingStore`, and already
        // modelled on `Meeting`. Written here through the store's own reader so
        // a key rename cannot pass this test by matching a hand-built struct.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-ux29-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data().write(to: dir.appendingPathComponent("20260723-103118.wav"))
        try """
        {"schema_version": 1, "workflow_name": "Client work", "workflow_nda_mode": true}
        """.write(
            to: dir.appendingPathComponent("20260723-103118.meta.json"),
            atomically: true, encoding: .utf8
        )

        let store = MeetingStore(recordingsDir: dir)
        let scanned = expectation(description: "scan")
        var captured: [Meeting] = []
        let cancel = store.$meetings.dropFirst().sink { meetings in
            captured = meetings
            scanned.fulfill()
        }
        store.start()
        wait(for: [scanned], timeout: 2.0)
        cancel.cancel()

        let meeting = try XCTUnwrap(captured.first)
        XCTAssertEqual(meeting.workflowNDAMode, true)

        let state = ReSummarizeMenu.resolve(
            workflowNDA: meeting.workflowNDAMode ?? false,
            regulatedMode: meeting.regulatedMode ?? false
        )
        XCTAssertFalse(state.cloudEnabled)
        XCTAssertTrue(state.offersWorkflowChange)
    }
}
