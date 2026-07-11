import Foundation

/// Pure builder for `<stem>.meta.json`. Canonical Swift-to-Python contract: the pipeline reads these keys via `mp.workflow.apply_overrides`. Unit-testable without a Coordinator.
enum MeetingMetaSidecar {

    /// Sidecar shape version. Bump when the key set or a key's semantics change so a future reader can migrate. The Python reader stays fail-open on it (an unknown key is ignored); the cross-language golden fixtures (CI2, `Fixtures/meta-contract/`) pin it on both sides. Bumped to 2 by MIC15 (added `mic_device_name` + `mic_silent`); to 3 by WF7 (added `workflow_extra_sections`).
    static let schemaVersion = 3

    /// Build the JSON-serializable dictionary for a finished recording. Returns an empty dict when neither source nor workflow is available (and not regulated); caller skips the write so the pipeline's no-sidecar fallback (LLM-derived title, global config) stays intact.
    ///
    /// `regulatedMode` is the global flag at record time (TECH-DSN6). Persisting it
    /// makes the resolved zero-egress state (`regulated_mode || workflow_nda_mode`)
    /// readable: the Library badge stops inferring NDA, and a reprocess stays
    /// fail-closed even if the global flag later flips.
    /// `micDeviceName` / `micSilent` are the MIC15 top-level keys: which input device the OS
    /// bound the recorder to (for the Library "which mic" detail), and whether the post-stop
    /// dead-mic gate fired (drives the Library row warning). Both are informational; the Python
    /// reader ignores them (fail-open). Added only to a sidecar we already write, so the
    /// skip-empty invariant holds; `micSilent` is stamped only when true, like `regulated_mode`.
    static func build(
        source: AppSource?,
        workflow: Workflow?,
        regulatedMode: Bool = false,
        micDeviceName: String? = nil,
        micSilent: Bool = false
    ) -> [String: Any] {
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
            // WF7: workflow-defined extra summary sections. Omitted when the
            // workflow defines none, so a workflow that predates WF7 stays
            // byte-identical apart from the schema_version bump.
            let sections = wf.usableExtraSections
            if !sections.isEmpty {
                dict["workflow_extra_sections"] = sections.map {
                    ["name": $0.name, "instruction": $0.instruction]
                }
            }
        }
        // Stamp the version only on a sidecar we actually write. An empty dict
        // (no source, workflow, or regulated flag) must stay empty so the caller
        // still skips the write and the pipeline's no-sidecar fallback holds. The
        // MIC15 keys ride the same guard so a device-only sidecar can't spring into
        // existence for an otherwise-empty manual run.
        if !dict.isEmpty {
            if let micDeviceName = micDeviceName, !micDeviceName.isEmpty {
                dict["mic_device_name"] = micDeviceName
            }
            if micSilent {
                dict["mic_silent"] = true
            }
            dict["schema_version"] = schemaVersion
        }
        return dict
    }

    /// Rewrite the workflow block of an existing sidecar dict for a post-hoc workflow
    /// reassignment (WF8). Everything not under the workflow block (source, title, the
    /// top-level `regulated_mode`, any unknown key) is preserved; every `workflow_*`
    /// key is dropped and rebuilt from `workflow` through `build`, so the omission
    /// rules stay in one place and a stale cloud key (e.g. a `workflow_notion_database_id`
    /// or `workflow_backend` from the old workflow) cannot survive a move into an NDA
    /// workflow. Pure, so `MetaContractFixtureTests` can pin it without the service.
    static func reassigned(existing: [String: Any], to workflow: Workflow) -> [String: Any] {
        var dict = existing
        for key in dict.keys where key.hasPrefix("workflow_") {
            dict.removeValue(forKey: key)
        }
        let block = build(source: nil, workflow: workflow)
        for (key, value) in block where key.hasPrefix("workflow_") {
            dict[key] = value
        }
        dict["schema_version"] = schemaVersion
        return dict
    }
}
