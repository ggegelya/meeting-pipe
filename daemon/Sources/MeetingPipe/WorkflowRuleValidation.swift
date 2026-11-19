import Foundation

/// SEC21 items 3 and 11: what the Workflows editor saves from the rules it holds. Pure, so the
/// rule is tested here rather than through a sheet.
///
/// - A rule with both fields blank is dropped: it can never match (`WorkflowMatcher.ruleCanMatch`),
///   and keeping it made the inspector say "Any meeting" for a workflow the matcher never picks.
/// - A title regex that does not compile refuses the save, naming the pattern: the matcher scores
///   such a rule 0, so an NDA workflow keyed on it would silently fail open.
enum WorkflowRuleValidation {

    enum Problem: Error, Equatable {
        case regexDoesNotCompile(String)

        var message: String {
            switch self {
            case .regexDoesNotCompile(let pattern):
                return "The title pattern \"\(pattern)\" is not valid."
            }
        }
    }

    static func prepareForSave(_ rules: [WorkflowMatchingRule]) -> Result<[WorkflowMatchingRule], Problem> {
        var kept: [WorkflowMatchingRule] = []
        for var rule in rules {
            rule.bundleID = rule.bundleID.trimmingCharacters(in: .whitespaces)
            guard WorkflowMatcher.ruleCanMatch(rule) else { continue }
            if !rule.titleRegex.isEmpty, !WorkflowMatcher.regexCompiles(rule.titleRegex) {
                return .failure(.regexDoesNotCompile(rule.titleRegex))
            }
            kept.append(rule)
        }
        return .success(kept)
    }

    /// The caption under a rule's title field, or nil. An uncompilable regex says so; a title rule
    /// in an NDA workflow says it may never match, because the meeting's title is unknown at record
    /// start on nearly every recording (155 of 155 since 2026-09-01), and an NDA meeting the rule
    /// misses records under the default workflow (the owner's decision, 2026-11-16).
    static func caption(for rule: WorkflowMatchingRule, ndaMode: Bool) -> String? {
        guard !rule.titleRegex.isEmpty else { return nil }
        if !WorkflowMatcher.regexCompiles(rule.titleRegex) { return WorkflowRuleTitle.invalidPatternCaption }
        if ndaMode {
            return "Meeting titles are usually unknown when recording starts, so this title rule may match nothing; a meeting it misses records under the default workflow."
        }
        return nil
    }
}
