import AppKit

/// Design-system button, the one button language (DSN24). Capsule geometry (macOS 26): `--mp-radius-full`, 26pt tall, 13pt side padding. `.primary`: filled `signalFill` (the deep teal that clears white-on-teal 4.5:1 in both modes, DSN23), the one-and-only primary action per surface. `.ghost`: hairline border, same size as primary but lower emphasis (e.g. "Record (BYO)" alongside the record key). `.text`: bare text with hover tint for tertiary actions. Press scales to 0.97 (the blessed press feedback), honoring reduce-motion. The circular record key is the named exception to this one-button rule (see `RecordKey`).
final class MPButton: NSButton {
    enum Style { case primary, ghost, text }

    private let mpStyle: Style
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }
            applyPressScale()
            needsDisplay = true
        }
    }
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
        self.layer?.cornerRadius = MPRadius.full // capsule (macOS 26); clamps to half-height at this 26pt size
        self.layer?.masksToBounds = true
        self.contentTintColor = nil
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        // 26pt height: unified capsule geometry shared with the chevron menu button (Roadmap P4.1) so the prompt's right cluster reads as one row. Width = text + 13pt padding each side (DSN24).
        let textSize = (attributedTitle).size()
        let padX: CGFloat = mpStyle == .text ? 8 : 13
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
            // Deep teal that clears white-on-teal 4.5:1 in both modes (signalFill,
            // DSN23). Flat like the locked capsule mockup: no hover/press colour
            // change, the tactile feedback is the 0.97 press scale below.
            layer.backgroundColor = MPColors.signalFill.cgColor
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

    /// Blessed press feedback (DSN24): scale to 0.97 over 130ms, honoring
    /// reduce-motion. An NSView-backed layer anchors at (0,0), so scale about the
    /// bounds centre via translate -> scale -> translate-back.
    private func applyPressScale() {
        guard let layer = layer else { return }
        let scale: CGFloat = isPressed ? 0.97 : 1.0
        let mid = CGPoint(x: bounds.midX, y: bounds.midY)
        let transform = CATransform3DConcat(
            CATransform3DConcat(
                CATransform3DMakeTranslation(-mid.x, -mid.y, 0),
                CATransform3DMakeScale(scale, scale, 1)),
            CATransform3DMakeTranslation(mid.x, mid.y, 0))
        CATransaction.begin()
        CATransaction.setAnimationDuration(MPMotion.reduceMotion ? 0 : MPMotion.durPress)
        CATransaction.setAnimationTimingFunction(MPMotion.easeOut)
        layer.transform = transform
        CATransaction.commit()
    }

    /// Make the primary button respond to Return.
    func bindAsDefault() {
        keyEquivalent = "\r"
    }
}
