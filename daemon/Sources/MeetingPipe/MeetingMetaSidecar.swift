import Foundation

/// Pure builder for `<stem>.meta.json`. Canonical Swift-to-Python contract: the pipeline reads these keys via `mp.workflow.apply_overrides`. Unit-testable without a Coordinator.
enum MeetingMetaSidecar {

    /// Sidecar shape version. Bump when the key set or a key's semantics change so a future reader can migrate. The Python reader stays fail-open on it (an unknown key is ignored); the cross-language golden fixtures (CI2, `Fixtures/meta-contract/`) pin it on both sides.
    static let schemaVersion = 1

    /// Build the JSON-serializable dictionary for a finished recording. Returns an empty dict when neither source nor workflow is available (and not regulated); caller skips the write so the pipeline's no-sidecar fallback (LLM-derived title, global config) stays intact.
    ///
    /// `regulatedMode` is the global flag at record time (TECH-DSN6). Persisting it
    /// makes the resolved zero-egress state (`regulated_mode || workflow_nda_mode`)
    /// readable: the Library badge stops inferring NDA, and a reprocess stays
    /// fail-closed even if the global flag later flips.
    static func build(source: AppSource?, workflow: Workflow?, regulatedMode: Bool = false) -> [String: Any] {
        var dict: [String: Any] = [:]
        // Global zero-egress state at record time. Top-level (not under the
        // workflow block) since it applies even to a manual, workflow-less run.
        if regulatedMode {
            dict["regulated_mode"] = true
        }
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
            // Only stamp the backend when the workflow actually pins one (or NDA
            // forces local). When it inherits, omit the key so the pipeline keeps
            // the global summarization.backend, which is how a global Apple
            // Intelligence setting stays reachable. (TECH-WF1)
            if let backend = wf.effectiveBackend {
                dict["workflow_backend"] = backend.rawValue
            }
            dict["workflow_sinks"] = wf.effectiveSinkTypeNames
            if !wf.notionDatabaseID.isEmpty {
                dict["workflow_notion_database_id"] = wf.notionDatabaseID
            }
            dict["workflow_nda_mode"] = wf.flags.ndaMode
        }
        // Stamp the version only on a sidecar we actually write. An empty dict
        // (no source, workflow, or regulated flag) must stay empty so the caller
        // still skips the write and the pipeline's no-sidecar fallback holds.
        if !dict.isEmpty {
            dict["schema_version"] = schemaVersion
        }
        return dict
    }
}
