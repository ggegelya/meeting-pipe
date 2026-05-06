import AppKit

/// Floating recording-status HUD shown during `.recording`. Compact vertical
/// pill, top-right of the screen, always-on-top. Two reasons it exists:
///
///   1. **Visibility** — the menu-bar icon flips to a coral dot, but that
///      surface is easy to miss when other apps are foregrounded. The HUD
///      makes "I am recording right now" unambiguous and at-a-glance.
///
///   2. **One-click stop** — the previous flow required clicking the
///      menu-bar icon, then "Stop Recording". For a panic moment ("oh
///      this got sensitive, kill it") that's two clicks too many. The
///      HUD's stop button is the same gesture as Notion's record-pill
///      stop affordance.
///
/// Drag-to-reposition is intentional: if the HUD covers a Zoom control or
/// a chat avatar, the user moves it. `NSPanel.isMovableByWindowBackground`
/// gives us that for free.
protocol RecordingHUDDelegate: AnyObject {
    func recordingHUDDidRequestStop(_ hud: RecordingHUDWindow)
}

/// Threading: every public method must run on the main queue. Same contract
/// as `MeetingPromptWindow`.
final class RecordingHUDWindow {
    weak var delegate: RecordingHUDDelegate?

    private var panel: NSPanel?
    private var elapsedLabel: NSTextField?
    private var pulseDot: PulseDotView?
    private var ticker: Timer?
    private var startedAt: Date?

    private static let panelWidth: CGFloat = 60
    private static let panelHeight: CGFloat = 132
    private static let edgeInset: CGFloat = 16

    func present(source: AppSource?, startedAt: Date) {
        dismiss(animated: false)
        self.startedAt = startedAt

        let panel = makePanel(source: source)
        self.panel = panel
        positionPanel(panel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = MPMotion.durBase
            ctx.timingFunction = MPMotion.easeOut
            panel.animator().alphaValue = 1
        }

        // Update mm:ss every 500ms — half-second cadence is smooth without
        // being jittery, and it costs nothing.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshElapsedLabel()
        }
        refreshElapsedLabel()
        pulseDot?.startPulsing()
    }

    func dismiss(animated: Bool = true) {
        ticker?.invalidate()
        ticker = nil
        startedAt = nil
        pulseDot?.stopPulsing()

        guard let panel = panel else { return }
        self.panel = nil
        self.elapsedLabel = nil
        self.pulseDot = nil

        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = MPMotion.durFast + 0.03
            ctx.timingFunction = MPMotion.easeOut
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // MARK: Panel construction

    private func makePanel(source: AppSource?) -> NSPanel {
        let rect = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false

        panel.contentView = makeContentView(source: source)
        return panel
    }

    private func makeContentView(source: AppSource?) -> NSView {
        let bg = HUDBackgroundView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight))
        bg.cornerRadius = MPRadius.lg
        bg.host = self

        // Top: app glyph (24×24). Falls back to the menubar mark if the
        // recording was started manually (no source).
        let glyph: NSView
        if let source = source {
            let g = AppGlyphView(source: source)
            glyph = g
        } else {
            let g = NSImageView(frame: .zero)
            g.translatesAutoresizingMaskIntoConstraints = false
            g.image = Self.fallbackGlyph()
            g.imageScaling = .scaleProportionallyUpOrDown
            glyph = g
        }
        bg.addSubview(glyph)

        let dot = PulseDotView(frame: .zero)
        dot.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(dot)
        self.pulseDot = dot

        let elapsed = NSTextField(labelWithString: "0:00")
        elapsed.font = .monospacedDigitSystemFont(ofSize: MPType.textSM, weight: MPType.medium)
        elapsed.textColor = MPColors.fg
        elapsed.alignment = .center
        elapsed.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(elapsed)
        self.elapsedLabel = elapsed

        let stop = StopButton(target: bg, action: #selector(HUDBackgroundView.didClickStop))
        stop.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stop)

        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            glyph.topAnchor.constraint(equalTo: bg.topAnchor, constant: 12),
            glyph.widthAnchor.constraint(equalToConstant: 24),
            glyph.heightAnchor.constraint(equalToConstant: 24),

            dot.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            dot.topAnchor.constraint(equalTo: glyph.bottomAnchor, constant: 10),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            elapsed.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            elapsed.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            elapsed.topAnchor.constraint(equalTo: dot.bottomAnchor, constant: 4),

            stop.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            stop.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -10),
            stop.widthAnchor.constraint(equalToConstant: 30),
            stop.heightAnchor.constraint(equalToConstant: 30),
        ])
        return bg
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - Self.panelWidth - Self.edgeInset,
            y: visible.maxY - Self.panelHeight - Self.edgeInset
        )
        panel.setFrameOrigin(origin)
    }

    private func refreshElapsedLabel() {
        guard let started = startedAt, let label = elapsedLabel else { return }
        let s = Int(Date().timeIntervalSince(started))
        let mins = s / 60
        let secs = s % 60
        label.stringValue = String(format: "%d:%02d", mins, secs)
    }

    fileprivate func handleStop() {
        delegate?.recordingHUDDidRequestStop(self)
    }

    private static func fallbackGlyph() -> NSImage {
        // Same waveform mark used in the menu-bar icon, drawn as a vector
        // so it scales cleanly inside the 24×24 slot.
        let img = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            let s = rect.width / 18.0
            let bars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
                (4.5, 8.0, 2.0), (6.6, 6.4, 5.2), (8.7, 5.0, 8.0),
                (10.8, 6.8, 4.4), (12.9, 8.0, 2.0),
            ]
            MPColors.fg.setFill()
            for bar in bars {
                let r = NSRect(x: bar.x * s, y: bar.y * s, width: 1.4 * s, height: bar.h * s)
                NSBezierPath(roundedRect: r, xRadius: 0.7 * s, yRadius: 0.7 * s).fill()
            }
            return true
        }
        img.accessibilityDescription = "Recording"
        return img
    }
}

// MARK: - HUD chrome

/// Translucent rounded background. Same hudWindow material as the prompt
/// panel so the two HUDs feel like the same surface family.
private final class HUDBackgroundView: NSView {
    var cornerRadius: CGFloat = MPRadius.lg { didSet { needsLayout = true } }
    weak var host: RecordingHUDWindow?

    private let blur = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = MPColors.border.cgColor

        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSAppearance(named: .vibrantDark)
            : NSAppearance(named: .vibrantLight)
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = cornerRadius
        layer?.borderColor = MPColors.border.cgColor
    }

    @objc func didClickStop() { host?.handleStop() }
}

/// Coral pulse dot driven by a Core Animation opacity loop. The animation
/// runs while the HUD is up and stops on dismiss so it doesn't leak past
/// the recording lifecycle.
private final class PulseDotView: NSView {
    private let dot = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(dot)
        dot.backgroundColor = MPColors.pulse600.cgColor
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let size = min(bounds.width, bounds.height)
        dot.frame = CGRect(
            x: (bounds.width - size) / 2,
            y: (bounds.height - size) / 2,
            width: size, height: size
        )
        dot.cornerRadius = size / 2
    }

    func startPulsing() {
        // Opacity-axis pulse (not scale): a recording-status indicator
        // that subtly grows and shrinks reads as a UI toggle, not as a
        // live state. Fading-in-and-out at the same physical size feels
        // like a heartbeat, which is the right metaphor. Design doc
        // targets a 1.6s loop (autoreverse, so 0.8s in each direction).
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.35
        anim.duration = 0.8
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(anim, forKey: "pulse")
    }

    func stopPulsing() {
        dot.removeAnimation(forKey: "pulse")
    }
}

/// Round red stop button with hover/press affordances. The square fill
/// inside is centered and slightly inset, matching iOS-style record stops.
private final class StopButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
        title = ""
        toolTip = "Stop recording"
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
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }
    override func mouseDown(with event: NSEvent) { isPressed = true; super.mouseDown(with: event); isPressed = false }

    override func draw(_ dirtyRect: NSRect) {
        let ring: NSColor
        if isPressed { ring = MPColors.pulse600 }
        else if isHovered { ring = MPColors.pulse500 }
        else { ring = MPColors.pulse600 }
        ring.setFill()
        NSBezierPath(ovalIn: bounds).fill()

        let inset: CGFloat = 9
        let square = bounds.insetBy(dx: inset, dy: inset)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: square, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
