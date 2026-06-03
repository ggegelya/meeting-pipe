import AppKit

/// 2pt progress hairline at the bottom of the prompt panel that drains over
/// `timeoutSec`. Mirrors the JSX `DismissBar`. Anchor leading/trailing/bottom at
/// height 2, call `start(timeoutSec:)`, then `stop()` on dismiss. `setPaused(_:)`
/// is wired by the host window's mouse tracking.
///
/// TECH-PERF4: the drain is a single CoreAnimation keyframe on the fill layer's
/// `transform.scale.x` (left-anchored), so it runs on the render server and the
/// main thread idles between frames instead of waking 60x/sec on a `Timer`.
/// Pause/resume uses the standard CALayer speed/timeOffset freeze, so no
/// per-frame work runs while the user hovers the panel.
final class DismissProgressView: NSView {
    private let track = CALayer()    // sunk hairline track
    private let fill  = CALayer()    // signal600 fill that drains

    private static let drainKey = "mp.dismiss.drain"

    private var isRunning = false
    private(set) var isPaused: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        track.backgroundColor = NSColor.black.withAlphaComponent(0.05).cgColor
        layer?.addSublayer(track)

        // Left-anchored so a scale-x shrink drains the right edge toward the
        // left, matching the old width-reducing tick.
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.backgroundColor = MPColors.signal600.cgColor
        fill.opacity = 0.60
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        track.frame = bounds
        // Keep the fill geometry in sync with a resize while idle; during a
        // drain CoreAnimation owns the transform, so leave it untouched.
        if !isRunning {
            resetFillGeometry()
        }
    }

    func start(timeoutSec: TimeInterval) {
        stop()
        let duration = max(1, timeoutSec)
        isPaused = false
        isRunning = true
        fill.opacity = 0.60
        resetFillGeometry()
        fill.speed = 1
        fill.timeOffset = 0
        fill.beginTime = 0

        // Settle the model on the drained state so the bar stays empty after the
        // keyframe finishes, then animate from full to empty over the timeout.
        fill.transform = CATransform3DMakeScale(0, 1, 1)
        let anim = CABasicAnimation(keyPath: "transform.scale.x")
        anim.fromValue = 1.0
        anim.toValue = 0.0
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        fill.add(anim, forKey: Self.drainKey)
    }

    func stop() {
        fill.removeAnimation(forKey: Self.drainKey)
        fill.speed = 1
        fill.timeOffset = 0
        fill.beginTime = 0
        fill.transform = CATransform3DIdentity
        isRunning = false
        isPaused = false
    }

    /// Freeze the fill at its current width and dim to 30% alpha so it reads as
    /// paused, not stalled. The CALayer speed/timeOffset freeze stops the drain
    /// without any per-frame work.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        fill.opacity = paused ? 0.30 : 0.60
        guard isRunning else { return }
        if paused {
            let pausedTime = fill.convertTime(CACurrentMediaTime(), from: nil)
            fill.speed = 0
            fill.timeOffset = pausedTime
        } else {
            let pausedTime = fill.timeOffset
            fill.speed = 1
            fill.timeOffset = 0
            fill.beginTime = 0
            let timeSincePause = fill.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
            fill.beginTime = timeSincePause
        }
    }

    /// Left-anchored, full-width, vertically centred, identity transform: the
    /// idle/pre-drain state the keyframe scales down from.
    private func resetFillGeometry() {
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        fill.position = CGPoint(x: bounds.minX, y: bounds.midY)
        fill.transform = CATransform3DIdentity
    }
}
