import AppKit

/// Floating recording-status HUD: compact vertical pill, top-right, always-on-top. Exists because the menu-bar coral dot is easy to miss when other apps are foregrounded, and one-click stop is essential for a "this got sensitive, kill it" moment without navigating menus. Draggable via `isMovableByWindowBackground` so the user can move it off a Zoom control or chat avatar.
protocol RecordingHUDDelegate: AnyObject {
    func recordingHUDDidRequestStop(_ hud: RecordingHUDWindow)
    /// User tapped "Retry system audio" on the degraded banner (TECH-UX4).
    func recordingHUDDidRequestRetrySystemAudio(_ hud: RecordingHUDWindow)
    /// User toggled off-the-record from the HUD (MIC14 discoverability, UX23): the icon toggle beside
    /// Stop, or the right-click menu. The session controller owns the actual on/off state.
    func recordingHUDDidRequestToggleOffTheRecord(_ hud: RecordingHUDWindow)
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

    /// Degraded-state banner (TECH-UX4). Built lazily only when the recorder
    /// reports a system-audio failure, so its wide content never inflates the
    /// borderless panel's fitting width while the pill is in its normal state.
    private weak var contentView: NSView?
    private weak var stopButton: NSView?
    private var stopBottomNormal: NSLayoutConstraint?
    private var stopBottomToBanner: NSLayoutConstraint?
    private var degradedBanner: HUDDegradedBanner?

    /// Voice-activity meter (TECH-UX8): polls the mic level at 10 Hz so the
    /// audio render thread never has to push to the UI.
    private var levelMeter: LEDMeterView?
    private var meterTicker: Timer?
    private var levelProvider: (() -> Float)?
    private var occlusionObserver: NSObjectProtocol?

    /// The "Recording" state label, swapped to "Off the record" while a manual off-record span is
    /// open (MIC14). Held so `setOffTheRecord` can retitle + retint it.
    private weak var recordingLabel: NSTextField?

    /// The off-the-record toggle beside Stop (MIC14 discoverability, UX23). Held so `setOffTheRecord`
    /// can flip its glyph + tint to reflect the live state.
    private weak var offRecordButton: HUDOffRecordButton?

    // 60 → 76: at 60 the "Recording" label (8pt dot + 5pt gap + 50pt text = 63pt) and
    // workflow names past ~9 chars overflowed the pill and were sliced by the rounded
    // mask. 76 gives the label margin and lets names up to "Engineering" fit.
    private static let panelWidth: CGFloat = 76
    // 132 → 146 for the workflow attribution line (TECH-B9), 146 → 162 for the TECH-UX8 voice-activity meter row, 162 → 192 for the DSN25 Instrument port (the 22pt timer anchor, the record key, and the "Recording" label are all taller than what they replaced). Sized for the tallest (NDA two-row) case and allocated unconditionally so the HUD geometry doesn't shift between workflowed and un-workflowed meetings.
    private static let panelHeight: CGFloat = 192
    private static let edgeInset: CGFloat = 16
    // Degraded mode (TECH-UX4): the pill widens into a card so the banner text and retry button fit.
    private static let degradedPanelWidth: CGFloat = 232
    private static let bannerHeight: CGFloat = 60
    // Off-the-record (MIC14): widen the pill just enough for the longer "Off the record" label.
    private static let offRecordPanelWidth: CGFloat = 150

    func present(source: AppSource?, workflow: Workflow? = nil, startedAt: Date, levelProvider: (() -> Float)? = nil) {
        dismiss(animated: false)
        self.startedAt = startedAt
        self.levelProvider = levelProvider

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

        // 10 Hz poll for the voice-activity meter (TECH-UX8). Polling keeps
        // the audio render thread free of any UI push.
        startMeterTickerIfNeeded()

        // HYG1: the meter is invisible when the panel is occluded (another Space,
        // or fully covered), so pause the 10 Hz timer there and resume when it shows.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel, queue: .main
        ) { [weak self] _ in
            self?.syncMeterToOcclusion()
        }
    }

    /// HYG1: poll the mic level only while the panel is on-screen and a level
    /// provider is set, so an occluded HUD doesn't wake the CPU 10x/second to
    /// update a meter no one can see.
    static func shouldMeterTick(occlusionVisible: Bool, hasProvider: Bool) -> Bool {
        occlusionVisible && hasProvider
    }

    /// (Re)start the 10 Hz meter poll if a provider is set and it isn't already
    /// running. Idempotent, so the occlusion observer can call it freely.
    private func startMeterTickerIfNeeded() {
        guard levelProvider != nil, meterTicker == nil else { return }
        meterTicker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let provider = self.levelProvider else { return }
            self.levelMeter?.level = RecordingHUDWindow.normalizedLevel(db: provider())
        }
    }

    private func stopMeterTicker() {
        meterTicker?.invalidate()
        meterTicker = nil
    }

    private func syncMeterToOcclusion() {
        guard let panel = panel else { return }
        if RecordingHUDWindow.shouldMeterTick(
            occlusionVisible: panel.occlusionState.contains(.visible),
            hasProvider: levelProvider != nil
        ) {
            startMeterTickerIfNeeded()
        } else {
            stopMeterTicker()
        }
    }

    func dismiss(animated: Bool = true) {
        ticker?.invalidate()
        ticker = nil
        stopMeterTicker()
        if let obs = occlusionObserver {
            NotificationCenter.default.removeObserver(obs)
            occlusionObserver = nil
        }
        levelProvider = nil
        startedAt = nil
        pulseDot?.stopPulsing()

        guard let panel = panel else { return }
        self.panel = nil
        self.elapsedLabel = nil
        self.pulseDot = nil
        self.levelMeter = nil
        self.degradedBanner = nil
        self.contentView = nil
        self.stopButton = nil
        self.stopBottomNormal = nil
        self.stopBottomToBanner = nil

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

    /// FEAT8: a single quiet opacity blink acknowledging a flagged moment. No
    /// persistent chrome. Under reduced motion it collapses to an instant
    /// dip-and-restore. Main-queue only; a no-op when the HUD isn't showing.
    func blink() {
        guard let panel = panel else { return }
        let dip: CGFloat = 0.4
        if MPMotion.reduceMotion {
            panel.alphaValue = dip
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak panel] in
                panel?.alphaValue = 1
            }
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = MPMotion.durFast
            ctx.timingFunction = MPMotion.easeOut
            panel.animator().alphaValue = dip
        }, completionHandler: { [weak panel] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = MPMotion.durFast
                ctx.timingFunction = MPMotion.easeOut
                panel?.animator().alphaValue = 1
            }
        })
    }

    // MARK: Degraded state (TECH-UX4)

    /// Add the "system audio not captured" banner and grow the HUD into a card.
    /// Built lazily (not kept hidden in the tree) so its wide content never
    /// inflates the compact pill. Idempotent. Main-queue only.
    func showSystemAudioDegraded() {
        guard degradedBanner == nil, let bg = contentView, let stop = stopButton else { return }
        let banner = HUDDegradedBanner(target: bg, action: #selector(HUDBackgroundView.didClickRetrySystemAudio))
        banner.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(banner)
        degradedBanner = banner

        // Re-pin the stop button above the banner for the duration of the card.
        stopBottomNormal?.isActive = false
        let stopToBanner = stop.bottomAnchor.constraint(equalTo: banner.topAnchor, constant: -10)
        stopBottomToBanner = stopToBanner
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 8),
            banner.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -8),
            banner.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -8),
            banner.heightAnchor.constraint(equalToConstant: Self.bannerHeight),
            stopToBanner,
        ])
        resizePanelAnchoringTopRight(width: Self.degradedPanelWidth, height: Self.panelHeight + Self.bannerHeight)
    }

    /// Remove the degraded banner and shrink the HUD back to the compact pill.
    /// Idempotent. Main-queue only.
    func clearSystemAudioDegraded() {
        guard let banner = degradedBanner else { return }
        banner.removeFromSuperview()   // also removes its constraints, incl. the stop->banner pin
        degradedBanner = nil
        stopBottomToBanner = nil
        stopBottomNormal?.isActive = true
        resizePanelAnchoringTopRight(width: Self.panelWidth, height: Self.panelHeight)
    }

    // MARK: Off the record (MIC14)

    /// Show or clear the persistent "Off the record" state: retitle + retint the state label so it
    /// cannot be forgotten, and widen the pill just enough to fit the longer text. Idempotent.
    /// Skips the resize while the degraded card owns the geometry (that rarer state dominates).
    /// Main-queue only.
    func setOffTheRecord(_ on: Bool) {
        recordingLabel?.stringValue = on ? "Off the record" : "Recording"
        recordingLabel?.textColor = on ? MPColors.pulse600 : MPColors.fgMuted
        offRecordButton?.setActive(on)
        (contentView as? HUDBackgroundView)?.isOffRecord = on
        if degradedBanner == nil {
            resizePanelAnchoringTopRight(width: on ? Self.offRecordPanelWidth : Self.panelWidth, height: Self.panelHeight)
        }
    }

    /// Resize keeping the panel's top-right corner fixed, so growing the
    /// degraded card doesn't yank a HUD the user dragged elsewhere.
    private func resizePanelAnchoringTopRight(width: CGFloat, height: CGFloat) {
        guard let panel = panel else { return }
        let frame = panel.frame
        let origin = NSPoint(x: frame.maxX - width, y: frame.maxY - height)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true, animate: true)
    }

    // MARK: Panel construction

    private func makePanel(source: AppSource?, workflow: Workflow?) -> NSPanel {
        let rect = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)
        let panel = HUDPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        // false (was true) so Stop + the off-record toggle are keyboard-reachable once the user clicks
        // the pill: a borderless nonactivating panel becomes key on click and takes keystrokes without
        // pulling activation off the meeting app (UX23). Shown without stealing focus (quiet register);
        // it only becomes key on an explicit click.
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false

        panel.contentView = makeContentView(source: source, workflow: workflow)
        // Stop takes first keyboard focus; Tab reaches the off-record toggle (wired in makeContentView).
        panel.initialFirstResponder = stopButton
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

        // Pulsing recording dot. Always coral now (DSN25 drops the old TECH-B5
        // workflow-colour tint): the locked mockup renders a coral dot, and it
        // upholds the unchanged Coral-Is-Recording rule. Workflow identity is
        // carried by the name line below, not by recolouring the recording signal.
        let dot = PulseDotView(frame: .zero)
        dot.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(dot)
        self.pulseDot = dot

        // "Recording" label beside the dot so the state is never colour-only. The
        // dot + label sit as a centred row; 10pt matches the workflow line below and
        // the pair fits the 76pt pill (it was clipped at the old 60pt width).
        let recordingLabel = NSTextField(labelWithString: "Recording")
        recordingLabel.font = .systemFont(ofSize: 10, weight: MPType.medium)
        recordingLabel.textColor = MPColors.fgMuted
        recordingLabel.translatesAutoresizingMaskIntoConstraints = false
        self.recordingLabel = recordingLabel

        let dotRow = NSStackView(views: [dot, recordingLabel])
        dotRow.orientation = .horizontal
        dotRow.spacing = 5
        dotRow.alignment = .centerY
        dotRow.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(dotRow)

        // Elapsed timer: the surface anchor (DSN21 Instrument), grown to 22pt
        // semibold - the mockup's 24 collapses to the nearest ramp step (textXL).
        // Monospaced digits keep the numerals tabular so they don't jitter.
        let elapsed = NSTextField(labelWithString: "0:00")
        elapsed.font = .monospacedDigitSystemFont(ofSize: MPType.textXL, weight: MPType.semibold)
        elapsed.textColor = MPColors.fg
        elapsed.alignment = .center
        elapsed.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(elapsed)
        self.elapsedLabel = elapsed

        // Voice-activity meter (TECH-UX8): the shared Instrument LED meter (DSN24),
        // 10 discrete on-air segments that step rather than slide. Always on-air -
        // DSN25 drops the old workflow-colour tint, matching the locked mockup.
        let meter = LEDMeterView(segmentCount: 10, gap: 2, segmentRadius: 1)
        meter.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(meter)
        self.levelMeter = meter

        // Workflow attribution (TECH-B9): hidden when no workflow but still in the view tree so panel height stays constant.
        let workflowLabel = HUDWorkflowLabel(workflow: workflow)
        workflowLabel.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(workflowLabel)

        // Stop control: the record key in its .stop form - a coral rounded-square core
        // in a hairline-bordered circle (the neon on-air ring was dropped in the
        // redesign). VoiceOver reads "Stop recording" from the key itself.
        let stop = RecordKey(state: .stop, target: bg, action: #selector(HUDBackgroundView.didClickStop))
        stop.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stop)

        // Off-the-record toggle beside Stop (MIC14 discoverability, UX23). One click marks a
        // sensitive stretch to keep out of the notes; the glyph + tint flip to coral while the span
        // is open, mirroring the "Off the record" state label. Also reachable from the HUD's
        // right-click menu. The [Stop + toggle] pair is centred (Stop shifted left by half the
        // toggle+gap), so it still fits the 76pt pill.
        let offRecord = HUDOffRecordButton(target: bg, action: #selector(HUDBackgroundView.didClickOffRecord))
        offRecord.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(offRecord)
        self.offRecordButton = offRecord

        // Retain refs so the degraded banner can be added lazily (TECH-UX4):
        // keeping it out of the tree while collapsed stops its wide content
        // from inflating the borderless panel's fitting width.
        self.contentView = bg
        self.stopButton = stop
        let stopBottom = stop.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -10)
        self.stopBottomNormal = stopBottom

        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            glyph.topAnchor.constraint(equalTo: bg.topAnchor, constant: 12),
            glyph.widthAnchor.constraint(equalToConstant: 24),
            glyph.heightAnchor.constraint(equalToConstant: 24),

            // Dot + "Recording" as a centred row (the dot keeps its fixed 8pt size).
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dotRow.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            dotRow.topAnchor.constraint(equalTo: glyph.bottomAnchor, constant: 8),

            elapsed.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            elapsed.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            elapsed.topAnchor.constraint(equalTo: dotRow.bottomAnchor, constant: 4),

            meter.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            meter.topAnchor.constraint(equalTo: elapsed.bottomAnchor, constant: 6),
            meter.widthAnchor.constraint(equalToConstant: 40),
            meter.heightAnchor.constraint(equalToConstant: 6),

            workflowLabel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 4),
            workflowLabel.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -4),
            workflowLabel.topAnchor.constraint(equalTo: meter.bottomAnchor, constant: 4),
            // No fixed height: the label sizes to one row (name) or two (name +
            // NDA eyebrow). TECH-DSN13 - it used to overlap in a fixed 14pt box.

            // The record key sits at the foot, pinned to the bottom; the top-anchored stack above
            // and this pin leave a flexible gap between, which absorbs the taller (NDA two-row)
            // workflow label. Shifted left by 17pt so [Stop + off-record toggle] reads as a centred
            // pair (34 + 8 + 26 = 68pt within the 76pt pill).
            stop.centerXAnchor.constraint(equalTo: bg.centerXAnchor, constant: -17),
            stopBottom,
            stop.widthAnchor.constraint(equalToConstant: RecordKey.Geometry.side),
            stop.heightAnchor.constraint(equalToConstant: RecordKey.Geometry.side),

            offRecord.leadingAnchor.constraint(equalTo: stop.trailingAnchor, constant: 8),
            offRecord.centerYAnchor.constraint(equalTo: stop.centerYAnchor),
            offRecord.widthAnchor.constraint(equalToConstant: 26),
            offRecord.heightAnchor.constraint(equalToConstant: 26),
        ])

        // Keyboard tab order (UX23): Stop <-> off-record toggle. `stopButton` is the panel's initial
        // first responder (set in makePanel), so a click on the pill focuses Stop and Tab reaches
        // the toggle.
        stop.nextKeyView = offRecord
        offRecord.nextKeyView = stop
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
        // TECH-DSN5: a firm trackpad detent for the consequential Stop action
        // (no-op without a Force Touch trackpad). Preserved from the old StopButton,
        // which fired it on press; the shared record key fires its action on click.
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        delegate?.recordingHUDDidRequestStop(self)
    }

    /// Map a mic level in dBFS to the meter's normalized 0...1 activity. -60 dBFS
    /// (the meter floor) and below reads as silence; 0 dBFS lights every segment.
    /// Pure, so the mapping is pinned by tests without the 10 Hz poll timer.
    static func normalizedLevel(db: Float) -> Float {
        let floorDb: Float = -60
        let clamped = max(floorDb, min(0, db))
        return (clamped - floorDb) / (0 - floorDb)
    }

    fileprivate func handleRetrySystemAudio() {
        delegate?.recordingHUDDidRequestRetrySystemAudio(self)
    }

    fileprivate func handleToggleOffTheRecord() {
        delegate?.recordingHUDDidRequestToggleOffTheRecord(self)
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

/// Borderless nonactivating pill that can still become key (UX23), so Stop + the off-record toggle
/// are keyboard-reachable once the user clicks the pill. A plain borderless window returns false from
/// `canBecomeKey`; overriding it lets Tab / Space / Return drive the controls after a click.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// A floating panel in an accessory app does not reliably become key on its own, so a click left
    /// the pill unfocused with no ring. Force it here, but only for a click on the empty pill body: a
    /// mouse click on Stop / the off-record toggle keeps the quiet nonactivating behavior, while a
    /// click in the pill body focuses it so Tab / Space drive Stop + the toggle (UX23). Mirrors
    /// QuickFind's makeKey + activate. A body click still drags the pill (super handles it).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow, MPPanelFocus.isEmptyAreaClick(self, event) {
            NSApp.activate(ignoringOtherApps: true)
            makeKey()
        }
        super.sendEvent(event)
    }
}

/// Translucent rounded background using `hudWindow` material, matching the prompt panel.
private final class HUDBackgroundView: NSView {
    var cornerRadius: CGFloat = MPRadius.lg { didSet { needsLayout = true } }
    weak var host: RecordingHUDWindow?
    /// Mirrors the live off-the-record state so the right-click menu label reads correctly (UX23).
    var isOffRecord = false

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
    @objc func didClickRetrySystemAudio() { host?.handleRetrySystemAudio() }
    @objc func didClickOffRecord() { host?.handleToggleOffTheRecord() }

    /// Right-click menu (UX23): the second discoverable path to off-the-record, plus Stop. The label
    /// reflects the live state so it reads "Back on the record" while a span is open.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let offRec = NSMenuItem(
            title: isOffRecord ? "Back on the record" : "Go off the record",
            action: #selector(didClickOffRecord),
            keyEquivalent: ""
        )
        offRec.target = self
        menu.addItem(offRec)
        menu.addItem(.separator())
        let stop = NSMenuItem(title: "Stop recording", action: #selector(didClickStop), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        return menu
    }
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

/// Workflow attribution label (TECH-B9, TECH-DSN13). The workflow name sits on
/// its own row; when NDA mode is on, a small uppercase coral "NDA" eyebrow
/// stacks below it. Laid out as two real rows that collapse to just the name
/// row when not NDA - the old fixed-height box pinned the name to the top and
/// the badge to the bottom of a 14pt frame, so they overlapped ~10pt. The 76pt
/// panel is still too narrow for an inline name + badge row, so the name keeps the
/// full width (truncating tail) and NDA drops to its own line.
private final class HUDWorkflowLabel: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let ndaLabel = NSTextField(labelWithString: "NDA")

    /// Toggled in `apply`: the view's bottom tracks the name row when not NDA,
    /// the NDA eyebrow when NDA, so the second row collapses for non-NDA workflows.
    private var nameBottom: NSLayoutConstraint!
    private var ndaTop: NSLayoutConstraint!
    private var ndaBottom: NSLayoutConstraint!

    init(workflow: Workflow?) {
        super.init(frame: .zero)
        wantsLayer = true

        nameLabel.font = .systemFont(ofSize: 10, weight: .medium)
        nameLabel.textColor = MPColors.fgMuted
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        // Truncate the name rather than widen the fixed 76pt panel.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(nameLabel)

        ndaLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        ndaLabel.textColor = MPColors.pulse600   // Pulse-coral, kept for the "sensitive" signal.
        ndaLabel.alignment = .center
        ndaLabel.translatesAutoresizingMaskIntoConstraints = false
        ndaLabel.isHidden = true
        addSubview(ndaLabel)

        nameBottom = nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        ndaTop = ndaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: MPSpace.s1)
        ndaBottom = ndaLabel.bottomAnchor.constraint(equalTo: bottomAnchor)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            ndaLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        apply(workflow)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func apply(_ workflow: Workflow?) {
        guard let wf = workflow else {
            nameLabel.stringValue = ""
            setNDA(false)
            isHidden = true
            return
        }
        isHidden = false
        nameLabel.stringValue = wf.name
        setNDA(wf.flags.ndaMode)
    }

    /// Switch between the one-row (name only) and two-row (name + NDA eyebrow) layout.
    private func setNDA(_ on: Bool) {
        ndaLabel.isHidden = !on
        nameBottom.isActive = !on
        ndaTop.isActive = on
        ndaBottom.isActive = on
    }
}

/// Degraded-state banner (TECH-UX4). Warns mid-recording that system-audio
/// capture failed to start (TCC race, SCStream init error) and offers a
/// one-click retry. Collapsed to zero height until the recorder reports the
/// failure, so the resting HUD is unchanged.
private final class HUDDegradedBanner: NSView {
    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        wantsLayer = true

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        icon.contentTintColor = MPColors.warningAccent
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)

        let label = NSTextField(labelWithString: "System audio not captured")
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = MPColors.fgMuted
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let retry = NSButton(title: "Retry system audio", target: target, action: action)
        retry.bezelStyle = .rounded
        retry.controlSize = .small
        retry.font = .systemFont(ofSize: 10, weight: .medium)
        retry.toolTip = "Re-attempt system-audio capture"
        retry.setAccessibilityLabel("Retry system audio")
        retry.translatesAutoresizingMaskIntoConstraints = false
        addSubview(retry)

        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 2),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            retry.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            retry.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            retry.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 6),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Compact off-the-record toggle beside Stop on the HUD (MIC14 discoverability, UX23). A borderless
/// mic-slash glyph that tints coral and fills while an off-record span is open, mirroring the "Off
/// the record" state label. VoiceOver reads its current action; the tooltip mirrors it.
private final class HUDOffRecordButton: NSButton {
    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        wantsLayer = true
        setActive(false)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Reflect the live off-the-record state: a filled coral glyph while open, a muted outline when
    /// not. Also updates the tooltip + VoiceOver label to name the action the next tap performs.
    func setActive(_ on: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        image = NSImage(systemSymbolName: on ? "mic.slash.fill" : "mic.slash", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        contentTintColor = on ? MPColors.pulse600 : MPColors.fgMuted
        let label = on ? "Back on the record" : "Go off the record"
        toolTip = label
        setAccessibilityLabel(label)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // Keyboard (UX23): reachable by Tab and activatable by Space / Return, with the system focus ring.
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76 { performClick(nil) }
        else { super.keyDown(with: event) }
    }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

