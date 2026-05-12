import Foundation

/// Per-context routing rules. A "workflow" bundles together everything
/// that should change between meeting types: the system-prompt seasoning
/// the LLM sees ("FDA-regulated SaaS team" vs "personal therapy notes"),
/// where the published summary goes (Notion DB X vs Obsidian vault Y vs
/// local-only Markdown), which summarisation backend runs (cloud vs
/// on-device), and a handful of behavioural toggles like NDA mode.
///
/// One TOML file per workflow under `~/.config/meeting-pipe/workflows/`.
/// The UUID is the filename; renames don't move the file. The default
/// workflow exists exactly once across the set — `WorkflowStore`
/// enforces single-default on every save.

/// Summarisation backend. Mirrors the strings already accepted by
/// `summarization.backend` in `config.toml` so the pipeline can apply a
/// per-meeting override without any new branching.
enum WorkflowBackend: String, Codable, Equatable, CaseIterable {
    case anthropic
    case local
    case auto
}

/// One sink destination. Workflow-scoped so a meeting can publish to the
/// "Client work" Notion DB even when the global default is the personal
/// one. Each case carries the destination-specific knobs (Notion DB id,
/// Obsidian vault, etc.); empty strings mean "fall back to the global
/// config field".
enum WorkflowSink: Codable, Equatable, Hashable {
    case notion(databaseId: String)
    case obsidian
    case filesystem

    /// Stable string identifier used in TOML (matches the pipeline's
    /// `output.sinks` vocabulary).
    var typeName: String {
        switch self {
        case .notion: return "notion"
        case .obsidian: return "obsidian"
        case .filesystem: return "filesystem"
        }
    }
}

/// Per-workflow behavioural toggles. Currently just NDA mode; carried as
/// its own struct so future flags (auto-delete, watermark transcript,
/// etc.) can land without rewriting the public Workflow shape.
struct WorkflowFlags: Codable, Equatable, Hashable {
    /// NDA mode forces `backend = .local` and `sinks = [.filesystem]`
    /// regardless of the workflow's other fields. Surfaces in the HUD
    /// so the user can spot a misroute before the meeting starts.
    var ndaMode: Bool = false
}

/// One match predicate. A workflow can carry several; any matching rule
/// counts as a match for the workflow as a whole. Empty `bundleID`
/// means "match any bundle" — useful when the rule is a title regex
/// targeting a browser-detected meeting that could surface as Chrome,
/// Safari, Edge, or Arc.
struct WorkflowMatchingRule: Codable, Equatable, Hashable, Identifiable {
    /// Stable identifier so SwiftUI can ForEach without index churn.
    var id: UUID = UUID()
    /// Exact bundle-id match. Empty/nil matches any.
    var bundleID: String = ""
    /// Optional case-insensitive regex against the source's
    /// `meetingTitle`. Empty means "any title".
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
    /// Hex string like "#FF6B6B". Stored verbatim — the UI parses on render.
    var color: String
    /// Single emoji char or nil. UI prefers emoji over color glyph when present.
    var emoji: String?
    var matchingRules: [WorkflowMatchingRule]
    /// Becomes `summarization.team_context` in the pipeline at run time.
    var contextPrompt: String
    var sinks: [WorkflowSink]
    var backend: WorkflowBackend
    var flags: WorkflowFlags
    /// Exactly one workflow has this set across the store. The matcher
    /// falls back to this workflow when no rule matches.
    var isDefault: Bool
    /// User-defined ordering in the Workflows list. Ties on `order`
    /// break alphabetically by name (see WorkflowStore.sorted).
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

    /// Effective backend after the NDA flag has been applied. UI surfaces
    /// the same value via the workflow chip so the user sees the override
    /// before pressing Record.
    var effectiveBackend: WorkflowBackend {
        flags.ndaMode ? .local : backend
    }

    /// Effective sinks after NDA. NDA forces filesystem-only — no Notion,
    /// no Obsidian — so the summary never leaves the Mac.
    var effectiveSinks: [WorkflowSink] {
        flags.ndaMode ? [.filesystem] : sinks
    }

    /// Pipeline-friendly list of sink type names, e.g. `["notion", "obsidian"]`.
    /// Drives the per-meeting override of `output.sinks` in the meta sidecar.
    var effectiveSinkTypeNames: [String] {
        effectiveSinks.map { $0.typeName }
    }

    /// Notion DB id this workflow should publish to, if any. Empty string
    /// means "fall back to the global `notion.database_id`".
    var notionDatabaseID: String {
        for sink in effectiveSinks {
            if case .notion(let id) = sink {
                return id
            }
        }
        return ""
    }
}
