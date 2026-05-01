import AppKit

/// On-screen prompt that pops in the top-right when a meeting is detected.
///
/// Replaces the banner notification for the "Record this meeting?" decision.
/// Banner notifications get suppressed under Focus modes and are easy to miss
/// — a floating panel stays put until the user clicks or the timeout fires.
///
/// Lifecycle: `present` shows the panel (animated) AND starts the mic-level
/// monitor. `dismiss` fades it out AND stops the monitor. One panel at a
/// time — calling `present` again replaces the current one. The panel
/// itself does not own outcome state; `MeetingPromptDelegate` carries the
/// click outcome back to the Coordinator (same surface area as the existing
/// `NotifierDelegate.didChooseRecord/Skip/Always`).
///
/// Sizing: width fixed at 380, height fixed at 226 to make room for the
/// app-glyph + privacy-copy line. Pinned 16pt from the top-right of the
/// screen the menu bar lives on.
protocol MeetingPromptDelegate: AnyObject {
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseRecord source: AppSource)
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseSkip source: AppSource)
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseAlways source: AppSource)
    /// User chose "Record (BYO)" — the recording proceeds normally, but the
    /// pipeline writes a manual-paste bundle instead of calling Anthropic.
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseRecordBYO source: AppSource)
}

/// Threading: every public method must run on the main queue. Same contract
/// as Coordinator — relies on AppKit being main-thread-only and on callers
/// dispatching back to `.main` before invoking us.
final class MeetingPromptWindow {
    weak var delegate: MeetingPromptDelegate?

    private var panel: NSPanel?
    private var currentSource: AppSource?
    private weak var liveWaveform: LiveWaveformView?
    private weak var dismissProgress: DismissProgressView?
    private let levelMonitor = MicLevelMonitor()

    /// Auto-dismiss timer kept here so we can pause/resume in sync with hover.
    private var dismissTimer: Timer?
    private var dismissDeadline: Date?
    private var dismissRemainingOnPause: TimeInterval?

    private static let panelWidth: CGFloat = 380
    private static let panelHeight: CGFloat = 226
    private static let edgeInset: CGFloat = 16

    func present(source: AppSource, autoDismissAfter seconds: TimeInterval) {
        // Replace any existing prompt — only one decision in flight at a time.
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

        // Start the live mic monitor — the waveform reads from this. If the
        // mic permission is missing, the monitor silently no-ops and the bars
        // stay at the floor level.
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
            ctx.duration = MPMotion.durFast + 0.03   // ~150ms — matches existing fade-out
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

        // --- Eyebrow row: app glyph + label + live waveform ----------
        let glyph = AppGlyphView(source: source)
        bg.addSubview(glyph)

        let eyebrow = NSTextField(labelWithString: "Meeting detected")
        eyebrow.font = .mpBodyMedium()
        eyebrow.textColor = MPColors.fgMuted
        eyebrow.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(eyebrow)

        let waveform = LiveWaveformView(frame: .zero)
        waveform.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(waveform)
        self.liveWaveform = waveform

        // --- Title: source name --------------------------------------
        let title = NSTextField(labelWithString: source.displayName)
        title.font = .mpTitle()
        title.textColor = MPColors.fg
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(title)

        // --- Body --------------------------------------------------
        let body = NSTextField(labelWithString: "Record this meeting?")
        body.font = .mpBody()
        body.textColor = MPColors.fgMuted
        body.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(body)

        // --- Privacy clarification ----------------------------------
        // Required because the prompt now starts the mic for level metering.
        // Copy taken verbatim from the design spec (chat #2 turn 3).
        let privacy = NSTextField(labelWithString: "Listening for level only — nothing is captured until you choose Record.")
        privacy.font = .systemFont(ofSize: MPType.textXS, weight: MPType.regular)
        privacy.textColor = MPColors.fgSubtle
        privacy.maximumNumberOfLines = 2
        privacy.lineBreakMode = .byWordWrapping
        privacy.cell?.wraps = true
        privacy.cell?.isScrollable = false
        privacy.preferredMaxLayoutWidth = Self.panelWidth - 2 * MPSpace.s4
        privacy.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(privacy)

        // --- Buttons --------------------------------------------------
        let skip = MPButton(title: "Skip", style: .text,
                            target: bg, action: #selector(RoundedBackgroundView.didClickSkip))
        let always = MPButton(title: "Always for \(source.displayName)", style: .text,
                              target: bg, action: #selector(RoundedBackgroundView.didClickAlways))
        let recordBYO = MPButton(title: "Record (BYO)", style: .ghost,
                                 target: bg, action: #selector(RoundedBackgroundView.didClickRecordBYO))
        recordBYO.toolTip = "Record, but skip the Anthropic API call. You'll summarize the transcript yourself."
        let record = MPButton(title: "Record", style: .primary,
                              target: bg, action: #selector(RoundedBackgroundView.didClickRecord))
        record.bindAsDefault()
        bg.host = self

        for b in [skip, always, recordBYO, record] {
            b.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(b)
        }

        // --- Auto-dismiss progress hairline (bottom edge) -----------
        let progress = DismissProgressView(frame: .zero)
        progress.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(progress)
        self.dismissProgress = progress
        bg.dismissProgress = progress

        // --- Layout ------------------------------------------------------
        // Inset matches the design's HUD card spec (16pt sides, 14pt top).
        let inset: CGFloat = MPSpace.s4   // 16
        let topInset: CGFloat = 14
        let bottomInset: CGFloat = 14

        NSLayoutConstraint.activate([
            // Eyebrow row: glyph (24×24) + eyebrow text + waveform (right).
            glyph.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: inset),
            glyph.topAnchor.constraint(equalTo: bg.topAnchor, constant: topInset),
            glyph.widthAnchor.constraint(equalToConstant: 24),
            glyph.heightAnchor.constraint(equalToConstant: 24),

            eyebrow.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: MPSpace.s2),
            eyebrow.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),

            waveform.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -inset),
            waveform.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: LiveWaveformView.intrinsicWidth),
            waveform.heightAnchor.constraint(equalToConstant: 14),

            // Title flush-left; aligned with glyph (NOT indented under it —
            // this preserves the JSX hierarchy where the source name reads
            // as the panel's primary content).
            title.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: inset),
            title.topAnchor.constraint(equalTo: glyph.bottomAnchor, constant: MPSpace.s1),
            title.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -inset),

            body.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: inset),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: MPSpace.s2),
            body.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -inset),

            privacy.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: inset),
            privacy.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -inset),
            privacy.topAnchor.constraint(equalTo: body.bottomAnchor, constant: MPSpace.s1),

            // Primary row: BYO + Record, right-aligned, on the bottom.
            record.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -bottomInset),
            record.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -inset),

            recordBYO.centerYAnchor.constraint(equalTo: record.centerYAnchor),
            recordBYO.trailingAnchor.constraint(equalTo: record.leadingAnchor, constant: -MPSpace.s2),

            // Secondary row: Skip + Always, left-aligned, above primary.
            skip.bottomAnchor.constraint(equalTo: record.topAnchor, constant: -MPSpace.s2),
            skip.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: inset),

            always.centerYAnchor.constraint(equalTo: skip.centerYAnchor),
            always.leadingAnchor.constraint(equalTo: skip.trailingAnchor, constant: MPSpace.s1),

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
            x: visible.maxX - Self.panelWidth - Self.edgeInset,
            y: visible.maxY - Self.panelHeight - Self.edgeInset
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

    /// Pauses the auto-dismiss timer + the progress fill while the mouse is
    /// over the panel. Mirrors the JSX behavior: a user reading the panel
    /// shouldn't lose it mid-decision.
    fileprivate func setHovered(_ hovered: Bool) {
        dismissProgress?.setPaused(hovered)
        if hovered {
            // Capture remaining time, cancel timer.
            if let deadline = dismissDeadline {
                dismissRemainingOnPause = max(0, deadline.timeIntervalSinceNow)
            }
            dismissTimer?.invalidate()
            dismissTimer = nil
        } else if let remaining = dismissRemainingOnPause {
            // Resume with whatever was left.
            scheduleAutoDismiss(after: remaining)
            dismissRemainingOnPause = nil
        }
    }

    // Called by the content view's button targets.
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
}

/// Rounded translucent background. Uses NSVisualEffectView with `.hudWindow`
/// material so the panel blends with the desktop behind it instead of
/// looking like a stuck dialog. Owns the mouse-tracking that drives
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
        // 0.5px hairline stroke matches the design's HUD spec.
        layer?.borderWidth = 0.5
        layer?.borderColor = MPColors.border.cgColor

        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
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
    @objc func didClickSkip() { host?.handleSkip() }
    @objc func didClickAlways() { host?.handleAlways() }
    @objc func didClickRecordBYO() { host?.handleRecordBYO() }
}
