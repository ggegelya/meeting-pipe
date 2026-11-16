import Foundation

/// Pure, deterministic resolver for the active workflow. Precedence (highest wins, ties by `order` asc): 1) explicit overrideID (set by the chevron menu before Record), 2) best rule match (bundle+title = 3, bundle-only = 2, title-only = 1), 3) the `isDefault` workflow. Returns nil only when the store is empty, which should be impossible after `WorkflowMigrator.runIfNeeded`.
enum WorkflowMatcher {

    /// Why the matcher chose (SEC39, in the shape SEC21 plans to extend): an explicit override, a
    /// rule match and its score, or the fallback to the default.
    enum Reason: Equatable {
        case override
        case matched(score: Int)
        /// SEC21: `undecided` lists the NDA workflows that had a rule whose bundle id matched but
        /// whose title regex could not be evaluated (no title known, or a regex that does not
        /// compile). By the owner's decision (2026-11-16) this changes no capture posture: it is
        /// logged, not acted on, while meeting titles are unknown on nearly every recording.
        case fallback(undecided: [Workflow])

        static let fallback = Reason.fallback(undecided: [])
    }

    /// Resolve the workflow for a (source, override) pair. Takes a plain array so tests can drive it without a WorkflowStore.
    static func resolve(
        source: AppSource?,
        overrideID: UUID? = nil,
        workflows: [Workflow]
    ) -> Workflow? {
        resolveWithReason(source: source, overrideID: overrideID, workflows: workflows).workflow
    }

    /// `resolve`, plus why. Pure.
    static func resolveWithReason(
        source: AppSource?,
        overrideID: UUID? = nil,
        workflows: [Workflow]
    ) -> (workflow: Workflow?, reason: Reason) {
        if workflows.isEmpty { return (nil, .fallback) }

        // 1. Explicit override.
        if let id = overrideID, let wf = workflows.first(where: { $0.id == id }) {
            return (wf, .override)
        }

        // 2. Score by best rule match; 0 means no match.
        var best: (workflow: Workflow, score: Int)?
        for wf in workflows {
            let score = bestRuleScore(rules: wf.matchingRules, source: source)
            guard score > 0 else { continue }
            if let current = best {
                if score > current.score {
                    best = (wf, score)
                } else if score == current.score && wf.order < current.workflow.order {
                    best = (wf, score)
                }
            } else {
                best = (wf, score)
            }
        }
        if let pick = best {
            return (pick.workflow, .matched(score: pick.score))
        }

        // 3. Default fallback, naming the NDA workflows that could not be ruled out.
        let undecided = workflows.filter { $0.flags.ndaMode && hasUndecidedRule($0.matchingRules, source: source) }
        if let def = workflows.first(where: { $0.isDefault }) {
            return (def, .fallback(undecided: undecided))
        }
        // Last resort: no default flagged; return the lowest-ordered workflow so behaviour stays defined.
        return (workflows.sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }.first, .fallback(undecided: undecided))
    }

    /// SEC21: a rule whose bundle id matched this source but whose title regex could not be
    /// evaluated, because no title is known or the regex does not compile. A title-only rule
    /// (blank bundle) is never undecided, by the owner's decision: with titles unknown on nearly
    /// every recording it would put every meeting with a source in that state.
    static func hasUndecidedRule(_ rules: [WorkflowMatchingRule], source: AppSource?) -> Bool {
        guard let source else { return false }
        return rules.contains { rule in
            guard !rule.bundleID.isEmpty, rule.bundleID == source.bundleID, !rule.titleRegex.isEmpty else { return false }
            let titleUnknown = (source.meetingTitle ?? "").isEmpty
            return titleUnknown || !regexCompiles(rule.titleRegex)
        }
    }

    /// Whether a title regex compiles under the matcher's own options. The editor refuses a save
    /// that fails this, and the inspector flags a stored rule that fails it.
    static func regexCompiles(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) != nil
    }

    /// SEC21 item 11: whether a rule can ever score above 0. A rule with both fields blank cannot.
    static func ruleCanMatch(_ rule: WorkflowMatchingRule) -> Bool {
        !rule.bundleID.isEmpty || !rule.titleRegex.isEmpty
    }

    /// SEC21 item 11: whether any of a workflow's rules can ever match, which is what the
    /// inspector's Trigger row and the editor's save read, so they cannot disagree with the matcher.
    static func canEverMatch(_ workflow: Workflow) -> Bool {
        workflow.matchingRules.contains(where: ruleCanMatch)
    }

    /// SEC39: which workflow a resumed recording records under. END17's resume used to pin the
    /// previous recording's workflow as an override, outranking the new call's own rule match with
    /// no NDA floor. Now a rule match wins; otherwise the previous workflow carries over, unless the
    /// fallback is NDA and the previous is not; a deleted previous workflow falls to the matcher.
    /// `source` names why, for `recording_resumed_after_end`. Pure.
    static func resumeWorkflow(
        matched: Workflow?,
        reason: Reason,
        previous: Workflow?
    ) -> (workflow: Workflow?, source: String) {
        if case .matched = reason { return (matched, "rule") }
        guard let previous else { return (matched, "default") }
        if (matched?.flags.ndaMode ?? false) && !previous.flags.ndaMode { return (matched, "nda_floor") }
        return (previous, "previous")
    }

    /// Best score across the workflow's rules. 0 = no match; 1 = title only; 2 = bundle only; 3 = bundle + title.
    private static func bestRuleScore(rules: [WorkflowMatchingRule], source: AppSource?) -> Int {
        var best = 0
        for rule in rules {
            let score = ruleScore(rule, source: source)
            if score > best { best = score }
        }
        return best
    }

    private static func ruleScore(_ rule: WorkflowMatchingRule, source: AppSource?) -> Int {
        let bundleSet = !rule.bundleID.isEmpty
        let regexSet = !rule.titleRegex.isEmpty
        if !bundleSet && !regexSet {
            // Empty rule (no fields filled) can't match anything; rely on the default.
            return 0
        }
        guard let source = source else {
            // Manual recording has no source, so no rule can match.
            return 0
        }
        if bundleSet && rule.bundleID != source.bundleID { return 0 }
        if regexSet {
            guard let title = source.meetingTitle, !title.isEmpty else { return 0 }
            if !titleMatches(regex: rule.titleRegex, in: title) { return 0 }
        }
        if bundleSet && regexSet { return 3 }
        if bundleSet { return 2 }
        return 1
    }

    private static func titleMatches(regex pattern: String, in title: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return re.firstMatch(in: title, options: [], range: range) != nil
    }
}
