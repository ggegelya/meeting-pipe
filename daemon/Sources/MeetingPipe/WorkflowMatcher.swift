import Foundation

/// Resolves the active workflow for a detected meeting.
///
/// Precedence (highest specificity wins, ties break by `order` ascending):
///
///   1. Explicit override — the caller passed an `overrideID`. The
///      chevron menu in the prompt window writes this when the user
///      picks a non-default workflow before clicking Record.
///   2. Rule match — a workflow whose `matchingRules` contains an entry
///      matching the bundle id AND title. A rule with both fields matches
///      more specifically than one with only a bundle id, which matches
///      more specifically than one with only a title regex.
///   3. Default workflow — the one flagged `isDefault`. Always exists
///      after `WorkflowMigrator.runIfNeeded`.
///
/// The matcher is pure / deterministic; no I/O or async work. Returns
/// nil only when the store is empty (a state that should be impossible
/// after migration ran).
enum WorkflowMatcher {

    /// Compute the workflow for a `(source, override)` pair against the
    /// given workflow set. The set is taken as a plain array so tests
    /// can drive it without standing up a WorkflowStore.
    static func resolve(
        source: AppSource?,
        overrideID: UUID? = nil,
        workflows: [Workflow]
    ) -> Workflow? {
        if workflows.isEmpty { return nil }

        // 1. Explicit override pins the result regardless of rules.
        if let id = overrideID, let wf = workflows.first(where: { $0.id == id }) {
            return wf
        }

        // 2. Score every workflow by its best rule match. Higher score
        //    = more specific match. Workflows whose rules don't apply
        //    score 0 and become candidates only via the default path.
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
        // Last-resort: store has workflows but none is flagged default.
        // Return the lowest-ordered one so behaviour stays defined.
        return workflows.sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }.first
    }

    /// Best score across every rule in the workflow. 0 means no match;
    /// 3 = bundle + title regex match, 2 = bundle only, 1 = title only.
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
            // Empty rule: a manually-saved rule with no fields filled
            // can't match anything meaningfully — treat as "no signal"
            // and rely on the default fallback for empty-rule cases.
            return 0
        }
        guard let source = source else {
            // Manual recording — no source attribution. A title-only
            // rule can't possibly match an audio-only manual capture.
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
