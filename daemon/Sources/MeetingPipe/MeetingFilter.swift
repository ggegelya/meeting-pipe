import Foundation

/// Filter state for the library list (TECH-A14). Pure value type; SwiftUI re-runs it trivially and tests drive every branch without rendering. FTS5 over full transcripts shipped as UX16 (the retired TECH-A3 upgrade path): `MeetingFilterEngine.apply` takes the FTS candidate stems, the chips stay in-memory equality filters. `Codable` since UX24, which persists a filter inside a saved smart folder.
struct MeetingFilter: Equatable, Codable {
    var query: String = ""
    var workflow: String? = nil           // nil = any
    var sourceBundleID: String? = nil     // nil = any
    var status: Meeting.Status? = nil     // nil = any
    var dateRange: DateRange = .all

    enum DateRange: String, CaseIterable, Identifiable {
        case all = "All time"
        case today = "Today"
        case week = "Last 7 days"
        case month = "Last 30 days"
        case year = "This year"

        var id: String { rawValue }
    }

    /// True when no filter is active; the view uses this to skip a redundant pass over the meetings array.
    var isEmpty: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && workflow == nil
            && sourceBundleID == nil
            && status == nil
            && dateRange == .all
    }

    /// Compose a refinement over a base filter (UX24, saving from inside a saved
    /// folder). A live chip wins where it is set; the two free-text queries AND
    /// together, since `MeetingFilterEngine.tokenize` splits on whitespace and every
    /// token has to match. This mirrors what the user is looking at, where the folder's
    /// filter and the live filter run one after the other.
    static func refining(_ base: MeetingFilter, with live: MeetingFilter) -> MeetingFilter {
        let queries = [base.query, live.query]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return MeetingFilter(
            query: queries.joined(separator: " "),
            workflow: live.workflow ?? base.workflow,
            sourceBundleID: live.sourceBundleID ?? base.sourceBundleID,
            status: live.status ?? base.status,
            dateRange: live.dateRange == .all ? base.dateRange : live.dateRange
        )
    }
}

/// Stable on-disk tokens for `DateRange`, decoupled from `rawValue` because that
/// doubles as the chip's menu label (UX24): rewording "Last 7 days" must not orphan a
/// saved folder. An unrecognised token decodes to `.all` rather than throwing, so a
/// hand-edited `saved_searches.json` degrades to a wider view instead of dropping the
/// folder entirely.
extension MeetingFilter.DateRange: Codable {
    private var token: String {
        switch self {
        case .all:   return "all"
        case .today: return "today"
        case .week:  return "week"
        case .month: return "month"
        case .year:  return "year"
        }
    }

    init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "today": self = .today
        case "week":  self = .week
        case "month": self = .month
        case "year":  self = .year
        default:      self = .all
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }
}

/// Pure filter applier, split out so tests can drive it without SwiftUI.
enum MeetingFilterEngine {
    /// `ftsMatches` (UX16): the stems the FTS5 index matched for `filter.query`, or nil to search
    /// in-memory only (empty query, or the index is unavailable). Chips + date stay in-memory
    /// equality filters; only the free-text branch consults FTS. Defaulted so the pre-FTS callers
    /// and the contract tests drive it unchanged.
    static func apply(
        _ filter: MeetingFilter,
        to meetings: [Meeting],
        ftsMatches: Set<String>? = nil,
        now: Date = Date()
    ) -> [Meeting] {
        if filter.isEmpty { return meetings }
        let trimmed = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needles = tokenize(trimmed)
        let cutoff = dateCutoff(filter.dateRange, now: now)
        return meetings.filter { m in
            if let wf = filter.workflow, m.workflowName != wf { return false }
            if let bid = filter.sourceBundleID, m.sourceBundleID != bid { return false }
            if let st = filter.status, m.status != st { return false }
            if let cut = cutoff, m.startedAt < cut { return false }
            if !needles.isEmpty && !matchesQuery(m, needles: needles, ftsMatches: ftsMatches) { return false }
            return true
        }
    }

    /// A meeting matches the free-text query when the FTS index matched it (transcript depth) OR its
    /// in-memory corpus contains every token (UX16). The in-memory arm keeps title/summary search
    /// working before the index catches up and covers a stem the index hasn't reached; the FTS arm
    /// adds full-transcript reach. Union, so search never regresses below the pre-FTS behaviour.
    static func matchesQuery(_ m: Meeting, needles: [String], ftsMatches: Set<String>?) -> Bool {
        if let ftsMatches, ftsMatches.contains(m.stem) { return true }
        let hay = m.searchableText
        return needles.allSatisfy { hay.contains($0) }
    }

    /// Lowercases, splits on whitespace, drops empties. ANDs at the call site ("client zoom" requires both words).
    static func tokenize(_ query: String) -> [String] {
        return query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func dateCutoff(_ range: MeetingFilter.DateRange, now: Date) -> Date? {
        let cal = Calendar.current
        switch range {
        case .all:
            return nil
        case .today:
            return cal.startOfDay(for: now)
        case .week:
            return cal.date(byAdding: .day, value: -7, to: now)
        case .month:
            return cal.date(byAdding: .day, value: -30, to: now)
        case .year:
            return cal.date(
                from: cal.dateComponents([.year], from: now)
            )
        }
    }
}

// MARK: - Facet derivation

/// Distinct facet values for filter chips. Recomputed on every list change; cheap given the library's row count.
struct MeetingFacets: Equatable {
    let workflows: [String]            // distinct workflow names, sorted
    let sources: [SourceFacet]         // distinct source apps, sorted by display name

    struct SourceFacet: Hashable, Identifiable {
        let bundleID: String
        let displayName: String

        var id: String { bundleID }
    }

    static func build(from meetings: [Meeting]) -> MeetingFacets {
        var wfSet = Set<String>()
        var srcMap: [String: String] = [:]
        for m in meetings {
            if let w = m.workflowName, !w.isEmpty { wfSet.insert(w) }
            if let bid = m.sourceBundleID, !bid.isEmpty {
                let name = m.sourceDisplayName ?? bid
                srcMap[bid] = name
            }
        }
        let sources = srcMap
            .map { SourceFacet(bundleID: $0.key, displayName: $0.value) }
            .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
        return MeetingFacets(
            workflows: wfSet.sorted { $0.lowercased() < $1.lowercased() },
            sources: sources
        )
    }
}
