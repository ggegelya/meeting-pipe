import Foundation

/// Whether a workflow is summarizing with no team context, and what to say about it
/// (FEAT11).
///
/// The context editor has existed since the workflow wizard shipped, with a footer
/// giving one example. Both of the owner's NDA workflows still carried an empty
/// `context_prompt`, so the meetings that most need help (local backend, no cloud
/// model to fall back on) were summarized with nothing about who these people are or
/// what their words mean. Nothing anywhere said so.
///
/// This is a nudge, not a feature: no new storage, nothing auto-filled, and a workflow
/// that genuinely wants no context just carries a quiet marker.
enum WorkflowContextHint {

    /// True when this workflow would summarize with no team context at all.
    /// Whitespace counts as empty: a context prompt of spaces and newlines reaches the
    /// model as nothing, so calling it "set" would be a lie the marker is here to stop.
    static func needsContext(_ workflow: Workflow) -> Bool {
        needsContext(prompt: workflow.contextPrompt)
    }

    static func needsContext(prompt: String) -> Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Placeholder guidance shown inside an empty context editor. Names the three
    /// things that actually move a summary (and move the small local model most,
    /// because each one turns a fact the model has to infer into a fact it is told):
    /// who is in the room, what this team's words mean, and what kind of meeting it is.
    static let placeholder = """
        Who is usually here and what they do.
          "Rana runs QA, Sudip leads backend, Anisha is the client's PM."

        The words this team says out loud that a transcript will mangle.
          "DMS-1234 is a Jira key. Spark is the web app, not a product name."

        What kind of meeting this is, and what a good note out of it looks like.
          "Weekly delivery sync. Decisions and owners matter; status updates do not."
        """

    /// The workflow list's marker for an empty context. Quiet on purpose: it sits
    /// beside the existing `default` marker in the same subtle style, and it is a
    /// standing observation, not a warning.
    static let listMarker = "no context"

    static let listMarkerHelp =
        "This workflow summarizes with no team context. Add one in the workflow editor "
        + "so the model knows who is in the room and what this team's words mean."
}
