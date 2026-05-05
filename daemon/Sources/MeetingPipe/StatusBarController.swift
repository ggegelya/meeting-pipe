import AppKit

/// Owns the NSStatusItem and its menu. Phase 0 just shows "Idle"; later phases
/// flip this to "Recording" and add Start/Stop entries.
final class StatusBarController {
    private let item: NSStatusItem
    weak var coordinator: Coordinator?

    /// 18pt is the menu-bar standard. Both icons render at this size.
    private static let iconSize: CGFloat = 18

    private lazy var idleIcon: NSImage = Self.makeIdleIcon(size: Self.iconSize)
    private lazy var recordingIcon: NSImage = Self.makeRecordingIcon(size: Self.iconSize)

    /// Last state we built a menu for, so `refreshMenuForPermissionChange`
    /// can rebuild without callers having to remember which state we're in.
    private var lastMenuState: AppState = .idle
    /// Cached recording-side title so the processing badge can be appended
    /// without callers re-supplying the current state.
    private var baseTitle: String = "Idle"
    /// Number of pipeline jobs currently queued or running. Surfaced as a
    /// badge alongside the recording state title so the user always knows
    /// how many meetings are still being transcribed in the background.
    private var processingCount: Int = 0

    init(item: NSStatusItem) {
        self.item = item
        if let button = item.button {
            button.image = idleIcon
            button.imagePosition = .imageLeft
        }
    }

    func setIdle() {
        item.button?.image = idleIcon
        baseTitle = "Idle"
        applyTitle()
        rebuildMenu(state: .idle)
    }

    func setPrompting(_ source: AppSource) {
        item.button?.image = idleIcon
        baseTitle = "Detected \(source.displayName)"
        applyTitle()
        rebuildMenu(state: .prompting(source: source))
    }

    func setRecording(file: URL, source: AppSource?, summaryMode: SummaryMode) {
        item.button?.image = recordingIcon
        baseTitle = summaryMode == .byo ? "Recording (BYO)" : "Recording"
        applyTitle()
        rebuildMenu(state: .recording(file: file, source: source, summaryMode: summaryMode))
    }

    func setStopping() {
        item.button?.image = idleIcon
        baseTitle = "Stopping…"
        applyTitle()
        rebuildMenu(state: .idle)
    }

    /// Update the processing-jobs badge. Called from the Coordinator
    /// whenever the queue grows or shrinks; independent of recording state.
    func setProcessingCount(_ n: Int) {
        processingCount = n
        applyTitle()
        rebuildMenu(state: lastMenuState)
    }

    private func applyTitle() {
        let badge = processingCount > 0 ? " · Processing (\(processingCount))" : ""
        item.button?.title = " \(baseTitle)\(badge)"
    }

    // MARK: Icons
    //
    // Both icons match the design's `assets/menubar-icon*.svg` shapes
    // (1.4pt circle, waveform bars at 4.5/6.6/8.7/10.8/12.9, recording dot
    // r=2.6 at center). We render via AppKit drawing rather than loading
    // the SVGs because:
    //   - The idle icon needs to be a TEMPLATE so AppKit auto-tints it
    //     light/dark with the menu-bar appearance.
    //   - The recording icon mixes a template-tinted ring with a fixed-color
    //     coral dot — NSImage has no partial-template mode, so we have to
    //     composite manually.
    // The SVGs in Resources/ remain the source of truth for the design;
    // these renderers reproduce the same shapes pixel-for-pixel.

    private static func makeIdleIcon(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width / 18.0  // SVG viewBox is 18×18

            // Ring: cx=9 cy=9 r=7.5 stroke-width=1.4
            let ringRect = NSRect(
                x: (9 - 7.5) * s, y: (9 - 7.5) * s,
                width: 15 * s, height: 15 * s
            )
            let ring = NSBezierPath(ovalIn: ringRect.insetBy(dx: 0.7 * s, dy: 0.7 * s))
            ring.lineWidth = 1.4 * s
            NSColor.black.setStroke()
            ring.stroke()

            // Waveform bars (5): same x-stride 2.1, varying heights, all rx=0.7
            let bars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
                (4.5,  8.0,  2.0),
                (6.6,  6.4,  5.2),
                (8.7,  5.0,  8.0),
                (10.8, 6.8,  4.4),
                (12.9, 8.0,  2.0),
            ]
            NSColor.black.setFill()
            for bar in bars {
                let r = NSRect(x: bar.x * s, y: bar.y * s, width: 1.4 * s, height: bar.h * s)
                NSBezierPath(roundedRect: r, xRadius: 0.7 * s, yRadius: 0.7 * s).fill()
            }
            return true
        }
        img.isTemplate = true   // AppKit will tint to match menu-bar appearance.
        img.accessibilityDescription = "MeetingPipe"
        return img
    }

    private static func makeRecordingIcon(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width / 18.0

            // Ring — drawn in template-friendly black so consumers that DO
            // template-tint this image still get a sensible ring. We render
            // this as a NON-template image (because of the coral dot), so
            // AppKit won't auto-tint; we pick a mid-tone that reads on both
            // light and dark menu bars.
            let ringStroke = NSColor(srgbRed: 0x4A/255.0, green: 0x4F/255.0, blue: 0x58/255.0, alpha: 1) // ink600
            ringStroke.setStroke()
            let ringRect = NSRect(
                x: (9 - 7.5) * s, y: (9 - 7.5) * s,
                width: 15 * s, height: 15 * s
            )
            let ring = NSBezierPath(ovalIn: ringRect.insetBy(dx: 0.7 * s, dy: 0.7 * s))
            ring.lineWidth = 1.4 * s
            ring.stroke()

            // Coral dot — cx=9 cy=9 r=2.6
            MPColors.pulse600.setFill()
            let dot = NSBezierPath(ovalIn: NSRect(
                x: (9 - 2.6) * s, y: (9 - 2.6) * s,
                width: 5.2 * s, height: 5.2 * s
            ))
            dot.fill()
            return true
        }
        img.isTemplate = false  // Coral dot must keep its color across appearances.
        img.accessibilityDescription = "MeetingPipe — Recording"
        return img
    }

    /// Rebuild the menu against whatever state we last rendered. Called when
    /// the Screen Recording permission flips to denied (or back) so the
    /// warning row appears/disappears without waiting for the next state
    /// transition.
    func refreshMenuForPermissionChange() {
        rebuildMenu(state: lastMenuState)
    }

    private func rebuildMenu(state: AppState) {
        lastMenuState = state
        let menu = NSMenu()

        let header = NSMenuItem(title: stateLabel(state), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if SystemAudioCapture.permissionState == .denied {
            let warn = NSMenuItem(
                title: "⚠ System audio blocked — Open Screen Recording Settings…",
                action: #selector(Coordinator.menuOpenScreenRecordingSettings),
                keyEquivalent: ""
            )
            warn.target = coordinator
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        switch state {
        case .idle:
            let start = NSMenuItem(title: "Start Recording", action: #selector(Coordinator.menuStart), keyEquivalent: "")
            start.target = coordinator
            menu.addItem(start)
        case .recording:
            let stop = NSMenuItem(title: "Stop Recording", action: #selector(Coordinator.menuStop), keyEquivalent: "")
            stop.target = coordinator
            menu.addItem(stop)
        default:
            break
        }

        menu.addItem(.separator())
        let openLogs = NSMenuItem(title: "Open Logs Folder", action: #selector(Coordinator.menuOpenLogs), keyEquivalent: "")
        openLogs.target = coordinator
        menu.addItem(openLogs)

        let openRecordings = NSMenuItem(title: "Open Recordings Folder", action: #selector(Coordinator.menuOpenRecordings), keyEquivalent: "")
        openRecordings.target = coordinator
        menu.addItem(openRecordings)

        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(Coordinator.menuPreferences), keyEquivalent: ",")
        prefs.target = coordinator
        menu.addItem(prefs)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MeetingPipe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
    }

    private func stateLabel(_ s: AppState) -> String {
        let suffix = processingCount > 0 ? " · Processing (\(processingCount))" : ""
        switch s {
        case .idle: return "MeetingPipe: Idle\(suffix)"
        case .prompting(let src): return "MeetingPipe: Detected \(src.displayName)\(suffix)"
        case .suppressed(let src): return "MeetingPipe: Suppressed (\(src.displayName))\(suffix)"
        case .recording: return "MeetingPipe: Recording\(suffix)"
        case .stopping: return "MeetingPipe: Stopping…\(suffix)"
        }
    }
}
