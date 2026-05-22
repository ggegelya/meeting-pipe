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

    private var idleIcon: NSImage = StatusBarController.makeIdleIcon(
        size: StatusBarController.iconSize,
        style: UISettings.shared.menuBarIconStyle
    )
    private var recordingIcon: NSImage = StatusBarController.makeRecordingIcon(size: StatusBarController.iconSize)

    /// Live regulated-mode flag for the lock-glyph badge. Driven by
    /// `Coordinator` whenever `ConfigStore` changes (or at startup).
    /// Pair this with `UISettings.shared.showRegulatedBadge` — both
    /// must be true for the glyph to appear.
    private var regulatedMode: Bool = false

    /// Combine subscriptions for live UI-setting changes (icon style +
    /// regulated badge toggle). Held so the menu bar updates without
    /// the user re-opening the menu.
    private var iconStyleCancellable: AnyCancellable?
    private var regulatedBadgeCancellable: AnyCancellable?

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

    /// Retained NSMenuDelegate for the "Recent meetings…" submenu. The
    /// submenu populates on `menuNeedsUpdate(_:)` rather than on every
    /// `rebuildMenu` so a stop click / state change doesn't pay a
    /// synchronous directory scan + per-entry mtime read for a submenu
    /// the user almost never opens.
    private var recentMeetingsDelegate: RecentMeetingsMenuDelegate?

    /// Delegate for the top-level status menu. Its `menuNeedsUpdate`
    /// re-probes the permission state just before the menu is shown,
    /// so the warning row reflects a permission the user just granted
    /// in System Settings without their having to open Preferences.
    private let menuDelegate = StatusMenuDelegate()

    /// Re-render the menu whenever any permission flips so the
    /// aggregate warning row appears / disappears without waiting for
    /// the next recording state change. Subscribed once at init.
    private var permissionsCancellable: AnyCancellable?

    /// Snapshot of every permission status, used by the combined
    /// publisher so we can `removeDuplicates` on the *actual* values
    /// rather than rebuilding the menu on every `objectWillChange`
    /// (which fires per-property and at 2s poll cadence). Equatable for
    /// the dedupe.
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
        // Subscribe to a derived stream of permission snapshots,
        // collapsed via `removeDuplicates` so the menu only rebuilds on
        // a real value change. The previous wiring subscribed to
        // `objectWillChange`, which fires per-property — and the
        // 2-second permissions polling timer in `PermissionsCenter`
        // emits 4+ commits per tick (one per @Published). That meant
        // the NSMenu was being rebuilt roughly twice a second whenever
        // the Permissions tab was open, even when nothing changed.
        permissionsCancellable = Publishers.CombineLatest4(
            center.$microphone,
            center.$screenRecording,
            center.$accessibility,
            center.$notifications
        )
        .map(PermissionsSnapshot.init(microphone:screenRecording:accessibility:notifications:))
        .removeDuplicates()
        .dropFirst()   // skip the initial snapshot — menu is built lazily on first state setter
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.refreshMenuForPermissionChange() }

        // Live icon-style swap: when the user flips Outline ↔ Filled in
        // Preferences, rebuild the cached idle icon and reflect it on
        // the button. The recording icon variant is style-independent
        // (it always pairs ring + coral dot) and stays as-is.
        iconStyleCancellable = UISettings.shared.$menuBarIconStyle
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] style in
                guard let self = self else { return }
                self.idleIcon = Self.makeIdleIcon(size: Self.iconSize, style: style)
                if !self.isShowingRecordingIcon { self.item.button?.image = self.idleIcon }
            }

        // The regulated-badge toggle is purely visual — recompute the
        // title suffix whenever it flips so the lock glyph appears /
        // disappears immediately without the user clicking around.
        regulatedBadgeCancellable = UISettings.shared.$showRegulatedBadge
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyTitle() }

        menuDelegate.controller = self
    }

    /// True when the recording icon (coral dot) is currently shown on
    /// the menu-bar button. Used by the icon-style live-swap so we don't
    /// stomp a recording icon back to the idle variant mid-session.
    private var isShowingRecordingIcon: Bool {
        item.button?.image === recordingIcon
    }

    /// Reflect a global `regulatedMode` change. Called by the
    /// Coordinator on startup and whenever the persisted config flips.
    /// The actual glyph rendering happens in `applyTitle()` so it
    /// stays in sync with whatever base title the current state holds.
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
    ///
    /// Writes into `LibraryWindowModel.processing` (a sibling
    /// `ObservableObject`) rather than a `@Published` on the parent
    /// model so the rail / list / detail don't re-render every tick.
    /// Only the toolbar observes `processing`.
    func setProcessingCount(_ n: Int) {
        processingCount = n
        applyTitle()
        rebuildMenu(state: lastMenuState)
        libraryModel?.processing.count = n
    }

    /// Reflect the model-prefetch lifecycle in the menu bar. The download
    /// is asynchronous; the user is otherwise blind to it because it
    /// happens inside a Python subprocess called from the Coordinator.
    /// Driven by `Coordinator.modelDownload.onStateChange`.
    ///
    /// Note: this used to also write into a `@Published modelDownload`
    /// on `LibraryWindowModel`, but nothing in the Library window
    /// renders it any more (the rail's old footer was the only reader
    /// and it was dropped in the IA re-architecture). Keeping the
    /// state on this controller alone removes a major source of
    /// re-renders during heavy model fetches.
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
        menu.delegate = menuDelegate
        populateMenu(menu, state: state)
        item.menu = menu
    }

    /// Re-probe the permissions the warning row depends on, then
    /// repopulate `menu` in place. Wired through
    /// `StatusMenuDelegate.menuNeedsUpdate` so opening the menu always
    /// reflects the current TCC verdict: a grant the user just made in
    /// System Settings clears the warning without their opening
    /// Preferences.
    fileprivate func refreshMenuBeforeDisplay(_ menu: NSMenu) {
        PermissionsCenter.shared.refreshMenuRelevantSync()
        populateMenu(menu, state: lastMenuState)
    }

    /// Build the status menu's items into `menu`, replacing whatever
    /// was there. Shared by `rebuildMenu` and `refreshMenuBeforeDisplay`.
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

        // Aggregate permission warning. Any of mic / screen recording /
        // accessibility being non-granted surfaces a single row that
        // routes to the new Permissions tab in Preferences (TECH-E3).
        // The legacy Screen-Recording-only row is preserved as a
        // shortcut to Settings when that's the specific problem.
        if hasPendingPermissionIssue() {
            let warn = NSMenuItem(
                title: "⚠ Permissions need attention — Open Preferences…",
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
    }

    /// "Recent meetings…" submenu placeholder. The submenu populates
    /// lazily via `NSMenuDelegate.menuNeedsUpdate(_:)` so opening the
    /// menu bar pays the directory scan once, not on every state change.
    /// Returns nil only when there's no Coordinator to reach into; the
    /// "no recent meetings" empty-list case is rendered as a single
    /// disabled row inside the submenu so users get an obvious answer
    /// when they open it.
    private func recentMeetingsMenuItem(coordinator: Coordinator) -> NSMenuItem? {
        let parent = NSMenuItem(title: "Recent meetings…", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let delegate = recentMeetingsDelegate ?? RecentMeetingsMenuDelegate(coordinator: coordinator)
        delegate.coordinator = coordinator
        submenu.delegate = delegate
        recentMeetingsDelegate = delegate
        // Placeholder so the submenu has at least one child while
        // unopened. macOS only triggers `menuNeedsUpdate` on submenus
        // that are about to display; we replace this row at that point.
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

/// Delegate for the top-level status-bar menu. `menuNeedsUpdate`
/// fires immediately before the menu is displayed; we use it to
/// re-probe the permission state so the warning row is never stale.
/// The 2 s `PermissionsCenter` poll, the only other refresh path,
/// runs solely while the Preferences window is open.
private final class StatusMenuDelegate: NSObject, NSMenuDelegate {
    weak var controller: StatusBarController?

    func menuNeedsUpdate(_ menu: NSMenu) {
        controller?.refreshMenuBeforeDisplay(menu)
    }
}

/// Populates the "Recent meetings…" submenu only when the user is about
/// to open it. Each open re-scans the recordings dir for fresh state;
/// the cost is paid once per click instead of on every menu rebuild.
///
/// `coordinator` is held weakly so the controller's lifetime owns the
/// delegate cleanly. The submenu is rebuilt in place (clear + add) so
/// stale items from a prior open never linger.
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
