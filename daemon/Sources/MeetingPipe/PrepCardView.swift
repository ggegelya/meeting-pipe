import AppKit

/// CAL2: the "Last time" card, rendered inside the detection prompt panel rather
/// than in a window of its own. It is a stratum the panel grows to reveal, never
/// a popup: nothing appears unless the user asks for it, and asking for it does
/// not steal focus or cover the meeting they are joining.
///
/// Rows measure and wrap (UX47), and the exact height is still known before the
/// view exists, so the panel can animate to a frame the content then fills. The
/// original CAL2 trade here was single-line truncation ("the Library holds the
/// full text one click away"); the owner overruled it from a live prompt on
/// 2026-07-30, and the UX34 cap is what makes wrapping affordable: complete
/// sentences spend height, and the viewport contains the spend.
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

    /// The width the body text wraps at inside a card of `width`: everything
    /// left of it (inset + bullet column) and right of it (inset) removed.
    static func textWidth(cardWidth: CGFloat) -> CGFloat {
        max(1, cardWidth - Metric.leftInset - Metric.bulletColumn - Metric.rightInset)
    }

    /// Wrapped height of one body string at the card's text width, with the
    /// same font the label renders in, so the arithmetic and the view agree.
    private static func measuredHeight(_ text: String, textWidth: CGFloat) -> CGFloat {
        let bounds = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: MPType.textSM)]
        ).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )
        return ceil(bounds.height)
    }

    static func layout(for card: PrepCard, width: CGFloat) -> Layout {
        let textWidth = Self.textWidth(cardWidth: width)
        // Self-calibrating row gap (UX47): a single-line row must advance exactly
        // the old fixed `Metric.row`, so every pre-wrap card height, and the
        // `PrepDisclosure` clamp arithmetic pinned against it, stays byte-identical.
        // Measuring a one-line probe here instead of hardcoding the font's line
        // height keeps that true across font-metric changes.
        let singleLine = measuredHeight("x", textWidth: textWidth)
        let gap = Metric.row - singleLine
        func advance(_ text: String) -> CGFloat {
            max(Metric.row, measuredHeight(text, textWidth: textWidth) + gap)
        }

        var out = Layout()
        var y = Metric.separator + Metric.padTop
        out.titleTop = y
        y += Metric.titleRow
        if !card.points.isEmpty {
            y += Metric.titleGap
            for point in card.points {
                out.pointTops.append(y)
                y += advance(point)
            }
        }
        if !card.actions.isEmpty {
            y += Metric.sectionGap
            out.eyebrowTop = y
            y += Metric.eyebrow + Metric.eyebrowGap
            for action in card.actions {
                out.actionTops.append(y)
                y += advance(Self.actionLine(action))
            }
            if card.moreActions > 0 {
                out.moreTop = y
                y += Metric.moreRow
            }
        }
        out.height = y + Metric.padBottom
        return out
    }

    /// Exact height this card needs at this width, callable before the view is built.
    static func height(for card: PrepCard, width: CGFloat) -> CGFloat {
        layout(for: card, width: width).height
    }

    /// UX34: the tallest viewport the prompt panel hands this card. Content past
    /// it scrolls instead of the panel growing, so the prompt stays a fixed size
    /// rather than quadrupling: a full 3+3 card is ~196pt on top of the 64pt pill,
    /// which is the ~260pt panel the owner reported covering the meeting window.
    ///
    /// Derived from the single-line row metrics UX34 shipped against: the card's
    /// head, a full `PrepCard.maxPoints` recap, the eyebrow, and half an action
    /// row, 123pt. The half-row slice was UX34's scroll cue, on the theory that a
    /// beheaded row tells the eye to scroll; the owner's 2026-07-30 read of it
    /// ("this is not okay") settled that theory, so under UX47 the cue is the
    /// bottom fade instead and this constant is simply the panel's fixed card
    /// budget, which wrapped rows spend faster than single lines did.
    static let maxCardHeight: CGFloat =
        Metric.separator + Metric.padTop + Metric.titleRow + Metric.titleGap
        + CGFloat(PrepCard.maxPoints) * Metric.row
        + Metric.sectionGap + Metric.eyebrow + Metric.eyebrowGap
        + Metric.row / 2

    /// Top-left origin, because the card is an `NSScrollView` document view now
    /// (UX34) and an unflipped one opens showing its *last* row. Auto Layout
    /// anchors are orientation-independent, so the rows below land unchanged.
    override var isFlipped: Bool { true }

    /// One action on one line: the task, then whoever owns it and when it is due.
    /// Middle dots rather than parentheses so the line still reads when
    /// truncation eats the tail.
    static func actionLine(_ action: PrepCard.Action) -> String {
        var parts = [action.task]
        if let owner = action.owner { parts.append(owner) }
        if let due = action.due { parts.append("due \(due)") }
        return parts.joined(separator: "  ·  ")
    }

    init(card: PrepCard, now: Date, width: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        let metrics = Self.layout(for: card, width: width)
        let textWidth = Self.textWidth(cardWidth: width)
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
            let text = Self.wrappingLabel(point, textWidth: textWidth, color: MPColors.fg)
            addSubview(text)
            constraints += [
                bullet.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                constant: Metric.leftInset),
                bullet.firstBaselineAnchor.constraint(equalTo: text.firstBaselineAnchor),
                text.leadingAnchor.constraint(equalTo: leadingAnchor,
                                              constant: Metric.leftInset + Metric.bulletColumn),
                // Equality, not the old <=: a wrapping label needs the exact edge
                // to wrap at, and the measured layout above assumed it.
                text.trailingAnchor.constraint(equalTo: trailingAnchor,
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
            let text = Self.wrappingLabel(Self.actionLine(action), textWidth: textWidth,
                                          color: MPColors.fg)
            addSubview(text)
            constraints += [
                bullet.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                constant: Metric.leftInset),
                // On the first line, not the block's centre: a wrapped action
                // would otherwise float its ring between lines.
                bullet.centerYAnchor.constraint(equalTo: text.firstBaselineAnchor,
                                                constant: -4),
                text.leadingAnchor.constraint(equalTo: leadingAnchor,
                                              constant: Metric.leftInset + Metric.bulletColumn),
                text.trailingAnchor.constraint(equalTo: trailingAnchor,
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

    /// Body text wraps (UX47); chrome labels above stay single-line. The
    /// preferred width matches what `layout(for:width:)` measured against, so
    /// the label's intrinsic height and the precomputed row top agree.
    private static func wrappingLabel(_ text: String, textWidth: CGFloat,
                                      color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: MPType.textSM)
        field.textColor = color
        field.preferredMaxLayoutWidth = textWidth
        field.isSelectable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}
