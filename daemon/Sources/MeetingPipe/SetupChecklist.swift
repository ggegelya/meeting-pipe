import Foundation

/// The pure derivation behind the menu bar's "Finish setup" row (UX22).
///
/// There are four setup surfaces (installer, README, Preferences, onboarding)
/// and, before this, no in-app answer to "am I done?". This type is that
/// answer: given a snapshot of what `mp doctor` already knows (secrets,
/// config, permissions, the local-model cache), it returns the list of
/// still-unmet setup items, each of which the status bar renders as a
/// deep-linked submenu row. An empty list means everything is green and the
/// row does not appear at all.
///
/// The `StatusBarModel.derive` / `MicGate.decide` idiom: explicit inputs in, a
/// value out, no globals read from inside, so every required-ness branch is
/// reachable from a test.
///
/// Required-ness is config-aware and is doctor's reachability (UX107): an item
/// shows only when it is both *relevant to the current configuration* and
/// *unmet*. Relevance unions across the workflows (a nil-backend workflow
/// inherits the global backend, resolved by the caller), falling back to the
/// global config only when there are zero workflows. What each backend and sink
/// needs is `backendNeeds` / `sinkNeeds`, the same table `mp.reachability` holds
/// for `mp doctor`; `reachability-golden.json` pins the two against each other.
enum SetupChecklist {

    /// Where an item's fix lives, so the status bar can target the right menu
    /// action. Not the fix itself (that is AppKit plumbing), just which one.
    enum Fix: Equatable {
        /// Preferences -> Permissions (the TCC grants).
        case permissions
        /// Preferences -> Integrations (the Anthropic key and the Notion pair).
        case integrations
        /// Start the local-model download on the shared supervisor (UX21).
        case downloadModel
        /// Preferences, whose parse-error pane names the line (UX94).
        case preferences
        /// UX107: how to install Claude Code, for a `claude_cli` workflow with no `claude`.
        case installClaudeCode
    }

    /// A requirement a backend or sink can have, keyed by `mp.reachability`'s gap ids.
    enum Gap: String, CaseIterable {
        case anthropicKey = "anthropic_key"
        case openaiKey = "openai_key"
        case claudeBinary = "claude_binary"
        case notionToken = "notion_token"
        case notionDatabase = "notion_database"
        case localModel = "local_model"
    }

    /// What each summarization backend needs (`mp.reachability.BACKEND_NEEDS`). `auto`
    /// tries Anthropic and falls back to the on-device model, so it needs both.
    static let backendNeeds: [String: Set<Gap>] = [
        "anthropic": [.anthropicKey],
        "auto": [.anthropicKey, .localModel],
        "openai": [.openaiKey],
        "claude_cli": [.claudeBinary],
        "local": [.localModel],
        "apple_intelligence": [],
    ]

    /// What each publish sink needs (`mp.reachability.SINK_NEEDS`).
    static let sinkNeeds: [String: Set<Gap>] = [
        "notion": [.notionToken, .notionDatabase],
        "obsidian": [],
        "filesystem": [],
        "lan": [],
    ]

    /// A single unmet setup item. `notion` carries which half is missing so the
    /// row can name the specific gap.
    enum Item: Equatable {
        case permissions
        case anthropicKey
        /// UX107: a workflow (or the global backend) summarizes with OpenAI and no key is set.
        case openaiKey
        /// UX107: a workflow summarizes with Claude CLI and no `claude` binary was found.
        case claudeBinary
        case notion(needsToken: Bool, needsDatabase: Bool)
        case localModel
        /// UX94: config.toml does not parse.
        case configUnreadable
        /// UX92: Notifications denied or banners off.
        case notifications

        var title: String {
            switch self {
            case .configUnreadable:
                return "Fix the settings file (config.toml)"
            case .notifications:
                return "Turn on notifications"
            case .permissions:
                return "Grant macOS permissions"
            case .anthropicKey:
                return "Add your Anthropic API key"
            case .openaiKey:
                return "Add your OpenAI API key"
            case .claudeBinary:
                return "Install Claude Code (for Claude CLI)"
            case .notion(let needsToken, let needsDatabase):
                if needsToken && needsDatabase { return "Connect Notion (token + database)" }
                if needsToken { return "Add your Notion token" }
                return "Choose a Notion database"
            case .localModel:
                return "Download the on-device model"
            }
        }

        var fix: Fix {
            switch self {
            case .permissions:            return .permissions
            case .anthropicKey, .openaiKey, .notion:  return .integrations
            case .claudeBinary:           return .installClaudeCode
            case .localModel:             return .downloadModel
            case .configUnreadable:       return .preferences
            case .notifications:          return .permissions
            }
        }
    }

    /// Everything the derivation depends on, read once by the caller. The
    /// controller sources these from `ConfigStore`, `WorkflowStore`,
    /// `SecretsStore`, `PermissionsCenter`, and the local-model preflight.
    struct Inputs: Equatable {
        var regulatedMode: Bool
        /// `summarization.backend` raw value.
        var globalBackend: String
        /// `output.sinks` type names.
        var globalSinks: [String]
        /// Each workflow's resolved backend raw value, with a nil pin already
        /// resolved to the global backend by the caller. Empty when there are
        /// no workflows, in which case the global backend stands in.
        var workflowBackends: [String]
        /// Each workflow's effective (post-NDA) sink type names. Empty when
        /// there are no workflows.
        var workflowSinks: [[String]]
        var anthropicKeyPresent: Bool
        /// UX107: `OPENAI_API_KEY` is set.
        var openaiKeyPresent: Bool
        /// UX107: a `claude` binary is installed (`ClaudeBinaryLocator`).
        var claudeBinaryPresent: Bool
        var notionTokenPresent: Bool
        /// The global `notion.database_id` is non-empty; the database a route uses
        /// when there are no workflows.
        var notionDatabaseIdPresent: Bool
        /// UX107: per workflow, parallel to `workflowSinks`, whether its effective Notion
        /// database id (its own, or the global fallback) is non-empty. A missing entry
        /// reads as the global one.
        var workflowNotionDatabasePresent: [Bool]
        /// The configured local model is non-empty and absent from the cache.
        var localModelMissing: Bool
        /// Any required TCC permission is missing (`StatusBarModel.hasPendingPermissionIssue`).
        var hasPermissionIssue: Bool
        /// UX94: config.toml does not parse.
        var configUnreadable: Bool
        /// UX92: Notifications denied, or authorized with banners off.
        var notificationsOff: Bool

        init(
            regulatedMode: Bool = false,
            globalBackend: String = "anthropic",
            globalSinks: [String] = ["notion"],
            workflowBackends: [String] = [],
            workflowSinks: [[String]] = [],
            anthropicKeyPresent: Bool = true,
            openaiKeyPresent: Bool = true,
            claudeBinaryPresent: Bool = true,
            notionTokenPresent: Bool = true,
            notionDatabaseIdPresent: Bool = true,
            workflowNotionDatabasePresent: [Bool] = [],
            localModelMissing: Bool = false,
            hasPermissionIssue: Bool = false,
            configUnreadable: Bool = false,
            notificationsOff: Bool = false
        ) {
            self.regulatedMode = regulatedMode
            self.globalBackend = globalBackend
            self.globalSinks = globalSinks
            self.workflowBackends = workflowBackends
            self.workflowSinks = workflowSinks
            self.anthropicKeyPresent = anthropicKeyPresent
            self.openaiKeyPresent = openaiKeyPresent
            self.claudeBinaryPresent = claudeBinaryPresent
            self.notionTokenPresent = notionTokenPresent
            self.notionDatabaseIdPresent = notionDatabaseIdPresent
            self.workflowNotionDatabasePresent = workflowNotionDatabasePresent
            self.localModelMissing = localModelMissing
            self.hasPermissionIssue = hasPermissionIssue
            self.configUnreadable = configUnreadable
            self.notificationsOff = notificationsOff
        }
    }

    // MARK: - Derivation

    static func decide(_ i: Inputs) -> [Item] {
        var items: [Item] = []

        // UX94: first, because every other item reads a file the app cannot read.
        if i.configUnreadable {
            items.append(.configUnreadable)
        }

        // Permissions are always relevant; they gate recording itself.
        if i.hasPermissionIssue {
            items.append(.permissions)
        }

        // UX92: optional, so it is its own item rather than part of `.permissions`.
        if i.notificationsOff {
            items.append(.notifications)
        }

        let need = required(i)

        if need.contains(.anthropicKey), !i.anthropicKeyPresent {
            items.append(.anthropicKey)
        }
        if need.contains(.openaiKey), !i.openaiKeyPresent {
            items.append(.openaiKey)
        }
        if need.contains(.claudeBinary), !i.claudeBinaryPresent {
            items.append(.claudeBinary)
        }

        // Notion: the token once for every route, the database per route (UX107).
        let needsToken = need.contains(.notionToken) && !i.notionTokenPresent
        let needsDatabase = notionRouteWithoutDatabase(i)
        if needsToken || needsDatabase {
            items.append(.notion(needsToken: needsToken, needsDatabase: needsDatabase))
        }

        if need.contains(.localModel), i.localModelMissing {
            items.append(.localModel)
        }

        return items
    }

    /// The menu-bar row title for a non-empty checklist. Nil when nothing is
    /// left, so the caller omits the row entirely.
    static func menuTitle(count: Int) -> String? {
        guard count > 0 else { return nil }
        let noun = count == 1 ? "step" : "steps"
        return "Finish setup (\(count) \(noun) left)"
    }

    // MARK: - Reachability (doctor's table, UX107)

    /// One route a meeting can take: each workflow, or the global config when there
    /// are none. Its backend and sinks are already post-NDA (the caller passes
    /// `effectiveBackend` / `effectiveSinkTypeNames`); regulated mode clamps here.
    private struct Route {
        var backend: String
        var sinks: [String]
        var notionDatabasePresent: Bool
    }

    private static func routes(_ i: Inputs) -> [Route] {
        if i.workflowBackends.isEmpty && i.workflowSinks.isEmpty {
            return [Route(backend: i.globalBackend, sinks: i.globalSinks, notionDatabasePresent: i.notionDatabaseIdPresent)]
        }
        // Each half falls back to the global value on its own, as before UX107, so a
        // caller that passes only one of the two lists keeps its old meaning.
        let count = max(i.workflowBackends.count, i.workflowSinks.count)
        return (0..<count).map { n in
            Route(
                backend: n < i.workflowBackends.count ? i.workflowBackends[n] : i.globalBackend,
                sinks: i.workflowSinks.isEmpty ? i.globalSinks : (n < i.workflowSinks.count ? i.workflowSinks[n] : []),
                notionDatabasePresent: n < i.workflowNotionDatabasePresent.count
                    ? i.workflowNotionDatabasePresent[n] : i.notionDatabaseIdPresent
            )
        }
    }

    /// The route's needs after the zero-egress clamp: regulated mode pins the on-device
    /// backend and the filesystem sink (SEC18), as `mp.config.effective_backend` /
    /// `effective_sinks` do.
    private static func needs(_ r: Route, regulated: Bool) -> Set<Gap> {
        let backend = regulated ? "local" : r.backend
        let sinks = regulated ? ["filesystem"] : r.sinks
        var out = backendNeeds[backend] ?? []
        for sink in sinks { out.formUnion(sinkNeeds[sink] ?? []) }
        return out
    }

    /// Every gap some route needs filled.
    static func required(_ i: Inputs) -> Set<Gap> {
        routes(i).reduce(into: Set<Gap>()) { $0.formUnion(needs($1, regulated: i.regulatedMode)) }
    }

    private static func notionRouteWithoutDatabase(_ i: Inputs) -> Bool {
        routes(i).contains { needs($0, regulated: i.regulatedMode).contains(.notionDatabase) && !$0.notionDatabasePresent }
    }

    /// The workflow-derived half of `Inputs`, as `Coordinator.setupChecklistInputs` builds it:
    /// each workflow's backend after NDA (a nil pin inherits the global backend), its sinks
    /// after NDA, and whether its effective Notion database id (own, else the global) is set.
    static func workflowRoutes(
        _ workflows: [Workflow], globalBackend: String, globalNotionDatabaseId: String
    ) -> (backends: [String], sinks: [[String]], notionDatabasePresent: [Bool]) {
        (
            workflows.map { $0.effectiveBackend?.rawValue ?? globalBackend },
            workflows.map { $0.effectiveSinkTypeNames },
            workflows.map { !$0.notionDatabaseID.isEmpty || !globalNotionDatabaseId.isEmpty }
        )
    }

}

extension SetupChecklist.Item {
    /// The `mp.reachability` gap ids this item stands for; empty for the Swift-only
    /// items (permissions, notifications, the settings file).
    var gaps: Set<SetupChecklist.Gap> {
        switch self {
        case .anthropicKey: return [.anthropicKey]
        case .openaiKey: return [.openaiKey]
        case .claudeBinary: return [.claudeBinary]
        case .notion(let token, let database):
            var out = Set<SetupChecklist.Gap>()
            if token { out.insert(.notionToken) }
            if database { out.insert(.notionDatabase) }
            return out
        case .localModel: return [.localModel]
        case .permissions, .notifications, .configUnreadable: return []
        }
    }
}

/// Whether a `claude` binary is installed, for the Finish setup checklist (UX107). The same
/// places `mp.provider_claude_cli.find_claude` looks: its fixed install directories and
/// `$PATH` (`reachability-golden.json`'s `claude_search_dirs` pins the list). The daemon
/// and the `mp` it spawns share one environment, so the two agree on `$PATH` too.
enum ClaudeBinaryLocator {
    static let searchDirs = ["~/.local/bin", "~/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]

    static func isInstalled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Bool {
        let fallbacks = searchDirs.map { (NSString(string: $0).expandingTildeInPath as NSString).appendingPathComponent("claude") }
        return ExecutableResolver.resolve(
            name: "claude", searchPath: true, fallbacks: fallbacks,
            environment: environment, isExecutable: isExecutable
        ) != nil
    }
}

/// UX107: a Guide heading to scroll to when the Guide window next shows. The Finish setup
/// row for a missing `claude` sets it to `installClaudeCode`; `GuideView` consumes it.
@MainActor
final class GuideJumpRequest: ObservableObject {
    static let shared = GuideJumpRequest()
    /// The `### ` heading in `docs/GUIDE.md` that says how to install Claude Code.
    /// `SetupChecklistTests` fails if the guide stops carrying it.
    static let installClaudeCode = "Summarizing with your Claude subscription"
    @Published var heading: String?
}
