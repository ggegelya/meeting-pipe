import Foundation

/// The Permissions pane's privacy callout, derived from the backend and the
/// sinks this Mac is actually configured for rather than written beside them
/// (DOC12 item 5).
///
/// The callout shipped as a fixed sentence naming two vendors: Anthropic for
/// summarization, Notion for publishing. Both were the whole truth when it was
/// written and neither is now. The app has since grown five more summarization
/// backends (`local`, `auto`, `apple_intelligence`, `claude_cli`, `openai`) and
/// three more sinks (Obsidian, a filesystem folder, a LAN share), so on a Mac
/// configured for OpenAI publishing to a network share, the one paragraph whose
/// job is to say where data goes named neither destination. That is worse than
/// vague: it is a privacy claim that is confidently wrong, on the pane someone
/// opens *because* they are asking the question.
///
/// So the strings are **built from** the same two predicates the pipeline
/// enforces, rather than restated next to them:
///
///   - `RegulatedMode.effectiveBackend` mirrors `mp.config.effective_backend`,
///     which is where the zero-egress clamp lands the summarizer.
///   - The sink clamp mirrors `mp.workflow.apply_overrides`, whose belt-and-
///     braces branch rewrites `output.sinks` to `["filesystem"]` for regulated
///     and NDA alike. Both keys off `mp.config.zero_egress`, the single owner
///     (TECH-ARCH1).
///
/// Two deliberate choices about *which* configuration the sentence describes,
/// since a pane-level callout covers a whole library rather than one meeting:
///
///   - It reports the **upper bound** on reach. Per-workflow NDA mode only ever
///     clamps further (local backend, filesystem only), so reading each
///     workflow's `effectiveSinks` and ignoring the global backend's per-meeting
///     overrides cannot understate where data goes. A privacy sentence may be
///     more cautious than the run; it may never be less.
///   - A sink whose case this file has not considered cannot compile, the same
///     property `WorkflowBackend.engine` relies on. A fifth sink that silently
///     defaulted to "stays on this Mac" is exactly how the first version rotted.
///
/// Pure, so `PrivacyReachTests` can drive every branch without a view, a config
/// or a workflow on disk. `RegulatedMode` is the local precedent for the shape.
enum PrivacyReach {

    // MARK: - The rule

    /// Whether publishing through this sink leaves the machine, and what to call
    /// the place it lands.
    ///
    /// Obsidian and the filesystem sink write to a path on this Mac. Notion is a
    /// cloud service; a LAN share is off the machine too, and saying so matters
    /// even though it never touches the internet, because "on this Mac" is the
    /// claim the reader is checking.
    static func offMachineName(_ sink: WorkflowSink) -> String? {
        switch sink {
        case .notion:     return "Notion"
        case .lan:        return "the network share set in Integrations"
        case .obsidian:   return nil
        case .filesystem: return nil
        }
    }

    /// The sinks a meeting can actually reach, after the zero-egress clamp.
    ///
    /// Regulated mode collapses this to the filesystem sink for every meeting,
    /// whatever the workflow editors hold, because `apply_overrides` re-applies
    /// that fail-closed rather than trusting the daemon to have done it.
    static func reachableSinks(regulatedMode: Bool, workflowSinks: [WorkflowSink]) -> [WorkflowSink] {
        guard !regulatedMode else { return [.filesystem] }
        var seen: [WorkflowSink] = []
        for sink in workflowSinks where !seen.contains(sink) {
            seen.append(sink)
        }
        return seen
    }

    // MARK: - The copy

    /// The callout under the permission cards.
    ///
    /// - Parameters:
    ///   - configuredBackend: `summarization.backend`, raw, so a backend this
    ///     build has never heard of still produces an honest sentence instead of
    ///     falling through unnamed.
    ///   - regulatedMode: `modes.regulated_mode`.
    ///   - workflowSinks: every workflow's `effectiveSinks`, concatenated. Order
    ///     is preserved and duplicates dropped, so the sentence is stable across
    ///     renders.
    static func callout(configuredBackend: String, regulatedMode: Bool, sinks workflowSinks: [WorkflowSink]) -> String {
        [
            "Audio capture and transcription are fully on-device.",
            summarizationSentence(configuredBackend: configuredBackend, regulatedMode: regulatedMode),
            publishSentence(regulatedMode: regulatedMode, workflowSinks: workflowSinks),
        ].joined(separator: " ")
    }

    /// Where the transcript goes to be summarized.
    static func summarizationSentence(configuredBackend: String, regulatedMode: Bool) -> String {
        let effective = RegulatedMode.effectiveBackend(
            configured: configuredBackend, regulated: regulatedMode, workflowNDA: false
        )
        guard let engine = SummarizationEngine.resolve(effective) else {
            // An id this build cannot name: point at the control that owns it
            // rather than inventing a vendor, which is the failure being fixed.
            return "Summarizing sends the transcript to whichever backend Preferences ▸ Pipeline selects."
        }
        switch engine.locality {
        case .onDevice:
            return "Summaries are written here by \(engine.name), so no transcript leaves this Mac to be summarized."
        case .cloud:
            return "Summarizing sends the transcript to \(engine.name)."
        case .cloudThenLocal:
            // `auto` is a real configured value, not just a recorded one: it
            // tries the cloud first, so the cautious half is the one to say.
            return "Summarizing sends the transcript to \(SummarizationEngine.anthropic.name), falling back to \(SummarizationEngine.local.name) here when it cannot."
        }
    }

    /// Where the finished summary is published.
    static func publishSentence(regulatedMode: Bool, workflowSinks: [WorkflowSink]) -> String {
        let sinks = reachableSinks(regulatedMode: regulatedMode, workflowSinks: workflowSinks)
        guard !sinks.isEmpty else {
            return "No workflow publishes anywhere, so nothing is uploaded."
        }
        // Deduplicated by *name*, not by sink: two workflows publishing to two
        // different Notion databases are still one destination in a sentence
        // about where data goes, and `WorkflowSink.notion` carries its id.
        var offMachine: [String] = []
        var anyOnMachine = false
        for sink in sinks {
            guard let name = offMachineName(sink) else {
                anyOnMachine = true
                continue
            }
            if !offMachine.contains(name) { offMachine.append(name) }
        }
        guard !offMachine.isEmpty else {
            return "Publishing writes to this Mac only."
        }
        let rest = anyOnMachine ? " Your other destinations write to this Mac." : ""
        return "Publishing sends it to \(joined(offMachine))." + rest
    }

    /// "a", "a and b", "a, b and c". No serial comma, matching the workflow
    /// inspector's own list rows.
    private static func joined(_ items: [String]) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return "\(items[0]) and \(items[1])"
        default: return "\(items.dropLast().joined(separator: ", ")) and \(items[items.count - 1])"
        }
    }
}
