import Foundation

/// The pure presentation derivation behind `StatusBarController` (T3).
///
/// The controller is 731 lines of `NSStatusItem`, `NSMenu`, `#selector` targets,
/// timers, and two singletons, and it is the always-visible surface, so every
/// branch in it is one the user sees. None of it was testable, because the
/// decisions were interleaved with the AppKit construction that carries them.
/// This type takes that decision out: given a snapshot of the inputs, what does
/// the menu bar say, which icon does it wear, and which conditional rows exist
/// in which order. The controller keeps the `NSMenuItem` building, which is
/// plumbing, and asks this for everything that varies.
///
/// T3 wrote this type and its tests, and then left `title`, `icon(for:)` and
/// `rows` with no production caller: the controller went on composing its own
/// title, picking its own icon and hand-ordering its own rows, so the two copies
/// were free to diverge and had already, over the `finishSetup` row this enum
/// carried no case for (ARCH6). Every decision here is now the one the menu bar
/// renders, which is what makes a row the tests below do not know about a row the
/// user does not see either.
///
/// The `MicGate.decide` / `AudioRetention.decide` idiom: explicit inputs in, a
/// value out, no globals read from inside.
enum StatusBarModel {

    enum Icon: Equatable {
        case idle
        case recording
    }

    /// The conditional menu rows, in the order they are added. Unconditional
    /// rows (Open Library, Preferences, Quit, ...) are not modelled: they are
    /// not a decision, and listing them here would just duplicate `populateMenu`.
    enum Row: Equatable {
        /// Informational unless `retryable`, which is the LOCAL1 retry affordance. `dismissible`
        /// (LOCAL20) adds the exit that is not Retry: clearing a failure used to mean
        /// re-downloading the model you had just moved away from.
        case modelDownload(title: String, retryable: Bool, toolTip: String?, dismissible: Bool)
        /// One row per missing permission, naming what stops working (UX23):
        /// "Microphone off: recordings will be silent", etc. Replaces the old
        /// single vague "Permissions need attention" row.
        case permissionConsequence(title: String)
        /// The Screen Recording deep link, only alongside a screen-recording
        /// `permissionConsequence`.
        case screenRecordingShortcut
        case accessibilityDegraded
        case failedMeetings(count: Int, title: String)
        /// UX22: the "Finish setup" checklist parent row, present while anything is
        /// still unmet. What is in the submenu is `SetupChecklist`'s decision, not this
        /// one, so the row carries only the title the caller already computed; what
        /// lives here is that it exists and where it sits. It shipped in the menu from
        /// UX22 and was missing from this enum until ARCH6, which is the divergence
        /// that proved the two row lists were not the same list.
        case finishSetup(title: String)
        case startRecording
        /// DET7: `startRecording` when a meeting the user skipped is still running, so
        /// the row names what a click will attach to. Same action, honest label: the
        /// start paths prefer the cached candidate, so the generic row would have been
        /// lying about what it does.
        case recordSuppressedMeeting(appName: String, title: String)
        case stopRecording(stem: String)
        case quitWithoutRelaunch
    }

    /// Everything the presentation depends on, read once by the caller. The
    /// controller sources these from `PermissionsCenter.shared`,
    /// `UISettings.shared`, and `SystemAudioCapture.permissionState`; keeping
    /// them as parameters is what makes the branches reachable from a test.
    struct Inputs: Equatable {
        var state: AppState
        /// Only meaningful while recording; the workflow clause and the NDA
        /// marker appear in the title and deliberately not in the menu header.
        var workflowName: String?
        var ndaMode: Bool
        var summaryMode: SummaryMode
        var queue: QueueActivity
        var regulatedMode: Bool
        var download: ModelDownloadSupervisor.State
        var microphone: PermissionsCenter.Status
        var screenRecording: PermissionsCenter.Status
        var accessibility: PermissionsCenter.Status
        /// `SystemAudioCapture.permissionState`, which is a separate probe from
        /// `screenRecording` above and drives only the deep-link row.
        var screenRecordingCaptureDenied: Bool
        var failedMeetingCount: Int
        /// UX22: `SetupChecklist.menuTitle` over the still-unmet items, or nil when
        /// every one of them is green and the row disappears entirely.
        var finishSetupTitle: String?
        var disableAutoRestart: Bool
        /// UX55: whether the `com.meetingpipe.daemon` launch agent is enabled, which is
        /// whether anything is left that *could* relaunch the app after a quit
        /// (`LaunchAtLoginService.status().isOn`). A second input to the quit row, not a
        /// second name for the preference above: UX42 made that agent the single owner of
        /// relaunch-after-quit, so the two can disagree.
        var launchAgentEnabled: Bool
        /// DET7: the display name of a skipped-but-still-running meeting's app, from
        /// `DetectionStateMachine.liveSuppressedCandidate`, or nil when there is none.
        /// Deliberately independent of `state`: an explicit Skip leaves the *presentation*
        /// state at `.suppressed` but a timeout-skip that has since lapsed does not, and a
        /// candidate can outlive either, so keying the row off the state would miss the
        /// case the owner actually reported.
        var suppressedCandidateAppName: String?

        init(
            state: AppState = .idle,
            workflowName: String? = nil,
            ndaMode: Bool = false,
            summaryMode: SummaryMode = .auto,
            queue: QueueActivity = .idle,
            regulatedMode: Bool = false,
            download: ModelDownloadSupervisor.State = .idle,
            microphone: PermissionsCenter.Status = .granted,
            screenRecording: PermissionsCenter.Status = .granted,
            accessibility: PermissionsCenter.Status = .granted,
            screenRecordingCaptureDenied: Bool = false,
            failedMeetingCount: Int = 0,
            finishSetupTitle: String? = nil,
            disableAutoRestart: Bool = false,
            launchAgentEnabled: Bool = true,
            suppressedCandidateAppName: String? = nil
        ) {
            self.state = state
            self.workflowName = workflowName
            self.ndaMode = ndaMode
            self.summaryMode = summaryMode
            self.queue = queue
            self.regulatedMode = regulatedMode
            self.download = download
            self.microphone = microphone
            self.screenRecording = screenRecording
            self.accessibility = accessibility
            self.screenRecordingCaptureDenied = screenRecordingCaptureDenied
            self.failedMeetingCount = failedMeetingCount
            self.finishSetupTitle = finishSetupTitle
            self.disableAutoRestart = disableAutoRestart
            self.launchAgentEnabled = launchAgentEnabled
            self.suppressedCandidateAppName = suppressedCandidateAppName
        }
    }

    struct Presentation: Equatable {
        var title: String
        var icon: Icon
        var headerLabel: String
        var rows: [Row]
    }

    static func derive(_ i: Inputs) -> Presentation {
        Presentation(
            title: title(i),
            icon: icon(for: i.state),
            headerLabel: headerLabel(i),
            rows: rows(i)
        )
    }

    // MARK: - Title

    /// One clause, not a pile-up (TECH-DSN7). The base state is the clause; only
    /// while idle does background work take its place, by priority: a model
    /// download (it blocks summaries), then the processing queue. Both also have
    /// their own surfaces, so collapsing the title loses nothing. The regulated
    /// lock is a single trailing glyph, not a clause.
    ///
    /// The glyph used to need `UISettings.showRegulatedBadge` as well. DSN1's IA pass
    /// cut that control and left the property with no writer anywhere in the app, so it
    /// sat pinned at its `true` default and the second half of the `&&` decided nothing;
    /// ARCH6 removed the property and this term together (`daemon/docs/gotchas.md`).
    static func title(_ i: Inputs) -> String {
        let lock = i.regulatedMode ? " \u{1F512}" : ""
        let clause: String
        if i.state == .idle, let download = downloadTitleClause(i.download) {
            clause = download
        } else if i.state == .idle, let queued = QueueActivityPresentation.menuLabel(i.queue) {
            clause = queued
        } else {
            clause = baseTitle(i)
        }
        return " \(clause)\(lock)"
    }

    private static func baseTitle(_ i: Inputs) -> String {
        switch i.state {
        case .idle:
            return "Idle"
        case .prompting(let source):
            return "Detected \(source.displayName)"
        case .suppressed(let source):
            return "Suppressed (\(source.displayName))"
        case .recording:
            // TECH-B5: show the active workflow so the destination is confirmable
            // at a glance; NDA mode gets a marker.
            var label = i.summaryMode == .byo ? "Recording (BYO)" : "Recording"
            if let name = i.workflowName {
                label += " - \(name)\(i.ndaMode ? " · NDA" : "")"
            }
            return label
        case .stopping:
            return "Stopping…"
        }
    }

    /// Compact download clause: percent only (or an ellipsis when total is
    /// unknown, or "failed"); the byte breakdown lives in the menu row.
    static func downloadTitleClause(_ download: ModelDownloadSupervisor.State) -> String? {
        switch download {
        case .idle, .completed:
            return nil
        case .downloading(_, let progress, _, _):
            if let pct = progress { return "↓ \(Int(pct * 100))%" }
            return "↓ …"
        case .failed:
            return "↓ failed"
        }
    }

    // MARK: - Icon

    static func icon(for state: AppState) -> Icon {
        if case .recording = state { return .recording }
        return .idle
    }

    // MARK: - Menu header

    static func headerLabel(_ i: Inputs) -> String {
        let suffix = QueueActivityPresentation.menuLabel(i.queue).map { " · \($0)" } ?? ""
        switch i.state {
        case .idle:                  return "MeetingPipe: Idle\(suffix)"
        case .prompting(let src):    return "MeetingPipe: Detected \(src.displayName)\(suffix)"
        case .suppressed(let src):   return "MeetingPipe: Suppressed (\(src.displayName))\(suffix)"
        case .recording:             return "MeetingPipe: Recording\(suffix)"
        case .stopping:              return "MeetingPipe: Stopping…\(suffix)"
        }
    }

    // MARK: - Rows

    static func rows(_ i: Inputs) -> [Row] {
        var rows: [Row] = []

        if let download = downloadRow(i.download) {
            rows.append(download)
        }

        // One row per missing permission, each naming what stops working (UX23),
        // routing to the Permissions tab (TECH-E3); the Screen Recording deep link
        // stays under the screen-recording consequence.
        for line in permissionConsequences(i) {
            rows.append(.permissionConsequence(title: line))
        }
        if i.screenRecordingCaptureDenied {
            rows.append(.screenRecordingShortcut)
        }

        // TECH-END4 (c): Accessibility is what lets the app read a meeting app at
        // all, so a denial is called out beyond the generic row above. See
        // `accessibilityOffTitle` for what it actually costs (DET11).
        if i.accessibility == .denied {
            rows.append(.accessibilityDegraded)
        }

        if let title = failedMeetingsTitle(count: i.failedMeetingCount) {
            rows.append(.failedMeetings(count: i.failedMeetingCount, title: title))
        }

        // UX22: the "Finish setup" checklist, a quiet holistic "am I done?" view.
        // Present only while something is unmet; the submenu lists each gap and
        // deep-links to its fix. The urgent per-permission rows above stay as the
        // fast nudge, so this sits below them and above the transport row.
        if let title = i.finishSetupTitle {
            rows.append(.finishSetup(title: title))
        }

        // Offer Start whenever a manual toggle would actually start a recording.
        // `.suppressed` is a presentation-only label (the skip-latch display in
        // `StatusBarController.setSuppressed`); the state machine underneath is
        // `.idle`, so `toggleManual` records and the menu must keep the affordance.
        // Dropping it here left a skipped meeting with no way to record from the
        // menu for the rest of the call. `.prompting` keeps the prompt window as its
        // record affordance; `.stopping` is a genuine no-op mid-flush.
        //
        // DET7: keeping the affordance was only half the fix. The row it kept offering
        // recorded `source: nil`, so the skipped meeting was recordable but not
        // *attachable*. With a live candidate the same row names it instead.
        switch i.state {
        case .idle, .suppressed:
            if let appName = i.suppressedCandidateAppName {
                rows.append(.recordSuppressedMeeting(
                    appName: appName,
                    title: startRecordingTitle(suppressedCandidateAppName: appName)
                ))
            } else {
                rows.append(.startRecording)
            }
        case .recording(let file, _, _):
            rows.append(.stopRecording(stem: file.deletingPathExtension().lastPathComponent))
        default:
            break
        }

        if offersQuitWithoutRelaunch(i) {
            rows.append(.quitWithoutRelaunch)
        }

        return rows
    }

    /// Whether to offer the one-off quit that does not relaunch.
    ///
    /// TECH-UX7 wrote the rule down correctly: the extra row exists only where a plain
    /// Quit would be undone by a relaunch, and is hidden otherwise, since otherwise the
    /// plain Quit above already means quit. It then implemented that rule against one
    /// input, the `disableAutoRestart` preference, which was the whole story at the time.
    ///
    /// UX42 gave relaunch-after-quit a second owner and this rule did not learn about it
    /// (UX55): the `com.meetingpipe.daemon` launch agent's `KeepAlive` is what actually
    /// brings the app back, so with the agent disabled a plain Quit already means quit
    /// while the preference still reads "relaunch", and the row was offered anyway. It is
    /// a truthfulness defect rather than a behavioural one, of exactly the family UX42
    /// was about: a control describing a distinction the machine no longer makes.
    ///
    /// A *missing* agent reads as not enabled and gets the same answer for the same
    /// reason, since nothing can relaunch the app then either.
    static func offersQuitWithoutRelaunch(_ i: Inputs) -> Bool {
        !i.disableAutoRestart && i.launchAgentEnabled
    }

    /// The start row's title (DET7). `StatusBarController.populateMenu` builds its
    /// `NSMenuItem`s by hand rather than from `rows`, so the copy lives here and both
    /// read it; otherwise the tested model and the shipped menu drift on wording and
    /// only the model is ever checked.
    ///
    /// Sentence case after the verb is deliberate, against the Title Case rule
    /// `design/README.md` sets for menu commands: "Record This Microsoft Teams Meeting"
    /// shouts, and the app name is a proper noun sitting inside a sentence, not a command
    /// word. This is the string DET7's owner-eyeball step names verbatim.
    static func startRecordingTitle(suppressedCandidateAppName: String?) -> String {
        guard let appName = suppressedCandidateAppName else { return "Start Recording" }
        return "Record this \(appName) meeting"
    }

    /// The Accessibility row's title (DET11), here for the reason `startRecordingTitle` is here:
    /// `StatusBarController.populateMenu` builds its `NSMenuItem`s by hand, so a string spelled
    /// only there is never checked and drifts from the model the tests do read.
    ///
    /// It said "meeting end-detection degraded" from TECH-END4 (c) until DET11, which is the claim
    /// four surfaces made and the code contradicts. `MeetingSourceScanner.collectSignals` gates
    /// EVERY native signal on AX trust and `MeetingSourceScorer.pickBest` then drops the
    /// zero-evidence candidate, so a denied grant means a native meeting is never detected at all;
    /// browsers do not even become candidates. Nothing auto-starts, so there is nothing left to
    /// auto-stop late. Recording by hand (the row below this one, or the hotkey) still works, which
    /// is why the copy names the loss rather than declaring the app broken.
    static let accessibilityOffTitle = "⚠ Accessibility off - meetings are not detected"

    /// The failed-pipeline row's title, or nil when there is nothing to show.
    /// Backed by the durable error sidecar, so a notification missed under Focus
    /// is not the only surface; it stays until retry or delete.
    static func failedMeetingsTitle(count: Int) -> String? {
        guard count > 0 else { return nil }
        let noun = count == 1 ? "meeting" : "meetings"
        return "⚠ \(count) \(noun) failed - open Library to retry"
    }

    /// "Any required permission missing" for the warning row. Screen Recording's
    /// transient `.unknown` is excluded so it does not flash at every cold
    /// launch, and mic counts `.notDetermined` because an unprompted mic is a
    /// recording that will fail.
    static func hasPendingPermissionIssue(_ i: Inputs) -> Bool {
        if i.microphone == .denied || i.microphone == .notDetermined { return true }
        if i.screenRecording == .denied { return true }
        if i.accessibility == .denied { return true }
        return false
    }

    /// One consequence line per missing permission (UX23): the menu names what
    /// actually stops working, not just that "attention is needed". Accessibility
    /// is deliberately absent here because it already has its own dedicated
    /// `accessibilityDegraded` row that names its own consequence. Mic counts
    /// `.notDetermined` for the same reason `hasPendingPermissionIssue` does (an
    /// unprompted mic is a recording that will be silent), and the screen-recording
    /// line fires on either the TCC `.denied` status or the capture probe's denial,
    /// since either one means the call audio is lost.
    static func permissionConsequences(_ i: Inputs) -> [String] {
        var out: [String] = []
        if i.microphone == .denied || i.microphone == .notDetermined {
            out.append("⚠ Microphone off: recordings will be silent")
        }
        if i.screenRecording == .denied || i.screenRecordingCaptureDenied {
            out.append("⚠ Screen Recording off: the call audio will not be recorded (mic only)")
        }
        return out
    }

    static func downloadRow(_ download: ModelDownloadSupervisor.State) -> Row? {
        switch download {
        case .idle:
            return nil
        case .downloading(let modelId, let progress, let downloaded, let total):
            let body: String
            if total > 0 {
                body = "\(formatBytes(downloaded)) / \(formatBytes(total))"
                    + (progress.map { " (\(Int($0 * 100))%)" } ?? "")
            } else {
                body = "\(formatBytes(downloaded)) downloaded"
            }
            return .modelDownload(
                title: "Downloading \(shortModelId(modelId)): \(body)",
                retryable: false,
                toolTip: nil,
                dismissible: false
            )
        case .completed(let modelId):
            return .modelDownload(
                title: "✓ Downloaded \(shortModelId(modelId))",
                retryable: false,
                toolTip: nil,
                dismissible: false
            )
        case .failed(let modelId, let error):
            // Actionable (LOCAL1): clicking re-spawns the prefetch. The full
            // error goes to the tooltip so the row title stays short.
            return .modelDownload(
                title: "⚠ Model download failed (\(shortModelId(modelId))) - Retry",
                retryable: true,
                toolTip: error,
                dismissible: true
            )
        }
    }

    /// Drop the `org/` prefix so the menu row stays readable; the full id is in
    /// Preferences -> Pipeline.
    static func shortModelId(_ id: String) -> String {
        if let slash = id.lastIndex(of: "/") {
            return String(id[id.index(after: slash)...])
        }
        return id
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        if kb >= 1 { return String(format: "%.0f KB", kb) }
        return "\(bytes) B"
    }
}
