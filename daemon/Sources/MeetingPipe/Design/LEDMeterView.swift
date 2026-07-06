import AppKit

/// The Instrument voice-activity meter (DSN21/DSN24): discrete LED segments that
/// step rather than slide. Lit segments run on-air (the lit-LED accent); the rest
/// are hairline. Decorative by design (the coral dot + "Recording" label carry the
/// state), so it sits below the 3:1 UI floor like a real LED. Horizontal, 10
/// segments with a 2pt gap by default, matching the HUD meter the port (DSN25)
/// drives from the live RMS level.
final class LEDMeterView: NSView {

    let segmentCount: Int
    let gap: CGFloat
    let segmentRadius: CGFloat

    /// Number of lit segments (values outside 0...`segmentCount` simply render as
    /// all-off or all-on). Set directly, or via `level`.
    var litCount: Int = 0 {
        didSet { if oldValue != litCount { needsDisplay = true } }
    }

    /// Normalized activity, 0...1, mapped to lit segments (steps, no interpolation).
    var level: Float = 0 {
        didSet { litCount = LEDMeterView.litCount(forLevel: level, segments: segmentCount) }
    }

    init(segmentCount: Int = 10, gap: CGFloat = 2, segmentRadius: CGFloat = 1) {
        self.segmentCount = max(1, segmentCount)
        self.gap = gap
        self.segmentRadius = segmentRadius
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 6) }

    override var isFlipped: Bool { true } // left-to-right, top-anchored is irrelevant for full-height bars

    /// Lit-segment count for a normalized level (pure; pinned by tests). Rounds to
    /// the nearest segment so quiet speech still lights the first bar and a full
    /// level lights them all.
    static func litCount(forLevel level: Float, segments: Int) -> Int {
        guard segments > 0 else { return 0 }
        let clamped = max(0, min(1, level))
        return Int((clamped * Float(segments)).rounded())
    }

    override func draw(_ dirtyRect: NSRect) {
        guard segmentCount > 0 else { return }
        let totalGap = gap * CGFloat(segmentCount - 1)
        let segWidth = max(0, (bounds.width - totalGap) / CGFloat(segmentCount))
        let lit = MPColors.onair600
        let unlit = MPColors.border
        for i in 0..<segmentCount {
            let x = CGFloat(i) * (segWidth + gap)
            let rect = NSRect(x: x, y: 0, width: segWidth, height: bounds.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: segmentRadius, yRadius: segmentRadius)
            (i < litCount ? lit : unlit).setFill()
            path.fill()
        }
    }
}
