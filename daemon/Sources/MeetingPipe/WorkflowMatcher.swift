import Foundation

/// Pure, deterministic resolver for the active workflow. Precedence (highest wins, ties by `order` asc): 1) explicit overrideID (set by the chevron menu before Record), 2) best rule match (bundle+title = 3, bundle-only = 2, title-only = 1), 3) the `isDefault` workflow. Returns nil only when the store is empty, which should be impossible after `WorkflowMigrator.runIfNeeded`.
enum WorkflowMatcher {

    /// Resolve the workflow for a (source, override) pair. Takes a plain array so tests can drive it without a WorkflowStore.
    static func resolve(
        source: AppSource?,
        overrideID: UUID? = nil,
        workflows: [Workflow]
    ) -> Workflow? {
        if workflows.isEmpty { return nil }

        // 1. Explicit override.
        if let id = overrideID, let wf = workflows.first(where: { $0.id == id }) {
            return wf
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
            return pick.workflow
        }

        // 3. Default fallback.
        if let def = workflows.first(where: { $0.isDefault }) {
            return def
        }
        // Last resort: no default flagged; return the lowest-ordered workflow so behaviour stays defined.
        return workflows.sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }.first
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
