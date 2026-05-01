import AppKit

/// Buttons styled per the design system.
///
/// `.primary` — filled `signal600`, white text. The one-and-only primary
///              action on a surface (per the design rule "Signal blue used
///              surgically").
/// `.ghost`   — transparent fill, `ink600` border, `fg` text. Secondary
///              actions of equal weight to primary in size, but lower in
///              emphasis (e.g. "Record (BYO)" alongside "Record").
/// `.text`    — bare text with hover tint. Tertiary actions ("Skip",
///              "Always for X") that should not compete for attention.
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
        // 28pt control height — slightly tighter than NSButton default but
        // matches mac chrome density. Width fits text + 14pt horizontal
        // padding either side.
        let textSize = (attributedTitle).size()
        let padX: CGFloat = mpStyle == .text ? 8 : 14
        return NSSize(width: ceil(textSize.width) + padX * 2, height: 28)
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
            // Press: 8% darken via signal700; hover: signal500.
            let fill: NSColor
            if isPressed { fill = MPColors.signal700 }
            else if isHovered { fill = MPColors.signal500 }
            else { fill = MPColors.signal600 }
            layer.backgroundColor = fill.cgColor
            layer.borderWidth = 0
            titleColor = MPColors.fgOnSignal

        case .ghost:
            let fill: NSColor
            if isPressed { fill = MPColors.ink100 }
            else if isHovered { fill = MPColors.ink50 }
            else { fill = NSColor.clear }
            layer.backgroundColor = fill.cgColor
            layer.borderWidth = 1
            layer.borderColor = MPColors.borderStrong.cgColor
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
