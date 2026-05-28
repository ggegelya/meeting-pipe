import AppKit

/// Floating recording-status HUD: compact vertical pill, top-right, always-on-top. Exists because the menu-bar coral dot is easy to miss when other apps are foregrounded, and one-click stop is essential for a "this got sensitive, kill it" moment without navigating menus. Draggable via `isMovableByWindowBackground` so the user can move it off a Zoom control or chat avatar.
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
    // 132 → 146 for the workflow attribution line (TECH-B9). Allocated unconditionally so the HUD geometry doesn't shift between workflowed and un-workflowed meetings.
    private static let panelHeight: CGFloat = 146
    private static let edgeInset: CGFloat = 16

    func present(source: AppSource?, workflow: Workflow? = nil, startedAt: Date) {
        dismiss(animated: false)
        self.startedAt = startedAt

        let panel = makePanel(source: source, workflow: workflow)
        self.panel = panel
        positionPanel(panel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = MPMotion.durBase
            ctx.timingFunction = MPMotion.easeOut
            panel.animator().alphaValue = 1
        }

        // Half-second cadence is smooth and cheap.
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

    private func makePanel(source: AppSource?, workflow: Workflow?) -> NSPanel {
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

        panel.contentView = makeContentView(source: source, workflow: workflow)
        return panel
    }

    private func makeContentView(source: AppSource?, workflow: Workflow?) -> NSView {
        let bg = HUDBackgroundView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight))
        bg.cornerRadius = MPRadius.lg
        bg.host = self

        // App glyph (24x24); falls back to the menubar mark for manual recordings (no source).
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
        // TECH-B5: tint the pulse dot to the workflow color. NDA mode keeps recording-coral so the "sensitive" signal isn't diluted by a softer accent.
        if let wf = workflow, !wf.flags.ndaMode,
           let color = HexColor.parse(wf.color) {
            dot.tintColor = color
        }
        bg.addSubview(dot)
        self.pulseDot = dot

        let elapsed = NSTextField(labelWithString: "0:00")
        elapsed.font = .monospacedDigitSystemFont(ofSize: MPType.textSM, weight: MPType.medium)
        elapsed.textColor = MPColors.fg
        elapsed.alignment = .center
        elapsed.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(elapsed)
        self.elapsedLabel = elapsed

        // Workflow attribution (TECH-B9): hidden when no workflow but still in the view tree so panel height stays constant.
        let workflowLabel = HUDWorkflowLabel(workflow: workflow)
        workflowLabel.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(workflowLabel)

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

            workflowLabel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 4),
            workflowLabel.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -4),
            workflowLabel.topAnchor.constraint(equalTo: elapsed.bottomAnchor, constant: 2),
            workflowLabel.heightAnchor.constraint(equalToConstant: 14),

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
        // Vector waveform mark (same as the menu-bar icon) so it scales cleanly at 24x24.
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

/// Translucent rounded background using `hudWindow` material, matching the prompt panel.
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

/// Core Animation opacity-loop pulse dot; starts with the HUD, stops on dismiss.
private final class PulseDotView: NSView {
    private let dot = CALayer()

    /// Workflow-driven tint (TECH-B5); defaults to recording-coral for manual/unworkflowed recordings.
    var tintColor: NSColor = MPColors.pulse600 {
        didSet { dot.backgroundColor = tintColor.cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(dot)
        dot.backgroundColor = tintColor.cgColor
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
        // Opacity-axis (not scale): scale growth reads as a UI toggle; opacity fade at fixed size feels like a heartbeat. 1.6 s loop (autoreverse, 0.8 s each way).
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

/// Round stop button with hover/press affordances; inset square fill matches iOS-style record stops.
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

/// Workflow attribution label (TECH-B9). NDA mode appends a coral "NDA" suffix so the user can spot a sensitive routing before saying something they'd regret in a non-NDA summary.
private final class HUDWorkflowLabel: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let ndaLabel = NSTextField(labelWithString: "NDA")

    init(workflow: Workflow?) {
        super.init(frame: .zero)
        wantsLayer = true

        nameLabel.font = .systemFont(ofSize: 10, weight: .medium)
        nameLabel.textColor = MPColors.fgMuted
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        ndaLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        ndaLabel.textColor = MPColors.pulse600
        ndaLabel.alignment = .center
        ndaLabel.translatesAutoresizingMaskIntoConstraints = false
        ndaLabel.isHidden = true
        addSubview(ndaLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameLabel.topAnchor.constraint(equalTo: topAnchor),
            ndaLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            ndaLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        apply(workflow)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func apply(_ workflow: Workflow?) {
        guard let wf = workflow else {
            nameLabel.stringValue = ""
            ndaLabel.isHidden = true
            isHidden = true
            return
        }
        isHidden = false
        nameLabel.stringValue = wf.name
        ndaLabel.isHidden = !wf.flags.ndaMode
    }
}

