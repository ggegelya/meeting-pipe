import CoreGraphics

/// Column-width floors for the three-pane Library window, in one place so the
/// `NavigationSplitView` columns and the `NSWindow` minimum stay in sync.
///
/// The window must never be allowed below the sum of the three column floors:
/// the detail column is the flexible trailing one, so once the window is
/// narrower than `sidebar + list + detail`, the detail column is squeezed under
/// its own content and the leading edge slides beneath the divider (TECH-UX11).
/// The Audio tab footer is the widest fixed content in the detail pane, so the
/// detail floor is sized to clear it (its Zoom control was moved to a compact
/// menu so the footer fits inside this floor).
///
/// `LibraryLayoutTests` pins the invariant `sidebarMin + listMin + detailMin <=
/// windowMinWidth`, so bumping any floor without raising the window minimum
/// fails the build rather than re-introducing the clip.
enum LibraryLayout {
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarIdealWidth: CGFloat = 220
    static let sidebarMaxWidth: CGFloat = 260

    static let listMinWidth: CGFloat = 400
    static let listIdealWidth: CGFloat = 460

    static let detailMinWidth: CGFloat = 450
    static let detailIdealWidth: CGFloat = 520

    /// Ceiling on the detail column (UX36, third pass, owner-picked). Without
    /// one, the detail column absorbs every pt of window growth, and the reading
    /// surfaces inside it were left choosing between parking their measured
    /// column beside a growing void (the pre-UX36 shape) and centering it
    /// between two voids (the second-pass shape the owner rejected on sight).
    /// Capping the column spends the slack on the meeting list instead, where
    /// titles truncate today, and lets the summary left-align against the same
    /// edge as the header, tabs, and transcript, so the content axis no longer
    /// jumps when the tab changes.
    ///
    /// 1040 fits the widest measured content plus its gutters with room for the
    /// transcript to breathe (`LibraryLayoutTests` pins the arithmetic): the
    /// summary column is 680 + 2 * 20, the inspector card 720 + 2 * 16. Past the
    /// cap the split view gives further width to the list column, which has no
    /// max, so nothing is ever left unclaimed.
    static let detailMaxWidth: CGFloat = 1040

    // Sum of the floors (200 + 400 + 450 = 1050) stays <= windowMinWidth, the
    // invariant LibraryLayoutTests pins. The row itself degrades to a two-line
    // tile (MeetingRow ViewThatFits) when the list column nears its floor, so the
    // window minimum stays modest rather than ballooning to fit a one-line row.
    static let windowMinWidth: CGFloat = 1060
    static let windowMinHeight: CGFloat = 480
}
