import Foundation

/// The Library list's selection rules, as pure functions over the flattened visible order (PERF9).
///
/// The list used to be a SwiftUI `List(selection:)`, which supplied click, Cmd-click, Shift-click
/// and arrow navigation itself. A `LazyVStack` supplies none of it, so the app owns it here and
/// the view only translates events into these calls. The order is the one on screen: the pinned
/// "In progress" rows first, then the date groups, with a pinned meeting dropped from its group.
struct MeetingListSelection: Equatable {
    /// What the selected set is.
    private(set) var selected: Set<Meeting.ID> = []
    /// The end Shift-click and Shift-arrow extend from: the last row clicked or arrowed onto.
    private(set) var anchor: Meeting.ID?
    /// The moving end of a Shift-arrow range, so shrinking back toward the anchor works.
    private(set) var cursor: Meeting.ID?

    enum Click { case plain, command, shift }
    enum Step { case up, down }

    init(selected: Set<Meeting.ID> = [], anchor: Meeting.ID? = nil) {
        self.selected = selected
        self.anchor = anchor ?? (selected.count == 1 ? selected.first : nil)
        self.cursor = self.anchor
    }

    /// Adopt a selection changed from outside (Quick Find, a recent-meeting click, the rail),
    /// keeping the anchor when it is still part of it.
    mutating func adopt(_ external: Set<Meeting.ID>) {
        guard external != selected else { return }
        selected = external
        if let a = anchor, external.contains(a) {} else {
            anchor = external.count == 1 ? external.first : nil
        }
        cursor = anchor
    }

    mutating func click(_ id: Meeting.ID, kind: Click, order: [Meeting.ID]) {
        switch kind {
        case .plain:
            selected = [id]
            anchor = id
            cursor = id
        case .command:
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id
            cursor = id
        case .shift:
            guard let from = anchor, let a = order.firstIndex(of: from), let b = order.firstIndex(of: id) else {
                click(id, kind: .plain, order: order)
                return
            }
            selected = Set(order[min(a, b)...max(a, b)])
            cursor = id
        }
    }

    /// Move the selection one row. Plain: select just the neighbour (or the first/last row when
    /// nothing is selected). Extending: grow or shrink the range from the anchor. Returns the id
    /// the view should scroll to, nil when the list is empty.
    @discardableResult
    mutating func move(_ step: Step, extend: Bool, order: [Meeting.ID]) -> Meeting.ID? {
        guard !order.isEmpty else { return nil }
        let from = cursor.flatMap { order.firstIndex(of: $0) }
        let target: Int
        if let from {
            target = step == .down ? min(from + 1, order.count - 1) : max(from - 1, 0)
        } else {
            target = step == .down ? 0 : order.count - 1
        }
        let id = order[target]
        if extend, let anchorID = anchor, let a = order.firstIndex(of: anchorID) {
            selected = Set(order[min(a, target)...max(a, target)])
            cursor = id
        } else {
            selected = [id]
            anchor = id
            cursor = id
        }
        return id
    }

    mutating func selectAll(order: [Meeting.ID]) {
        selected = Set(order)
        if anchor == nil { anchor = order.first }
        cursor = order.last
    }

    /// UX103: a multi-selection narrowed to the rows the list shows. The batch pane acts on every
    /// selected meeting, so a search, a chip or a rail switch that hides some of them must take
    /// them out of the selection rather than leave Trash or Re-summarize aimed at rows nobody can
    /// see. A single selection is left alone: Quick Find, a notification or a citation jump selects
    /// one meeting without clearing the filter, and pruning it would undo the jump.
    static func pruned(_ selection: Set<Meeting.ID>, toVisible visible: [Meeting.ID]) -> Set<Meeting.ID> {
        guard selection.count > 1 else { return selection }
        return selection.intersection(visible)
    }

    /// The rendered sections: an "In progress" block of pinned meetings first, then each date
    /// group without the pinned ones (a meeting never renders twice), empty groups omitted.
    static func sections(pinned: [Meeting], groups: [MeetingGroup]) -> [(title: String, meetings: [Meeting])] {
        let pinnedStems = Set(pinned.map(\.stem))
        var out: [(title: String, meetings: [Meeting])] = []
        if !pinned.isEmpty { out.append(("In progress", pinned)) }
        for group in groups {
            let rows = group.meetings.filter { !pinnedStems.contains($0.stem) }
            if !rows.isEmpty { out.append((group.title, rows)) }
        }
        return out
    }
}
