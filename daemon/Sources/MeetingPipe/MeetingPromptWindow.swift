import AppKit

/// Detection prompt: a Notion-style horizontal pill centered near the top of the screen. The primary action is a labelled teal capsule (`PromptRecordButton`); secondary actions (Record BYO, Always, Skip, Screen Recording Settings) live under a chevron menu rather than inline buttons, so the right cluster stays quiet. Lifecycle: `present` shows the panel and starts the mic monitor; `dismiss` fades it out and stops the monitor. One panel at a time; the delegate carries outcome clicks back to the Coordinator.
protocol MeetingPromptDelegate: AnyObject {
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseRecord source: AppSource)
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseSkip source: AppSource)
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseAlways source: AppSource)
    /// User chose "Record (BYO)" - recording proceeds normally but the pipeline writes a manual-paste bundle instead of calling Anthropic.
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseRecordBYO source: AppSource)
    /// User picked a workflow override. Prompt stays open; the Coordinator stashes it so the next `beginRecording` matcher call returns this workflow.
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseWorkflow id: UUID?)
}

/// Threading: every public method must run on the main queue.
final class MeetingPromptWindow {
    weak var delegate: MeetingPromptDelegate?

    private var panel: NSPanel?
    private var currentSource: AppSource?
    private weak var liveWaveform: LiveWaveformView?
    private weak var dismissProgress: DismissProgressView?
    private weak var workflowChip: WorkflowChipView?
    /// Workflows frozen at `present` time so the override popup is stable (a workflow added mid-prompt is fine to miss; it will appear on the next meeting).
    private var availableWorkflows: [Workflow] = []
    /// Workflow displayed on the chip; updated on override pick so the chip reflects the choice without a full panel rebuild.
    private var currentWorkflow: Workflow?
    private let levelMonitor = MicLevelMonitor()

    /// Auto-dismiss timer; paused on hover.
    private var dismissTimer: Timer?
    private var dismissDeadline: Date?
    private var dismissRemainingOnPause: TimeInterval?

    // 520 → 600 to fit the workflow chip (TECH-B5) without crowding the action cluster.
    private static let panelWidth: CGFloat = 600
    // 88 → 64: denser hierarchy (eyebrow + title) needs less vertical air. Per Roadmap P4.1.
    private static let panelHeight: CGFloat = 64
    /// 80pt down matches Notion's pill position so the two HUDs feel like the same family side-by-side.
    private static let topInset: CGFloat = 80

    func present(
        source: AppSource,
        workflow: Workflow? = nil,
        availableWorkflows: [Workflow] = [],
        autoDismissAfter seconds: TimeInterval
    ) {
        dismiss(animated: false)
        currentSource = source
        currentWorkflow = workflow
        self.availableWorkflows = availableWorkflows

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
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
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

        // Stacked text: question is the primary CTA; app name is the eyebrow above it.
        let eyebrow = NSTextField(labelWithString: source.displayName.uppercased())
        eyebrow.font = .mpEyebrow()
        // fgMuted (appearance-aware) instead of the fixed ink500 palette step:
        // ink500 stays dark in dark mode, so on the dark HUD material the app
        // name washed out to ~2.3:1. fgMuted flips to ink300 in dark for ~6:1.
        eyebrow.textColor = MPColors.fgMuted
        eyebrow.lineBreakMode = .byTruncatingTail
        eyebrow.translatesAutoresizingMaskIntoConstraints = false
        // NSAttributedString is the only way to set tracking on NSTextField; it overrides `stringValue`.
        eyebrow.attributedStringValue = NSAttributedString(
            string: source.displayName.uppercased(),
            attributes: [
                .font: NSFont.mpEyebrow(),
                .foregroundColor: MPColors.fgMuted,
                .kern: 0.4,
            ]
        )
        bg.addSubview(eyebrow)

        let permDenied = SystemAudioCapture.permissionState == .denied
        let question = HintLabel()
        if permDenied {
            question.stringValue = "⚠ System audio blocked, recording will be mic-only"
            question.textColor = MPColors.pulse500
            question.makeClickable {
                SystemAudioCapture.openScreenRecordingSettings()
            }
        } else {
            question.stringValue = "Record this meeting?"
            question.textColor = MPColors.fg
        }
        // DSN25 anchor retune: the mockup's 14pt question collapses to the nearest
        // ramp step (15 / textMD), down from the old 17pt title. One anchor per surface.
        question.font = .systemFont(ofSize: MPType.textMD, weight: MPType.semibold)
        question.maximumNumberOfLines = 1
        question.lineBreakMode = .byTruncatingTail
        question.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(question)

        // --- Live waveform (small, between title and primary action) -
        let waveform = LiveWaveformView(frame: .zero)
        waveform.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(waveform)
        self.liveWaveform = waveform

        // Workflow chip (TECH-B5): tap opens the override menu. Hidden when no workflow exists (rare: fresh install before migration, or store deleted by hand) so there is no noisy "(none)" pill.
        let chip = WorkflowChipView()
        chip.onClick = { [weak self, weak bg] in
            guard let self = self, let host = bg else { return }
            self.showWorkflowMenu(from: host)
        }
        bg.addSubview(chip)
        if let wf = currentWorkflow {
            applyWorkflow(wf, to: chip)
            chip.isHidden = false
        } else {
            chip.isHidden = true
        }
        self.workflowChip = chip

        // --- Right cluster: [Record] primary + ⌄ menu ---
        // The primary action is a labelled teal capsule. It is a purpose-built control
        // (PromptRecordButton), not the shared MPButton: MPButton fills via its layer
        // backgroundColor sitting behind an NSButtonCell, and that does not composite on
        // the prompt's vibrant hudWindow material - the button rendered invisible. This
        // capsule uses the same layer-fill + NSTextField approach as the record key,
        // which does render here. It folds the old key plus its separate "Record" label
        // into one control; "Record (BYO)" and the other secondary actions live under
        // the ⌄ menu so the cluster stays quiet.
        let record = PromptRecordButton(target: bg, action: #selector(RoundedBackgroundView.didClickRecord))
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

        // Layout: × pinned to top-left corner; action row starts at the glyph.
        let leftEdge: CGFloat = 14
        let rightEdge: CGFloat = 12
        let textLeading: CGFloat = leftEdge + 32 + 10 // glyph(32) + gap(10)

        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 6),
            close.topAnchor.constraint(equalTo: bg.topAnchor, constant: 6),
            close.widthAnchor.constraint(equalToConstant: 14),
            close.heightAnchor.constraint(equalToConstant: 14),

            glyph.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: leftEdge),
            glyph.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 32),
            glyph.heightAnchor.constraint(equalToConstant: 32),

            eyebrow.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: textLeading),
            eyebrow.topAnchor.constraint(equalTo: glyph.topAnchor, constant: 0),
            eyebrow.trailingAnchor.constraint(lessThanOrEqualTo: waveform.leadingAnchor, constant: -8),

            question.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: textLeading),
            question.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 1),
            question.trailingAnchor.constraint(lessThanOrEqualTo: waveform.leadingAnchor, constant: -8),

            // Waveform sits left of the chip + action cluster; when chip is hidden it falls back to recordBYO via the chip's leading constraint.
            waveform.trailingAnchor.constraint(equalTo: chip.leadingAnchor, constant: -8),
            waveform.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: LiveWaveformView.intrinsicWidth),
            waveform.heightAnchor.constraint(equalToConstant: 14),

            // Max width prevents a long workflow name from pushing the action cluster off-canvas.
            chip.trailingAnchor.constraint(equalTo: record.leadingAnchor, constant: -10),
            chip.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            chip.widthAnchor.constraint(lessThanOrEqualToConstant: 160),

            // Right cluster: chevron flush right, the primary Record button before it.
            chevron.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -rightEdge),
            chevron.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 26),
            chevron.heightAnchor.constraint(equalToConstant: 26),

            record.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),
            record.centerYAnchor.constraint(equalTo: bg.centerYAnchor),

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

    /// Build the chevron popup. Held on `MeetingPromptWindow`, not the NSView, to access `currentSource` for the "Always for {App}" label without piping it through the view hierarchy.
    fileprivate func showChevronMenu(from button: NSView) {
        guard let source = currentSource else { return }
        let menu = NSMenu()

        // Record (BYO): record normally, but the pipeline writes a manual-paste bundle
        // instead of calling Anthropic. Moved here from an inline button to keep the
        // prompt's action cluster quiet.
        let byo = NSMenuItem(title: "Record (BYO)", action: #selector(menuPickBYO), keyEquivalent: "")
        byo.target = self
        byo.toolTip = "Record, but skip the Anthropic API call. You'll summarize the transcript yourself."
        menu.addItem(byo)

        let always = NSMenuItem(title: "Always for \(source.displayName)", action: #selector(menuPickAlways), keyEquivalent: "")
        always.target = self
        menu.addItem(always)

        menu.addItem(.separator())

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
    @objc private func menuPickBYO() { handleRecordBYO() }
    @objc private func menuPickOpenSettings() {
        SystemAudioCapture.openScreenRecordingSettings()
    }

    fileprivate func handleClose() { handleSkip() }

    // MARK: - Workflow chip (TECH-B5)

    private func applyWorkflow(_ wf: Workflow, to chip: WorkflowChipView) {
        chip.workflowName = wf.flags.ndaMode ? "\(wf.name) · NDA" : wf.name
        chip.emoji = wf.emoji
        if let color = HexColor.parse(wf.color) {
            chip.workflowColor = color
        }
    }

    /// Present the workflow override menu under the chip. Each item carries the workflow id as `representedObject`.
    fileprivate func showWorkflowMenu(from host: NSView) {
        guard let chip = workflowChip, !availableWorkflows.isEmpty else { return }
        let menu = NSMenu()
        for wf in availableWorkflows.sorted(by: { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }) {
            let item = NSMenuItem(
                title: wf.name + (wf.isDefault ? " (default)" : ""),
                action: #selector(menuPickWorkflow(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = wf.id
            if let current = currentWorkflow, current.id == wf.id {
                item.state = .on
            }
            menu.addItem(item)
        }
        let origin = NSPoint(x: 0, y: chip.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: host)
    }

    @objc private func menuPickWorkflow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        delegate?.meetingPrompt(self, didChooseWorkflow: id)
        if let wf = availableWorkflows.first(where: { $0.id == id }) {
            currentWorkflow = wf
            if let chip = workflowChip {
                applyWorkflow(wf, to: chip)
            }
        }
    }
}

// MARK: - Background

/// Translucent rounded background; owns the mouse-tracking that pauses the auto-dismiss progress bar on hover.
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
    @objc func didClickClose() { host?.handleClose() }
    @objc func didClickChevron(_ sender: NSView) { host?.showChevronMenu(from: sender) }
}

// MARK: - Small chrome controls

/// Round × close button; treated as "Skip" (top-left, matching Notion's idiom).
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
        // Light HUD: no resting disc - it read as a box crammed into the panel's rounded corner.
        // The bare × is the affordance and a soft disc appears on hover. Dark HUD keeps the faint
        // disc at rest so the control separates from the dark material.
        let dark = effectiveAppearance.mpIsDark
        let fill: NSColor?
        if isHovered { fill = dark ? MPColors.bgRaised.withAlphaComponent(0.85) : MPColors.ink100 }
        else { fill = dark ? MPColors.bgRaised.withAlphaComponent(0.55) : nil }
        if let fill = fill {
            fill.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        }

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

/// Compact chevron-down button hosting the secondary-actions menu.
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
        // Light HUD rests fill-less with a faint border so it stops reading as a box beside
        // Record; the filled box returns on hover. Dark HUD keeps the resting tint.
        let dark = effectiveAppearance.mpIsDark
        // Capsule (DSN25): full radius clamps to half-height at 26pt, matching the
        // ghost-capsule button language of Record (BYO) beside it.
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: MPRadius.full, yRadius: MPRadius.full)
        if isHovered {
            MPColors.ink50.setFill()
            path.fill()
        } else if dark {
            MPColors.bgRaised.withAlphaComponent(0.55).setFill()
            path.fill()
        }
        (dark || isHovered ? MPColors.borderStrong : MPColors.border).setStroke()
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

/// Primary "Record" action on the prompt: a filled signal-teal capsule with a white
/// label. Purpose-built rather than reusing `MPButton(.primary)` because that fills via
/// `layer.backgroundColor` behind an `NSButtonCell`, which does not composite on the
/// prompt's vibrant `hudWindow` material (the button drew invisible). This uses the same
/// layer-fill + `NSTextField` approach as `RecordKey`, which renders here. `NSControl`
/// (not `NSButton`) so there is no cell in the way; click is a manual mouse-tracking
/// `sendAction`, mirroring `RecordKey`.
final class PromptRecordButton: NSControl {
    private let titleLabel = NSTextField(labelWithString: "Record")

    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.backgroundColor = MPColors.signalFill.cgColor   // deep teal, both modes (clears white 4.5:1)
        layer?.masksToBounds = true
        toolTip = "Record this meeting"

        titleLabel.font = .systemFont(ofSize: MPType.textBase, weight: MPType.semibold)
        titleLabel.textColor = MPColors.fgOnSignal
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Record")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // 26pt tall capsule matching the button language; width hugs the label + 14pt each side.
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(titleLabel.intrinsicContentSize.width) + 28, height: 26)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2   // full-radius capsule
    }

    override func mouseDown(with event: NSEvent) {
        // Manual tracking so releasing outside cancels, like a real button; a quick
        // opacity dip is the press feedback. Mirrors RecordKey (no NSButtonCell here).
        layer?.opacity = 0.82
        var inside = true
        while true {
            guard let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
            if next.type == .leftMouseDragged {
                inside = bounds.contains(convert(next.locationInWindow, from: nil))
                layer?.opacity = inside ? 0.82 : 1.0
            } else {
                inside = bounds.contains(convert(next.locationInWindow, from: nil))
                break
            }
        }
        layer?.opacity = 1.0
        if inside, isEnabled { sendAction(action, to: target) }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Single-line label with an optional click target; used for the question subline (plain) or the permission-denied warning (clickable to System Settings).
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
