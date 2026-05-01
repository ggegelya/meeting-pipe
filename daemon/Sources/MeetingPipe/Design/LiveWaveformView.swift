import AppKit

/// 4-bar live audio meter rendered in `signal600`. Reads from the mic via
/// `MicLevelMonitor` (started/stopped by the prompt window's lifecycle).
///
/// Visual: 14×8pt bounding box, 2pt-wide bars with 2pt gaps, heights
/// driven by recent level samples. The newest sample appears on the right;
/// older samples shift left so the bars feel like a moving sound wave
/// rather than 4 independent meters.
///
/// Privacy: this view is purely visual; the sample buffer is computed and
/// discarded inside `MicLevelMonitor`. The accompanying eyebrow copy on
/// the prompt makes the contract explicit ("Listening for level only —
/// nothing is captured until you choose Record.").
final class LiveWaveformView: NSView {
    private static let barCount = 4
    private static let barWidth: CGFloat = 2
    private static let barGap:   CGFloat = 2
    private static let viewHeight: CGFloat = 14
    static let intrinsicWidth: CGFloat = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap

    /// Floor: bars never collapse to zero — even silence shows a 2pt baseline,
    /// matching the JSX prototype's `Math.max(0.18, ...)`.
    private static let levelFloor: Float = 0.18

    private var levels: [CGFloat] = Array(repeating: 0.4, count: LiveWaveformView.barCount)
    private let barLayers: [CALayer]

    override init(frame frameRect: NSRect) {
        self.barLayers = (0..<Self.barCount).map { _ in CALayer() }
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        for bar in barLayers {
            bar.backgroundColor = MPColors.signal600.cgColor
            bar.cornerRadius = Self.barWidth / 2
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)   // grow from middle
            layer?.addSublayer(bar)
        }
        layoutBars()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.intrinsicWidth, height: Self.viewHeight)
    }

    override func layout() {
        super.layout()
        layoutBars()
    }

    /// Push a new mic-level sample (0...1). Older samples shift left.
    func push(level: Float) {
        let clamped = CGFloat(min(1, max(Self.levelFloor, level)))
        levels.removeFirst()
        levels.append(clamped)
        // Animate bar heights together; the layout itself doesn't move.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.09)   // matches JSX 90ms tick
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        layoutBars()
        CATransaction.commit()
    }

    private func layoutBars() {
        let h = bounds.height
        for (i, bar) in barLayers.enumerated() {
            let x = CGFloat(i) * (Self.barWidth + Self.barGap)
            let barH = max(2, levels[i] * h)
            let y = (h - barH) / 2
            bar.frame = CGRect(x: x, y: y, width: Self.barWidth, height: barH)
        }
    }
}
