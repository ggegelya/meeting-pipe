import Foundation

/// Multi-segment selection for per-segment speaker reassignment (FEAT3-SEGMENT).
///
/// The transcript's plain left-click still seeks; selection layers on modifier-clicks
/// so a diarization merge (many segments wrongly in one cluster) can be reassigned in
/// one go. Pure, keyed by `TranscriptSegment.index`, so the click logic is unit-tested
/// without the view.
struct SegmentSelection: Equatable {
    private(set) var selected: Set<Int> = []
    /// The last click, used as the pivot for a shift-range extension.
    private(set) var anchor: Int?

    var isEmpty: Bool { selected.isEmpty }
    func contains(_ index: Int) -> Bool { selected.contains(index) }

    /// A plain click (the seek path): clears the multi-selection and re-anchors.
    mutating func plainClick(_ index: Int) {
        selected = []
        anchor = index
    }

    /// Cmd-click: toggle one segment in the selection; it becomes the new anchor.
    mutating func toggle(_ index: Int) {
        if selected.contains(index) {
            selected.remove(index)
        } else {
            selected.insert(index)
        }
        anchor = index
    }

    /// Shift-click: select the contiguous run (in display order) from the anchor to
    /// `index`, inclusive. With no anchor yet it selects just `index`. `order` is the
    /// displayed segment indices, since raw indices can skip (empty segments filtered).
    mutating func extendTo(_ index: Int, in order: [Int]) {
        guard let a = anchor,
              let ai = order.firstIndex(of: a),
              let ii = order.firstIndex(of: index) else {
            selected = [index]
            anchor = index
            return
        }
        let lo = min(ai, ii), hi = max(ai, ii)
        selected = Set(order[lo...hi])
    }

    mutating func clear() {
        selected = []
        anchor = nil
    }

    /// The segments a menu action on `index` should apply to: the whole selection when
    /// `index` is part of a multi-selection, else just `index`. So right-clicking a
    /// selected row reassigns the batch, but right-clicking an unselected row acts only
    /// on it.
    func targets(for index: Int) -> [Int] {
        (selected.count > 1 && selected.contains(index)) ? selected.sorted() : [index]
    }
}
