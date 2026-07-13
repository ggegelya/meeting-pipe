import AppKit
import SwiftUI

/// No-System-Blue (DSN10): the Library replaces the native list/sidebar selection
/// highlight with its own translucent teal wash (`mpSelectionWash`). SwiftUI's
/// `.tint` cannot recolor the AppKit selection, and `.listRowBackground(...)`
/// paints *over* the highlight rather than suppressing it, so the native
/// highlight (system-blue when focused, grey when not) otherwise stacks under the
/// wash as a doubled selection. This reaches the backing `NSTableView` /
/// `NSOutlineView` and turns the native highlight off, leaving the teal wash as
/// the single selection cue.
///
/// The probe sits in the `List`'s `.background`, so its superview is the composite
/// container that also holds the list's scroll view and table. It walks up until
/// it reaches an ancestor whose subtree contains a table, then clears the native
/// highlight on every table under it (clearing sibling tables too is harmless:
/// No-System-Blue applies to all of them). A no-op if no table is found, so it
/// never regresses past the current doubled-but-visible state; idempotent, and
/// re-applied on each SwiftUI update in case the list's table is rebuilt.
private struct NoNativeSelection: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            var ancestor: NSView? = nsView.superview
            while let a = ancestor {
                if NoNativeSelection.disableTableHighlights(in: a) { return }
                ancestor = a.superview
            }
        }
    }

    /// Sets `.none` on every `NSTableView`/`NSOutlineView` in the subtree; returns
    /// whether it found any, so the caller can stop at the nearest table-bearing
    /// ancestor instead of sweeping the whole window.
    @discardableResult
    static func disableTableHighlights(in view: NSView) -> Bool {
        var found = false
        if let table = view as? NSTableView {
            table.selectionHighlightStyle = .none
            found = true
        }
        for sub in view.subviews where disableTableHighlights(in: sub) {
            found = true
        }
        return found
    }
}

extension View {
    /// Suppress the native table selection highlight for the `List` this modifies,
    /// leaving the app's teal `mpSelectionWash` as the only selection cue
    /// (No-System-Blue, DSN10). Attach to the `List`, not a row.
    func noNativeListSelection() -> some View {
        background(
            NoNativeSelection()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}
