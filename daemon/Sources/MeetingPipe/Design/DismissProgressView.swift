import AppKit

/// 2pt progress hairline at the bottom of the prompt panel that drains over `timeoutSec`. Mirrors the JSX `DismissBar`. Anchor leading/trailing/bottom at height 2, call `start(timeoutSec:)`, then `stop()` on dismiss. `setPaused(_:)` is wired by the host window's mouse tracking.
final class DismissProgressView: NSView {
    private let track = CALayer()    // sunk hairline track
    private let fill  = CALayer()    // signal600 fill that drains

    private var totalDuration: TimeInterval = 30
    private var elapsedAtPauseStart: TimeInterval = 0
    private var pauseStart: Date?
    private var tickTimer: Timer?
    private var startedAt: Date?

    private(set) var isPaused: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        track.backgroundColor = NSColor.black.withAlphaComponent(0.05).cgColor
        layer?.addSublayer(track)

        fill.backgroundColor = MPColors.signal600.cgColor
        fill.opacity = 0.60
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        track.frame = bounds
        // fill width updated by tick loop
        if startedAt == nil {
            fill.frame = bounds
        }
    }

    func start(timeoutSec: TimeInterval) {
        stop()
        totalDuration = max(1, timeoutSec)
        startedAt = Date()
        elapsedAtPauseStart = 0
        pauseStart = nil
        isPaused = false
        fill.opacity = 0.60
        fill.frame = bounds
        // 60 Hz tick: smooth enough without the cost of a CVDisplayLink. Fires on the main runloop.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        startedAt = nil
        pauseStart = nil
    }

    /// Freeze the fill at its current width and dim to 30% alpha so it reads as paused, not stalled.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            pauseStart = Date()
            fill.opacity = 0.30
        } else if let start = pauseStart {
            elapsedAtPauseStart += Date().timeIntervalSince(start)
            pauseStart = nil
            fill.opacity = 0.60
        }
    }

    // MARK: Tick loop

    private func tick() {
        guard let started = startedAt, !isPaused else { return }
        let raw = Date().timeIntervalSince(started)
        let elapsed = raw - elapsedAtPauseStart
        let remaining = max(0, 1 - elapsed / totalDuration)

        // Disable implicit animation so the fill glides smoothly rather than hopping with CA's default 0.25s curve.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 0,
                            width: bounds.width * CGFloat(remaining),
                            height: bounds.height)
        CATransaction.commit()

        if remaining <= 0 { stop() }
    }
}
