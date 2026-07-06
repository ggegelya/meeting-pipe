import AppKit
import SwiftUI

/// The Instrument record key (DSN21/DSN24): a 40pt circular key with machined
/// geometry, the named exception to the one-button-language rule (see `MPButton`).
/// A concentric on-air ring (inset 5pt, 1.5pt) surrounds a coral core; the core is
/// a disc in `.record` (idle) and a rounded square in `.stop` (recording), so the
/// state is never carried by colour alone. Press travels 1.5pt down and compresses
/// the ring over 100ms (springless), honoring reduce-motion.
///
/// The key is colour + shape only; the beside/above text label ("Record" on the
/// prompt, "Recording" on the HUD) is the consuming surface's job. Built as an
/// `NSControl` so it drops into the AppKit prompt and HUD next to `MPButton`;
/// `RecordKeyView` wraps it for the SwiftUI Library toolbar.
final class RecordKey: NSControl {

    enum KeyState {
        /// Idle: coral disc, "press to start". The prompt and Library toolbar rest here.
        case record
        /// Recording: coral rounded square (a stop affordance). The HUD and an
        /// active Library rest here.
        case stop
    }

    /// Fixed geometry, mirroring the locked mockups. Exposed for tests and for the
    /// SwiftUI wrapper's intrinsic size.
    enum Geometry {
        static let side: CGFloat = 40
        static let ringInset: CGFloat = 5
        static let ringWidth: CGFloat = 1.5
        static let ringPressScale: CGFloat = 0.86
        static let pressTravel: CGFloat = 1.5
        static let discSize: CGFloat = 15   // .record core (circle)
        static let stopSize: CGFloat = 13   // .stop core (rounded square)
        static let stopRadius: CGFloat = 3

        /// Core edge length and corner radius for a state. A `.record` disc is a
        /// circle (corner radius = half its size); a `.stop` square is lightly
        /// rounded. Pure, so tests pin the disc-vs-square morph.
        static func core(for state: KeyState) -> (size: CGFloat, cornerRadius: CGFloat) {
            switch state {
            case .record: return (discSize, discSize / 2)
            case .stop:   return (stopSize, stopRadius)
            }
        }
    }

    var keyState: KeyState = .record {
        didSet {
            guard keyState != oldValue else { return }
            layoutCore()
            updateAccessibility()
        }
    }

    private let ringLayer = CALayer()
    private let coreLayer = CALayer()
    private var isPressed = false { didSet { guard isPressed != oldValue else { return }; applyPress() } }
    private var trackingArea: NSTrackingArea?

    init(state: KeyState = .record, target: AnyObject?, action: Selector?) {
        self.keyState = state
        super.init(frame: NSRect(x: 0, y: 0, width: Geometry.side, height: Geometry.side))
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.masksToBounds = false // let the drop shadow show
        ringLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ringLayer.borderWidth = Geometry.ringWidth
        ringLayer.backgroundColor = NSColor.clear.cgColor
        coreLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(ringLayer)
        layer?.addSublayer(coreLayer)
        applyColors()
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: Geometry.side, height: Geometry.side) }

    // MARK: Layout

    override func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if let layer = layer {
            layer.cornerRadius = bounds.width / 2 // capsule -> circle at 40pt
        }
        let ringSide = bounds.width - Geometry.ringInset * 2
        ringLayer.bounds = CGRect(x: 0, y: 0, width: ringSide, height: ringSide)
        ringLayer.cornerRadius = ringSide / 2
        ringLayer.position = center
        layoutCore()
    }

    private func layoutCore() {
        let (size, radius) = Geometry.core(for: keyState)
        coreLayer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        coreLayer.cornerRadius = radius
        coreLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    // MARK: Colours (appearance-aware; dynamic tokens resolve at draw time)

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MPColors.bgRaised.cgColor
            layer?.borderWidth = 0.5
            layer?.borderColor = MPColors.borderStrong.cgColor
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.06
            layer?.shadowRadius = 1.5
            layer?.shadowOffset = CGSize(width: 0, height: -1) // shadow-xs
            ringLayer.borderColor = MPColors.onair600.cgColor
            coreLayer.backgroundColor = MPColors.pulse600.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // MARK: Press (down 1.5pt + ring compress, 100ms)

    private func applyPress() {
        let reduce = MPMotion.reduceMotion
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduce ? 0 : MPMotion.durKey)
        CATransaction.setAnimationTimingFunction(MPMotion.easeOut)
        // Downward travel (AppKit layer y points up, so down is -y).
        layer?.transform = isPressed
            ? CATransform3DMakeTranslation(0, -Geometry.pressTravel, 0)
            : CATransform3DIdentity
        ringLayer.transform = isPressed
            ? CATransform3DMakeScale(Geometry.ringPressScale, Geometry.ringPressScale, 1)
            : CATransform3DIdentity
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        // Track the drag so releasing outside cancels, like a real button.
        var inside = true
        while true {
            guard let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
            if next.type == .leftMouseDragged {
                inside = bounds.contains(convert(next.locationInWindow, from: nil))
                isPressed = inside
            } else { // leftMouseUp
                inside = bounds.contains(convert(next.locationInWindow, from: nil))
                break
            }
        }
        isPressed = false
        if inside, isEnabled { sendAction(action, to: target) }
    }

    // MARK: Accessibility (state never colour-only; VoiceOver reads the verb)

    private func updateAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(keyState == .record ? "Record" : "Stop recording")
    }
}

/// SwiftUI host for `RecordKey`, for the Library toolbar (DSN27). Bridges the
/// AppKit control into a SwiftUI surface so the record key is one implementation
/// across both worlds.
struct RecordKeyView: NSViewRepresentable {
    var state: RecordKey.KeyState = .record
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> RecordKey {
        RecordKey(state: state, target: context.coordinator, action: #selector(Coordinator.fire))
    }

    func updateNSView(_ nsView: RecordKey, context: Context) {
        nsView.keyState = state
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}
