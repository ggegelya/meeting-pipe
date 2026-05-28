import AppKit

/// Horizontal pill showing the active workflow on the prompt panel and library row: emoji or color swatch + name, with a hover affordance. Click is forwarded via `onClick`; the chip has no knowledge of other workflows.
final class WorkflowChipView: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { needsDisplay = true } }
    private let titleLabel = NSTextField(labelWithString: "")
    private let leadingGlyph = NSView(frame: .zero)

    /// Workflow color parsed from hex by the caller. Drives the leading swatch fill. Default is signal-blue ("General" seed).
    var workflowColor: NSColor = MPColors.signal600 {
        didSet { leadingGlyph.layer?.backgroundColor = workflowColor.cgColor }
    }
    /// Emoji to render instead of the color swatch. Nil falls back to a filled circle in `workflowColor`.
    var emoji: String? {
        didSet { refreshGlyph() }
    }
    /// Display name shown next to the glyph, truncated tail-side.
    var workflowName: String = "" {
        didSet { titleLabel.stringValue = workflowName }
    }

    /// Click handler set by the caller (the prompt window builds and presents the workflow NSMenu).
    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        title = ""
        bezelStyle = .regularSquare
        wantsLayer = true
        target = self
        action = #selector(handleClick)

        leadingGlyph.translatesAutoresizingMaskIntoConstraints = false
        leadingGlyph.wantsLayer = true
        leadingGlyph.layer?.cornerRadius = 4
        addSubview(leadingGlyph)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: MPType.textSM, weight: MPType.medium)
        titleLabel.textColor = MPColors.fg
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            leadingGlyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            leadingGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingGlyph.widthAnchor.constraint(equalToConstant: 10),
            leadingGlyph.heightAnchor.constraint(equalToConstant: 10),

            titleLabel.leadingAnchor.constraint(equalTo: leadingGlyph.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 22),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let fill = isHovered ? MPColors.ink50 : MPColors.bgRaised.withAlphaComponent(0.55)
        fill.setFill()
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: MPRadius.sm,
            yRadius: MPRadius.sm
        )
        path.fill()
        MPColors.borderStrong.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    @objc private func handleClick() { onClick?() }

    private func refreshGlyph() {
        // Emoji replaces the swatch; chip height stays fixed so the action row's vertical rhythm doesn't shift.
        if let emoji = emoji, !emoji.isEmpty {
            leadingGlyph.layer?.backgroundColor = nil
            leadingGlyph.subviews.forEach { $0.removeFromSuperview() }
            let label = NSTextField(labelWithString: emoji)
            label.font = .systemFont(ofSize: 12)
            label.translatesAutoresizingMaskIntoConstraints = false
            leadingGlyph.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: leadingGlyph.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: leadingGlyph.centerYAnchor),
            ])
        } else {
            leadingGlyph.subviews.forEach { $0.removeFromSuperview() }
            leadingGlyph.layer?.backgroundColor = workflowColor.cgColor
        }
    }
}

/// Parse `#FF6B6B` or `FF6B6B` into NSColor. Returns nil for malformed input.
enum HexColor {
    static func parse(_ raw: String) -> NSColor? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8) & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
