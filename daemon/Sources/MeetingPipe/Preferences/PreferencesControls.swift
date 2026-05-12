import SwiftUI

/// Shared SwiftUI primitives for the redesigned Preferences window.
///
/// The visual contract comes from the Claude-Design handoff for TECH-E4:
/// uppercase group label → raised card with a thin hairline → row stack
/// with a fixed-width label column and a flexible control column →
/// optional footer caption below the card. This matches the layout
/// vocabulary the prompt panel and recording HUD already use, so all
/// three surfaces feel like the same family.
///
/// Spacing values mirror the HTML prototype (`primitives.jsx`) so any
/// pixel-perfect comparison still holds: 22pt between groups, 14pt
/// horizontal pad inside rows, 168pt label column, 26pt control height.

// MARK: - SectionHeader

struct SettingsSectionHeader<Trailing: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, caption: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.caption = caption
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                if let caption = caption {
                    Text(caption)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.bottom, 18)
    }
}

// MARK: - Group card

/// One titled section card. Uppercase eyebrow label, raised-paper card
/// holding row-stack content, optional footer caption. Pass an empty
/// label to skip the eyebrow entirely (used by the Permissions section).
struct SettingsGroup<Content: View, Footer: View>: View {
    let label: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    init(_ label: String? = nil,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }) {
        self.label = label
        self.content = content
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label = label, !label.isEmpty {
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(MPColors.bgRaised))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(MPColors.border), lineWidth: 1)
                )
            footer()
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 22)
    }
}

// MARK: - Row

/// A label+control row inside a SettingsGroup card. The label column is
/// fixed at 168pt to keep controls vertically aligned across rows; the
/// control column flexes to fill remaining width.
struct SettingsRow<Content: View>: View {
    let label: String
    let sublabel: String?
    let alignTop: Bool
    @ViewBuilder var content: () -> Content
    /// Whether to draw the divider above this row. The first row in a
    /// card omits it; everything else gets a hairline matching the
    /// design's `border-faint` token.
    var showsDivider: Bool

    init(_ label: String,
         sublabel: String? = nil,
         alignTop: Bool = false,
         showsDivider: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.sublabel = sublabel
        self.alignTop = alignTop
        self.showsDivider = showsDivider
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsDivider {
                Rectangle()
                    .fill(Color(MPColors.borderFaint))
                    .frame(height: 1)
            }
            HStack(alignment: alignTop ? .top : .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 13))
                    if let sublabel = sublabel {
                        Text(sublabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 168, alignment: .leading)
                .padding(.top, alignTop ? 4 : 0)
                HStack(spacing: 8) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }
}

/// Full-width row variant — no label column. Used by the auto-consent
/// allowlist where the tag stack + add input fill the whole card width.
struct SettingsFullRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var showsDivider: Bool

    init(showsDivider: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.showsDivider = showsDivider
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsDivider {
                Rectangle()
                    .fill(Color(MPColors.borderFaint))
                    .frame(height: 1)
            }
            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }
}

// MARK: - Segmented

/// Picker-as-segmented-control. SwiftUI's `.segmented` style matches
/// the design's segmented look closely enough that we don't need a
/// custom control here.
struct SettingsSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options.indices, id: \.self) { i in
                Text(options[i].label).tag(options[i].value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - StatusPill

/// Small pill used for permission status and integration health.
/// Coloring lives in the Tone enum so callers don't repeat the mapping.
struct SettingsStatusPill: View {
    enum Tone {
        case granted
        case needed
        case denied
        case neutral

        var fg: Color {
            switch self {
            case .granted: return .green
            case .needed:  return .orange
            case .denied:  return .red
            case .neutral: return .secondary
            }
        }
    }

    let tone: Tone
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tone.fg)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(tone.fg.opacity(0.15))
        )
    }
}

// MARK: - Tag

/// Bundle-id chip with a remove affordance. Used in the auto-consent
/// allowlist. Mono font so the bundle id reads as code, not copy.
struct SettingsTag: View {
    let label: String
    let onRemove: (() -> Void)?

    init(_ label: String, onRemove: (() -> Void)? = nil) {
        self.label = label
        self.onRemove = onRemove
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
            if let onRemove = onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(MPColors.bgSunk))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color(MPColors.border), lineWidth: 1)
        )
    }
}

// MARK: - Slider with value badge

/// Slider + monospaced value readout pinned to the right. Matches the
/// HTML prototype's `Slider` component including the signal-tinted
/// filled portion of the track.
struct SettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    var valueWidth: CGFloat = 56

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: $value, in: range, step: step)
                .tint(Color(MPColors.signal600))
            Text(format(value))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }
}

// MARK: - SecretInput

/// Password-style field with an eye toggle to reveal. Used for the two
/// secrets in the Integrations section.
struct SettingsSecretField: View {
    @Binding var text: String
    var placeholder: String = ""
    @State private var isVisible: Bool = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Group {
                if isVisible {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))

            Button {
                isVisible.toggle()
            } label: {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
    }
}
