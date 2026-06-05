import XCTest
import MeetingPipeCore
@testable import MeetingPipe

/// The gate that stops a Teams mini-window leave-button invalidation from
/// tearing down an explicit Skip and re-opening the prompt every minute.
final class PromptEndPolicyTests: XCTestCase {

    private let axLeaveButton = PrimarySignalKind.axLeaveButton.rawValue
    private let shareableWindow = PrimarySignalKind.shareableContentWindow.rawValue

    func test_bare_leave_button_invalidation_does_not_clear_prompt_state() {
        // The reported loop: the mini-window swap invalidates the Leave button
        // with no corroborating PRIMARY while the call is still live.
        let reason = EndingReason(leadingSignal: axLeaveButton, confirmedBy: [])
        XCTAssertFalse(PromptEndPolicy.clearsPromptState(reason: reason))
    }

    func test_corroborated_leave_button_end_clears_prompt_state() {
        // A genuine leave: the window/audio PRIMARYs confirm the end too.
        let reason = EndingReason(
            leadingSignal: axLeaveButton,
            confirmedBy: [shareableWindow]
        )
        XCTAssertTrue(PromptEndPolicy.clearsPromptState(reason: reason))
    }

    func test_non_leave_button_end_clears_prompt_state_even_without_corroboration() {
        // A window-gone or audio-stopped end is trustworthy on its own; only the
        // structural leave-button invalidation is the mini-window artifact.
        let reason = EndingReason(leadingSignal: shareableWindow, confirmedBy: [])
        XCTAssertTrue(PromptEndPolicy.clearsPromptState(reason: reason))
    }

    func test_workspace_app_terminated_end_clears_prompt_state() {
        // Process death is a definitive end; never withhold it.
        let reason = EndingReason(
            leadingSignal: PrimarySignalKind.workspaceAppTerminated.rawValue,
            confirmedBy: []
        )
        XCTAssertTrue(PromptEndPolicy.clearsPromptState(reason: reason))
    }
}
