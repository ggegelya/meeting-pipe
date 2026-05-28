import Foundation

/// Per-context routing rules: LLM context prompt, publish sinks, summarisation backend, and behavioural toggles (NDA mode). One TOML file per workflow under `~/.config/meeting-pipe/workflows/`; UUID is the filename so renames don't move the file. Exactly one workflow is flagged default; `WorkflowStore` enforces single-default on every save.

/// Summarisation backend. Mirrors `summarization.backend` strings from `config.toml` so the pipeline can apply per-meeting overrides without new branching.
enum WorkflowBackend: String, Codable, Equatable, CaseIterable {
    case anthropic
    case local
    case auto
}

/// One publish destination, workflow-scoped. Empty strings fall back to the global config field.
enum WorkflowSink: Codable, Equatable, Hashable {
    case notion(databaseId: String)
    case obsidian
    case filesystem

    /// Stable string used in TOML; matches the pipeline's `output.sinks` vocabulary.
    var typeName: String {
        switch self {
        case .notion: return "notion"
        case .obsidian: return "obsidian"
        case .filesystem: return "filesystem"
        }
    }
}

/// Per-workflow behavioural toggles. Separate struct so future flags land without touching the Workflow shape.
struct WorkflowFlags: Codable, Equatable, Hashable {
    /// Forces `backend = .local` and `sinks = [.filesystem]` regardless of other fields. Surfaced in the HUD so a misroute is visible before recording starts.
    var ndaMode: Bool = false
}

/// One match predicate; any matching rule counts for the workflow. Empty `bundleID` matches any bundle, useful for title-regex rules targeting browser meetings that may surface as Chrome, Safari, Edge, or Arc.
struct WorkflowMatchingRule: Codable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    /// Exact bundle-id match. Empty matches any.
    var bundleID: String = ""
    /// Case-insensitive regex against `meetingTitle`. Empty means any title.
    var titleRegex: String = ""

    enum CodingKeys: String, CodingKey {
        case id
        case bundleID = "bundle_id"
        case titleRegex = "title_regex"
    }

    init(id: UUID = UUID(), bundleID: String = "", titleRegex: String = "") {
        self.id = id
        self.bundleID = bundleID
        self.titleRegex = titleRegex
    }
}

struct Workflow: Codable, Equatable, Hashable, Identifiable {
    let id: UUID
    var name: String
    /// Hex string like "#FF6B6B". Parsed by the UI on render.
    var color: String
    /// Single emoji char or nil; UI shows it instead of the color glyph.
    var emoji: String?
    var matchingRules: [WorkflowMatchingRule]
    /// Becomes `summarization.team_context` in the pipeline.
    var contextPrompt: String
    var sinks: [WorkflowSink]
    var backend: WorkflowBackend
    var flags: WorkflowFlags
    /// Exactly one workflow has this set; the matcher falls back to it when no rule matches.
    var isDefault: Bool
    /// User-defined display order; ties break alphabetically by name.
    var order: Int

    init(
        id: UUID = UUID(),
        name: String,
        color: String = "#3478F6",
        emoji: String? = nil,
        matchingRules: [WorkflowMatchingRule] = [],
        contextPrompt: String = "",
        sinks: [WorkflowSink] = [.notion(databaseId: "")],
        backend: WorkflowBackend = .anthropic,
        flags: WorkflowFlags = WorkflowFlags(),
        isDefault: Bool = false,
        order: Int = 0
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.emoji = emoji
        self.matchingRules = matchingRules
        self.contextPrompt = contextPrompt
        self.sinks = sinks
        self.backend = backend
        self.flags = flags
        self.isDefault = isDefault
        self.order = order
    }

    /// Effective backend after applying NDA override; surfaced on the workflow chip so the user sees the override before pressing Record.
    var effectiveBackend: WorkflowBackend {
        flags.ndaMode ? .local : backend
    }

    /// Effective sinks after NDA; NDA forces filesystem-only so the summary never leaves the Mac.
    var effectiveSinks: [WorkflowSink] {
        flags.ndaMode ? [.filesystem] : sinks
    }

    /// Sink type names for the meta sidecar's `output.sinks` override.
    var effectiveSinkTypeNames: [String] {
        effectiveSinks.map { $0.typeName }
    }

    /// Notion DB id this workflow publishes to; empty string falls back to the global `notion.database_id`.
    var notionDatabaseID: String {
        for sink in effectiveSinks {
            if case .notion(let id) = sink {
                return id
            }
        }
        return ""
    }
}
