import Foundation
import MeetingPipeCore

/// Decides whether a lifecycle `.ended` verdict should clear prompt-side state
/// (`.prompting` / `.suppressed`).
///
/// The Teams compact/mini window destroys the in-call Leave button, and the
/// rescue re-walk can't re-find it on the redesigned mini window, so the
/// lifecycle emits `.ended` with `leadingSignal == ax_leave_button_invalid` and
/// no corroborating PRIMARY (`confirmedBy` empty) while the call is still live.
/// Honoring that on the prompt side tore down an explicit Skip and re-opened the
/// detection prompt every ~minute for the whole meeting (seen in events.jsonl as
/// a repeating `starting -> suppressed -> idle -> starting` loop).
///
/// So a bare, uncorroborated leave-button invalidation does NOT clear the
/// prompt/suppressed state. Every other end (corroborated, or led by any other
/// signal such as shareable-content-window-gone or process-audio-stopped) still
/// clears it, so a genuine end is not missed. The recording-stop path is
/// separate and deliberately honors every end.
///
/// Pure decision, no I/O: the Coordinator forwards the end's reason in.
enum PromptEndPolicy {
    /// `true` if this end should clear `.prompting` / `.suppressed`; `false` to
    /// hold the current state because the end is an untrustworthy mini-window
    /// artifact rather than a real meeting end.
    static func clearsPromptState(reason: EndingReason) -> Bool {
        let isBareLeaveButtonInvalidation =
            reason.leadingSignal == PrimarySignalKind.axLeaveButton.rawValue
            && reason.confirmedBy.isEmpty
        return !isBareLeaveButtonInvalidation
    }
}
