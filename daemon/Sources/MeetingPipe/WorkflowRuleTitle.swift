import Foundation
import os

/// How a workflow rule's title field is edited (UX88). The stored value stays `title_regex`, read
/// by `WorkflowMatcher` unchanged, so no schema moves and every existing rule keeps matching.
///
/// **Title contains** is the default: what the user types is stored as
/// `NSRegularExpression.escapedPattern(for:)` of it, so `Q3 (EU) planning [draft]` matches that
/// literal title (case-insensitive, as the matcher compiles) instead of failing to compile on its
/// brackets. **Use a pattern** keeps the raw regular expression for power users. A stored rule
/// opens in contains mode only when it is exactly an escaped literal (`isLiteral`), so a hand
/// written regex is never shown, or re-saved, as if it were plain text.
enum WorkflowRuleTitle {
    /// The stored pattern for a "title contains" input.
    static func storedPattern(contains text: String) -> String {
        NSRegularExpression.escapedPattern(for: text)
    }

    /// The plain text a stored pattern stands for, or nil when it is not an escaped literal.
    /// A round trip, so it agrees with `escapedPattern(for:)` by construction: strip each
    /// backslash escape, escape the result again, and compare. `a\.b` is a literal `a.b`; `a.b`
    /// and `Q3.*` are patterns.
    static func literalText(of stored: String) -> String? {
        var out = ""
        var escaping = false
        for ch in stored {
            if escaping {
                out.append(ch)
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        if escaping { return nil }
        return storedPattern(contains: out) == stored ? out : nil
    }

    static func isLiteral(_ stored: String) -> Bool { literalText(of: stored) != nil }

    /// Whether a rule opens with **Use a pattern** on: a non-empty stored regex that is not an
    /// escaped literal.
    static func opensInPatternMode(_ stored: String) -> Bool {
        !stored.isEmpty && !isLiteral(stored)
    }

    /// The inline message under a pattern-mode field that does not compile (UX88). Shared with
    /// `WorkflowRuleValidation.caption`, so the row and the save refusal say the same thing.
    static let invalidPatternCaption = "This pattern is not valid."
}

/// UX88: a stored title rule that does not compile scores 0 in `WorkflowMatcher` and so never
/// matches, and a rule hand-edited into a workflow TOML never passes the editor's validation.
/// This writes one `workflow` / `rule_regex_invalid` row the first time each such rule is seen at a
/// record start, keyed on the workflow and the pattern so it is once per rule per process, not per
/// meeting. The row names the workflow and the rule's position, never the pattern: a title rule
/// can carry a client or project name, and titles are never logged.
///
/// Kept out of `WorkflowMatcher.resolve`, which stays pure: the record-start call site asks this
/// beside it. The sink is injectable so a test never writes the real event log.
final class RuleRegexReporter: Sendable {
    typealias Sink = @Sendable (_ workflowID: String, _ ruleIndex: Int) -> Void

    static let shared = RuleRegexReporter { workflowID, ruleIndex in
        Log.event(category: "workflow", action: "rule_regex_invalid", attributes: [
            "workflow_id": workflowID,
            "rule_index": ruleIndex,
        ])
    }

    private let seen = OSAllocatedUnfairLock(initialState: Set<String>())
    private let sink: Sink

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    /// Report every stored rule whose title regex does not compile, once each.
    func report(_ workflows: [Workflow]) {
        for workflow in workflows {
            for (index, rule) in workflow.matchingRules.enumerated()
            where !rule.titleRegex.isEmpty && !WorkflowMatcher.regexCompiles(rule.titleRegex) {
                let key = "\(workflow.id.uuidString)|\(rule.titleRegex)"
                let isNew = seen.withLock { $0.insert(key).inserted }
                if isNew { sink(workflow.id.uuidString, index) }
            }
        }
    }
}
