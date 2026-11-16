import Foundation

/// The copy behind Preferences ▸ Permissions ▸ Regulated mode, derived from the
/// clamp it describes rather than written beside it (UX60).
///
/// The control shipped titled "Skip Notion publish", with a sublabel and a footer
/// that between them named exactly one of the two things the switch does. The
/// other one is the larger. `modes.regulated_mode` is half of `zero_egress`, and
/// `mp.config.effective_backend` pins summarization to the on-device model for
/// **every** meeting while it is on, whatever Preferences ▸ Pipeline is set to.
/// On a Mac configured for Anthropic, flipping it for one client call silently
/// repoints the whole library onto Qwen at lower quality, and if the model was
/// never fetched the run refuses outright rather than downloading it.
///
/// The per-workflow sibling one pane away already said both halves ("NDA mode
/// (force local backend, filesystem only)"), which is what makes the global
/// control's silence a drift rather than a house style.
///
/// So the strings are **built from** `effectiveBackend`, the mirror of the Python
/// chokepoint, and `RegulatedModeTests` asserts the clamp and the sentence that
/// describes it together: a future change to one fails on the other, which is the
/// only thing that stops this pair drifting a second time. `SpeakerAccuracy` is
/// the local precedent for the shape, a pure table plus its own tests, with no
/// view and no config in reach.
enum RegulatedMode {

    // MARK: - The rule

    /// Mirror of `mp.config.effective_backend`: the backend that actually runs
    /// once the regulated / NDA force-local rule has been applied.
    ///
    /// Kept as raw ids rather than `SummarizationEngine` because that is what the
    /// contract is written in on both sides (`summarization.backend` in
    /// `config.toml`, `workflow_backend` in the sidecar, `backend` in
    /// `run.json`), and because a backend this build has never heard of still has
    /// to clamp rather than fall through unnamed.
    ///
    /// Every non-local backend is a cloud backend here, exactly as in Python: the
    /// CLI providers egress through a child process outside the in-process
    /// transport guard, so the fail-closed decision belongs at the policy layer.
    static func effectiveBackend(configured: String, regulated: Bool, workflowNDA: Bool) -> String {
        let zeroEgress = regulated || workflowNDA
        return zeroEgress && configured != "local" ? "local" : configured
    }

    /// Mirror of `mp.config.effective_sinks` (SEC18), and the one Swift owner of the rule:
    /// `Workflow.effectiveSinks(regulated:)` and `PrivacyReach.reachableSinks` both call it, so there
    /// is a single copy to keep pinned against Python's (`sink-rule-golden.json`).
    ///
    /// Under zero egress the only sink left is the local folder, whatever the workflows hold. That
    /// is what `workflow.apply_overrides` has always enforced on every recorded meeting, so an
    /// Obsidian-only or network-share-only workflow stops reaching its vault or share and lands in
    /// the filesystem folder instead. The Preferences copy below is built from this, not written
    /// beside it, which is the drift G034 found (the copy named Notion and nothing else).
    static func effectiveSinks(configured: [WorkflowSink], regulated: Bool, workflowNDA: Bool) -> [WorkflowSink] {
        regulated || workflowNDA ? [.filesystem] : configured
    }

    /// The sinks regulated mode takes away from a workflow that holds every kind, named for the
    /// reader. Derived from `effectiveSinks`, so a sink the rule starts keeping (or drops) changes
    /// the sentence with it.
    static var droppedSinkNames: String {
        let all: [WorkflowSink] = [.notion(databaseId: ""), .obsidian, .filesystem, .lan]
        let kept = effectiveSinks(configured: all, regulated: true, workflowNDA: false)
        let names = all.filter { !kept.contains($0) }.map { sink -> String in
            switch sink {
            case .notion: return "Notion"
            case .obsidian: return "Obsidian"
            case .filesystem: return "the local folder"
            case .lan: return "the network share"
            }
        }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// The sentence both the sublabel and the footer carry about where summaries go.
    private static var sinkClampSentence: String {
        "every meeting is published only to a folder on this Mac, so \(droppedSinkNames) are skipped"
    }

    /// True when switching regulated mode on would move summarization off the
    /// configured backend.
    ///
    /// False only when the config is already `local`, which is the single case
    /// where the toggle really is Notion-only and the copy it shipped with was
    /// accurate. Every sentence below that mentions the backend is gated on this,
    /// so the honest wording cannot appear on a config it would not be honest
    /// about.
    static func clampsBackend(configured: String) -> Bool {
        effectiveBackend(configured: configured, regulated: true, workflowNDA: false) != configured
    }

    /// The engine a clamped run summarizes on. Read through `SummarizationEngine`
    /// (UX31) rather than spelled here, so this copy tracks the picker's name for
    /// the same thing.
    static var forcedEngine: SummarizationEngine { .local }

    // MARK: - The copy

    /// The toggle's title. Names both halves, because a title naming one of two
    /// consequences is how the old one read as a Notion switch.
    static let title = "Skip Notion publish and summarize on-device"

    /// The line under the toggle. Says what is true right now, in this config,
    /// which is why it takes the configured backend: "instead of Anthropic" is
    /// the half that makes the clamp concrete, and it is a lie on a Mac already
    /// set to the local model.
    static func sublabel(isOn: Bool, configured: String) -> String {
        let configuredName = SummarizationEngine.resolve(configured)?.name
        guard clampsBackend(configured: configured) else {
            // Already local: the switch genuinely only touches Notion, so say
            // that and nothing more rather than warning about a change that
            // cannot happen here.
            return isOn
                ? "On - \(sinkClampSentence.prefix(1).uppercased() + sinkClampSentence.dropFirst()). Summaries already run on this Mac, so nothing changes there."
                : "Off - meetings publish to each workflow's own sinks (Notion only if that workflow enables it)."
        }
        let insteadOf = configuredName.map { " instead of \($0)" } ?? ""
        return isOn
            ? "On - \(sinkClampSentence), and every summary is written by \(forcedEngine.name) on this Mac\(insteadOf)."
            : "Off - meetings publish to each workflow's own sinks (Notion only if that workflow enables it), and summaries run\(configuredName.map { " on \($0)" } ?? " on the engine Preferences ▸ Pipeline selects")."
    }

    /// The group footer, the last chance to name the consequence before the
    /// switch is flipped. Both halves, and the scope: this is every meeting, not
    /// the next one.
    static func footer(configured: String) -> String {
        let base = "Use for client / regulated meetings."
        guard clampsBackend(configured: configured) else {
            return base + " While it is on, \(sinkClampSentence). Summaries are already produced on this Mac, so it changes nothing about where they run."
        }
        return base
            + " Two things happen while it is on, and both apply to every meeting rather than the next one: \(sinkClampSentence), and every summary is produced on this Mac by \(forcedEngine.name), whatever Preferences ▸ Pipeline is set to."
    }

    /// The inline warning when the clamp would land on a model that is not on
    /// disk, or nil when there is nothing to say.
    ///
    /// It exists because the only surface that used to carry this was the menu
    /// bar's Finish setup row, which is not where the decision is made, and
    /// because the daemon's eager prefetch does not cover this case:
    /// `ConfigRefreshCoordinator.prefetchDecision` keys on the *configured*
    /// backend, so a Mac on `anthropic` never pre-fetches the model regulated
    /// mode is about to require. Nothing downloads until someone asks, which is
    /// what the affordance beside this string is for.
    ///
    /// - Parameters:
    ///   - isOn: only warn about a clamp that is actually in force. Off, the
    ///     model is not needed and a warning would be noise on a Mac that may
    ///     never turn this on.
    ///   - modelIsMissing: the preflight's filesystem probe.
    ///   - downloadSize: a human-readable estimate, e.g. "~4.3 GB".
    static func modelMissingNotice(
        isOn: Bool,
        configured: String,
        modelIsMissing: Bool,
        downloadSize: String
    ) -> String? {
        guard isOn, modelIsMissing, clampsBackend(configured: configured) else { return nil }
        return "Regulated mode summarizes on this Mac, and \(forcedEngine.name) is not downloaded yet (\(downloadSize)). Until it is, summaries will fail rather than fall back to the cloud."
    }
}
