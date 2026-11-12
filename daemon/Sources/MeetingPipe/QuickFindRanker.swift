import Foundation

/// Pure-logic ranker for the quick-find panel (TECH-A3, its FTS5 index shipped as UX16). Split from the view so XCTest can exercise ranking directly; `ftsMatches` adds transcript-depth matches on top of the field-weight ranking.
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

    /// UX16: baseline score for a meeting the FTS index matched (on its transcript) that no in-memory
    /// field matched. Below the lowest field weight (summary = 20) so field matches always rank above.
    private static let transcriptBaseline: Double = 10

    /// Trims, lowercases, collapses whitespace. Returns nil for empty input so callers can skip ranking and show recents.
    static func normalizeQuery(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed.lowercased()
    }

    /// Top-N matches. Empty query returns the newest `limit` meetings unscored. `ftsMatches` (UX16)
    /// are stems the FTS index matched (on transcript depth); one that no in-memory field matched is
    /// surfaced below the field matches with a transcript baseline, so Quick Find searches full
    /// transcripts too. Defaulted empty so the ranking tests drive it unchanged.
    static func rank(
        query rawQuery: String,
        in meetings: [Meeting],
        ftsMatches: Set<String> = [],
        limit: Int = 50,
        now: Date = Date(),
        titles: [String: String]? = nil
    ) -> [Match] {
        guard let q = normalizeQuery(rawQuery) else {
            return meetings
                .prefix(limit)
                .map { Match(meeting: $0, score: 0, hitField: "recent") }
        }
        var out: [Match] = []
        out.reserveCapacity(min(limit, meetings.count))
        for m in meetings {
            if let match = score(query: q, against: m, now: now, titles: titles) {
                out.append(match)
            } else if ftsMatches.contains(m.stem) {
                let ageDays = max(now.timeIntervalSince(m.startedAt) / 86_400, 0)
                let bonus = max(0, recencyMaxBonus * (1 - min(ageDays / recencyHalfLifeDays, 1)))
                out.append(Match(meeting: m, score: transcriptBaseline + bonus, hitField: "transcript"))
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
    /// `titles` (PERF20) is a stem-to-lowercased-title map the caller built once per scan; a stem
    /// missing from it, or a nil map, lowercases the title here.
    static func score(query q: String, against m: Meeting, now: Date, titles: [String: String]? = nil) -> Match? {
        var best: (score: Double, field: String)? = nil

        for (field, weight) in fieldWeights {
            let cached = field == "title" ? titles?[m.stem] : nil
            guard let hay = cached ?? haystack(for: field, of: m) else { continue }
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
            return titleHaystack(of: m)
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

    /// The lowercased title haystack (summary title, then meta title), or nil when the meeting has
    /// neither. Raw fields, so no formatter cost. `QuickFindModel` caches it per store revision.
    static func titleHaystack(of m: Meeting) -> String? {
        var parts: [String] = []
        if let s = m.summaryTitle, !s.isEmpty { parts.append(s) }
        if let s = m.meetingTitle, !s.isEmpty { parts.append(s) }
        return parts.isEmpty ? nil : parts.joined(separator: " ").lowercased()
    }

    /// Scores `query` against `haystack` (both pre-normalized), or nil for no match. Three tiers:
    /// a prefix of the whole field (1.5x), a match at a word boundary (1.2x), anywhere (1x).
    ///
    /// PERF20: the word-boundary check used to run only after `contains(q)` had failed, where it
    /// cannot succeed, so the 1.2x tier was unreachable and a non-matching field paid five extra
    /// passes over its haystack. It now runs inside the `contains` branch, which is the boost the
    /// comment always described.
    static func scoreField(query q: String, haystack hay: String, weight: Double) -> Double? {
        if hay.hasPrefix(q) {
            return weight * 1.5  // prefix beats substring
        }
        guard hay.contains(q) else { return nil }
        // Word-boundary boost: a match that starts a word, though not the whole field.
        for sep: Character in [" ", "\n", "(", "[", "-"] where hay.contains(String(sep) + q) {
            return weight * 1.2
        }
        return weight
    }
}
