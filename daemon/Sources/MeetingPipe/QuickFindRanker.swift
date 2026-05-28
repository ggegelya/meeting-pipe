import Foundation

/// Pure-logic ranker for the quick-find panel (TECH-A3). Split from the view so XCTest can exercise ranking directly.
enum QuickFindRanker {

    /// A scored result. `hitField` is shown as a subtitle so the user can see why the result surfaced.
    struct Match: Equatable {
        let meeting: Meeting
        let score: Double
        /// e.g. "title", "workflow", "summary". Display-only.
        let hitField: String

        /// Stable identity so ForEach doesn't recompute on each keystroke.
        var id: String { meeting.stem }
    }

    /// Field-weight schedule. Higher weight = stronger match signal; prefix beats substring within a field.
    private static let fieldWeights: [(field: String, weight: Double)] = [
        ("title", 100),
        ("source", 40),
        ("workflow", 30),
        ("summary", 20),
    ]

    /// Recency bias added to the field score, falling off linearly over `recencyHalfLifeDays`.
    private static let recencyMaxBonus: Double = 8
    private static let recencyHalfLifeDays: Double = 365

    /// Trims, lowercases, collapses whitespace. Returns nil for empty input so callers can skip ranking and show recents.
    static func normalizeQuery(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed.lowercased()
    }

    /// Top-N matches. Empty query returns the newest `limit` meetings unscored.
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
        // Stable sort: score desc, then recency desc, then stem desc so equal scores are deterministic across renders.
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

    /// Scores one meeting against a normalized query. Returns nil when no field matches (row is dropped).
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
            // Search raw title fields (summary > meta) without paying formatter cost per keystroke.
            var parts: [String] = []
            if let s = m.summaryTitle, !s.isEmpty { parts.append(s) }
            if let s = m.meetingTitle, !s.isEmpty { parts.append(s) }
            return parts.isEmpty ? nil : parts.joined(separator: " ").lowercased()
        case "source":
            return m.sourceDisplayName?.lowercased()
        case "workflow":
            return m.workflowName?.lowercased()
        case "summary":
            return m.searchableText.isEmpty ? nil : m.searchableText // already lowercased + concatenated
        default:
            return nil
        }
    }

    /// Scores `query` against `haystack` (both pre-normalized), or nil for no match.
    private static func scoreField(query q: String, haystack hay: String, weight: Double) -> Double? {
        if hay.hasPrefix(q) {
            return weight * 1.5  // prefix beats substring
        }
        if hay.contains(q) {
            return weight
        }
        // Word-boundary boost: catches matches that aren't a prefix of the whole field.
        for sep: Character in [" ", "\n", "(", "[", "-"] {
            if hay.contains(String(sep) + q) { return weight * 1.2 }
        }
        return nil
    }
}
