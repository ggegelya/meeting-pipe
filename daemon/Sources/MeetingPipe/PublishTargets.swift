import Foundation

/// A publish destination whose *where* lives in global config while a workflow
/// only chooses *whether* (UX45).
///
/// Notion is absent on purpose. Its token and database already have their own
/// in-app configuration, their own status pill, and a per-workflow database
/// override; these three had nothing, which is how a workflow could enable the
/// Obsidian sink and have it silently not run.
enum PublishTarget: String, CaseIterable, Equatable {
    case obsidian
    case filesystem
    case lan

    /// The `output.sinks` / `WorkflowSink.typeName` vocabulary. Same strings, so
    /// a target and the sink it configures cannot drift apart.
    var sinkTypeName: String { rawValue }

    /// How Preferences and the workflow editor name it.
    var displayName: String {
        switch self {
        case .obsidian:   return "Obsidian"
        case .filesystem: return "Filesystem"
        case .lan:        return "LAN share"
        }
    }
}

/// Where each publish target writes, as Preferences has it configured.
///
/// A snapshot rather than a live binding: the only consumer outside Preferences
/// is the workflow editor sheet, which opens over a different window and uses
/// this for an informational caption. `PreferencesView` binds `ConfigStore`
/// directly and never goes through here.
///
/// Configured means "a path is set", nothing more. Whether a vault or a mount is
/// actually reachable is the publisher's question, answered at publish time
/// (`LanPublisher` refuses rather than falling back to local disk), and a
/// Preferences pane that probed the filesystem on every render would be both
/// slower and less truthful than that.
struct PublishTargets: Equatable {
    var obsidianVaultPath: String = ""
    var filesystemOutputDir: String = ""
    var lanMountPath: String = ""

    func path(for target: PublishTarget) -> String {
        switch target {
        case .obsidian:   return obsidianVaultPath
        case .filesystem: return filesystemOutputDir
        case .lan:        return lanMountPath
        }
    }

    func isConfigured(_ target: PublishTarget) -> Bool {
        !path(for: target).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The caption a workflow editor shows under a sink checkbox, or nil when
    /// there is nothing to say: the sink is off, or its destination is set.
    ///
    /// Pure, and on its own type for the same reason `WorkflowNameCollision` is:
    /// the whole point is the enabled-but-unconfigured case, and a derivation
    /// living inside a `View` is one no test can reach.
    func caption(for target: PublishTarget, enabled: Bool) -> String? {
        guard enabled, !isConfigured(target) else { return nil }
        switch target {
        case .obsidian:
            return "No Obsidian vault is set, so this sink cannot run. "
                + "Choose one in Preferences > Integrations."
        case .filesystem:
            return "No output folder is set, so this sink has nowhere to write. "
                + "Choose one in Preferences > Integrations."
        case .lan:
            return "No mount path is set, so this sink cannot run. "
                + "Choose one in Preferences > Integrations."
        }
    }

    /// What the Integrations pane says under a target's status pill while it is
    /// unconfigured, or nil once it is. Names the missing setting rather than
    /// only reporting that something is missing.
    func missingSettingHint(for target: PublishTarget) -> String? {
        guard !isConfigured(target) else { return nil }
        switch target {
        case .obsidian:
            return "Set a vault folder above. Until then, a workflow with the Obsidian sink on publishes nothing there."
        case .filesystem:
            return "Set an output folder above. NDA workflows publish here and nowhere else."
        case .lan:
            return "Set a mount path above. It has to be a share that is already mounted."
        }
    }
}
