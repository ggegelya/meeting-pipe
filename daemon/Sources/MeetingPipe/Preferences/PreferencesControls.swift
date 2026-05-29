import SwiftUI

/// Shared SwiftUI primitives for the Preferences window (TECH-E4). Spacing mirrors the HTML prototype (`primitives.jsx`): 22pt between groups, 14pt horizontal pad, 168pt label column, 26pt control height.

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

/// Titled section card: uppercase eyebrow label, raised-paper card, optional footer. Pass nil/empty to skip the eyebrow (used by the Permissions section).
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

/// Label+control row inside a SettingsGroup card. Label column is fixed at 168pt; control column flexes. `showsDivider: false` on the first row in a card.
struct SettingsRow<Content: View>: View {
    let label: String
    let sublabel: String?
    let alignTop: Bool
    @ViewBuilder var content: () -> Content
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

/// Label row whose control is a trailing-aligned switch (macOS System Settings
/// convention). Wraps `SettingsRow` so the divider and 168pt label column match
/// every other row; the switch hugs the right edge instead of leaving dead space.
struct SettingsToggleRow: View {
    let label: String
    let sublabel: String?
    @Binding var isOn: Bool
    var showsDivider: Bool

    init(_ label: String, sublabel: String? = nil, isOn: Binding<Bool>, showsDivider: Bool = true) {
        self.label = label
        self.sublabel = sublabel
        self._isOn = isOn
        self.showsDivider = showsDivider
    }

    var body: some View {
        SettingsRow(label, sublabel: sublabel, showsDivider: showsDivider) {
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

/// Full-width row variant (no label column). Used by the auto-consent allowlist.
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

/// Picker-as-segmented-control using SwiftUI's `.segmented` style.
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

// MARK: - Menu picker

/// Compact dropdown picker. Unlike `SettingsSegmented`, its width is fixed
/// regardless of option count, so a long or many-option list (e.g. the
/// summarization backend) doesn't stretch the row and blow out the window.
struct SettingsMenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var width: CGFloat = 200

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options.indices, id: \.self) { i in
                Text(options[i].label).tag(options[i].value)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: width)
    }
}

// MARK: - StatusPill

/// Status pill for permission status and integration health. Color mapping lives in `Tone`.
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

/// Bundle-id chip with a remove affordance. Mono font so the id reads as code.
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

/// Slider with a monospaced value readout, signal-tinted track.
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

// MARK: - HotkeyField

/// Click-to-record hotkey field. Captures a modifier+letter chord, renders it as ⌃⌥⇧⌘ glyphs, and commits in `ctrl+option+m` format that `HotkeyManager.parse` accepts. Only letters are accepted - digits/function keys are not handled by `HotkeyManager.keyCodeFor`, so a non-letter press is silently ignored and capture stays armed. Escape cancels.
struct SettingsHotkeyField: View {
    @Binding var text: String
    @State private var isCapturing: Bool = false
    @State private var monitor: Any?

    private static let letters: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz")

    var body: some View {
        Button(action: startCapture) {
            HStack(spacing: 6) {
                if isCapturing {
                    Text("Press keys…")
                        .foregroundStyle(Color(MPColors.signal600))
                        .font(.system(size: 12))
                } else if text.isEmpty {
                    Text("Not set")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                } else {
                    Text(Self.renderGlyphs(text))
                        .font(.system(size: 13, design: .monospaced))
                }
                Spacer(minLength: 0)
                if isCapturing {
                    Image(systemName: "command")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: 200, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isCapturing
                            ? Color(MPColors.signal600)
                            : Color.secondary.opacity(0.3),
                        lineWidth: isCapturing ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onDisappear { stopCapture() }
    }

    private func startCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event: event)
        }
    }

    private func stopCapture() {
        isCapturing = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    /// Returns nil to swallow the keystroke so it doesn't propagate to the field behind us in the responder chain.
    private func handle(event: NSEvent) -> NSEvent? {
        // Escape cancels without writing.
        if event.keyCode == 53 {
            stopCapture()
            return nil
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let ch = chars.first,
              Self.letters.contains(ch) else {
            return nil  // ignore non-letter keys, stay in capture mode
        }
        let flags = event.modifierFlags
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option)  { parts.append("option") }
        if flags.contains(.shift)   { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        guard !parts.isEmpty else {
            // Bare letter would steal the key from every app; require a modifier.
            return nil
        }
        parts.append(String(ch))
        text = parts.joined(separator: "+")
        stopCapture()
        return nil
    }

    /// Render `ctrl+option+m` as `⌃⌥M`. Falls back to raw text for unusual chords typed directly in the TOML file.
    static func renderGlyphs(_ raw: String) -> String {
        let parts = raw.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var prefix = ""
        var key = ""
        for part in parts {
            switch part {
            case "ctrl", "control": prefix += "\u{2303}"  // ⌃
            case "option", "opt", "alt": prefix += "\u{2325}"  // ⌥
            case "shift": prefix += "\u{21E7}"  // ⇧
            case "cmd", "command": prefix += "\u{2318}"  // ⌘
            default:
                if part.count == 1, let c = part.first, c.isLetter {
                    key = String(c).uppercased()
                }
            }
        }
        guard !key.isEmpty else { return raw }
        return prefix + key
    }
}

// MARK: - SecretInput

/// Password-style field with a reveal toggle. The eye sits *beside* the field
/// (not overlaid on the masked dots) as a distinct bordered button, so it stays
/// clearly visible and never collides with the text. Tinted when revealing.
struct SettingsSecretField: View {
    @Binding var text: String
    var placeholder: String = ""
    @State private var isVisible: Bool = false

    var body: some View {
        HStack(spacing: 6) {
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
                Image(systemName: isVisible ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isVisible ? Color(MPColors.signal600) : Color(MPColors.fgMuted))
                    .frame(width: 30, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(MPColors.bgSunk))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color(MPColors.border), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(isVisible ? "Hide" : "Reveal")
            .accessibilityLabel(isVisible ? "Hide secret" : "Reveal secret")
        }
    }
}
