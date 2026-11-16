import AppKit

/// The meeting prompt's mic-activity pulse (REC18): four short bars in `onair600`, the DSN21
/// on-air LED accent, that breathe slowly while another app holds the microphone and rest dim
/// when none does. It replaces a live level meter that opened the microphone with its own
/// `AVAudioEngine` while the consent question was still on screen, so macOS showed MeetingPipe
/// using the mic before the owner had said yes. The pulse is driven by
/// `MeetingDiscoveryWatcher`'s mic-busy state (`isInUseByAnotherApplication`), which needs no
/// device open and carries no level: it says the meeting app holds the mic, nothing more.
/// 14x8pt bounding box, the old meter's footprint, so the prompt's layout is unchanged.
final class MicActivityPulseView: NSView {
    private static let barCount = 4
    private static let barWidth: CGFloat = 2
    private static let barGap: CGFloat = 2
    private static let viewHeight: CGFloat = 14
    static let intrinsicWidth: CGFloat = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap

    /// Fixed bar heights, a still echo of a level shape. Nothing here is a measurement.
    private static let barHeights: [CGFloat] = [0.45, 0.8, 0.6, 0.35]
    static let pulseKey = "mp.micActivityPulse"

    private let barLayers: [CALayer]
    private(set) var pulseAppearance = MicActivityPulse.Appearance.resting

    override init(frame frameRect: NSRect) {
        self.barLayers = (0..<Self.barCount).map { _ in CALayer() }
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        for bar in barLayers {
            bar.backgroundColor = MPColors.onair600.cgColor
            bar.cornerRadius = Self.barWidth / 2
            layer?.addSublayer(bar)
        }
        apply(.resting)
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

    /// Whether the pulse is animating now (a test reads this rather than the layer).
    var isPulsing: Bool { barLayers.first?.animation(forKey: Self.pulseKey) != nil }

    /// Follow the mic-busy signal.
    func setMicBusy(_ busy: Bool) {
        let next = MicActivityPulse.appearance(
            micBusy: busy,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        guard next != pulseAppearance else { return }
        apply(next)
    }

    private func apply(_ next: MicActivityPulse.Appearance) {
        pulseAppearance = next
        for bar in barLayers {
            bar.removeAnimation(forKey: Self.pulseKey)
            bar.opacity = next.opacity
            guard next == .pulsing else { continue }
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = MicActivityPulse.pulseLowOpacity
            breathe.toValue = 1.0
            breathe.duration = MicActivityPulse.halfPeriod
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(breathe, forKey: Self.pulseKey)
        }
    }

    private func layoutBars() {
        let h = bounds.height
        for (i, bar) in barLayers.enumerated() {
            let x = CGFloat(i) * (Self.barWidth + Self.barGap)
            let barH = max(2, Self.barHeights[i] * h)
            bar.frame = CGRect(x: x, y: (h - barH) / 2, width: Self.barWidth, height: barH)
        }
    }
}

/// The pulse's one decision, pure so a test can drive it.
enum MicActivityPulse {
    enum Appearance: Equatable {
        /// No app holds the mic: dim and still.
        case resting
        /// An app holds the mic, and motion is allowed: a slow breath.
        case pulsing
        /// An app holds the mic, under Reduce Motion: lit and still.
        case lit

        var opacity: Float {
            switch self {
            case .resting: return 0.3
            case .pulsing, .lit: return 1.0
            }
        }
    }

    /// Slow on purpose: a breath, not a meter (PRODUCT.md's quiet register). 1.4 s each way.
    static let halfPeriod: CFTimeInterval = 1.4
    static let pulseLowOpacity: Float = 0.45

    static func appearance(micBusy: Bool, reduceMotion: Bool) -> Appearance {
        guard micBusy else { return .resting }
        return reduceMotion ? .lit : .pulsing
    }
}
