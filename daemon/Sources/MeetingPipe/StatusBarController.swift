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

    private let idleIcon: NSImage = StatusBarController.makeIdleIcon(size: StatusBarController.iconSize)
    private let recordingIcon: NSImage = StatusBarController.makeRecordingIcon(size: StatusBarController.iconSize)

    /// Regulated-mode flag for the lock-glyph badge (driven by Coordinator). It used
    /// to need `UISettings.shared.showRegulatedBadge` too; DSN1 cut that control and
    /// ARCH6 removed the property, so this is the whole condition now.
    private var regulatedMode: Bool = false

    /// Last state a menu was built for, so a permission-driven rebuild
    /// doesn't need the caller to re-supply it.
    private var lastMenuState: AppState = .idle

    /// The state the title and the icon are showing. Deliberately NOT `lastMenuState`:
    /// `setStopping` rebuilds the menu as `.idle` (which is what ships, header and Start
    /// row included), while the title has always read "Stopping…" through the flush.
    /// Collapsing the two would change what the menu says mid-stop, so they stay apart
    /// and the difference is stated here rather than left to be rediscovered.
    private var titleState: AppState = .idle

    /// The workflow whose clause the recording title carries (TECH-B5). Only read while
    /// `titleState` is `.recording`, and `setRecording` always writes it on the way in,
    /// so a stale value from the last meeting can never surface.
    private var recordingWorkflow: Workflow?

    /// Pipeline jobs queued or running; shown as a title badge.
    private var processingCount: Int = 0

    /// Last model-download state. Shown as a title prefix + a menu header
    /// row; `completed` collapses to idle after `completedDisplayDuration`
    /// so a stale "Downloaded X" line doesn't linger.
    private var modelDownload: ModelDownloadSupervisor.State = .idle
    private var modelDownloadCompletedDisplayTimer: Timer?
    private static let completedDisplayDuration: TimeInterval = 5

    /// Drives the UX10 "Suppressed (<app>)" title. The recording-side state machine
    /// stays `.idle` after a timeout-skip (START1), so this is a presentation-only
    /// label that lives as long as the bundle's skip latch holds. `suppressedIsActive`
    /// reads that latch (the single source of truth); the timer re-checks it and
    /// collapses to Idle once it lapses, which is a full `skipLatchGraceSec` after discovery last
    /// saw the meeting and not "shortly after it ends" (DET9).
    private var suppressedDisplayTimer: Timer?
    private var suppressedIsActive: (() -> Bool)?
    private static let suppressedRecheckInterval: TimeInterval = 5

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

    /// UX55: whether the `com.meetingpipe.daemon` agent is enabled, which is what
    /// decides whether a plain Quit can be undone by a relaunch at all. Cached
    /// rather than read where it is used, because reading it shells out to
    /// `launchctl`: `populateMenu` also runs on every model-download progress tick
    /// and every processing-count change, so an inline read would be a subprocess
    /// per tick on the main queue. `refreshMenuBeforeDisplay` re-reads it, and
    /// AppKit calls that before every display of this menu, so what the user is
    /// looking at is never stale. Optimistic until that first read, which is the
    /// pre-UX55 behaviour and only ever visible in a menu nobody has opened.
    private var launchAgentEnabled: Bool = true
    private let launchAtLogin = LaunchAtLoginService()

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

        menuDelegate.controller = self
    }

    /// Reflect a `regulatedMode` change; the glyph renders in `applyTitle()`.
    func setRegulatedMode(_ on: Bool) {
        regulatedMode = on
        applyTitle()
    }

    func setIdle() {
        cancelSuppressedDisplay()
        titleState = .idle
        applyIcon()
        applyTitle()
        rebuildMenu(state: .idle)
        libraryModel?.status = .idle
        libraryModel?.liveRecordingStem = nil
    }

    func setPrompting(_ source: AppSource) {
        cancelSuppressedDisplay()
        titleState = .prompting(source: source)
        applyIcon()
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
        cancelSuppressedDisplay()
        recordingWorkflow = workflow
        titleState = .recording(file: file, source: source, summaryMode: summaryMode)
        applyIcon()
        applyTitle()
        rebuildMenu(state: .recording(file: file, source: source, summaryMode: summaryMode))
        libraryModel?.status = .recording(appName: source?.displayName)
        libraryModel?.liveRecordingStem = file.deletingPathExtension().lastPathComponent
    }

    func setStopping(file: URL, source: AppSource?, summaryMode: SummaryMode) {
        cancelSuppressedDisplay()
        titleState = .stopping(file: file, source: source, summaryMode: summaryMode)
        applyIcon()
        applyTitle()
        // Deliberately `.idle`, not `titleState`: the menu built during a flush is the
        // idle one (its header and its Start row), which is what has always shipped.
        rebuildMenu(state: .idle)
        libraryModel?.status = .stopping
        // Keep liveRecordingStem until setIdle fires so the row's pulse
        // stays visible through the flush.
    }

    /// Surface a silent timeout-skip in the menu bar (UX10 / AUD-12): show
    /// "Suppressed (<app>)" while the skip latch holds. `isStillSuppressed` reads
    /// that latch; we re-check on a low-frequency timer and collapse to Idle once
    /// it lapses, a full `DetectionStateMachine.skipLatchGraceSec` after discovery last saw the
    /// meeting. That grace is what keeps this label up across a mid-call stretch of scans that
    /// find no confident winner (DET9); losing it there destroyed DET7's attach affordance while
    /// the call was still running, which is the whole point of the label. Presentation-only: the state machine
    /// stays `.idle` (re-entering the old global `.suppressed` is the START1 wedge),
    /// so detection keeps running for other apps the whole time.
    func setSuppressed(_ source: AppSource, isStillSuppressed: @escaping () -> Bool) {
        cancelSuppressedDisplay()
        suppressedIsActive = isStillSuppressed
        titleState = .suppressed(source: source)
        applyIcon()
        applyTitle()
        rebuildMenu(state: .suppressed(source: source))
        libraryModel?.status = .idle
        scheduleSuppressedRecheck()
    }

    private func scheduleSuppressedRecheck() {
        suppressedDisplayTimer = Timer.scheduledTimer(
            withTimeInterval: Self.suppressedRecheckInterval, repeats: false
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.suppressedIsActive?() == true {
                self.scheduleSuppressedRecheck()
            } else {
                self.setIdle()
            }
        }
    }

    private func cancelSuppressedDisplay() {
        suppressedDisplayTimer?.invalidate()
        suppressedDisplayTimer = nil
        suppressedIsActive = nil
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

    /// The title is `StatusBarModel.title`'s decision; this only sources its inputs
    /// (ARCH6). It used to be a second, independent copy of that function, which is
    /// how the tested model and the always-visible surface were free to drift: the two
    /// agreed string-for-string when they were finally compared, but nothing had ever
    /// required them to.
    private func applyTitle() {
        item.button?.title = StatusBarModel.title(titleInputs)
    }

    /// Which icon the button wears is `StatusBarModel.icon`'s decision, for the same
    /// reason (ARCH6). Every state setter calls this after writing `titleState`.
    private func applyIcon() {
        item.button?.image = StatusBarModel.icon(for: titleState) == .recording ? recordingIcon : idleIcon
    }

    /// The title's half of the model's inputs. `summaryMode` is read back off
    /// `titleState`, which already carries it, rather than mirrored into a field that
    /// could drift from it; the rest of `Inputs` decides rows and is left at defaults.
    private var titleInputs: StatusBarModel.Inputs {
        var summaryMode: SummaryMode = .auto
        if case .recording(_, _, let mode) = titleState { summaryMode = mode }
        return StatusBarModel.Inputs(
            state: titleState,
            workflowName: recordingWorkflow?.name,
            ndaMode: recordingWorkflow?.flags.ndaMode ?? false,
            summaryMode: summaryMode,
            processingCount: processingCount,
            regulatedMode: regulatedMode,
            download: modelDownload
        )
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

    /// One glyph, the outline one. There used to be a `filled` variant selected by
    /// `UISettings.menuBarIconStyle`; DSN1's IA pass cut the control that chose it and
    /// left the property with no writer, so the branches below rendered only ever one
    /// way and ARCH6 folded them out (`daemon/docs/gotchas.md`).
    private static func makeIdleIcon(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width / 18.0  // SVG viewBox is 18×18

            // The chrome ring around the bars.
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

            // Non-template image (coral dot), so AppKit won't auto-tint the
            // ring: a fixed mid-tone (ink600) that reads on light and dark menu
            // bars. The coral dot is the actual recording signal; the ring is
            // chrome.
            MPColors.ink600.setStroke()
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

    /// Small coral status dot for the "Stop Recording" menu row (the locked
    /// dropdown's `--mp-pulse-600` bullet, DSN20). Non-template so it stays
    /// coral over the menu's selection highlight rather than tinting to the
    /// accent colour, mirroring the recording icon's dot.
    private static func makeStopDotImage() -> NSImage {
        let side: CGFloat = 12
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            MPColors.pulse600.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Rebuild the menu against the last-rendered state, so a permission flip
    /// shows/hides the warning row without a state transition.
    func refreshMenuForPermissionChange() {
        rebuildMenu(state: lastMenuState)
    }

    /// Everything `StatusBarModel` needs to decide the menu, sourced from the live
    /// singletons and the Coordinator (ARCH6). The three helpers that used to build a
    /// partial `Inputs` each (`permissionConsequences`, `offersQuitWithoutRelaunch`,
    /// and a `hasPendingPermissionIssue` with no caller at all) collapse into this one:
    /// every row now comes out of a single `rows(_:)` call over a single snapshot.
    ///
    /// `state` is a parameter rather than a read of `lastMenuState` because
    /// `setStopping` passes `.idle` here on purpose while the title says "Stopping…".
    private func menuInputs(state: AppState, finishSetupTitle: String?) -> StatusBarModel.Inputs {
        let center = PermissionsCenter.shared
        return StatusBarModel.Inputs(
            state: state,
            processingCount: processingCount,
            regulatedMode: regulatedMode,
            download: modelDownload,
            microphone: center.microphone,
            screenRecording: center.screenRecording,
            accessibility: center.accessibility,
            screenRecordingCaptureDenied: SystemAudioCapture.permissionState == .denied,
            failedMeetingCount: coordinator?.failedMeetingCount() ?? 0,
            finishSetupTitle: finishSetupTitle,
            disableAutoRestart: UISettings.shared.disableAutoRestart,
            launchAgentEnabled: launchAgentEnabled,
            suppressedCandidateAppName: coordinator?.stateMachine.liveSuppressedCandidate()?.displayName
        )
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
    ///
    /// UX55 re-reads the launch agent here for the same reason: Preferences ▸ General
    /// ▸ Launch at login can flip between two opens, and so can a `launchctl` in a
    /// terminal or an `install.sh` run, so the quit rows are decided against launchd
    /// as the user looks at them rather than against a value cached at launch.
    fileprivate func refreshMenuBeforeDisplay(_ menu: NSMenu) {
        PermissionsCenter.shared.refreshMenuRelevantSync()
        launchAgentEnabled = launchAtLogin.status().isOn
        populateMenu(menu, state: lastMenuState)
    }

    /// Build the menu items into `menu`, replacing existing ones.
    ///
    /// Which conditional rows exist, and in what order, is `StatusBarModel.rows`'
    /// decision (ARCH6); this walks that list and builds an `NSMenuItem` per row. The
    /// hand-written conditional cascade this replaces was a second copy of the same
    /// decisions, and it had already outgrown the model over the "Finish setup" row.
    /// The unconditional rows below (Open Library through Quit) stay spelled out here:
    /// they are not a decision, so modelling them would only duplicate this file.
    private func populateMenu(_ menu: NSMenu, state: AppState) {
        menu.removeAllItems()

        // Decided once and passed down: `setupChecklistInputs()` reads config, secrets
        // and the model cache, and this runs on every download tick and processing-count
        // change, so the title and the submenu share one evaluation.
        let setupItems = finishSetupItems()
        let inputs = menuInputs(
            state: state,
            finishSetupTitle: SetupChecklist.menuTitle(count: setupItems.count)
        )
        let rows = StatusBarModel.rows(inputs)

        let header = NSMenuItem(title: StatusBarModel.headerLabel(inputs), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // `quitWithoutRelaunch` is the one modelled row that sits BELOW the fixed tail,
        // beside the plain Quit it qualifies, so it is added at the bottom instead.
        addConditionalRows(rows.filter { $0 != .quitWithoutRelaunch }, to: menu, setupItems: setupItems)

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
            keyEquivalent: "k"
        )
        quickFind.keyEquivalentModifierMask = [.command]
        quickFind.target = coordinator
        menu.addItem(quickFind)

        // TECH-WF5: top-level entry for workflow management; previously reachable
        // only by selecting a Library rail scope and clicking the pencil.
        let manageWorkflows = NSMenuItem(
            title: "Manage Workflows…",
            action: #selector(Coordinator.menuManageWorkflows),
            keyEquivalent: ""
        )
        manageWorkflows.target = coordinator
        menu.addItem(manageWorkflows)

        if let coordinator = coordinator,
           let recentItem = recentMeetingsMenuItem(coordinator: coordinator) {
            menu.addItem(recentItem)
        }

        let openLogs = NSMenuItem(title: "Open Logs Folder", action: #selector(Coordinator.menuOpenLogs), keyEquivalent: "")
        openLogs.target = coordinator
        menu.addItem(openLogs)

        let openDiagnostics = NSMenuItem(title: "Diagnostics…", action: #selector(Coordinator.menuOpenDiagnostics), keyEquivalent: "")
        openDiagnostics.target = coordinator
        menu.addItem(openDiagnostics)

        // DOC11: the in-app user guide. Unconditional, so it is not in
        // `StatusBarModel.Row`; it sits beside Diagnostics because both are
        // "explain what is going on" rather than "do something".
        let openGuide = NSMenuItem(title: "Guide…", action: #selector(Coordinator.menuOpenGuide), keyEquivalent: "")
        openGuide.target = coordinator
        menu.addItem(openGuide)

        // FEAT15: the guided tour, next to the guide it complements. Also
        // unconditional, and also not in `StatusBarModel.Row`. A menu item is the
        // whole surface area of the reversal: the tour runs when someone asks for
        // it and never on launch, which is what separates it from the first-run
        // machinery the root `CLAUDE.md` still defers.
        let openTutorial = NSMenuItem(title: "Tutorial…", action: #selector(Coordinator.menuOpenTutorial), keyEquivalent: "")
        openTutorial.target = coordinator
        menu.addItem(openTutorial)

        let openRecordings = NSMenuItem(title: "Open Recordings Folder", action: #selector(Coordinator.menuOpenRecordings), keyEquivalent: "")
        openRecordings.target = coordinator
        menu.addItem(openRecordings)

        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(Coordinator.menuPreferences), keyEquivalent: ",")
        prefs.target = coordinator
        menu.addItem(prefs)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MeetingPipe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // TECH-UX7 / UX55: the one-off quit that does not relaunch, offered only while
        // something could actually relaunch us. `StatusBarModel` owns that rule, so the
        // shipped menu and the tested model cannot disagree about it again.
        if rows.contains(.quitWithoutRelaunch), let coordinator = coordinator {
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

    // MARK: - Conditional rows (the model's list, this file's NSMenuItems)

    /// Where the dividers fall between the model's rows. Grouping is chrome, so it
    /// stays on this side; `StatusBarModel.rows` decides presence and order.
    private enum RowGroup {
        case download
        case permissions
        case accessibility
        case failedMeetings
        case finishSetup
        case transport
        /// Added below the fixed tail by `populateMenu`, so it never reaches the walk.
        case quit

        /// Every group but the transport rows closes with a divider. The transport
        /// group is followed by the unconditional divider above Open Library, which is
        /// why `.stopping` (no transport row at all) renders two in a row, as it always
        /// has.
        var closesWithSeparator: Bool {
            switch self {
            case .download, .permissions, .accessibility, .failedMeetings, .finishSetup:
                return true
            case .transport, .quit:
                return false
            }
        }
    }

    private static func group(for row: StatusBarModel.Row) -> RowGroup {
        switch row {
        case .modelDownload:                             return .download
        case .permissionConsequence, .screenRecordingShortcut: return .permissions
        case .accessibilityDegraded:                     return .accessibility
        case .failedMeetings:                            return .failedMeetings
        case .finishSetup:                               return .finishSetup
        case .startRecording, .recordSuppressedMeeting, .stopRecording: return .transport
        case .quitWithoutRelaunch:                       return .quit
        }
    }

    /// Walk the model's rows in order, building each one's `NSMenuItem`(s) and closing
    /// each group with its divider.
    private func addConditionalRows(
        _ rows: [StatusBarModel.Row],
        to menu: NSMenu,
        setupItems: [SetupChecklist.Item]
    ) {
        var index = rows.startIndex
        while index < rows.endIndex {
            let group = Self.group(for: rows[index])
            var end = index
            while end < rows.endIndex, Self.group(for: rows[end]) == group {
                addRow(rows[end], to: menu, setupItems: setupItems)
                end += 1
            }
            if group.closesWithSeparator { menu.addItem(.separator()) }
            index = end
        }
    }

    private func addRow(_ row: StatusBarModel.Row, to menu: NSMenu, setupItems: [SetupChecklist.Item]) {
        switch row {
        case .modelDownload(let title, let retryable, let toolTip):
            menu.addItem(modelDownloadMenuItem(title: title, retryable: retryable, toolTip: toolTip))

        // One row per missing permission, each naming what stops working (UX23),
        // routing to the Permissions tab (TECH-E3).
        case .permissionConsequence(let title):
            menu.addItem(actionRow(title: title, action: #selector(Coordinator.menuPreferencesPermissions)))

        case .screenRecordingShortcut:
            menu.addItem(actionRow(
                title: "Open Screen Recording Settings…",
                action: #selector(Coordinator.menuOpenScreenRecordingSettings)
            ))

        // TECH-END4 (c): Accessibility is what lets the app read a meeting app's
        // windows and controls at all, so denying it costs the whole detection path,
        // start included (DET11), and the user otherwise has no signal. Called out
        // specifically beyond the generic permission rows above. The PermissionsSnapshot
        // sink rebuilds this menu when AX flips, so the row appears/clears on its own
        // (the audit showed AX is usually a transient launch race that recovers, so
        // there is deliberately no title glyph).
        case .accessibilityDegraded:
            menu.addItem(actionRow(
                title: StatusBarModel.accessibilityOffTitle,
                action: #selector(Coordinator.menuPreferencesPermissions)
            ))

        // Failed-pipeline row, backed by the durable error sidecar, so a notification
        // missed under Focus isn't the only surface. Stays until retry or delete.
        case .failedMeetings(_, let title):
            menu.addItem(actionRow(title: title, action: #selector(Coordinator.menuOpenLibrary)))

        case .finishSetup(let title):
            menu.addItem(finishSetupMenuItem(title: title, items: setupItems))

        // `.suppressed` is the skip-latch display over an idle state machine (see
        // `setSuppressed`), so a manual start still works and the model keeps offering
        // it; dropping it left a skipped meeting with no menu route to record for the
        // rest of the call. DET7: with a live candidate the same row names what a click
        // will attach to. The candidate is read per `menuNeedsUpdate` rather than cached
        // (the menu is repopulated in place on open), so the row is right at the instant
        // it is looked at and nothing rebuilds on the discovery cadence.
        case .startRecording:
            menu.addItem(actionRow(
                title: StatusBarModel.startRecordingTitle(suppressedCandidateAppName: nil),
                action: #selector(Coordinator.menuStart)
            ))

        case .recordSuppressedMeeting(_, let title):
            menu.addItem(actionRow(title: title, action: #selector(Coordinator.menuStart)))

        case .stopRecording(let stem):
            let stop = actionRow(title: "Stop Recording", action: #selector(Coordinator.menuStop))
            stop.image = Self.makeStopDotImage()   // coral status dot (DSN20)
            menu.addItem(stop)
            menu.addItem(Self.recordingFileRow(stem: stem))

        case .quitWithoutRelaunch:
            break   // added below the fixed tail by `populateMenu`
        }
    }

    /// An enabled row aimed at the Coordinator. A nil coordinator leaves `target` nil,
    /// which is what every hand-built row here already did.
    private func actionRow(title: String, action: Selector) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
        row.target = coordinator
        return row
    }

    /// DSN21: the live recording file, mono tabular numerals like every other
    /// capture-surface timecode. Disabled/informational.
    private static func recordingFileRow(stem: String) -> NSMenuItem {
        let row = NSMenuItem(title: stem, action: nil, keyEquivalent: "")
        row.isEnabled = false
        row.attributedTitle = NSAttributedString(string: stem, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: MPColors.fgSubtle,
        ])
        return row
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

    /// Detailed model-download row. Disabled (informational) unless retryable.
    private func modelDownloadMenuItem(title: String, retryable: Bool, toolTip: String?) -> NSMenuItem {
        guard retryable else {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
        // Actionable (LOCAL1): clicking re-spawns the prefetch. The full error
        // goes to the tooltip so the row title stays short and clean.
        let item = actionRow(title: title, action: #selector(Coordinator.menuRetryModelDownload))
        item.toolTip = toolTip
        return item
    }

    /// The still-unmet setup items (UX22), or empty when every one is green. Empty
    /// without a Coordinator too, since the signals are all read through it.
    private func finishSetupItems() -> [SetupChecklist.Item] {
        guard let coordinator = coordinator else { return [] }
        var inputs = coordinator.setupChecklistInputs()
        // The dedicated download row already covers an in-flight / just-finished
        // pull, so don't also nag to start the model download from here.
        switch modelDownload {
        case .downloading, .completed: inputs.localModelMissing = false
        default: break
        }
        return SetupChecklist.decide(inputs)
    }

    /// The "Finish setup" checklist parent row + submenu (UX22). Each submenu row
    /// deep-links to its fix. Whether the row exists at all is the model's call, off
    /// the title this was given.
    private func finishSetupMenuItem(title: String, items: [SetupChecklist.Item]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for item in items {
            submenu.addItem(actionRow(title: item.title, action: Self.selector(for: item.fix)))
        }
        parent.submenu = submenu
        return parent
    }

    /// Map a checklist fix to the Coordinator selector that resolves it.
    private static func selector(for fix: SetupChecklist.Fix) -> Selector {
        switch fix {
        case .permissions:   return #selector(Coordinator.menuPreferencesPermissions)
        case .integrations:  return #selector(Coordinator.menuPreferencesIntegrations)
        case .downloadModel: return #selector(Coordinator.menuFinishSetupDownloadModel)
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
