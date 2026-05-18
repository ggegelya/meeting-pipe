import Foundation

/// Pure-logic ranker for the menu-bar quick-find panel (TECH-A3).
/// Scores every meeting against a search query and returns the top
/// matches in descending order. Splitting this out from the view lets
/// XCTest hammer the ranking without touching SwiftUI.
enum QuickFindRanker {

    /// A scored result, paired with the field that produced the best
    /// hit. The field is shown as a subtitle in the UI so the user can
    /// tell why the result surfaced.
    struct Match: Equatable {
        let meeting: Meeting
        let score: Double
        /// e.g. "title", "workflow", "summary". Display-only.
        let hitField: String

        /// Stable so the list view can ForEach without recomputing
        /// identity from the meeting + score on each keystroke.
        var id: String { meeting.stem }
    }

    /// Field-weight schedule. Higher = stronger field. Within a field,
    /// a prefix match scores higher than a substring match.
    private static let fieldWeights: [(field: String, weight: Double)] = [
        ("title", 100),
        ("source", 40),
        ("workflow", 30),
        ("summary", 20),
    ]

    /// Recency bias: a meeting from today scores `recencyMaxBonus`
    /// over an otherwise-identical meeting from a year ago, falling
    /// off linearly across `recencyHalfLifeDays`.
    private static let recencyMaxBonus: Double = 8
    private static let recencyHalfLifeDays: Double = 365

    /// Trim, lowercase, collapse repeated whitespace. Empty query
    /// returns nil so callers can short-circuit (the panel renders the
    /// most-recent meetings when there's nothing typed yet).
    static func normalizeQuery(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed.lowercased()
    }

    /// Top-N matches for `query` against `meetings`. Empty query
    /// returns the newest `limit` meetings unchanged, no scoring.
    static func rank(
        query rawQuery: String,
        in meetings: [Meeting],
        limit: Int = 50,
        now: Date = Date()
    ) -> [Match] {
        guard let q = normalizeQuery(rawQuery) else {
            return meetings
                .prefix(limit)
                .map { Match(meeting: $0, score: 0, hitField: "recent") }
        }
        var out: [Match] = []
        out.reserveCapacity(min(limit, meetings.count))
        for m in meetings {
            if let match = score(query: q, against: m, now: now) {
                out.append(match)
            }
        }
        // Stable sort: score desc, then recency desc, then stem desc
        // so equal scores still come out the same order across renders.
        out.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.meeting.startedAt != rhs.meeting.startedAt {
                return lhs.meeting.startedAt > rhs.meeting.startedAt
            }
            return lhs.meeting.stem > rhs.meeting.stem
        }
        if out.count > limit { return Array(out.prefix(limit)) }
        return out
    }

    /// Score one meeting against a normalized query. nil means
    /// no field matched; the row is dropped.
    static func score(query q: String, against m: Meeting, now: Date) -> Match? {
        var best: (score: Double, field: String)? = nil

        for (field, weight) in fieldWeights {
            guard let hay = haystack(for: field, of: m) else { continue }
            if let s = scoreField(query: q, haystack: hay, weight: weight) {
                if best == nil || s > best!.score {
                    best = (s, field)
                }
            }
        }
        guard let b = best else { return nil }

        let ageDays = max(now.timeIntervalSince(m.startedAt) / 86_400, 0)
        let bonus = max(0, recencyMaxBonus * (1 - min(ageDays / recencyHalfLifeDays, 1)))
        return Match(meeting: m, score: b.score + bonus, hitField: b.field)
    }

    private static func haystack(for field: String, of m: Meeting) -> String? {
        switch field {
        case "title":
            // Display title is summary > meta > "{source} at HH:mm".
            // Searching the raw fields covers all three without paying
            // formatter cost per keystroke.
            var parts: [String] = []
            if let s = m.summaryTitle, !s.isEmpty { parts.append(s) }
            if let s = m.meetingTitle, !s.isEmpty { parts.append(s) }
            return parts.isEmpty ? nil : parts.joined(separator: " ").lowercased()
        case "source":
            return m.sourceDisplayName?.lowercased()
        case "workflow":
            return m.workflowName?.lowercased()
        case "summary":
            // searchableText is already lowercased + concatenated.
            return m.searchableText.isEmpty ? nil : m.searchableText
        default:
            return nil
        }
    }

    /// Returns a score for `query` against `haystack`, or nil if no
    /// match. Both inputs are already normalized.
    private static func scoreField(query q: String, haystack hay: String, weight: Double) -> Double? {
        if hay.hasPrefix(q) {
            return weight * 1.5  // prefix beats substring
        }
        if hay.contains(q) {
            return weight
        }
        // Word-boundary boost: cheap check for " <q>" / "\n<q>" / "(<q>"
        // catches matches that aren't a prefix of the whole field.
        for sep: Character in [" ", "\n", "(", "[", "-"] {
            if hay.contains(String(sep) + q) { return weight * 1.2 }
        }
        return nil
    }
}
