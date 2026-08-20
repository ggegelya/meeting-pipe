import AppKit

/// Floating recording-status HUD: compact vertical pill, top-right, always-on-top. Exists because the menu-bar coral dot is easy to miss when other apps are foregrounded, and one-click stop is essential for a "this got sensitive, kill it" moment without navigating menus. Draggable via `isMovableByWindowBackground` so the user can move it off a Zoom control or chat avatar.
protocol RecordingHUDDelegate: AnyObject {
    func recordingHUDDidRequestStop(_ hud: RecordingHUDWindow)
    /// User tapped "Retry system audio" on the degraded banner (TECH-UX4).
    func recordingHUDDidRequestRetrySystemAudio(_ hud: RecordingHUDWindow)
    /// User toggled off-the-record from the HUD (MIC14 discoverability, UX23): the icon toggle beside
    /// Stop, or the right-click menu. The session controller owns the actual on/off state.
    func recordingHUDDidRequestToggleOffTheRecord(_ hud: RecordingHUDWindow)
    /// User flagged a moment from the HUD (FEAT8 discoverability, UX46): the flag button on the
    /// control row, or the right-click menu. Routes to the same session entry the flag-moment hotkey
    /// uses, so the marker has exactly one writer; `acknowledgeFlag(count:)` is the acknowledgement
    /// (UX73), and a press while nothing is recording is the same no-op the hotkey is.
    func recordingHUDDidRequestFlagMoment(_ hud: RecordingHUDWindow)
}

/// Pure panel geometry for the recording HUD (UX35), in the house `decide` style: explicit
/// inputs, nothing read off AppKit inside. Lifted off `RecordingHUDWindow` so the invariant that
/// matters is pinned by a test instead of by re-reading `setOffTheRecord`.
///
/// The HUD has exactly two shapes, the compact pill and the degraded card. `offRecord` is a
/// deliberate input that changes nothing: recording and off-the-record share one pill width, so
/// toggling can never resize the panel. `HUDPanelGeometryTests` asserts exactly that, which is
/// what stops a per-state width coming back.
enum HUDPanelGeometry {
    /// Gap between the controls at the pill's foot, and the side of one icon control.
    static let controlGap: CGFloat = 8
    static let iconControlSide: CGFloat = 26

    /// The control row at the pill's foot: the Stop record key, then the two icon controls beside
    /// it (off the record, MIC14 / UX23; flag a moment, UX46). 34 + 8 + 26 + 8 + 26 = 102pt.
    /// Derived rather than written out, so the pill width and Stop's centring offset cannot drift
    /// apart from the row they describe.
    static let controlRowWidth: CGFloat =
        RecordKey.Geometry.side + 2 * (controlGap + iconControlSide)

    /// Stop's offset from the pill's centreX. The row is centred as a group with Stop leftmost, so
    /// Stop sits half the row left of centre and half its own width back again: -17 with one icon
    /// control beside it (UX23), -34 with two (UX46).
    static let stopCenterXOffset: CGFloat = -(controlRowWidth - RecordKey.Geometry.side) / 2

    /// Shared pill width for the recording and off-the-record states.
    ///
    /// 76 -> 96 (UX35) -> 116 (UX46). Two pieces of content compete for it. The dot row (dot 8 +
    /// gap 5 + the state label at 10pt medium) lays out at 64pt for "Recording" and 83pt for "Off
    /// the record"; 76 fit only the first, so off-the-record used to resize to a hand-picked 150
    /// and carry ~67pt of dead space, and UX35 measured 96 as 83 plus 13pt of side margin, rounded
    /// onto the 4pt grid. UX46's third control then made the *control row* the wider of the two at
    /// `controlRowWidth` 102pt, which 96 could not have held, so 116 is 102 plus that same 13pt of
    /// margin, rounded onto the grid the same way. Every element in the pill is centred on its
    /// centerX or pinned to both edges, so one width stays layout-safe and the truncating workflow
    /// name only gains room (88pt of text width -> 108pt).
    ///
    /// This is the single place to resize the pill. A fourth control widens `controlRowWidth`,
    /// which moves `stopCenterXOffset` on its own but not this constant; `HUDPanelGeometryTests`
    /// fails on the row outgrowing the pill rather than letting it clip on screen.
    static let pillWidth: CGFloat = 116

    /// Degraded mode (TECH-UX4): the pill widens into a card so the banner text and retry button fit.
    static let cardWidth: CGFloat = 232

    // 132 -> 146 for the workflow attribution line (TECH-B9), 146 -> 162 for the TECH-UX8 voice-activity meter row, 162 -> 192 for the DSN25 Instrument port (the 22pt timer anchor, the record key, and the "Recording" label are all taller than what they replaced). Sized for the tallest (NDA two-row) case and allocated unconditionally so the HUD geometry doesn't shift between workflowed and un-workflowed meetings.
    static let height: CGFloat = 192

    static let bannerHeight: CGFloat = 60

    /// The panel size for a HUD state. Degraded dominates: that card owns the geometry for as long
    /// as the banner is up. Off-the-record never moves it, in either state, which is the UX35
    /// contract and also what keeps clearing the banner mid-span from shrinking the pill under a
    /// label it can no longer fit.
    static func size(offRecord: Bool, degraded: Bool) -> CGSize {
        degraded
            ? CGSize(width: cardWidth, height: height + bannerHeight)
            : CGSize(width: pillWidth, height: height)
    }
}

/// UX73: what the flag control shows once a moment has been flagged. Pure, in the same house
/// `decide` style as `HUDPanelGeometry` above: explicit inputs, nothing read off AppKit inside, so
/// the acknowledgement is pinned by a test rather than by re-reading an animation block.
///
/// FEAT8 acknowledged a flag by dipping the *whole panel's* `alphaValue` to 0.4 and back, and the
/// owner read that as no reaction at all (2026-08-04, "pretty weird feeling"). Three things made it
/// read that way: a window-level fade is the gesture macOS uses for a window losing focus, so it
/// reads as the HUD reacting to the click rather than to the flag; it left nothing behind, so a
/// user watching the call window could not learn afterwards that the press registered; and it said
/// nothing about what was recorded, though `flagMoment` had the count in hand the whole time. So
/// the acknowledgement moved onto the control that was pressed, and it carries the count.
struct HUDFlagAcknowledgement: Equatable {
    /// Flagged moments so far in this recording. Always the count of the same `markerSeconds` the
    /// marker sidecar is written from, so the badge and the artifact cannot disagree about how many
    /// moments were flagged.
    let count: Int

    /// Whether the press plays its scale. False under reduced motion, where the tint is applied and
    /// released without it, the way `blink()` collapsed to an instant dip-and-restore.
    let animated: Bool

    /// Nothing to show before the first flag: the resting control stays the plain outline glyph,
    /// per the design system's "no filled icons as primary state, filled is reserved for selected".
    var showsBadge: Bool { count > 0 }

    var badgeText: String { count > 0 ? String(count) : "" }

    /// The VoiceOver label, which has to carry the count too: a badge a sighted user can read after
    /// the fact is not an acknowledgement for someone who cannot see it.
    func accessibilityLabel(base: String) -> String {
        count > 0 ? "\(base), \(count) flagged" : base
    }

    static func decide(count: Int, reduceMotion: Bool) -> HUDFlagAcknowledgement {
        HUDFlagAcknowledgement(count: max(0, count), animated: !reduceMotion)
    }
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

    /// The flag-a-moment button (UX46). Held so `acknowledgeFlag` can render the count on it (UX73);
    /// before that the control was momentary and there was nothing to render.
    private weak var flagButton: HUDFlagButton?

    private static let edgeInset: CGFloat = 16

    /// The live off-the-record flag, mirrored onto the background view by `setOffTheRecord` for the
    /// right-click menu's label. Read back here so the geometry decision gets the real state rather
    /// than an assumption.
    private var isOffTheRecord: Bool { (contentView as? HUDBackgroundView)?.isOffRecord ?? false }

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

    /// UX73: acknowledge a flagged moment at the control that was pressed, carrying the running
    /// count. Replaces FEAT8's whole-panel opacity dip, which the owner reported as no reaction at
    /// all. `count` is the caller's `markerSeconds.count`, so the badge and the marker sidecar are
    /// the same number by construction. Main-queue only; a no-op when the HUD isn't showing.
    func acknowledgeFlag(count: Int) {
        flagButton?.apply(
            HUDFlagAcknowledgement.decide(count: count, reduceMotion: MPMotion.reduceMotion),
            pulsing: true
        )
    }

    /// UX73: drop the count for a fresh recording, with no acknowledgement played. Paired with
    /// every `markerSeconds` reset in `MeetingSessionController` so the surface can never outlive
    /// the batch it is counting.
    func resetFlagCount() {
        flagButton?.apply(
            HUDFlagAcknowledgement.decide(count: 0, reduceMotion: MPMotion.reduceMotion),
            pulsing: false
        )
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
            banner.heightAnchor.constraint(equalToConstant: HUDPanelGeometry.bannerHeight),
            stopToBanner,
        ])
        resizePanelAnchoringTopRight(to: HUDPanelGeometry.size(offRecord: isOffTheRecord, degraded: true))
    }

    /// Remove the degraded banner and shrink the HUD back to the compact pill.
    /// Idempotent. Main-queue only.
    func clearSystemAudioDegraded() {
        guard let banner = degradedBanner else { return }
        banner.removeFromSuperview()   // also removes its constraints, incl. the stop->banner pin
        degradedBanner = nil
        stopBottomToBanner = nil
        stopBottomNormal?.isActive = true
        resizePanelAnchoringTopRight(to: HUDPanelGeometry.size(offRecord: isOffTheRecord, degraded: false))
    }

    // MARK: Off the record (MIC14)

    /// Show or clear the persistent "Off the record" state: retitle + retint the state label so it
    /// cannot be forgotten, flip the toggle's glyph, and drop the meter. Idempotent. Main-queue only.
    ///
    /// Deliberately does not resize (UX35): `HUDPanelGeometry.pillWidth` holds the longer label
    /// with room to spare, so both states share one width and the pill never jumps under the
    /// user's cursor.
    func setOffTheRecord(_ on: Bool) {
        recordingLabel?.stringValue = on ? "Off the record" : "Recording"
        recordingLabel?.textColor = on ? MPColors.pulse600 : MPColors.fgMuted
        offRecordButton?.setActive(on)
        (contentView as? HUDBackgroundView)?.isOffRecord = on
        // Drop the meter on the click rather than at the next 10 Hz poll, so the toggle reads as
        // instant. Also the only cover for a stalled mic tap, which leaves the recorder's level
        // frozen at its last value: without this the meter would sit lit beside the label forever.
        if on { levelMeter?.level = 0 }
    }

    /// END9: show or clear the "confirming end" state. The call's controls have gone but Teams has
    /// not logged the teardown, so the recording is still running on purpose while the oracle
    /// decides. Idempotent, main-queue only, and it does not resize for the reason above.
    ///
    /// The elapsed readout goes `fgSubtle` rather than being hidden: it is still counting real
    /// captured seconds, and hiding it would misrepresent a recording that is genuinely running.
    /// `fgSubtle` is the quietest token that still clears DSN3's 4.5:1 contrast floor, which
    /// `fgFaint` does not (it measures about 2.8:1).
    func setConfirmingEnd(_ on: Bool) {
        // Off-the-record owns this label while it is on, and it is the stronger claim: it is about
        // what is being captured, where this is only about why we are still capturing.
        if (contentView as? HUDBackgroundView)?.isOffRecord != true {
            recordingLabel?.stringValue = on ? "Confirming end" : "Recording"
            recordingLabel?.textColor = on ? MPColors.fgSubtle : MPColors.fgMuted
        }
        elapsedLabel?.textColor = on ? MPColors.fgSubtle : MPColors.fgMuted
    }

    /// Resize keeping the panel's top-right corner fixed, so growing the
    /// degraded card doesn't yank a HUD the user dragged elsewhere.
    private func resizePanelAnchoringTopRight(to size: CGSize) {
        guard let panel = panel else { return }
        let frame = panel.frame
        let origin = NSPoint(x: frame.maxX - size.width, y: frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
    }

    // MARK: Panel construction

    private func makePanel(source: AppSource?, workflow: Workflow?) -> NSPanel {
        let rect = NSRect(origin: .zero, size: HUDPanelGeometry.size(offRecord: false, degraded: false))
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
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false

        panel.contentView = makeContentView(source: source, workflow: workflow)
        return panel
    }

    /// Internal rather than private so `HUDControlRowTests` can build the pill's content view and
    /// fire its controls without a panel or a window server (UX46).
    func makeContentView(source: AppSource?, workflow: Workflow?) -> NSView {
        let bg = HUDBackgroundView(frame: NSRect(origin: .zero, size: HUDPanelGeometry.size(offRecord: false, degraded: false)))
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

        // "Recording" label beside the dot so the state is never colour-only. The dot + label sit
        // as a centred row; 10pt matches the workflow line below. This row sized the pill until
        // UX46: 64pt here, 83pt once `setOffTheRecord` swaps in "Off the record", which is what
        // UX35 measured 96 against. The three-control row at the foot is wider still (102pt), so
        // `HUDPanelGeometry.pillWidth` now holds that and this row clears it comfortably.
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
        // right-click menu. The whole control row is centred as a group (Stop shifted left by
        // `HUDPanelGeometry.stopCenterXOffset`), so it fits any pill width.
        let offRecord = HUDOffRecordButton(target: bg, action: #selector(HUDBackgroundView.didClickOffRecord))
        offRecord.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(offRecord)
        self.offRecordButton = offRecord

        // Flag-a-moment button, the third control on the row (FEAT8 discoverability, UX46). FEAT8
        // was hotkey-only, so the one surface that is on screen for exactly as long as flagging is
        // possible never offered it. Still not a toggle, and it fires the same session entry the
        // hotkey does; UX73 gave it the one piece of state it does carry, the running count.
        let flag = HUDFlagButton(target: bg, action: #selector(HUDBackgroundView.didClickFlagMoment))
        flag.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(flag)
        self.flagButton = flag

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
            // workflow label. Shifted left so [Stop + the two icon controls] reads as a centred
            // group (34 + 8 + 26 + 8 + 26 = 102pt within the 116pt pill). Both the offset and the
            // width come off `HUDPanelGeometry`, so a control added or removed moves them together.
            stop.centerXAnchor.constraint(equalTo: bg.centerXAnchor, constant: HUDPanelGeometry.stopCenterXOffset),
            stopBottom,
            stop.widthAnchor.constraint(equalToConstant: RecordKey.Geometry.side),
            stop.heightAnchor.constraint(equalToConstant: RecordKey.Geometry.side),

            offRecord.leadingAnchor.constraint(equalTo: stop.trailingAnchor, constant: HUDPanelGeometry.controlGap),
            offRecord.centerYAnchor.constraint(equalTo: stop.centerYAnchor),
            offRecord.widthAnchor.constraint(equalToConstant: HUDPanelGeometry.iconControlSide),
            offRecord.heightAnchor.constraint(equalToConstant: HUDPanelGeometry.iconControlSide),

            flag.leadingAnchor.constraint(equalTo: offRecord.trailingAnchor, constant: HUDPanelGeometry.controlGap),
            flag.centerYAnchor.constraint(equalTo: stop.centerYAnchor),
            flag.widthAnchor.constraint(equalToConstant: HUDPanelGeometry.iconControlSide),
            flag.heightAnchor.constraint(equalToConstant: HUDPanelGeometry.iconControlSide),
        ])
        return bg
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - HUDPanelGeometry.pillWidth - Self.edgeInset,
            y: visible.maxY - HUDPanelGeometry.height - Self.edgeInset
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

    /// UX46: the button and the right-click item both land here, and this is the only thing either
    /// does. No marker is written on this side; the delegate hop reaches the same
    /// `MeetingSessionController.flagMoment` the hotkey calls, which stamps the timestamp and calls
    /// back into `acknowledgeFlag(count:)` with the new count (UX73). That single hop is why both
    /// controls acknowledge identically without either of them knowing the count.
    fileprivate func handleFlagMoment() {
        delegate?.recordingHUDDidRequestFlagMoment(self)
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
    @objc func didClickFlagMoment() { host?.handleFlagMoment() }

    /// Right-click menu (UX23): the second discoverable path to off-the-record and, since UX46, to
    /// flagging a moment, plus Stop. The off-record label reflects the live state so it reads "Back
    /// on the record" while a span is open. Ordered by consequence, the destructive one last behind
    /// its separator; each item is the same selector its button on the control row fires, so a
    /// press by either route is one path.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let flag = NSMenuItem(title: HUDFlagButton.label, action: #selector(didClickFlagMoment), keyEquivalent: "")
        flag.target = self
        menu.addItem(flag)
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
/// the badge to the bottom of a 14pt frame, so they overlapped ~10pt. The name keeps
/// the full width (truncating tail) and NDA drops to its own line, which holds at any
/// pill width: an inline row would have to truncate the name against the badge, and a
/// name is not bounded the way "NDA" is. UX35's extra room (68pt of text width -> 88pt)
/// buys longer names before the tail truncates; it does not revisit the two-row shape.
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
        // Truncate the name rather than widen the fixed-width panel.
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
}

/// Compact flag-a-moment button on the HUD control row (FEAT8 discoverability, UX46). Its sibling
/// above is a toggle; this one is not, and UX73 gave it the only state it carries: the running count
/// of moments flagged in this recording, as a badge on the glyph, plus the press acknowledgement
/// that used to live on the whole panel.
///
/// The glyph stays outline and monochrome in every state, per the design system's two iconography
/// rules ("no filled icons as primary state, filled is reserved for selected in toggles" and
/// "monochrome only, never tinted decoratively"). A count is not a selection, so it does not earn a
/// fill. The one tint is the press itself, which uses `signal600`, the sanctioned active state, and
/// releases straight back to `fgMuted` (the AA-clearing muted step, not `fgFaint`).
private final class HUDFlagButton: NSButton {
    /// Named once, so the tooltip, the VoiceOver label, and the right-click item cannot drift into
    /// three descriptions of one action.
    static let label = "Flag this moment"

    /// The running count, bottom-trailing on the glyph. Hidden at zero so an untouched control is
    /// byte-for-byte the resting state UX46 shipped.
    private let badge = NSTextField(labelWithString: "")

    /// Guards the settle: two presses inside one press duration would otherwise let the first one's
    /// restore fire during the second and leave the control muted mid-acknowledgement.
    private var pulseGeneration = 0

    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        wantsLayer = true
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        image = NSImage(systemSymbolName: "flag", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        contentTintColor = MPColors.fgMuted
        toolTip = HUDFlagButton.label
        setAccessibilityLabel(HUDFlagButton.label)

        badge.font = .systemFont(ofSize: MPType.textXS, weight: MPType.semibold)
        badge.textColor = MPColors.fgMuted
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: trailingAnchor),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Render `ack`, and when `pulsing` play the press acknowledgement on the control itself. The
    /// count is rendered either way, so the reset path shares this one code path and there is no
    /// second implementation to drift.
    func apply(_ ack: HUDFlagAcknowledgement, pulsing: Bool) {
        badge.stringValue = ack.badgeText
        badge.isHidden = !ack.showsBadge
        setAccessibilityLabel(ack.accessibilityLabel(base: HUDFlagButton.label))
        guard pulsing else { return }
        pulse(animated: ack.animated)
    }

    /// The blessed press feedback (DSN24), applied here on demand rather than on a real mouse-down:
    /// the acknowledgement has to fire for the right-click item and the hotkey too, neither of which
    /// presses this button. Scale to 0.97 over `durPress` about the bounds centre, exactly as
    /// `MPButton.applyPressScale` does, plus the `signal600` tint. Under reduced motion the scale is
    /// skipped and only the tint plays, which is the same collapse `blink()` made.
    private func pulse(animated: Bool) {
        pulseGeneration += 1
        let generation = pulseGeneration
        contentTintColor = MPColors.signal600
        badge.textColor = MPColors.signal600
        if animated { applyPressScale(0.97) }

        DispatchQueue.main.asyncAfter(deadline: .now() + MPMotion.durPress) { [weak self] in
            guard let self = self, self.pulseGeneration == generation else { return }
            self.contentTintColor = MPColors.fgMuted
            self.badge.textColor = MPColors.fgMuted
            if animated { self.applyPressScale(1) }
        }
    }

    /// An NSView-backed layer anchors at (0,0), so scale about the bounds centre via
    /// translate -> scale -> translate-back.
    private func applyPressScale(_ scale: CGFloat) {
        guard let layer = layer else { return }
        let mid = CGPoint(x: bounds.midX, y: bounds.midY)
        let transform = CATransform3DConcat(
            CATransform3DConcat(
                CATransform3DMakeTranslation(-mid.x, -mid.y, 0),
                CATransform3DMakeScale(scale, scale, 1)),
            CATransform3DMakeTranslation(mid.x, mid.y, 0))
        CATransaction.begin()
        CATransaction.setAnimationDuration(MPMotion.durPress)
        CATransaction.setAnimationTimingFunction(MPMotion.easeOut)
        layer.transform = transform
        CATransaction.commit()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

