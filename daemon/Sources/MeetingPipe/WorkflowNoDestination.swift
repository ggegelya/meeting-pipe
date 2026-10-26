import Foundation

/// What a workflow with no destinations means, said once for the two surfaces
/// that show it (WF10).
///
/// An empty sink list used to mean two opposite things: the inspector said "No
/// destination set" while `mp.workflow.apply_overrides` skipped the empty list on
/// purpose and published to the global default, which is Notion. It now means
/// publish nowhere on both sides (the summary stays in the Library and the run
/// records `state: "local"`), and the editor and the inspector both say so in the
/// same words. `WorkflowContextHint` is the same shape for the context prompt.
enum WorkflowNoDestination {

    /// The consequence, shared so the two phrasings cannot drift apart.
    static let consequence = "summaries stay in the Library and are never published"

    /// The workflow inspector's Output row value for an empty effective sink list.
    static let inspectorValue = "No destination set: \(consequence)"

    /// The caption under the editor's sink toggles, or nil when it has nothing
    /// to say: some destination is on, or NDA mode is on, which forces the local
    /// folder whatever the toggles hold and carries its own caption.
    static func editorCaption(sinks: [WorkflowSink], ndaMode: Bool) -> String? {
        guard sinks.isEmpty, !ndaMode else { return nil }
        return "No destinations: \(consequence)."
    }
}
