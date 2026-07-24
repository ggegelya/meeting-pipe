import AppKit

/// CAL2: the "Last time" card, rendered inside the detection prompt panel rather
/// than in a window of its own. It is a stratum the panel grows to reveal, never
/// a popup: nothing appears unless the user asks for it, and asking for it does
/// not steal focus or cover the meeting they are joining.
///
/// Fixed row metrics and single-line truncation, so the exact height is known
/// before the view exists and the panel can animate to a frame the content then
/// fills. Truncation is the right trade here: the card answers "what was this
/// about", and the Library holds the full text one click away.
final class PrepCardView: NSView {

    /// Row geometry. The card is chrome, so these are fixed mac-native sizes
    /// (PRODUCT.md: Dynamic Type applies to content surfaces, not chrome).
    private enum Metric {
        static let separator: CGFloat = 1
        static let padTop: CGFloat = 10
        static let padBottom: CGFloat = 12
        static let titleRow: CGFloat = 18
        static let titleGap: CGFloat = 6
        static let row: CGFloat = 18
        static let sectionGap: CGFloat = 8
        static let eyebrow: CGFloat = 14
        static let eyebrowGap: CGFloat = 3
        static let moreRow: CGFloat = 16
        static let leftInset: CGFloat = 14
        static let rightInset: CGFloat = 12
        /// Bullet column: the glyph sits in it and the text starts after it, so
        /// every row lines up down the card.
        static let bulletColumn: CGFloat = 15
    }

    /// Where each row starts, measured from the card's top edge, plus the total
    /// height that follows from them. One arithmetic pass shared by the layout
    /// and by `height(for:)`, so the panel can never animate to a frame the
    /// content does not fill.
    struct Layout {
        var titleTop: CGFloat = 0
        var pointTops: [CGFloat] = []
        var eyebrowTop: CGFloat?
        var actionTops: [CGFloat] = []
        var moreTop: CGFloat?
        var height: CGFloat = 0
    }

    static func layout(for card: PrepCard) -> Layout {
        var out = Layout()
        var y = Metric.separator + Metric.padTop
        out.titleTop = y
        y += Metric.titleRow
        if !card.points.isEmpty {
            y += Metric.titleGap
            for _ in card.points {
                out.pointTops.append(y)
                y += Metric.row
            }
        }
        if !card.actions.isEmpty {
            y += Metric.sectionGap
            out.eyebrowTop = y
            y += Metric.eyebrow + Metric.eyebrowGap
            for _ in card.actions {
                out.actionTops.append(y)
                y += Metric.row
            }
            if card.moreActions > 0 {
                out.moreTop = y
                y += Metric.moreRow
            }
        }
        out.height = y + Metric.padBottom
        return out
    }

    /// Exact height this card needs, callable before the view is built.
    static func height(for card: PrepCard) -> CGFloat { layout(for: card).height }

    /// One action on one line: the task, then whoever owns it and when it is due.
    /// Middle dots rather than parentheses so the line still reads when
    /// truncation eats the tail.
    static func actionLine(_ action: PrepCard.Action) -> String {
        var parts = [action.task]
        if let owner = action.owner { parts.append(owner) }
        if let due = action.due { parts.append("due \(due)") }
        return parts.joined(separator: "  ·  ")
    }

    init(card: PrepCard, now: Date) {
        super.init(frame: .zero)
        wantsLayer = true
        let metrics = Self.layout(for: card)
        var constraints: [NSLayoutConstraint] = []

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        constraints += [
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(equalToConstant: Metric.separator),
        ]

        let title = Self.label(card.title, size: MPType.textBase,
                               weight: MPType.semibold, color: MPColors.fg)
        addSubview(title)
        let when = Self.label(card.relativeDay(now: now), size: MPType.textXS,
                              weight: MPType.regular, color: MPColors.fgMuted)
        when.alignment = .right
        when.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(when)
        constraints += [
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metric.leftInset),
            title.topAnchor.constraint(equalTo: topAnchor, constant: metrics.titleTop),
            title.trailingAnchor.constraint(lessThanOrEqualTo: when.leadingAnchor,
                                            constant: -MPSpace.s2),
            when.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metric.rightInset),
            when.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ]

        for (point, top) in zip(card.points, metrics.pointTops) {
            let bullet = Self.label("·", size: MPType.textSM,
                                    weight: MPType.regular, color: MPColors.fgMuted)
            addSubview(bullet)
            let text = Self.label(point, size: MPType.textSM,
                                  weight: MPType.regular, color: MPColors.fg)
            addSubview(text)
            constraints += [
                bullet.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                constant: Metric.leftInset),
                bullet.firstBaselineAnchor.constraint(equalTo: text.firstBaselineAnchor),
                text.leadingAnchor.constraint(equalTo: leadingAnchor,
                                              constant: Metric.leftInset + Metric.bulletColumn),
                text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                               constant: -Metric.rightInset),
                text.topAnchor.constraint(equalTo: topAnchor, constant: top),
            ]
        }

        if let eyebrowTop = metrics.eyebrowTop {
            let eyebrow = NSTextField(labelWithString: "OPEN ACTIONS")
            eyebrow.attributedStringValue = NSAttributedString(
                string: "OPEN ACTIONS",
                attributes: [
                    .font: NSFont.mpEyebrow(),
                    .foregroundColor: MPColors.fgMuted,
                    .kern: 0.4,
                ]
            )
            eyebrow.translatesAutoresizingMaskIntoConstraints = false
            addSubview(eyebrow)
            constraints += [
                eyebrow.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                 constant: Metric.leftInset),
                eyebrow.topAnchor.constraint(equalTo: topAnchor, constant: eyebrowTop),
            ]
        }

        for (action, top) in zip(card.actions, metrics.actionTops) {
            let bullet = NSImageView()
            bullet.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
            bullet.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: MPType.textXS, weight: .regular
            )
            bullet.contentTintColor = MPColors.fgMuted
            bullet.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bullet)
            let text = Self.label(Self.actionLine(action), size: MPType.textSM,
                                  weight: MPType.regular, color: MPColors.fg)
            addSubview(text)
            constraints += [
                bullet.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                constant: Metric.leftInset),
                bullet.centerYAnchor.constraint(equalTo: text.centerYAnchor),
                text.leadingAnchor.constraint(equalTo: leadingAnchor,
                                              constant: Metric.leftInset + Metric.bulletColumn),
                text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                               constant: -Metric.rightInset),
                text.topAnchor.constraint(equalTo: topAnchor, constant: top),
            ]
        }

        if let moreTop = metrics.moreTop {
            let more = Self.label("\(card.moreActions) more in the Library",
                                  size: MPType.textXS, weight: MPType.regular,
                                  color: MPColors.fgMuted)
            addSubview(more)
            constraints += [
                more.leadingAnchor.constraint(equalTo: leadingAnchor,
                                              constant: Metric.leftInset + Metric.bulletColumn),
                more.topAnchor.constraint(equalTo: topAnchor, constant: moreTop),
            ]
        }

        NSLayoutConstraint.activate(constraints)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Last time in \(card.workflowName)")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func label(_ text: String, size: CGFloat,
                              weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}
