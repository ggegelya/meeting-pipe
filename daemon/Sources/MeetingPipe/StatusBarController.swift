import AppKit
import Combine

/// Owns the NSStatusItem and its menu. Phase 0 just shows "Idle"; later phases
/// flip this to "Recording" and add Start/Stop entries.
final class StatusBarController {
    private let item: NSStatusItem
    weak var coordinator: Coordinator?
    /// Optional bridge into the SwiftUI Library window's footer. Each
    /// state setter mirrors here so the rail's status row + record button
    /// stay in sync with the menu bar without subscribing to private
    /// AppKit setters.
    var libraryModel: LibraryWindowModel?

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

    /// Last reported model-download state. Surfaced as a prefix on the
    /// menu-bar title (so it's visible without opening the menu) plus a
    /// dedicated header row in the menu (so the user can see the bytes
    /// breakdown). `idle` means no downloading happening; we never show
    /// `completed` longer than `completedDisplayDuration` to avoid a
    /// stale "Downloaded X" line lingering forever.
    private var modelDownload: ModelDownloadSupervisor.State = .idle
    private var modelDownloadCompletedDisplayTimer: Timer?
    private static let completedDisplayDuration: TimeInterval = 5

    /// Re-render the menu whenever any permission flips so the
    /// aggregate warning row appears / disappears without waiting for
    /// the next recording state change. Subscribed once at init.
    private var permissionsCancellable: AnyCancellable?

    init(item: NSStatusItem) {
        self.item = item
        if let button = item.button {
            button.image = idleIcon
            button.imagePosition = .imageLeft
        }
        permissionsCancellable = PermissionsCenter.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // objectWillChange fires *before* the value flips. Hop
                // one runloop so the menu sees the new state.
                DispatchQueue.main.async { self?.refreshMenuForPermissionChange() }
            }
    }

    func setIdle() {
        item.button?.image = idleIcon
        baseTitle = "Idle"
        applyTitle()
        rebuildMenu(state: .idle)
        libraryModel?.status = .idle
        libraryModel?.liveRecordingStem = nil
    }

    func setPrompting(_ source: AppSource) {
        item.button?.image = idleIcon
        baseTitle = "Detected \(source.displayName)"
        applyTitle()
        rebuildMenu(state: .prompting(source: source))
        libraryModel?.status = .prompting(appName: source.displayName)
    }

    func setRecording(
        file: URL,
        source: AppSource?,
        summaryMode: SummaryMode,
        workflow: Workflow? = nil
    ) {
        item.button?.image = recordingIcon
        var label = summaryMode == .byo ? "Recording (BYO)" : "Recording"
        if let wf = workflow {
            // TECH-B5: status-bar title now includes the active workflow
            // so the user can confirm at a glance that they're recording
            // to e.g. the "Client work" Notion DB and not their personal
            // one. NDA mode gets a coral marker.
            label += " — \(wf.name)\(wf.flags.ndaMode ? " · NDA" : "")"
        }
        baseTitle = label
        applyTitle()
        rebuildMenu(state: .recording(file: file, source: source, summaryMode: summaryMode))
        libraryModel?.status = .recording(appName: source?.displayName)
        libraryModel?.liveRecordingStem = file.deletingPathExtension().lastPathComponent
    }

    func setStopping() {
        item.button?.image = idleIcon
        baseTitle = "Stopping…"
        applyTitle()
        rebuildMenu(state: .idle)
        libraryModel?.status = .stopping
        // Keep liveRecordingStem until setIdle fires so the row's pulse
        // stays visible through the flush.
    }

    /// Update the processing-jobs badge. Called from the Coordinator
    /// whenever the queue grows or shrinks; independent of recording state.
    func setProcessingCount(_ n: Int) {
        processingCount = n
        applyTitle()
        rebuildMenu(state: lastMenuState)
        libraryModel?.processingCount = n
    }

    /// Reflect the model-prefetch lifecycle in the menu bar. The download
    /// is asynchronous; the user is otherwise blind to it because it
    /// happens inside a Python subprocess called from the Coordinator.
    /// Driven by `Coordinator.modelDownload.onStateChange`.
    func setModelDownload(_ s: ModelDownloadSupervisor.State) {
        modelDownload = s
        modelDownloadCompletedDisplayTimer?.invalidate()
        modelDownloadCompletedDisplayTimer = nil
        if case .completed = s {
            // Keep the "Downloaded X" line up briefly so the user sees
            // the resolution; then collapse to idle so the menu isn't
            // perpetually advertising a now-finished download.
            modelDownloadCompletedDisplayTimer = Timer.scheduledTimer(
                withTimeInterval: Self.completedDisplayDuration, repeats: false
            ) { [weak self] _ in
                guard let self = self else { return }
                self.modelDownload = .idle
                self.applyTitle()
                self.rebuildMenu(state: self.lastMenuState)
                self.libraryModel?.modelDownload = .idle
            }
        }
        applyTitle()
        rebuildMenu(state: lastMenuState)
        libraryModel?.modelDownload = s
    }

    private func applyTitle() {
        let badge = processingCount > 0 ? " · Processing (\(processingCount))" : ""
        let download = modelDownloadTitleSuffix
        item.button?.title = " \(baseTitle)\(badge)\(download)"
    }

    /// Compact suffix that fits in the menu-bar title alongside the
    /// existing state label. We show only the percent (or "…" when the
    /// total is unknown) here; full byte breakdown lives in the menu.
    private var modelDownloadTitleSuffix: String {
        switch modelDownload {
        case .idle, .completed:
            return ""
        case .downloading(_, let progress, _, _):
            if let pct = progress {
                return " · ↓ \(Int(pct * 100))%"
            }
            return " · ↓ …"
        case .failed:
            return " · ↓ failed"
        }
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

    /// Aggregated "any required permission is missing" check used by
    /// the menu's warning row. Screen Recording's `.unknown` state is
    /// excluded — it's transient (prewarm hasn't finished) and would
    /// flash the warning at every cold launch.
    private func hasPendingPermissionIssue() -> Bool {
        let center = PermissionsCenter.shared
        if center.microphone == .denied || center.microphone == .notDetermined {
            return true
        }
        if center.screenRecording == .denied {
            return true
        }
        if center.accessibility == .denied {
            return true
        }
        return false
    }

    private func rebuildMenu(state: AppState) {
        lastMenuState = state
        let menu = NSMenu()

        let header = NSMenuItem(title: stateLabel(state), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if let downloadRow = modelDownloadMenuRow {
            menu.addItem(downloadRow)
            menu.addItem(.separator())
        }

        // Aggregate permission warning. Any of mic / screen recording /
        // accessibility being non-granted surfaces a single row that
        // routes to the new Permissions tab in Preferences (TECH-E3).
        // The legacy Screen-Recording-only row is preserved as a
        // shortcut to Settings when that's the specific problem.
        if hasPendingPermissionIssue() {
            let warn = NSMenuItem(
                title: "⚠ Permissions need attention — Open Preferences…",
                action: #selector(Coordinator.menuPreferences),
                keyEquivalent: ""
            )
            warn.target = coordinator
            menu.addItem(warn)
            if SystemAudioCapture.permissionState == .denied {
                let scrShortcut = NSMenuItem(
                    title: "Open Screen Recording Settings…",
                    action: #selector(Coordinator.menuOpenScreenRecordingSettings),
                    keyEquivalent: ""
                )
                scrShortcut.target = coordinator
                menu.addItem(scrShortcut)
            }
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
        let openLibrary = NSMenuItem(
            title: "Open Library…",
            action: #selector(Coordinator.menuOpenLibrary),
            keyEquivalent: "l"
        )
        openLibrary.target = coordinator
        menu.addItem(openLibrary)

        if let coordinator = coordinator,
           let recentItem = recentMeetingsMenuItem(coordinator: coordinator) {
            menu.addItem(recentItem)
        }

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

    /// "Recent meetings…" submenu containing the last 10 meetings with
    /// a run sidecar on disk. Each child opens the correction sheet for
    /// that stem. Returns nil when no eligible meetings exist so the
    /// menu does not advertise an empty submenu.
    private func recentMeetingsMenuItem(coordinator: Coordinator) -> NSMenuItem? {
        let entries = coordinator.recentCorrectableMeetings(limit: 10)
        if entries.isEmpty { return nil }
        let parent = NSMenuItem(title: "Recent meetings…", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for entry in entries {
            let item = NSMenuItem(
                title: entry.displayName,
                action: #selector(Coordinator.menuRecentMeeting(_:)),
                keyEquivalent: ""
            )
            item.target = coordinator
            item.representedObject = entry.stem
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    /// Detailed model-download row, or nil when there's nothing to show.
    /// Disabled (informational); clicking does nothing.
    private var modelDownloadMenuRow: NSMenuItem? {
        switch modelDownload {
        case .idle:
            return nil
        case .downloading(let modelId, let progress, let downloaded, let total):
            let head = Self.shortModelId(modelId)
            let body: String
            if total > 0 {
                body = "\(Self.formatBytes(downloaded)) / \(Self.formatBytes(total))"
                    + (progress.map { " (\(Int($0 * 100))%)" } ?? "")
            } else {
                body = "\(Self.formatBytes(downloaded)) downloaded"
            }
            let item = NSMenuItem(title: "Downloading \(head): \(body)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .completed(let modelId):
            let item = NSMenuItem(title: "✓ Downloaded \(Self.shortModelId(modelId))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .failed(let modelId, let error):
            let item = NSMenuItem(
                title: "⚠ Model download failed: \(Self.shortModelId(modelId)): \(error.prefix(80))",
                action: nil, keyEquivalent: ""
            )
            item.isEnabled = false
            return item
        }
    }

    /// Drop the `mlx-community/` prefix when present so the menu row
    /// stays readable on a 24"+ display without truncation. The full id
    /// is in Preferences -> Pipeline if the user wants exact-string.
    private static func shortModelId(_ id: String) -> String {
        if let slash = id.lastIndex(of: "/") {
            return String(id[id.index(after: slash)...])
        }
        return id
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        if kb >= 1 { return String(format: "%.0f KB", kb) }
        return "\(bytes) B"
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
