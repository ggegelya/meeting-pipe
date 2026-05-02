import AppKit

/// On-screen prompt that surfaces when a meeting is detected.
///
/// Replaces the older 380×204 top-right card with a Notion-style horizontal
/// pill, centered horizontally near the top of the screen. The visual
/// vocabulary tracks Notion's "Start AI Meeting Note" pill but uses our
/// design tokens (paper/ink/signal) instead of Notion's gray/blue.
///
/// Layout, left to right:
///   [×]  [glyph]   Microsoft Teams         [Record (BYO)] [Record] [⌄]
///                  Record this meeting?
///
/// The chevron `⌄` opens a popup menu with the secondary actions:
///   - Always for {App}
///   - Skip
///   - (when permission denied) Open Screen Recording Settings…
///
/// Why a popup menu instead of inline chips: at 480pt wide, four buttons
/// in a row leaves no breathing room and the `Always for Microsoft Teams`
/// label is ~190pt by itself. Pushing it under a chevron reads as Notion's
/// "more options" affordance and keeps the pill compact.
///
/// Lifecycle: `present` shows the panel + starts the mic-level monitor.
/// `dismiss` fades it out + stops the monitor. One panel at a time. The
/// panel doesn't own outcome state; the delegate carries clicks back to
/// the Coordinator.
protocol MeetingPromptDelegate: AnyObject {
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseRecord source: AppSource)
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseSkip source: AppSource)
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseAlways source: AppSource)
    /// User chose "Record (BYO)" — the recording proceeds normally, but the
    /// pipeline writes a manual-paste bundle instead of calling Anthropic.
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseRecordBYO source: AppSource)
}

/// Threading: every public method must run on the main queue.
final class MeetingPromptWindow {
    weak var delegate: MeetingPromptDelegate?

    private var panel: NSPanel?
    private var currentSource: AppSource?
    private weak var liveWaveform: LiveWaveformView?
    private weak var dismissProgress: DismissProgressView?
    private let levelMonitor = MicLevelMonitor()

    /// Auto-dismiss timer; paused on hover.
    private var dismissTimer: Timer?
    private var dismissDeadline: Date?
    private var dismissRemainingOnPause: TimeInterval?

    private static let panelWidth: CGFloat = 520
    private static let panelHeight: CGFloat = 88
    /// Distance from the top of the visible area. Notion's pill sits ~80pt
    /// down; we match that so the two HUDs read as the same family when
    /// they appear side-by-side.
    private static let topInset: CGFloat = 80

    func present(source: AppSource, autoDismissAfter seconds: TimeInterval) {
        dismiss(animated: false)
        currentSource = source

        let panel = makePanel(source: source, timeoutSec: seconds)
        self.panel = panel
        positionPanel(panel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = MPMotion.durBase
            ctx.timingFunction = MPMotion.easeOut
            panel.animator().alphaValue = 1
        }

        levelMonitor.start { [weak self] level in
            self?.liveWaveform?.push(level: level)
        }
        dismissProgress?.start(timeoutSec: seconds)
        scheduleAutoDismiss(after: seconds)
    }

    func dismiss(animated: Bool = true) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        dismissDeadline = nil
        dismissRemainingOnPause = nil
        levelMonitor.stop()
        dismissProgress?.stop()

        guard let panel = panel else { return }
        self.panel = nil
        currentSource = nil
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

    // MARK: - Panel construction

    private func makePanel(source: AppSource, timeoutSec: TimeInterval) -> NSPanel {
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
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false

        panel.contentView = makeContentView(source: source, timeoutSec: timeoutSec)
        return panel
    }

    private func makeContentView(source: AppSource, timeoutSec: TimeInterval) -> NSView {
        let bg = RoundedBackgroundView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight))
        bg.cornerRadius = MPRadius.lg
        bg.host = self

        // --- × close (top-left corner) -------------------------------
        let close = CloseButton(target: bg, action: #selector(RoundedBackgroundView.didClickClose))
        close.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(close)

        // --- App glyph (32×32) ---------------------------------------
        let glyph = AppGlyphView(source: source)
        bg.addSubview(glyph)

        // --- Stacked text: title + subline ---------------------------
        let title = NSTextField(labelWithString: source.displayName)
        title.font = .mpTitle()
        title.textColor = MPColors.fg
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(title)

        let permDenied = SystemAudioCapture.permissionState == .denied
        let subline = HintLabel()
        if permDenied {
            subline.stringValue = "⚠ System audio blocked — recording will be mic-only"
            subline.textColor = MPColors.pulse500
            subline.makeClickable {
                SystemAudioCapture.openScreenRecordingSettings()
            }
        } else {
            subline.stringValue = "Record this meeting?"
            subline.textColor = MPColors.fgMuted
        }
        subline.font = .mpCaption()
        subline.maximumNumberOfLines = 1
        subline.lineBreakMode = .byTruncatingTail
        subline.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(subline)

        // --- Live waveform (small, between title and primary action) -
        let waveform = LiveWaveformView(frame: .zero)
        waveform.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(waveform)
        self.liveWaveform = waveform

        // --- Right-cluster: Record (BYO) + Record + ⌄ ----------------
        let recordBYO = MPButton(title: "Record (BYO)", style: .ghost,
                                 target: bg, action: #selector(RoundedBackgroundView.didClickRecordBYO))
        recordBYO.toolTip = "Record, but skip the Anthropic API call. You'll summarize the transcript yourself."
        recordBYO.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(recordBYO)

        let record = MPButton(title: "Record", style: .primary,
                              target: bg, action: #selector(RoundedBackgroundView.didClickRecord))
        record.bindAsDefault()
        record.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(record)

        let chevron = ChevronMenuButton(target: bg, action: #selector(RoundedBackgroundView.didClickChevron))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(chevron)

        // --- Auto-dismiss progress hairline (bottom edge) -----------
        let progress = DismissProgressView(frame: .zero)
        progress.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(progress)
        self.dismissProgress = progress
        bg.dismissProgress = progress

        // --- Layout --------------------------------------------------
        // 12pt top/bottom padding; horizontal layout flows left → right.
        let leftEdge: CGFloat = 14
        let rightEdge: CGFloat = 12
        let textLeading: CGFloat = leftEdge + 22 + 10 + 32 + 10
        // close(22) + gap(10) + glyph(32) + gap(10)

        NSLayoutConstraint.activate([
            // × close
            close.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: leftEdge),
            close.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 22),

            // App glyph
            glyph.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 10),
            glyph.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 32),
            glyph.heightAnchor.constraint(equalToConstant: 32),

            // Title (top of stacked text)
            title.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: textLeading),
            title.topAnchor.constraint(equalTo: glyph.topAnchor, constant: -2),
            title.trailingAnchor.constraint(lessThanOrEqualTo: waveform.leadingAnchor, constant: -8),

            // Subline (under title)
            subline.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: textLeading),
            subline.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subline.trailingAnchor.constraint(lessThanOrEqualTo: waveform.leadingAnchor, constant: -8),

            // Waveform sits left of the action cluster.
            waveform.trailingAnchor.constraint(equalTo: recordBYO.leadingAnchor, constant: -10),
            waveform.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: LiveWaveformView.intrinsicWidth),
            waveform.heightAnchor.constraint(equalToConstant: 14),

            // Right cluster: chevron flush right; Record before it; BYO before that.
            chevron.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -rightEdge),
            chevron.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 28),
            chevron.heightAnchor.constraint(equalToConstant: 28),

            record.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),
            record.centerYAnchor.constraint(equalTo: bg.centerYAnchor),

            recordBYO.trailingAnchor.constraint(equalTo: record.leadingAnchor, constant: -8),
            recordBYO.centerYAnchor.constraint(equalTo: bg.centerYAnchor),

            // Dismiss progress: 2pt bar flush to the bottom edge, full width.
            progress.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            progress.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
        ])
        return bg
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - Self.panelWidth / 2,
            y: visible.maxY - Self.panelHeight - Self.topInset
        )
        panel.setFrameOrigin(origin)
    }

    private func scheduleAutoDismiss(after seconds: TimeInterval) {
        dismissTimer?.invalidate()
        dismissDeadline = Date().addingTimeInterval(seconds)
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.dismiss() }
        }
    }

    fileprivate func setHovered(_ hovered: Bool) {
        dismissProgress?.setPaused(hovered)
        if hovered {
            if let deadline = dismissDeadline {
                dismissRemainingOnPause = max(0, deadline.timeIntervalSinceNow)
            }
            dismissTimer?.invalidate()
            dismissTimer = nil
        } else if let remaining = dismissRemainingOnPause {
            scheduleAutoDismiss(after: remaining)
            dismissRemainingOnPause = nil
        }
    }

    // MARK: - Click handling

    fileprivate func handleRecord() {
        guard let s = currentSource else { return }
        delegate?.meetingPrompt(self, didChooseRecord: s)
        dismiss()
    }

    fileprivate func handleSkip() {
        guard let s = currentSource else { return }
        delegate?.meetingPrompt(self, didChooseSkip: s)
        dismiss()
    }

    fileprivate func handleAlways() {
        guard let s = currentSource else { return }
        delegate?.meetingPrompt(self, didChooseAlways: s)
        dismiss()
    }

    fileprivate func handleRecordBYO() {
        guard let s = currentSource else { return }
        delegate?.meetingPrompt(self, didChooseRecordBYO: s)
        dismiss()
    }

    /// Build + present the chevron's popup menu. Held here (not on the
    /// NSView) so we can read `currentSource` for the "Always for {App}"
    /// label without piping it through the view hierarchy.
    fileprivate func showChevronMenu(from button: NSView) {
        guard let source = currentSource else { return }
        let menu = NSMenu()
        let always = NSMenuItem(title: "Always for \(source.displayName)", action: #selector(menuPickAlways), keyEquivalent: "")
        always.target = self
        menu.addItem(always)

        let skip = NSMenuItem(title: "Skip this meeting", action: #selector(menuPickSkip), keyEquivalent: "")
        skip.target = self
        menu.addItem(skip)

        if SystemAudioCapture.permissionState == .denied {
            menu.addItem(.separator())
            let openSettings = NSMenuItem(
                title: "Open Screen Recording Settings…",
                action: #selector(menuPickOpenSettings),
                keyEquivalent: ""
            )
            openSettings.target = self
            menu.addItem(openSettings)
        }

        let origin = NSPoint(x: 0, y: button.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: button)
    }

    @objc private func menuPickAlways() { handleAlways() }
    @objc private func menuPickSkip() { handleSkip() }
    @objc private func menuPickOpenSettings() {
        SystemAudioCapture.openScreenRecordingSettings()
    }

    fileprivate func handleClose() { handleSkip() }
}

// MARK: - Background

/// Translucent rounded background. Owns the mouse-tracking that drives
/// pause-on-hover for the dismiss progress hairline.
private final class RoundedBackgroundView: NSView {
    var cornerRadius: CGFloat = MPRadius.lg { didSet { needsLayout = true } }
    weak var host: MeetingPromptWindow?
    weak var dismissProgress: DismissProgressView?

    private let blur = NSVisualEffectView()
    private var trackingArea: NSTrackingArea?

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

    override func mouseEntered(with event: NSEvent) { host?.setHovered(true) }
    override func mouseExited(with event: NSEvent) { host?.setHovered(false) }

    @objc func didClickRecord() { host?.handleRecord() }
    @objc func didClickRecordBYO() { host?.handleRecordBYO() }
    @objc func didClickClose() { host?.handleClose() }
    @objc func didClickChevron(_ sender: NSView) { host?.showChevronMenu(from: sender) }
}

// MARK: - Small chrome controls

/// Round × close button. Treated as "Skip" — same outcome as the Skip menu
/// item but in the most idiomatic spot (top-left, like Notion).
private final class CloseButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { needsDisplay = true } }

    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
        title = ""
        toolTip = "Dismiss"
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
        let fill = isHovered
            ? MPColors.bgRaised.withAlphaComponent(0.85)
            : MPColors.bgRaised.withAlphaComponent(0.55)
        fill.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()

        // ×
        let mid = NSPoint(x: bounds.midX, y: bounds.midY)
        let half: CGFloat = 4
        MPColors.fgMuted.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: mid.x - half, y: mid.y - half))
        path.line(to: NSPoint(x: mid.x + half, y: mid.y + half))
        path.move(to: NSPoint(x: mid.x - half, y: mid.y + half))
        path.line(to: NSPoint(x: mid.x + half, y: mid.y - half))
        path.stroke()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Compact chevron-down button that hosts the secondary-actions menu.
/// Visual: ghost-style fill + a 6×3pt chevron rendered in `fgMuted`.
private final class ChevronMenuButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { needsDisplay = true } }

    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
        title = ""
        toolTip = "More options"
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
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: MPRadius.sm, yRadius: MPRadius.sm)
        path.fill()
        MPColors.borderStrong.setStroke()
        path.lineWidth = 1
        path.stroke()

        let mid = NSPoint(x: bounds.midX, y: bounds.midY)
        MPColors.fg.setStroke()
        let chev = NSBezierPath()
        chev.lineWidth = 1.5
        chev.lineCapStyle = .round
        chev.lineJoinStyle = .round
        chev.move(to: NSPoint(x: mid.x - 4, y: mid.y + 1.5))
        chev.line(to: NSPoint(x: mid.x,     y: mid.y - 2.5))
        chev.line(to: NSPoint(x: mid.x + 4, y: mid.y + 1.5))
        chev.stroke()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Single-line hint label with an optional click target. Used for the
/// subline beneath the title — either privacy text (non-clickable) or a
/// permission-denied warning (clickable → System Settings).
private final class HintLabel: NSTextField {
    private var clickHandler: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        isSelectable = false
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func makeClickable(_ handler: @escaping () -> Void) {
        clickHandler = handler
    }

    override func mouseDown(with event: NSEvent) {
        if let handler = clickHandler { handler() } else { super.mouseDown(with: event) }
    }

    override func resetCursorRects() {
        if clickHandler != nil { addCursorRect(bounds, cursor: .pointingHand) }
        else { super.resetCursorRects() }
    }
}
