import Foundation
import TOMLKit

/// One-shot migration from the pre-workflows config shape (a single
/// `summarization.team_context` string + a single `notion.database_id`)
/// into the per-workflow store TECH-B introduces.
///
/// Idempotent: if any workflows already exist on disk, the migrator is
/// a no-op. That way an upgrade-once-then-downgrade cycle won't keep
/// re-creating "General" every launch, and an in-progress reorder via
/// the Workflows tab can't accidentally repopulate after a restart.
///
/// The migration never overwrites the user's `config.toml`. The legacy
/// `team_context` field stays in the file as a fallback the pipeline can
/// still read; the new behaviour is that the workflow's `context_prompt`
/// takes precedence once present in the meta sidecar.
enum WorkflowMigrator {

    /// Run the migration if the store is empty. Returns whether anything
    /// was inserted so callers can log it; the daemon ignores the return
    /// value.
    @discardableResult
    static func runIfNeeded(
        store: WorkflowStore,
        configStore: ConfigStore?,
        config: Config,
        configURL: URL = Config.defaultPath
    ) -> Bool {
        guard store.workflows.isEmpty else { return false }

        let legacyTeamContext = readLegacyTeamContext(at: configURL)
        let legacyNotionDB = configStore?.notionDatabaseId ?? ""

        // Always seed a default workflow when none exist — even on a
        // brand-new install with no `team_context` set. Without a default
        // the matcher would have nothing to resolve to, and the user
        // would have to open the Workflows tab before the first meeting.
        let general = Workflow(
            id: UUID(),
            name: "General",
            color: "#3478F6",
            emoji: nil,
            matchingRules: [],  // empty rules → default-only fallback
            contextPrompt: legacyTeamContext,
            sinks: [.notion(databaseId: legacyNotionDB)],
            backend: legacyBackend(configStore: configStore),
            flags: WorkflowFlags(),
            isDefault: true,
            order: 0
        )
        do {
            try store.upsert(general)
            Log.main.info("WorkflowMigrator: seeded 'General' workflow (had_team_context=\(!legacyTeamContext.isEmpty))")
            Log.event(category: "workflow", action: "migrator_seeded", attributes: [
                "name": "General",
                "had_team_context": !legacyTeamContext.isEmpty,
                "had_notion_db": !legacyNotionDB.isEmpty,
            ])
            return true
        } catch {
            Log.main.error("WorkflowMigrator: failed to seed General workflow: \(error.localizedDescription)")
            return false
        }
    }

    /// Read `summarization.team_context` straight from the on-disk
    /// `config.toml`. We avoid extending ConfigStore for this because
    /// `team_context` is a pipeline-side knob and surfacing it on the
    /// daemon side just for one-shot migration would muddy the contract.
    private static func readLegacyTeamContext(at url: URL) -> String {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let doc = try? TOMLTable(string: raw),
              let summ = doc["summarization"]?.table else {
            return ""
        }
        return summ["team_context"]?.string ?? ""
    }

    private static func legacyBackend(configStore: ConfigStore?) -> WorkflowBackend {
        let raw = configStore?.summarizationBackend ?? "anthropic"
        return WorkflowBackend(rawValue: raw) ?? .anthropic
    }
}
