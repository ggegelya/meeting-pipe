import AppKit
import Combine

/// Owns the NSStatusItem and its menu, and mirrors state to the menu bar.
final class StatusBarController {
    private let item: NSStatusItem
    weak var coordinator: Coordinator?
    /// Bridge into the Library window's footer; state setters mirror here so
    /// the rail stays in sync with the menu bar.
    var libraryModel: LibraryWindowModel?

    /// 18pt is the menu-bar standard.
    private static let iconSize: CGFloat = 18

    private var idleIcon: NSImage = StatusBarController.makeIdleIcon(
        size: StatusBarController.iconSize,
        style: UISettings.shared.menuBarIconStyle
    )
    private var recordingIcon: NSImage = StatusBarController.makeRecordingIcon(size: StatusBarController.iconSize)

    /// Regulated-mode flag for the lock-glyph badge (driven by Coordinator).
    /// The glyph needs this AND `UISettings.shared.showRegulatedBadge`.
    private var regulatedMode: Bool = false

    /// Live UI-setting subscriptions (icon style + regulated badge).
    private var iconStyleCancellable: AnyCancellable?
    private var regulatedBadgeCancellable: AnyCancellable?

    /// Last state a menu was built for, so a permission-driven rebuild
    /// doesn't need the caller to re-supply it.
    private var lastMenuState: AppState = .idle
    /// Cached recording title so the processing badge can append to it.
    private var baseTitle: String = "Idle"
    /// Pipeline jobs queued or running; shown as a title badge.
    private var processingCount: Int = 0

    /// Last model-download state. Shown as a title prefix + a menu header
    /// row; `completed` collapses to idle after `completedDisplayDuration`
    /// so a stale "Downloaded X" line doesn't linger.
    private var modelDownload: ModelDownloadSupervisor.State = .idle
    private var modelDownloadCompletedDisplayTimer: Timer?
    private static let completedDisplayDuration: TimeInterval = 5

    /// Delegate for the "Recent meetings" submenu; populates on
    /// `menuNeedsUpdate` so a rebuild doesn't pay a dir scan for a submenu
    /// the user rarely opens.
    private var recentMeetingsDelegate: RecentMeetingsMenuDelegate?

    /// Top-level menu delegate; re-probes permissions just before showing so
    /// the warning row reflects a just-granted permission.
    private let menuDelegate = StatusMenuDelegate()

    /// Rebuild the menu when any permission flips, so the warning row
    /// appears/disappears without waiting for a state change.
    private var permissionsCancellable: AnyCancellable?

    /// Permission snapshot for `removeDuplicates`, so the menu rebuilds on
    /// real value changes rather than every `objectWillChange` (per-property,
    /// 2 s poll).
    private struct PermissionsSnapshot: Equatable {
        let microphone: PermissionsCenter.Status
        let screenRecording: PermissionsCenter.Status
        let accessibility: PermissionsCenter.Status
        let notifications: PermissionsCenter.Status
    }

    init(item: NSStatusItem) {
        self.item = item
        if let button = item.button {
            button.image = idleIcon
            button.imagePosition = .imageLeft
        }
        let center = PermissionsCenter.shared
        // Dedupe permission snapshots so the menu rebuilds only on a real
        // change; subscribing to `objectWillChange` rebuilt it ~twice a
        // second (4+ commits per 2 s poll tick).
        permissionsCancellable = Publishers.CombineLatest4(
            center.$microphone,
            center.$screenRecording,
            center.$accessibility,
            center.$notifications
        )
        .map(PermissionsSnapshot.init(microphone:screenRecording:accessibility:notifications:))
        .removeDuplicates()
        .dropFirst()   // menu is built lazily on the first state setter
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.refreshMenuForPermissionChange() }

        // Live icon-style swap (Outline/Filled); the recording icon is
        // style-independent and stays as-is.
        iconStyleCancellable = UISettings.shared.$menuBarIconStyle
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] style in
                guard let self = self else { return }
                self.idleIcon = Self.makeIdleIcon(size: Self.iconSize, style: style)
                if !self.isShowingRecordingIcon { self.item.button?.image = self.idleIcon }
            }

        // Recompute the title suffix when the badge toggle flips so the lock
        // glyph appears/disappears immediately.
        regulatedBadgeCancellable = UISettings.shared.$showRegulatedBadge
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyTitle() }

        menuDelegate.controller = self
    }

    /// True when the recording icon is shown; the icon-style live-swap
    /// checks this so it doesn't stomp it back to idle mid-session.
    private var isShowingRecordingIcon: Bool {
        item.button?.image === recordingIcon
    }

    /// Reflect a `regulatedMode` change; the glyph renders in `applyTitle()`.
    func setRegulatedMode(_ on: Bool) {
        regulatedMode = on
        applyTitle()
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
            // TECH-B5: show the active workflow so the user can confirm the
            // destination at a glance; NDA mode gets a marker.
            label += " - \(wf.name)\(wf.flags.ndaMode ? " · NDA" : "")"
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

    /// Update the processing-jobs badge. Writes into the sibling
    /// `LibraryWindowModel.processing` (not a parent @Published) so only the
    /// toolbar re-renders per tick.
    func setProcessingCount(_ n: Int) {
        processingCount = n
        applyTitle()
        rebuildMenu(state: lastMenuState)
        libraryModel?.processing.count = n
    }

    /// Reflect the async model-prefetch lifecycle in the menu bar (driven by
    /// the supervisor's `onStateChange`), the only surface for it.
    func setModelDownload(_ s: ModelDownloadSupervisor.State) {
        modelDownload = s
        modelDownloadCompletedDisplayTimer?.invalidate()
        modelDownloadCompletedDisplayTimer = nil
        if case .completed = s {
            // Show "Downloaded X" briefly, then collapse to idle.
            modelDownloadCompletedDisplayTimer = Timer.scheduledTimer(
                withTimeInterval: Self.completedDisplayDuration, repeats: false
            ) { [weak self] _ in
                guard let self = self else { return }
                self.modelDownload = .idle
                self.applyTitle()
                self.rebuildMenu(state: self.lastMenuState)
            }
        }
        applyTitle()
        rebuildMenu(state: lastMenuState)
    }

    private func applyTitle() {
        let badge = processingCount > 0 ? " · Processing (\(processingCount))" : ""
        let download = modelDownloadTitleSuffix
        let lock = (regulatedMode && UISettings.shared.showRegulatedBadge) ? " \u{1F512}" : ""
        item.button?.title = " \(baseTitle)\(badge)\(download)\(lock)"
    }

    /// Compact title suffix: percent only (or "…" when total is unknown);
    /// the byte breakdown lives in the menu.
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
    //     coral dot - NSImage has no partial-template mode, so we have to
    //     composite manually.
    // The SVGs in Resources/ remain the source of truth for the design;
    // these renderers reproduce the same shapes pixel-for-pixel.

    private static func makeIdleIcon(size: CGFloat, style: UISettings.MenuBarIconStyle = .outline) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width / 18.0  // SVG viewBox is 18×18

            // Outline variant keeps the chrome ring around the bars. The
            // filled variant drops the ring entirely (heavier-feeling
            // bars alone), so users on a busy menu bar can pick the
            // chunkier glyph if the thin ring disappears into other
            // status icons.
            if style == .outline {
                let ringRect = NSRect(
                    x: (9 - 7.5) * s, y: (9 - 7.5) * s,
                    width: 15 * s, height: 15 * s
                )
                let ring = NSBezierPath(ovalIn: ringRect.insetBy(dx: 0.7 * s, dy: 0.7 * s))
                ring.lineWidth = 1.4 * s
                NSColor.black.setStroke()
                ring.stroke()
            }

            // Waveform bars (5): same x-stride 2.1, varying heights, all rx=0.7
            let bars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
                (4.5,  8.0,  2.0),
                (6.6,  6.4,  5.2),
                (8.7,  5.0,  8.0),
                (10.8, 6.8,  4.4),
                (12.9, 8.0,  2.0),
            ]
            // Filled variant widens the bars so dropping the ring
            // doesn't shrink the perceived footprint.
            let barWidth: CGFloat = style == .filled ? 2.0 : 1.4
            let barRadius: CGFloat = style == .filled ? 1.0 : 0.7
            NSColor.black.setFill()
            for bar in bars {
                let r = NSRect(x: bar.x * s, y: bar.y * s, width: barWidth * s, height: bar.h * s)
                NSBezierPath(roundedRect: r, xRadius: barRadius * s, yRadius: barRadius * s).fill()
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

            // Non-template image (coral dot), so AppKit won't auto-tint the
            // ring: pick a mid-tone that reads on light and dark menu bars.
            let ringStroke = NSColor(srgbRed: 0x4A/255.0, green: 0x4F/255.0, blue: 0x58/255.0, alpha: 1) // ink600
            ringStroke.setStroke()
            let ringRect = NSRect(
                x: (9 - 7.5) * s, y: (9 - 7.5) * s,
                width: 15 * s, height: 15 * s
            )
            let ring = NSBezierPath(ovalIn: ringRect.insetBy(dx: 0.7 * s, dy: 0.7 * s))
            ring.lineWidth = 1.4 * s
            ring.stroke()

            // Coral dot - cx=9 cy=9 r=2.6
            MPColors.pulse600.setFill()
            let dot = NSBezierPath(ovalIn: NSRect(
                x: (9 - 2.6) * s, y: (9 - 2.6) * s,
                width: 5.2 * s, height: 5.2 * s
            ))
            dot.fill()
            return true
        }
        img.isTemplate = false  // Coral dot must keep its color across appearances.
        img.accessibilityDescription = "MeetingPipe - Recording"
        return img
    }

    /// Rebuild the menu against the last-rendered state, so a permission flip
    /// shows/hides the warning row without a state transition.
    func refreshMenuForPermissionChange() {
        rebuildMenu(state: lastMenuState)
    }

    /// "Any required permission missing" for the warning row. Screen
    /// Recording's transient `.unknown` is excluded so it doesn't flash at
    /// every cold launch.
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
        menu.delegate = menuDelegate
        populateMenu(menu, state: state)
        item.menu = menu
    }

    /// Re-probe permissions then repopulate in place (via
    /// `menuNeedsUpdate`), so opening the menu reflects a just-made grant.
    fileprivate func refreshMenuBeforeDisplay(_ menu: NSMenu) {
        PermissionsCenter.shared.refreshMenuRelevantSync()
        populateMenu(menu, state: lastMenuState)
    }

    /// Build the menu items into `menu`, replacing existing ones.
    private func populateMenu(_ menu: NSMenu, state: AppState) {
        menu.removeAllItems()

        let header = NSMenuItem(title: stateLabel(state), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if let downloadRow = modelDownloadMenuRow {
            menu.addItem(downloadRow)
            menu.addItem(.separator())
        }

        // One warning row when any of mic/screen-recording/accessibility is
        // ungranted, routing to the Permissions tab (TECH-E3); the
        // Screen-Recording shortcut stays for that specific case.
        if hasPendingPermissionIssue() {
            let warn = NSMenuItem(
                title: "⚠ Permissions need attention - Open Preferences…",
                action: #selector(Coordinator.menuPreferencesPermissions),
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

        // Failed-pipeline row, backed by the durable error sidecar, so a
        // notification missed under Focus isn't the only surface. Stays
        // until retry or delete.
        if let coordinator = coordinator {
            let failedCount = coordinator.failedMeetingCount()
            if failedCount > 0 {
                let noun = failedCount == 1 ? "meeting" : "meetings"
                let failedRow = NSMenuItem(
                    title: "⚠ \(failedCount) \(noun) failed - open Library to retry",
                    action: #selector(Coordinator.menuOpenLibrary),
                    keyEquivalent: ""
                )
                failedRow.target = coordinator
                menu.addItem(failedRow)
                menu.addItem(.separator())
            }
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

        let quickFind = NSMenuItem(
            title: "Quick Find…",
            action: #selector(Coordinator.menuQuickFind),
            keyEquivalent: "f"
        )
        quickFind.keyEquivalentModifierMask = [.command, .shift]
        quickFind.target = coordinator
        menu.addItem(quickFind)

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
        // TECH-UX7: when auto-restart is on (the default), offer a one-off quit
        // that does not relaunch. Hidden when the user already disabled
        // auto-restart, since the plain Quit above already means quit.
        if !UISettings.shared.disableAutoRestart, let coordinator = coordinator {
            let quitNoRelaunch = NSMenuItem(
                title: "Quit (do not relaunch)",
                action: #selector(Coordinator.menuQuitWithoutRelaunch),
                keyEquivalent: "q"
            )
            quitNoRelaunch.keyEquivalentModifierMask = [.command, .option]
            quitNoRelaunch.target = coordinator
            menu.addItem(quitNoRelaunch)
        }
    }

    /// "Recent meetings" submenu, populated lazily via `menuNeedsUpdate` so
    /// the dir scan is paid on open, not on every state change. Nil only
    /// without a Coordinator; the empty case renders a disabled row.
    private func recentMeetingsMenuItem(coordinator: Coordinator) -> NSMenuItem? {
        let parent = NSMenuItem(title: "Recent meetings…", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let delegate = recentMeetingsDelegate ?? RecentMeetingsMenuDelegate(coordinator: coordinator)
        delegate.coordinator = coordinator
        submenu.delegate = delegate
        recentMeetingsDelegate = delegate
        // A child so the submenu isn't empty before `menuNeedsUpdate` fires.
        let placeholder = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        submenu.addItem(placeholder)
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

    /// Drop the `org/` prefix so the menu row stays readable; the full id is
    /// in Preferences -> Pipeline.
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

/// Top-level menu delegate; `menuNeedsUpdate` re-probes permissions just
/// before display so the warning row is never stale (the 2 s poll only runs
/// while Preferences is open).
private final class StatusMenuDelegate: NSObject, NSMenuDelegate {
    weak var controller: StatusBarController?

    func menuNeedsUpdate(_ menu: NSMenu) {
        controller?.refreshMenuBeforeDisplay(menu)
    }
}

/// Populates the "Recent meetings" submenu on open (re-scans the dir, paid
/// per click not per rebuild). Rebuilt in place so stale items don't linger.
private final class RecentMeetingsMenuDelegate: NSObject, NSMenuDelegate {
    weak var coordinator: Coordinator?

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let coordinator = coordinator else {
            let row = NSMenuItem(title: "Coordinator unavailable", action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
            return
        }
        let entries = coordinator.recentCorrectableMeetings(limit: 10)
        if entries.isEmpty {
            let row = NSMenuItem(title: "No recent meetings", action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
            return
        }
        for entry in entries {
            let item = NSMenuItem(
                title: entry.displayName,
                action: #selector(Coordinator.menuRecentMeeting(_:)),
                keyEquivalent: ""
            )
            item.target = coordinator
            item.representedObject = entry.stem
            menu.addItem(item)
        }
    }
}
