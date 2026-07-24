import Foundation

/// What the "Re-summarize with ..." menu may honestly offer for one meeting
/// (UX29).
///
/// The clamp itself is the product's core promise and is untouched: under an NDA
/// workflow or global regulated mode the pipeline forces the local backend
/// (`effective_backend`) and the daemon strips the cloud key from the child env
/// (`PipelineLauncher.cloudSecretPolicy`). The defect was purely communicative.
/// The menu emitted "Anthropic (cloud)" unconditionally, the owner clicked it
/// twice on an NDA meeting, got local Qwen output both times, and read a working
/// privacy guarantee as a bug.
///
/// Pure and on its own type because the option appears in more than one place
/// (the detail `...` menu and the failed-summary recovery in the Summary tab),
/// and an affordance that explains itself in one of them is worse than one that
/// explains itself in neither: it teaches that the absence of a caption means
/// the cloud call will happen.
struct ReSummarizeMenu: Equatable {

    /// Why the cloud option cannot do what it says, or nil when it can.
    enum Clamp: Equatable {
        /// The meeting's workflow carries `nda_mode`. Escapable, deliberately:
        /// reassigning the meeting to another workflow is the designed way out,
        /// and it already confirms the NDA crossing explicitly.
        case ndaWorkflow
        /// Global regulated mode. Not escapable per meeting, by design.
        case regulatedMode
    }

    let clamp: Clamp?

    /// Global regulated mode is the wider clamp: it holds whatever workflow the
    /// meeting is in, so it takes precedence when both apply. Getting that order
    /// wrong would offer "Change workflow..." as the fix for something changing
    /// the workflow cannot fix.
    static func resolve(workflowNDA: Bool, regulatedMode: Bool) -> ReSummarizeMenu {
        if regulatedMode { return ReSummarizeMenu(clamp: .regulatedMode) }
        if workflowNDA { return ReSummarizeMenu(clamp: .ndaWorkflow) }
        return ReSummarizeMenu(clamp: nil)
    }

    var cloudEnabled: Bool { clamp == nil }

    /// The quiet inline caption under the disabled item. Says what is true and
    /// where the summary went, not what is forbidden: local summarization is a
    /// first-class outcome here, not a downgrade.
    var caption: String? {
        switch clamp {
        case .none:            return nil
        case .ndaWorkflow:     return "NDA workflow: summaries stay on this Mac"
        case .regulatedMode:   return "Regulated mode: summaries stay on this Mac"
        }
    }

    /// VoiceOver label for the cloud item. A disabled control announces no
    /// reason on its own, so the reason rides in the label (PRODUCT.md's a11y
    /// floor: nothing meaningful visible-only).
    func accessibilityLabel(for title: String) -> String {
        guard let caption = caption else { return title }
        return "\(title), unavailable. \(caption)"
    }

    /// Whether to offer the deep link into the reassign flow. Only for an NDA
    /// workflow: under global regulated mode every workflow is clamped, so the
    /// row would point at a door that opens onto a wall.
    var offersWorkflowChange: Bool { clamp == .ndaWorkflow }
}
