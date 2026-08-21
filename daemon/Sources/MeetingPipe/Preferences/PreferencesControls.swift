import SwiftUI

/// Shared SwiftUI primitives for the Preferences window (TECH-E4). Spacing mirrors the mockup (`PreferencesWindow.jsx`): 22pt between groups, 14pt horizontal pad, 16pt row gap. An inline row is [info grows · control hugs right] (`SettingsRow`); wide or descriptive controls stack the control full-width below the label (`SettingsStackRow`).

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
        HStack(alignment: .firstTextBaseline, spacing: MPSpace.s4) {
            VStack(alignment: .leading, spacing: MPSpace.s1) {
                Text(title)
                    .font(.mpTextLG.weight(.semibold)) // DSN28: 17 (the locked one-anchor-per-surface size), retuned down from mpTextXL
                if let caption = caption {
                    Text(caption)
                        .font(.mpTextBase)
                        .foregroundStyle(Color(MPColors.fgMuted))
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
        VStack(alignment: .leading, spacing: MPSpace.s2) {
            if let label = label, !label.isEmpty {
                Text(label.uppercased())
                    .font(.mpTextXS.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) { content() }
                .mpSurface() // DSN19 card primitive; DSN28 retuned the radius 10 -> md (14), the locked card radius
            footer()
                .font(.mpTextSM)
                .foregroundStyle(Color(MPColors.fgMuted))
                .padding(.leading, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 22)
    }
}

// MARK: - Row

/// Label+control row inside a SettingsGroup card. Info (label + sublabel) grows and wraps across the full width; the control hugs the right at its natural size. `showsDivider: false` on the first row in a card.
struct SettingsRow<Content: View>: View {
    let label: String
    let sublabel: String?
    let alignTop: Bool
    /// UX43: `true` for a control that genuinely wants the remaining width instead of
    /// hugging (the Pipeline pane's prompt preview is the only one). Everything else
    /// leaves this alone: a button, pill, picker, or value readout has an ideal width,
    /// and hugging it is what stops the greedy label column truncating it.
    let controlFills: Bool
    @ViewBuilder var content: () -> Content
    var showsDivider: Bool

    init(_ label: String,
         sublabel: String? = nil,
         alignTop: Bool = false,
         showsDivider: Bool = true,
         controlFills: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.sublabel = sublabel
        self.alignTop = alignTop
        self.showsDivider = showsDivider
        self.controlFills = controlFills
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsDivider {
                Rectangle()
                    .fill(Color(MPColors.borderFaint))
                    .frame(height: 1)
            }
            HStack(alignment: alignTop ? .top : .center, spacing: MPSpace.s4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.mpTextBase)
                    if let sublabel = sublabel {
                        Text(sublabel)
                            .font(.mpTextXS)
                            .foregroundStyle(Color(MPColors.fgMuted))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, alignTop ? 4 : 0)
                // UX43: the control column keeps its natural width under a squeeze,
                // which is what the row's own doc comment above has always claimed and
                // what the locked mockup pins (`PWRow` in `PreferencesWindow.jsx` gives
                // this column `flexShrink: 0`). The Swift shipped without it: the info
                // column beside it is greedy (`maxWidth: .infinity`) and the controls
                // carry no compression resistance of their own, so a narrow window ate
                // the buttons instead. Storage's "Choose destination…" read as an
                // ellipsis, and People and Caches have the same two-ghost-button shape.
                // Horizontal only: a wrapping control still gets its height.
                // `controlFills` opts out for a control that wants the remaining width,
                // since fixing one of those to its ideal width would be worse than the
                // truncation (a ScrollView's ideal width is its content's, i.e. a mile
                // of unwrapped prose).
                HStack(spacing: 8) { content() }
                    .fixedSize(horizontal: !controlFills, vertical: false)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, MPSpace.s3)
        }
    }
}

/// Label row whose control is a trailing-aligned switch (macOS System Settings
/// convention). Wraps `SettingsRow` so the divider and info-grows layout match
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
            // DSN28: the locked mechanical toggle (DSN24) replaces the stock switch.
            // The switch was innately accessible; the custom style is a Button, so
            // re-attach the setting name + on/off value to keep VoiceOver's floor.
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.mechanical)
                .accessibilityLabel(label)
                .accessibilityValue(isOn ? "On" : "Off")
        }
    }
}

/// Stacked row variant: label + sublabel on top, full-width control below. For
/// sliders, file paths, endpoints, and secret fields - anything that wants room
/// or carries a long description. Mirrors `SettingsRow`'s divider and padding so
/// it sits flush among inline rows in the same card.
struct SettingsStackRow<Content: View>: View {
    let label: String
    let sublabel: String?
    var showsDivider: Bool
    @ViewBuilder var content: () -> Content

    init(_ label: String,
         sublabel: String? = nil,
         showsDivider: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.sublabel = sublabel
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
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.mpTextBase)
                if let sublabel = sublabel {
                    Text(sublabel)
                        .font(.mpTextXS)
                        .foregroundStyle(Color(MPColors.fgMuted))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                HStack(spacing: 8) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, MPSpace.s2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, MPSpace.s3)
        }
    }
}

/// Expandable row inside a SettingsGroup card: a tappable header (label +
/// chevron) that discloses nested rows below it. Collapsed, a whole cluster
/// reads as one row; expanded, the nested SettingsRows render with their own
/// dividers. Matches the SettingsRow divider and 14pt padding so it sits flush
/// in the card.
struct SettingsDisclosure<Content: View>: View {
    let label: String
    let sublabel: String?
    @Binding var isExpanded: Bool
    var showsDivider: Bool
    @ViewBuilder var content: () -> Content

    init(_ label: String,
         sublabel: String? = nil,
         isExpanded: Binding<Bool>,
         showsDivider: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.sublabel = sublabel
        self._isExpanded = isExpanded
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
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: MPSpace.s4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(.mpTextBase)
                        if let sublabel = sublabel {
                            Text(sublabel)
                                .font(.mpTextXS)
                                .foregroundStyle(Color(MPColors.fgMuted))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(MPColors.fgMuted))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                content()
            }
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
            case .granted: return .mpSuccess
            case .needed:  return .mpWarning
            case .denied:  return .mpDanger
            case .neutral: return Color(MPColors.fgMuted)
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
                .font(.mpTextXS.weight(.medium))
        }
        .foregroundStyle(tone.fg)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(tone.fg.opacity(0.15))
        )
        .overlay(
            // DSN28: the locked pill carries a faint same-hue hairline (mockup: fill
            // 15% currentColor under a 28% currentColor 0.5pt border).
            Capsule().strokeBorder(tone.fg.opacity(0.28), lineWidth: 0.5)
        )
    }
}

// MARK: - Tag

/// Mono identifier chip, with an optional remove affordance. Mono font so the id
/// reads as code. The trailing pad follows that affordance: 4 leaves room for the
/// xmark's own 14pt hit area, and a chip without one pads evenly instead of
/// sitting lopsided (the MCP tools row is the first read-only caller).
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
                .font(.mpTextSM.monospaced())
            if let onRemove = onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(MPColors.fgMuted))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, onRemove == nil ? 8 : 4)
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
                .font(.mpTextSM.monospaced())
                .foregroundStyle(Color(MPColors.fgMuted))
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
                        .foregroundStyle(.mpSignal)
                        .font(.mpTextSM)
                } else if text.isEmpty {
                    Text("Not set")
                        .foregroundStyle(Color(MPColors.fgMuted))
                        .font(.mpTextSM)
                } else {
                    Text(Self.renderGlyphs(text))
                        .font(.mpTextBase.monospaced())
                }
                Spacer(minLength: 0)
                if isCapturing {
                    Image(systemName: "command")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(MPColors.fgMuted))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: 200, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MPRadius.sm, style: .continuous)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MPRadius.sm, style: .continuous)
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
            .font(.mpTextSM.monospaced())

            Button {
                isVisible.toggle()
            } label: {
                Image(systemName: isVisible ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isVisible ? Color(MPColors.signal600) : Color(MPColors.fgMuted))
                    .frame(width: 30, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: MPRadius.sm, style: .continuous)
                            .fill(Color(MPColors.bgSunk))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: MPRadius.sm, style: .continuous)
                            .strokeBorder(Color(MPColors.border), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(isVisible ? "Hide" : "Reveal")
            .accessibilityLabel(isVisible ? "Hide secret" : "Reveal secret")
        }
    }
}

// MARK: - Danger button

/// Pulse-tinted outline button for a destructive action (matches the recording HUD's
/// Stop button). No fill at rest, so it carries weight without becoming the one filled
/// primary on its surface, which is what DSN28 moved inline buttons off.
///
/// UX30 promoted this out of `BatchActionsPane`'s private scope. It shipped there for the
/// Library's "Move to Trash" and was invisible to everything else, so the workflow editor
/// re-derived from its absence that the app had no destructive button and rendered Delete
/// as a neutral ghost capsule with the same weight as Save beside it. Two consumers now,
/// one declaration; a third destructive control reaches for `.mpDanger` rather than a
/// third copy.
struct MPDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Rendered(configuration: configuration)
    }

    /// A nested View for the same reason `MPGhostButtonStyle` has one: a ButtonStyle
    /// struct is built once and does not re-read the environment, so `isEnabled` and
    /// reduce-motion have to be read by a view SwiftUI re-evaluates. The disabled dimming
    /// is not cosmetic here: this style is worn by controls that disable themselves (the
    /// editor's Delete on the default workflow, "Move to Trash" mid-batch), and a
    /// destructive button that reads live while it is inert is the same class of untruth
    /// UX30 exists to fix.
    struct Rendered: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.mpTextSM.weight(.medium))
                .foregroundStyle(Color(MPColors.pulse500))
                .padding(.horizontal, 10)
                .frame(height: MPButtonMetrics.height)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(configuration.isPressed
                              ? Color(MPColors.pulse600).opacity(0.18)
                              : Color(MPColors.pulse600).opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(MPColors.pulse600).opacity(0.32), lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? MPButtonMetrics.pressScale : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: MPMotion.durPress),
                           value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == MPDangerButtonStyle {
    /// The design-system destructive button, the sibling of `.mpGhost` / `.mpIcon`.
    static var mpDanger: MPDangerButtonStyle { MPDangerButtonStyle() }
}

// MARK: - Flow layout

/// Wrapping row layout, using SwiftUI's `Layout` API: subviews are placed left to
/// right and break onto a new row when the next one would not fit the proposed
/// width. Every subview keeps its ideal size, so nothing is compressed or clipped.
///
/// UX51 promoted this out of `PreferencesView+Recording.swift`'s private scope, the
/// same move UX30 made for `MPDangerButtonStyle` above. It is worth recording *why*
/// the promotion happened now and not sooner, so the next reader does not re-litigate
/// either half: UX38 looked at promoting it, decided against it because that surface
/// wanted stacked chips rather than wrapped ones, and wrote down that it would not
/// promote a primitive "for one speculative caller". That was right. UX51 is the real
/// second caller (the cast strip above the transcript clipped its last chip mid-word
/// against the reading measure, with no fade, scrollbar or chevron to say so), and a
/// second wrapping layout beside this one would have been the actual mistake.
///
/// Two callers now: the Preferences auto-record allowlist's bundle-id tags, through
/// the `WrappingHStack` convenience that still lives beside them, and `VoiceResolutionBar`.
struct FlowLayout: Layout {
    var spacing: CGFloat

    /// One laid-out row: which subviews landed in it, how wide they came to together,
    /// and how tall the row is (its tallest subview).
    struct Row: Equatable {
        var indices: [Int]
        var width: CGFloat
        var height: CGFloat
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = Self.rows(for: measure(subviews), width: width, spacing: spacing)
        let height = rows.reduce(CGFloat(0)) { acc, row in
            acc + row.height + (acc == 0 ? 0 : spacing)
        }
        return CGSize(width: proposal.width ?? rows.first?.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = measure(subviews)
        var y = bounds.minY
        for row in Self.rows(for: sizes, width: bounds.width, spacing: spacing) {
            var x = bounds.minX
            for index in row.indices {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width + spacing
            }
            y += row.height + spacing
        }
    }

    private func measure(_ subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    /// The break arithmetic, over already-measured sizes rather than over `Subviews`.
    /// Split out and made static so it is reachable from a test: `LayoutSubviews` cannot
    /// be constructed outside a live layout pass, and "do these chips wrap or get sliced"
    /// is exactly the claim UX51 needs pinned. A subview wider than `width` on its own
    /// still gets a row rather than being dropped, because the break is only ever taken
    /// against a row that already holds something.
    static func rows(for sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row(indices: [], width: 0, height: 0)
        for (i, size) in sizes.enumerated() {
            let needsBreak = !current.indices.isEmpty && current.width + size.width + spacing > width
            if needsBreak {
                rows.append(current)
                current = Row(indices: [], width: 0, height: 0)
            }
            current.indices.append(i)
            current.width += size.width + (current.indices.count == 1 ? 0 : spacing)
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
