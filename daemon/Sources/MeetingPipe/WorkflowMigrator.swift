import Foundation
import TOMLKit

/// One-shot migration from the flat config shape (`summarization.team_context` + `notion.database_id`) into the per-workflow store introduced by TECH-B. Idempotent: skips if any workflows already exist, so upgrade/downgrade cycles don't re-create "General". Never overwrites `config.toml`; the legacy `team_context` stays as a pipeline fallback until the workflow's `context_prompt` is present in the meta sidecar.
enum WorkflowMigrator {

    /// Seed a default "General" workflow if the store is empty. Returns true when anything was inserted.
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

        // Seed even on a fresh install with no legacy context; without a default the matcher has nothing to resolve to.
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

    /// Read `summarization.team_context` directly from `config.toml`. Not plumbed through ConfigStore because it is a pipeline-side knob and exposing it in the daemon just for this one-shot migration would muddy the contract.
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
