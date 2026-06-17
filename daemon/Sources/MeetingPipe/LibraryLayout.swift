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

    // Sum of the floors (200 + 400 + 450 = 1050) stays <= windowMinWidth, the
    // invariant LibraryLayoutTests pins. The row itself degrades to a two-line
    // tile (MeetingRow ViewThatFits) when the list column nears its floor, so the
    // window minimum stays modest rather than ballooning to fit a one-line row.
    static let windowMinWidth: CGFloat = 1060
    static let windowMinHeight: CGFloat = 480
}
