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

    /// The query's tokens: lowercased, split on whitespace, empties dropped, by the filter bar's own
    /// tokenizer (`MeetingFilterEngine.tokenize`, UX103), so "client zoom" means both words anywhere
    /// here exactly as it does there, and a double space is no different from one. Nil for a query
    /// with no tokens, so callers can skip ranking and show recents.
    static func normalizeQuery(_ raw: String) -> [String]? {
        let tokens = MeetingFilterEngine.tokenize(raw)
        return tokens.isEmpty ? nil : tokens
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
        guard let tokens = normalizeQuery(rawQuery) else {
            return meetings
                .prefix(limit)
                .map { Match(meeting: $0, score: 0, hitField: "recent") }
        }
        var out: [Match] = []
        out.reserveCapacity(min(limit, meetings.count))
        for m in meetings {
            if let match = score(tokens: tokens, against: m, now: now, titles: titles) {
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

    /// Scores one meeting against a normalized query's tokens. Returns nil when the tokens are not all
    /// found (row is dropped). The best single field holding every token wins; failing that, tokens
    /// split across fields (UX103: "client" in the title, "zoom" in the summary) match at the lowest
    /// weight among the fields they were found in, so the in-memory set is never smaller than the
    /// filter bar's, whose haystack (`searchableText`) is the summary field here.
    /// `titles` (PERF20) is a stem-to-lowercased-title map the caller built once per scan; a stem
    /// missing from it, or a nil map, lowercases the title here.
    static func score(tokens: [String], against m: Meeting, now: Date, titles: [String: String]? = nil) -> Match? {
        var best: (score: Double, field: String)? = nil
        var hays: [(field: String, weight: Double, hay: String)] = []

        for (field, weight) in fieldWeights {
            let cached = field == "title" ? titles?[m.stem] : nil
            guard let hay = cached ?? haystack(for: field, of: m) else { continue }
            hays.append((field, weight, hay))
            if let s = scoreField(tokens: tokens, haystack: hay, weight: weight) {
                if best == nil || s > best!.score {
                    best = (s, field)
                }
            }
        }
        if best == nil, tokens.count > 1 {
            best = splitAcrossFields(tokens: tokens, hays: hays)
        }
        guard let b = best else { return nil }

        let ageDays = max(now.timeIntervalSince(m.startedAt) / 86_400, 0)
        let bonus = max(0, recencyMaxBonus * (1 - min(ageDays / recencyHalfLifeDays, 1)))
        return Match(meeting: m, score: b.score + bonus, hitField: b.field)
    }

    /// UX103: every token is in some field but no field holds them all. Each token takes the
    /// highest-weight field that holds it, and the match scores the lowest of those weights, plain
    /// (no prefix or word-boundary tier), named after that field.
    private static func splitAcrossFields(
        tokens: [String], hays: [(field: String, weight: Double, hay: String)]
    ) -> (score: Double, field: String)? {
        var lowest: (score: Double, field: String)? = nil
        for token in tokens {
            // `fieldWeights` is in descending weight order, so the first holder is the strongest.
            guard let holder = hays.first(where: { $0.hay.contains(token) }) else { return nil }
            if lowest == nil || holder.weight < lowest!.score {
                lowest = (holder.weight, holder.field)
            }
        }
        return lowest
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

    /// Scores the query's tokens against `haystack` (both pre-normalized), or nil unless the field
    /// holds every token. Three tiers: the field starts with the first token (1.5x), every token
    /// starts a word (1.2x), anywhere (1x). A one-token query scores exactly as before UX103.
    ///
    /// PERF20: the word-boundary check used to run only after `contains(q)` had failed, where it
    /// cannot succeed, so the 1.2x tier was unreachable and a non-matching field paid five extra
    /// passes over its haystack. It now runs once the field is known to hold the tokens, which is
    /// the boost the comment always described.
    static func scoreField(tokens: [String], haystack hay: String, weight: Double) -> Double? {
        guard let first = tokens.first, tokens.allSatisfy({ hay.contains($0) }) else { return nil }
        if hay.hasPrefix(first) {
            return weight * 1.5  // prefix beats substring
        }
        // Word-boundary boost: every token starts a word, though the field does not start with the query.
        if tokens.allSatisfy({ startsWord($0, in: hay) }) {
            return weight * 1.2
        }
        return weight
    }

    private static func startsWord(_ token: String, in hay: String) -> Bool {
        if hay.hasPrefix(token) { return true }
        for sep: Character in [" ", "\n", "(", "[", "-"] where hay.contains(String(sep) + token) {
            return true
        }
        return false
    }
}
