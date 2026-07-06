import SwiftUI

/// SwiftUI capsule button styles (DSN24 button language), the SwiftUI sibling of
/// the AppKit `MPButton`. Preferences and other SwiftUI surfaces reach these via
/// `.buttonStyle(.mpGhost)` / `.mpIcon`, so a stock macOS bezel button never leaks
/// into a redesigned surface.
///
/// - `.mpGhost`: the secondary capsule (`PWSmallButton` in the locked mockup) - a
///   `borderStrong` hairline over a `bgRaised` fill, no filled emphasis. Used for
///   choose / add / reveal / reset / re-check / open-settings actions.
/// - `.mpIcon`: the square icon affordance (`PWIconButton`) - a 24x24 `radius-sm`
///   box, muted glyph. Used for the reveal-in-Finder button.
///
/// Both take the blessed 0.97 press scale (honoring reduce-motion) and dim when
/// disabled. There is deliberately no `.mpPrimary` here: the one filled primary
/// per surface is the AppKit `MPButton(.primary)` or the record key, and
/// Preferences has no filled small button (YAGNI).

/// Fixed geometry shared by the SwiftUI button styles, exposed for tests.
enum MPButtonMetrics {
    static let height: CGFloat = 24
    static let ghostPadding: CGFloat = 12
    static let iconSize: CGFloat = 24
    static let pressScale: CGFloat = 0.97
}

/// Secondary capsule button. Matches the locked `PWSmallButton`: 24pt tall,
/// capsule (`radius-full`), a 1pt `borderStrong` hairline over `bgRaised`.
struct MPGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Rendered(configuration: configuration)
    }

    // A nested View, not `@Environment` on the style itself: a ButtonStyle struct
    // is built once and does not re-read the environment, so the dynamic
    // properties have to live on a view SwiftUI re-evaluates. Named `Rendered`
    // (not `Body`) to avoid colliding with ButtonStyle's own `associatedtype Body`.
    struct Rendered: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.mpTextSM.weight(.medium))
                .foregroundStyle(Color(MPColors.fg))
                .padding(.horizontal, MPButtonMetrics.ghostPadding)
                .frame(height: MPButtonMetrics.height)
                .background(
                    Capsule(style: .continuous).fill(Color(MPColors.bgRaised))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color(MPColors.borderStrong), lineWidth: 1)
                )
                .contentShape(Capsule(style: .continuous))
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? MPButtonMetrics.pressScale : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: MPMotion.durPress),
                           value: configuration.isPressed)
        }
    }
}

/// Square icon button. Matches the locked `PWIconButton`: a 24x24 `radius-sm` box,
/// a 1pt `borderStrong` hairline over `bgRaised`, a muted glyph.
struct MPIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Rendered(configuration: configuration)
    }

    struct Rendered: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.mpTextBase)
                .foregroundStyle(Color(MPColors.fgMuted))
                .frame(width: MPButtonMetrics.iconSize, height: MPButtonMetrics.iconSize)
                .background(
                    RoundedRectangle(cornerRadius: MPRadius.sm, style: .continuous)
                        .fill(Color(MPColors.bgRaised))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MPRadius.sm, style: .continuous)
                        .strokeBorder(Color(MPColors.borderStrong), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: MPRadius.sm, style: .continuous))
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? MPButtonMetrics.pressScale : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: MPMotion.durPress),
                           value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == MPGhostButtonStyle {
    /// The design-system secondary capsule button (DSN24).
    static var mpGhost: MPGhostButtonStyle { MPGhostButtonStyle() }
}

extension ButtonStyle where Self == MPIconButtonStyle {
    /// The design-system square icon button (DSN24).
    static var mpIcon: MPIconButtonStyle { MPIconButtonStyle() }
}
