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
        /// Informational unless `retryable`, which is the LOCAL1 retry affordance.
        case modelDownload(title: String, retryable: Bool, toolTip: String?)
        /// One row per missing permission, naming what stops working (UX23):
        /// "Microphone off: recordings will be silent", etc. Replaces the old
        /// single vague "Permissions need attention" row.
        case permissionConsequence(title: String)
        /// The Screen Recording deep link, only alongside a screen-recording
        /// `permissionConsequence`.
        case screenRecordingShortcut
        case accessibilityDegraded
        case failedMeetings(count: Int, title: String)
        case startRecording
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
        var processingCount: Int
        var regulatedMode: Bool
        var showRegulatedBadge: Bool
        var download: ModelDownloadSupervisor.State
        var microphone: PermissionsCenter.Status
        var screenRecording: PermissionsCenter.Status
        var accessibility: PermissionsCenter.Status
        /// `SystemAudioCapture.permissionState`, which is a separate probe from
        /// `screenRecording` above and drives only the deep-link row.
        var screenRecordingCaptureDenied: Bool
        var failedMeetingCount: Int
        var disableAutoRestart: Bool

        init(
            state: AppState = .idle,
            workflowName: String? = nil,
            ndaMode: Bool = false,
            summaryMode: SummaryMode = .auto,
            processingCount: Int = 0,
            regulatedMode: Bool = false,
            showRegulatedBadge: Bool = true,
            download: ModelDownloadSupervisor.State = .idle,
            microphone: PermissionsCenter.Status = .granted,
            screenRecording: PermissionsCenter.Status = .granted,
            accessibility: PermissionsCenter.Status = .granted,
            screenRecordingCaptureDenied: Bool = false,
            failedMeetingCount: Int = 0,
            disableAutoRestart: Bool = false
        ) {
            self.state = state
            self.workflowName = workflowName
            self.ndaMode = ndaMode
            self.summaryMode = summaryMode
            self.processingCount = processingCount
            self.regulatedMode = regulatedMode
            self.showRegulatedBadge = showRegulatedBadge
            self.download = download
            self.microphone = microphone
            self.screenRecording = screenRecording
            self.accessibility = accessibility
            self.screenRecordingCaptureDenied = screenRecordingCaptureDenied
            self.failedMeetingCount = failedMeetingCount
            self.disableAutoRestart = disableAutoRestart
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
    static func title(_ i: Inputs) -> String {
        let lock = (i.regulatedMode && i.showRegulatedBadge) ? " \u{1F512}" : ""
        let clause: String
        if i.state == .idle, let download = downloadTitleClause(i.download) {
            clause = download
        } else if i.state == .idle, i.processingCount > 0 {
            clause = "Processing (\(i.processingCount))"
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
        let suffix = i.processingCount > 0 ? " · Processing (\(i.processingCount))" : ""
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

        // TECH-END4 (c): Accessibility drives native meeting-end detection, so a
        // denial is called out beyond the generic row above.
        if i.accessibility == .denied {
            rows.append(.accessibilityDegraded)
        }

        if let title = failedMeetingsTitle(count: i.failedMeetingCount) {
            rows.append(.failedMeetings(count: i.failedMeetingCount, title: title))
        }

        switch i.state {
        case .idle:
            rows.append(.startRecording)
        case .recording(let file, _, _):
            rows.append(.stopRecording(stem: file.deletingPathExtension().lastPathComponent))
        default:
            break
        }

        // TECH-UX7: the one-off quit that does not relaunch is offered only when
        // auto-restart is on, since otherwise plain Quit already means quit.
        if !i.disableAutoRestart {
            rows.append(.quitWithoutRelaunch)
        }

        return rows
    }

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
                toolTip: nil
            )
        case .completed(let modelId):
            return .modelDownload(
                title: "✓ Downloaded \(shortModelId(modelId))",
                retryable: false,
                toolTip: nil
            )
        case .failed(let modelId, let error):
            // Actionable (LOCAL1): clicking re-spawns the prefetch. The full
            // error goes to the tooltip so the row title stays short.
            return .modelDownload(
                title: "⚠ Model download failed (\(shortModelId(modelId))) - Retry",
                retryable: true,
                toolTip: error
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
