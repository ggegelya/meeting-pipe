import SwiftUI

/// The one raised-surface primitive (DSN19). A single fill (`bgRaised`) and a
/// single hairline (`border`) at one radius, replacing the 5-plus hand-rolled
/// card treatments that had drifted apart: `bgRaised` + border at three radii,
/// `controlBackgroundColor.opacity(0.6)`, `controlBackgroundColor.opacity(0.5)`,
/// and raw `controlBackgroundColor`. Routing them through one modifier means the
/// surface ports (DSN27/28) restyle a single primitive instead of chasing copies.
///
/// Floating chrome (the HUD, the meeting prompt, Quick Find) keeps its
/// `.hudWindow` glass and is deliberately NOT routed through this: Float-Earns-Blur.
struct MPSurface: ViewModifier {
    /// Corner radius. Defaults to the card radius (`md`, 14). Adopting call sites
    /// pass their existing radius so the consolidation is green-to-green; the
    /// surface ports flip them to the default when they retune against pixels.
    var radius: CGFloat = MPRadius.md
    /// Hairline width. 1 for in-window cards, 0.5 for finer chrome.
    var borderWidth: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(MPColors.bgRaised))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color(MPColors.border), lineWidth: borderWidth)
            )
    }
}

extension View {
    /// Wrap in the standard raised card surface (DSN19): a `bgRaised` fill under a
    /// `border` hairline at `radius` (the card radius `md` by default).
    func mpSurface(radius: CGFloat = MPRadius.md, borderWidth: CGFloat = 1) -> some View {
        modifier(MPSurface(radius: radius, borderWidth: borderWidth))
    }
}
