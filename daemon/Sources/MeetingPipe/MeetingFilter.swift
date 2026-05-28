import Foundation

/// Filter state for the library list (TECH-A14). Pure value type; SwiftUI re-runs it trivially and tests drive every branch without rendering. FTS5 over full transcripts is the TECH-A3 upgrade path; nothing here blocks it.
struct MeetingFilter: Equatable {
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
}

/// Pure filter applier, split out so tests can drive it without SwiftUI.
enum MeetingFilterEngine {
    static func apply(
        _ filter: MeetingFilter,
        to meetings: [Meeting],
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
            if !needles.isEmpty {
                let hay = m.searchableText
                for n in needles {
                    if !hay.contains(n) { return false }
                }
            }
            return true
        }
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
