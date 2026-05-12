import AppKit
import SwiftUI

/// Shared chip + button vocabulary used by the polished Library window
/// chrome (row, filter bar, detail header, batch actions). All four
/// surfaces lean on the same primitives so the visual family stays
/// coherent — same chip metrics, same hover treatments, same hairlines.
///
/// Tokens-only: no new colors, no new spacing constants. Everything
/// resolves to `MPColors`, `MPRadius`, `MPSpace`, `MPType` so dark mode
/// auto-flips and so the design system stays the single source of
/// truth for visual decisions.

// MARK: - Workflow chip

/// Color-tinted workflow chip — `.wf` family from the design audit:
/// 18pt tall, full-rounded, leading 6pt dot in the workflow's color,
/// background tinted at ~16% of the same hue, label at 11pt medium.
///
/// Replaces the prior bordered-rectangle treatment. Used in the row
/// caption, the filter bar (when a workflow scope is active), and the
/// detail header's title row.
struct WorkflowChip: View {
    let name: String
    let colorHex: String?

    /// Optional display weight. Compact omits the dot to fit denser
    /// layouts (the row caption already carries a workflow scope
    /// hairline upstream); standard keeps it for the filter bar and
    /// detail header where the chip has to stand on its own.
    var weight: Weight = .standard

    enum Weight { case standard, compact }

    var body: some View {
        HStack(spacing: 5) {
            if weight == .standard {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
            }
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accent)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(
            Capsule(style: .continuous)
                .fill(accent.opacity(0.16))
        )
    }

    private var accent: Color {
        if let hex = colorHex, let ns = HexColor.parse(hex) { return Color(ns) }
        return Color(MPColors.fgMuted)
    }
}

// MARK: - Status pill

/// 0.5px-stroked status pill with one inline dot — `MPStatusPill`
/// family from the design audit. No background fill on resting states;
/// the dot and the label do the work.
///
/// `kind` is the visual treatment, not the recording state machine —
/// callers map their domain status (`Meeting.Status`, etc.) into one
/// of these tones.
struct MPStatusPill: View {
    let kind: Kind
    let label: String

    enum Kind {
        case ready
        case recording
        case processing
        case failed
        case nda
        case neutral
    }

    var body: some View {
        HStack(spacing: 5) {
            indicator
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(strokeColor, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var indicator: some View {
        switch kind {
        case .recording:
            // Same TimelineView-driven dot the toolbar uses, so the
            // row's pulse stays in lockstep with the toolbar's
            // recording chip. Steady opacity loop, no scale pulse.
            MPSteadyPulseDot(color: dotColor, size: 5)
        case .processing:
            MPRingSpinner(color: dotColor, size: 7)
        default:
            Circle().fill(dotColor).frame(width: 5, height: 5)
        }
    }

    private var dotColor: Color {
        switch kind {
        case .ready:      return Color(MPColors.success600)
        case .recording:  return Color(MPColors.pulse500)
        case .processing: return Color(MPColors.signal400)
        case .failed:     return Color(MPColors.pulse500)
        case .nda:        return Color(MPColors.fgSubtle)
        case .neutral:    return Color(MPColors.fgSubtle)
        }
    }

    private var textColor: Color { dotColor }

    private var strokeColor: Color {
        switch kind {
        case .failed:  return Color(MPColors.pulse500).opacity(0.32)
        default:       return Color(MPColors.borderStrong)
        }
    }
}

/// Self-paced 1.6s opacity loop driven by `TimelineView(.animation)`.
/// Identical timeline to the toolbar's `PulsleDot` so a row's pulse
/// and the toolbar pulse stay phase-locked (both read the same
/// `Date.timeIntervalSinceReferenceDate`). No `@State`, no
/// `withAnimation` — the parent can't perturb it.
struct MPSteadyPulseDot: View {
    let color: Color
    var size: CGFloat = 6

    private static let periodSec: Double = 1.6

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: Self.periodSec)) / Self.periodSec
            // 1 .. 0.35 .. 1 envelope. Matches the "steady, not urgent"
            // motion note in the design system guide.
            let envelope = 0.675 + 0.325 * cos(phase * 2 * .pi)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .opacity(envelope)
        }
        .frame(width: size, height: size)
    }
}

/// Compact 1s rotation spinner that reads as the processing indicator
/// inside the status pill. Ring rather than filled disc so it doesn't
/// over-weight the pill (matches the CSS audit's `.pill--proc` rule).
struct MPRingSpinner: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: 1.0)) / 1.0
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(color, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(360 * phase))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Ref chip (filter bar)

/// Flat ghost chip used by the filter bar's source/status/date
/// dropdowns. Visually subordinate to `WorkflowChip` so workflow stays
/// the primary scope; renders the *value* inline when set, not the
/// field name — the set state IS the labelled state.
///
/// The trailing caret hints at the dropdown without claiming weight.
struct MPRefChip<Content: View>: View {
    let label: String
    let currentValue: String?
    let isActive: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Text(currentValue ?? label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isActive ? Color(MPColors.fg) : Color(MPColors.fgMuted))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isActive ? Color(MPColors.borderStrong) : Color(MPColors.border),
                        lineWidth: 0.5
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Ghost icon button

/// 26pt square button with hover tint, no border, no fill at rest.
/// Used by the detail header's trailing edge for Notion / Obsidian /
/// Reveal-in-Finder shortcuts and by the batch-actions cards for
/// secondary triggers. Help-string carries the action name; the icon
/// alone carries the label visually.
struct MPGhostIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var hovering: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(hovering ? Color(MPColors.fg) : Color(MPColors.fgMuted))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.06) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
