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
/// Required-ness is config-aware and mirrors doctor's reachability: an item
/// shows only when it is both *relevant to the current configuration* and
/// *unmet*. Relevance unions across the workflows (a nil-backend workflow
/// inherits the global backend, resolved by the caller), falling back to the
/// global config only when there are zero workflows.
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
    }

    /// A single unmet setup item. `notion` carries which half is missing so the
    /// row can name the specific gap.
    enum Item: Equatable {
        case permissions
        case anthropicKey
        case notion(needsToken: Bool, needsDatabase: Bool)
        case localModel

        var title: String {
            switch self {
            case .permissions:
                return "Grant macOS permissions"
            case .anthropicKey:
                return "Add your Anthropic API key"
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
            case .anthropicKey, .notion:  return .integrations
            case .localModel:             return .downloadModel
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
        var notionTokenPresent: Bool
        var notionDatabaseIdPresent: Bool
        /// The configured local model is non-empty and absent from the cache.
        var localModelMissing: Bool
        /// Any required TCC permission is missing (`StatusBarModel.hasPendingPermissionIssue`).
        var hasPermissionIssue: Bool

        init(
            regulatedMode: Bool = false,
            globalBackend: String = "anthropic",
            globalSinks: [String] = ["notion"],
            workflowBackends: [String] = [],
            workflowSinks: [[String]] = [],
            anthropicKeyPresent: Bool = true,
            notionTokenPresent: Bool = true,
            notionDatabaseIdPresent: Bool = true,
            localModelMissing: Bool = false,
            hasPermissionIssue: Bool = false
        ) {
            self.regulatedMode = regulatedMode
            self.globalBackend = globalBackend
            self.globalSinks = globalSinks
            self.workflowBackends = workflowBackends
            self.workflowSinks = workflowSinks
            self.anthropicKeyPresent = anthropicKeyPresent
            self.notionTokenPresent = notionTokenPresent
            self.notionDatabaseIdPresent = notionDatabaseIdPresent
            self.localModelMissing = localModelMissing
            self.hasPermissionIssue = hasPermissionIssue
        }
    }

    // MARK: - Derivation

    static func decide(_ i: Inputs) -> [Item] {
        var items: [Item] = []

        // Permissions are always relevant; they gate recording itself.
        if i.hasPermissionIssue {
            items.append(.permissions)
        }

        // The Anthropic key is relevant only when a cloud summary path can run.
        if cloudReachable(i), !i.anthropicKeyPresent {
            items.append(.anthropicKey)
        }

        // Notion setup is relevant only when a notion sink is active.
        if notionActive(i), !i.notionTokenPresent || !i.notionDatabaseIdPresent {
            items.append(.notion(
                needsToken: !i.notionTokenPresent,
                needsDatabase: !i.notionDatabaseIdPresent
            ))
        }

        // The on-device model is relevant only when the local stack is reachable.
        if localReachable(i), i.localModelMissing {
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

    // MARK: - Reachability (mirrors doctor)

    /// Cloud summarization can run: a backend in {anthropic, auto} is active and
    /// regulated mode is not forcing local. `auto` counts, since it prefers
    /// cloud when a key is present.
    private static func cloudReachable(_ i: Inputs) -> Bool {
        guard !i.regulatedMode else { return false }
        return backends(i).contains { $0 == "anthropic" || $0 == "auto" }
    }

    /// The on-device MLX stack is reachable: doctor's `stack_reachable`. A
    /// backend in {local, auto} is active, or regulated mode forces local.
    private static func localReachable(_ i: Inputs) -> Bool {
        if i.regulatedMode { return true }
        return backends(i).contains { $0 == "local" || $0 == "auto" }
    }

    /// A notion sink is active and regulated mode is not suppressing it.
    private static func notionActive(_ i: Inputs) -> Bool {
        guard !i.regulatedMode else { return false }
        let sinkSets = i.workflowSinks.isEmpty ? [i.globalSinks] : i.workflowSinks
        return sinkSets.contains { $0.contains("notion") }
    }

    /// The backends in play: the workflows' resolved backends, or the global
    /// backend when there are no workflows.
    private static func backends(_ i: Inputs) -> [String] {
        i.workflowBackends.isEmpty ? [i.globalBackend] : i.workflowBackends
    }
}
