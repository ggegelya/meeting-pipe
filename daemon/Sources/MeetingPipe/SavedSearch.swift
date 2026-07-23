import Foundation

/// A named rail scope the user saved (UX24): a base scope plus the filter-bar state
/// that was active when they saved it. `SavedSearchStore` persists it, so it survives
/// a restart and narrows the list exactly like a built-in `LibraryScope`.
///
/// `base` is a restricted subset of `LibraryScope` on purpose. The projection rails
/// (`.facts` / `.ask` / `.digests`) have no meeting list to save; `.workflow` folds
/// into the filter's workflow chip, so a folder never pins a workflow id that a
/// delete could orphan; and `.saved` is excluded so a folder can never reference
/// another folder.
struct SavedSearch: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var base: Base
    var filter: MeetingFilter
    /// Rail display order. Ties break on case-insensitive name.
    var order: Int

    init(
        id: UUID = UUID(),
        name: String,
        base: Base = .allMeetings,
        filter: MeetingFilter,
        order: Int = 0
    ) {
        self.id = id
        self.name = name
        self.base = base
        self.filter = filter
        self.order = order
    }

    /// The saveable half of `LibraryScope`. Raw values are the case names, which are
    /// on-disk tokens rather than display text, so a rail label can be reworded
    /// without orphaning a saved folder.
    enum Base: String, Codable, CaseIterable {
        case allMeetings
        case today
        case last7Days
        case last30Days
        case needsYou
        case ndaOnly
        case untagged

        var scope: LibraryScope {
            switch self {
            case .allMeetings: return .allMeetings
            case .today:       return .today
            case .last7Days:   return .last7Days
            case .last30Days:  return .last30Days
            case .needsYou:    return .needsYou
            case .ndaOnly:     return .ndaOnly
            case .untagged:    return .untagged
            }
        }

        /// The base a rail scope collapses to, or nil when the scope carries no
        /// plain meeting list (`.workflow` and `.saved` need the stores to resolve,
        /// so `SavedSearch.capture` handles those two).
        init?(scope: LibraryScope) {
            switch scope {
            case .allMeetings: self = .allMeetings
            case .today:       self = .today
            case .last7Days:   self = .last7Days
            case .last30Days:  self = .last30Days
            case .needsYou:    self = .needsYou
            case .ndaOnly:     self = .ndaOnly
            case .untagged:    self = .untagged
            case .facts, .ask, .digests, .workflow, .saved: return nil
            }
        }
    }

    /// This folder's rail scope.
    var scope: LibraryScope { .saved(id) }

    /// Pure: the meetings this folder selects. The base scope narrows first, then the
    /// saved chips and query, which is the same order the live rail plus filter bar
    /// apply. `ftsMatches` is the FTS5 candidate set for `filter.query` (UX16), or nil
    /// to fall back to the in-memory corpus.
    func apply(
        to meetings: [Meeting],
        workflows: [Workflow],
        ftsMatches: Set<String>? = nil,
        now: Date = Date()
    ) -> [Meeting] {
        let scoped = meetings.filter { base.scope.includes($0, workflows: workflows, now: now) }
        return MeetingFilterEngine.apply(filter, to: scoped, ftsMatches: ftsMatches, now: now)
    }

    /// Fold the view the user is looking at (rail scope + live filter chips) into a
    /// saveable folder. Returns nil when there is nothing to save: a projection rail,
    /// an unresolvable scope, or a blank name.
    ///
    /// A workflow scope becomes `.allMeetings` plus the workflow chip. The chip is only
    /// filled when unset, and it cannot already disagree with the scope: `MeetingFacets`
    /// are built from the *scoped* meetings, so inside workflow B the chip menu only
    /// offers B. Refining a saved folder inherits that folder's base and filter, with
    /// the live chips winning and the two queries ANDing (`MeetingFilter.refining`).
    static func capture(
        name: String,
        scope: LibraryScope,
        liveFilter: MeetingFilter,
        workflows: [Workflow],
        savedSearches: [SavedSearch],
        order: Int
    ) -> SavedSearch? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let base: Base
        var filter = liveFilter
        switch scope {
        case .facts, .ask, .digests:
            return nil
        case .workflow(let id):
            guard let wf = workflows.first(where: { $0.id == id }) else { return nil }
            base = .allMeetings
            if filter.workflow == nil { filter.workflow = wf.name }
        case .saved(let id):
            guard let parent = savedSearches.first(where: { $0.id == id }) else { return nil }
            base = parent.base
            filter = MeetingFilter.refining(parent.filter, with: liveFilter)
        default:
            guard let resolved = Base(scope: scope) else { return nil }
            base = resolved
        }
        return SavedSearch(name: trimmedName, base: base, filter: filter, order: order)
    }
}
