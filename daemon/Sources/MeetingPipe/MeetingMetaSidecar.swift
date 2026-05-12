import Foundation

/// Pure builder for the on-disk `<stem>.meta.json` payload.
///
/// Lives in its own type so the JSON shape is unit-testable without
/// standing up a Coordinator. The pipeline reads the same file via
/// `mp.workflow.apply_overrides` and expects exactly these keys, so this
/// is the canonical contract surface between Swift and Python.
enum MeetingMetaSidecar {

    /// Build the JSON-serializable dictionary for a finished recording.
    /// Returns an empty dict when neither a source nor a workflow is
    /// available — the caller skips the write in that case so the
    /// pipeline's "no sidecar" fallback (LLM-derived title, global
    /// config) keeps working unchanged.
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
            // Pipeline-side overrides. Keys mirror what the Python side
            // reads in `mp.workflow.apply_overrides` so the daemon and
            // the pipeline share a single contract for what changes
            // per-meeting.
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
