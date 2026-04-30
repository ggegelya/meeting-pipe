import AppKit

/// On-screen prompt that pops in the top-right when a meeting is detected.
///
/// Replaces the banner notification for the "Record this meeting?" decision.
/// Banner notifications get suppressed under Focus modes and are easy to miss
/// — a floating panel stays put until the user clicks or the timeout fires.
///
/// Lifecycle: `present` shows the panel (animated), `dismiss` fades it out.
/// One panel at a time — calling `present` again replaces the current one.
/// The panel itself does not own state; `MeetingPromptDelegate` carries the
/// click outcome back to the Coordinator (same surface area as the existing
/// `NotifierDelegate.didChooseRecord/Skip/Always`).
///
/// Sizing constraints: width fixed at 360, height grows with subtitle length
/// up to 200. Always pinned 16pt from the top-right edge of the screen the
/// menu bar lives on (mainScreen).
protocol MeetingPromptDelegate: AnyObject {
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseRecord source: AppSource)
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseSkip source: AppSource)
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseAlways source: AppSource)
}

/// Threading: every public method must run on the main queue. Same contract
/// as Coordinator — relies on AppKit being main-thread-only and on callers
/// dispatching back to `.main` before invoking us.
final class MeetingPromptWindow {
    weak var delegate: MeetingPromptDelegate?

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var currentSource: AppSource?

    private static let panelWidth: CGFloat = 360
    private static let panelHeight: CGFloat = 152
    private static let edgeInset: CGFloat = 16

    func present(source: AppSource, autoDismissAfter seconds: TimeInterval) {
        // Replace any existing prompt — only one decision in flight at a time.
        dismiss(animated: false)
        currentSource = source

        let panel = makePanel(source: source)
        self.panel = panel
        positionPanel(panel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }

        scheduleAutoDismiss(after: seconds)
    }

    func dismiss(animated: Bool = true) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let panel = panel else { return }
        self.panel = nil
        currentSource = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // MARK: - Panel construction

    private func makePanel(source: AppSource) -> NSPanel {
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

        panel.contentView = makeContentView(source: source)
        return panel
    }

    private func makeContentView(source: AppSource) -> NSView {
        let bg = RoundedBackgroundView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight))
        bg.cornerRadius = 14

        let title = NSTextField(labelWithString: "Meeting detected")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(title)

        let subtitle = NSTextField(labelWithString: source.displayName)
        subtitle.font = .systemFont(ofSize: 17, weight: .semibold)
        subtitle.textColor = .labelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(subtitle)

        let body = NSTextField(labelWithString: "Record this meeting?")
        body.font = .systemFont(ofSize: 13, weight: .regular)
        body.textColor = .secondaryLabelColor
        body.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(body)

        let record = makeButton(title: "Record", isPrimary: true, action: #selector(RoundedBackgroundView.didClickRecord))
        let skip = makeButton(title: "Skip", isPrimary: false, action: #selector(RoundedBackgroundView.didClickSkip))
        let always = makeButton(title: "Always for \(source.displayName)", isPrimary: false, action: #selector(RoundedBackgroundView.didClickAlways))
        for b in [record, skip, always] {
            b.target = bg
            bg.addSubview(b)
        }
        bg.host = self

        let buttonsRow = NSStackView(views: [skip, always, record])
        buttonsRow.orientation = .horizontal
        buttonsRow.alignment = .centerY
        buttonsRow.spacing = 8
        buttonsRow.distribution = .fill
        buttonsRow.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(buttonsRow)
        // Push Record to the right edge.
        buttonsRow.setHuggingPriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: bg.topAnchor, constant: 14),
            title.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -16),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -16),

            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 8),

            buttonsRow.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            buttonsRow.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),
            buttonsRow.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -14),
        ])
        return bg
    }

    private func makeButton(title: String, isPrimary: Bool, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: nil, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .regular
        b.translatesAutoresizingMaskIntoConstraints = false
        if isPrimary {
            b.keyEquivalent = "\r"
            b.bezelColor = .controlAccentColor
            b.contentTintColor = .white
        }
        return b
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
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            // Auto-dismiss = same as Skip semantically. Coordinator already
            // has a parallel timeout that flips state to .suppressed; we just
            // hide the window so it doesn't sit there after the timeout.
            DispatchQueue.main.async { self?.dismiss() }
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
}

/// Rounded translucent background. Uses NSVisualEffectView so the panel
/// blends with whatever's behind it instead of looking like a stuck dialog.
private final class RoundedBackgroundView: NSView {
    var cornerRadius: CGFloat = 12 { didSet { needsLayout = true } }
    weak var host: MeetingPromptWindow?

    private let blur = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true

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
    }

    @objc func didClickRecord() { host?.handleRecord() }
    @objc func didClickSkip() { host?.handleSkip() }
    @objc func didClickAlways() { host?.handleAlways() }
}
