import Foundation

/// Pure builder for `<stem>.meta.json`. Canonical Swift-to-Python contract: the pipeline reads these keys via `mp.workflow.apply_overrides`. Unit-testable without a Coordinator.
enum MeetingMetaSidecar {

    /// Build the JSON-serializable dictionary for a finished recording. Returns an empty dict when neither source nor workflow is available; caller skips the write so the pipeline's no-sidecar fallback (LLM-derived title, global config) stays intact.
    static func build(source: AppSource?, workflow: Workflow?) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let source = source {
            dict["source_bundle_id"] = source.bundleID
            dict["source_display_name"] = source.displayName
            dict["source_kind"] = source.kind == .browser ? "browser" : "native"
            if let title = source.meetingTitle, !title.isEmpty {
                dict["meeting_title"] = title
            }
        }
        if let wf = workflow {
            dict["workflow_id"] = wf.id.uuidString
            dict["workflow_name"] = wf.name
            dict["workflow_color"] = wf.color
            if let emoji = wf.emoji, !emoji.isEmpty {
                dict["workflow_emoji"] = emoji
            }
            dict["workflow_context_prompt"] = wf.contextPrompt
            dict["workflow_backend"] = wf.effectiveBackend.rawValue
            dict["workflow_sinks"] = wf.effectiveSinkTypeNames
            if !wf.notionDatabaseID.isEmpty {
                dict["workflow_notion_database_id"] = wf.notionDatabaseID
            }
            dict["workflow_nda_mode"] = wf.flags.ndaMode
        }
        return dict
    }
}
