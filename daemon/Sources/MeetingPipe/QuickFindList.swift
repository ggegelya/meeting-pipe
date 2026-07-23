import Foundation

/// UX25: one row in the Quick Find panel. Either a ranked meeting or the "Ask about …"
/// handoff that sends the typed query to the Library's Ask rail.
enum QuickFindItem: Equatable {
    case meeting(QuickFindRanker.Match)
    case ask(question: String)

    /// Stable identity so `ForEach` doesn't rebuild the whole list on each keystroke.
    /// Namespaced so a meeting whose stem is literally `ask` cannot collide with the row.
    var id: String {
        switch self {
        case .meeting(let m): return "meeting:" + m.id
        case .ask: return "ask"
        }
    }
}

/// UX25: assembles the Quick Find list from the ranked meetings plus the Ask handoff row.
///
/// Pure and split from `QuickFindRanker` so the placement rule is unit-testable without the
/// panel. Quick Find and Ask are one story from the user's side: typing a question into
/// Cmd+K should reach a cited answer, not a "no matches" dead end that only pays off if you
/// happen to know the Library has a separate rail for questions.
enum QuickFindList {

    /// A query is question-shaped when it ends in `?` after trimming. Deliberately the one
    /// unambiguous signal: a leading question word ("how", "what") opens as many meeting
    /// titles as it does questions, and a wrong lead turns Return into the wrong action.
    /// Without the mark the row is still offered, just under the results (and ⌘↩ always
    /// reaches it), so nothing becomes unreachable, only unranked.
    static func isQuestionShaped(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
    }

    /// Rows for the panel. An empty query is the recents list with no Ask row, since there
    /// is no question to hand off. Otherwise the Ask row leads when the query is
    /// question-shaped (so Return alone runs it) and trails the results when it is not.
    static func items(query: String, matches: [QuickFindRanker.Match]) -> [QuickFindItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = matches.map(QuickFindItem.meeting)
        guard !q.isEmpty else { return rows }
        let ask = QuickFindItem.ask(question: q)
        return isQuestionShaped(q) ? [ask] + rows : rows + [ask]
    }
}
