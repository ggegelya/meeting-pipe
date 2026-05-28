import AppKit
import SwiftUI

/// Shared chip and button primitives used across Library chrome (row, filter bar, detail header, batch actions). All tokens resolve to `MPColors`/`MPRadius`/`MPSpace`/`MPType`; no new color or spacing constants.

// MARK: - Workflow chip

/// Color-tinted workflow chip: 18pt capsule, leading 6pt dot, 16% tinted background. Used in the row caption, filter bar, and detail header.
struct WorkflowChip: View {
    let name: String
    let colorHex: String?

    /// Compact omits the dot for denser layouts; standard keeps it where the chip must stand on its own.
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

/// 0.5px-stroked status pill with an inline dot. `kind` is the visual tone; callers map their domain status to it.
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
            // Same TimelineView clock as the toolbar's dot, so both pulses stay phase-locked.
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

/// 1.6s opacity loop via `TimelineView(.animation)`. Reads the same `timeIntervalSinceReferenceDate` as the toolbar's `PulseDot` so both pulses stay phase-locked. No `@State`/`withAnimation`; parent re-renders can't perturb it.
struct MPSteadyPulseDot: View {
    let color: Color
    var size: CGFloat = 6

    private static let periodSec: Double = 1.6

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: Self.periodSec)) / Self.periodSec
            // 1..0.35..1 envelope - "steady, not urgent" per design system.
            let envelope = 0.675 + 0.325 * cos(phase * 2 * .pi)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .opacity(envelope)
        }
        .frame(width: size, height: size)
    }
}

/// Compact 1s ring spinner for the processing pill indicator. Ring (not filled disc) so it doesn't over-weight the pill.
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

/// Flat ghost chip for filter bar dropdowns. Renders the set value inline (not the field name) with a trailing caret hinting at the dropdown.
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

/// 26pt square ghost icon button with hover tint. Used in the detail header and batch-actions cards; help string carries the label.
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
