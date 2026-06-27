import AppKit

/// Design-system button. `.primary`: filled `signal600`, one-and-only primary action per surface. `.ghost`: `ink600` border, same size as primary but lower emphasis (e.g. "Record (BYO)" alongside "Record"). `.text`: bare text with hover tint for tertiary actions.
final class MPButton: NSButton {
    enum Style { case primary, ghost, text }

    private let mpStyle: Style
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    init(title: String, style: Style, target: AnyObject?, action: Selector?) {
        self.mpStyle = style
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        self.bezelStyle = .regularSquare
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.cornerRadius = MPRadius.sm
        self.layer?.masksToBounds = true
        self.contentTintColor = nil
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        // 26pt height: unified pill geometry shared with the chevron menu button (Roadmap P4.1) so the prompt's right cluster reads as one row. Width = text + 14pt padding each side.
        let textSize = (attributedTitle).size()
        let padX: CGFloat = mpStyle == .text ? 8 : 14
        return NSSize(width: ceil(textSize.width) + padX * 2, height: 26)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }
    override func mouseDown(with event: NSEvent) { isPressed = true; super.mouseDown(with: event); isPressed = false }

    override func draw(_ dirtyRect: NSRect) {
        applyStyle()
        super.draw(dirtyRect)
    }

    private func applyStyle() {
        guard let layer = layer else { return }

        let titleColor: NSColor
        switch mpStyle {
        case .primary:
            // The white label needs >= 4.5:1, so the resting fill is signal700
            // (white-on-teal 6.0:1), not signal600 (4.1:1, WCAG-failing) (UX14).
            // Hover lifts to signal600, press returns to signal700 for feedback.
            let fill: NSColor
            if isPressed { fill = MPColors.signal700 }
            else if isHovered { fill = MPColors.signal600 }
            else { fill = MPColors.signal700 }
            layer.backgroundColor = fill.cgColor
            layer.borderWidth = 0
            titleColor = MPColors.fgOnSignal

        case .ghost:
            // Resting fill on the dark hudWindow material is a faint tint, not clear: the 1pt
            // border alone wasn't enough affordance and labels blended into the body. On the
            // light HUD that same tint reads as an opaque box, so resting goes fill-less with a
            // faint border and the box returns on hover/press - keeps the prompt's right cluster
            // from looking boxy in light mode.
            let dark = effectiveAppearance.mpIsDark
            let fill: NSColor
            if isPressed { fill = MPColors.ink100 }
            else if isHovered { fill = MPColors.ink50 }
            else { fill = dark ? MPColors.bgRaised.withAlphaComponent(0.55) : .clear }
            layer.backgroundColor = fill.cgColor
            layer.borderWidth = 1
            let firmBorder = isHovered || isPressed
            layer.borderColor = (dark || firmBorder ? MPColors.borderStrong : MPColors.border).cgColor
            titleColor = MPColors.fg

        case .text:
            let fill: NSColor
            if isPressed { fill = MPColors.ink100 }
            else if isHovered { fill = MPColors.ink50 }
            else { fill = NSColor.clear }
            layer.backgroundColor = fill.cgColor
            layer.borderWidth = 0
            titleColor = MPColors.fgMuted
        }

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let weight: NSFont.Weight = mpStyle == .primary ? MPType.semibold : MPType.medium
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: MPType.textBase, weight: weight),
                .foregroundColor: titleColor,
                .paragraphStyle: para,
            ]
        )
    }

    /// Make the primary button respond to Return.
    func bindAsDefault() {
        keyEquivalent = "\r"
    }
}
