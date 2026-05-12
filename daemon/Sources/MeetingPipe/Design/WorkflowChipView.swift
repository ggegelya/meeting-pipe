import AppKit

/// Small horizontal pill that surfaces the active workflow on the prompt
/// panel + library row. Visual: emoji or color swatch + name in a rounded
/// rect, with a hover affordance. Clicking pops up the override menu the
/// prompt window owns — the chip itself doesn't know about other
/// workflows; the click is forwarded to a closure the caller sets up.
final class WorkflowChipView: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { needsDisplay = true } }
    private let titleLabel = NSTextField(labelWithString: "")
    private let leadingGlyph = NSView(frame: .zero)

    /// Resolved workflow color (parsed from hex string by the caller).
    /// Drives both the leading swatch fill and the chip's left border
    /// accent. Default is the signal-blue used for the "General" seed.
    var workflowColor: NSColor = MPColors.signal600 {
        didSet { leadingGlyph.layer?.backgroundColor = workflowColor.cgColor }
    }
    /// Emoji to render instead of a color swatch. Optional; nil falls
    /// back to a filled circle in `workflowColor`.
    var emoji: String? {
        didSet { refreshGlyph() }
    }
    /// Display name shown next to the glyph. Truncated tail-side.
    var workflowName: String = "" {
        didSet { titleLabel.stringValue = workflowName }
    }

    /// Caller-provided click handler. The prompt window builds and
    /// presents an NSMenu of available workflows inside this; we don't
    /// own that data here.
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
        // When an emoji is set we hide the colored swatch and render the
        // glyph itself as the leading marker. The chip stays a fixed
        // height so the action row's vertical rhythm doesn't shift.
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

/// Parse a hex color string like "#FF6B6B" or "FF6B6B" into NSColor.
/// Returns nil for malformed input; the caller falls back to a default.
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
