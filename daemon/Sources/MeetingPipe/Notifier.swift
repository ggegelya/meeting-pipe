import AppKit
import UserNotifications

/// Coordinator callback protocol. Both `MeetingPromptWindow` and notification actions route here so the state machine has one entry point per outcome regardless of which surface fired it.
protocol NotifierDelegate: AnyObject {
    func notifier(_ notifier: Notifier, didChooseRecord source: AppSource)
    func notifier(_ notifier: Notifier, didChooseSkip source: AppSource)
    func notifier(_ notifier: Notifier, didChooseAlways source: AppSource)
    func notifier(_ notifier: Notifier, didOpenPage url: URL)
    /// User tapped "Open Settings" on the Screen Recording permission warning.
    func notifierDidRequestScreenRecordingSettings(_ notifier: Notifier)
    /// User tapped "Open Settings" on the Accessibility permission warning. Distinct from the Screen Recording variant so the Coordinator can deep-link to the correct pane.
    func notifierDidRequestAccessibilitySettings(_ notifier: Notifier)
    /// User tapped the explicit "Stop recording" action on the "Still meeting?" notification. Coordinator stops the recording (no-op if state is no longer `.recording`).
    func notifierDidRequestStopRecording(_ notifier: Notifier)
    /// User tapped "Keep recording", or the banner body, on the "Still meeting?" notification. Coordinator restarts the silence countdown so the recording is not auto-stopped.
    func notifierDidRequestKeepRecording(_ notifier: Notifier)
    /// User tapped "Start recording" (or the banner body) on the timeout-skip notification (UX10). Coordinator clears the bundle's suppression and starts a late recording.
    func notifier(_ notifier: Notifier, didRequestStartLate source: AppSource)
    /// User clicked "Looks good" on the published-meeting notification.
    func notifier(
        _ notifier: Notifier,
        didMarkLooksGoodFor stem: String,
        recordingsDir: URL
    )
    /// User clicked "Edit summary" or selected a meeting from the Recent meetings submenu.
    func notifier(
        _ notifier: Notifier,
        didRequestEditSummaryFor stem: String,
        recordingsDir: URL
    )
}

/// Wraps UNUserNotificationCenter for informational banners (started / processing / done / error). The "Record this meeting?" prompt lives in `MeetingPromptWindow` - banners are silenced by Focus mode and are the secondary surface.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    weak var delegate: NotifierDelegate?

    // `NotificationRouter` owns the identifier vocabulary: it is the type that
    // interprets these, and the routing table's test needs them without
    // reaching into this class. Aliased so every `Self.x` call site below reads
    // the same as before.
    private static let doneCategory = NotificationRouter.doneCategory
    private static let doneCorrectableCategory = NotificationRouter.doneCorrectableCategory
    private static let doneCorrectableLocalCategory = NotificationRouter.doneCorrectableLocalCategory
    private static let actionOpen = NotificationRouter.actionOpen
    private static let actionLooksGood = NotificationRouter.actionLooksGood
    private static let actionEditSummary = NotificationRouter.actionEditSummary
    private static let permCategory = NotificationRouter.permCategory
    private static let actionOpenSettings = NotificationRouter.actionOpenSettings
    private static let stillMeetingCategory = NotificationRouter.stillMeetingCategory
    /// Separate from `permCategory` so "Open Settings" routes to Accessibility instead of Screen Recording.
    private static let accessibilityCategory = NotificationRouter.accessibilityCategory
    private static let actionOpenAccessibilitySettings = NotificationRouter.actionOpenAccessibilitySettings
    private static let actionStopRecording = NotificationRouter.actionStopRecording
    private static let actionKeepRecording = NotificationRouter.actionKeepRecording
    private static let stillMeetingIDPrefix = NotificationRouter.stillMeetingIDPrefix
    private static let skipLateCategory = "MP_SKIP_LATE"
    private static let actionStartLate = NotificationRouter.actionStartLate
    private static let skipLateIDPrefix = NotificationRouter.skipLateIDPrefix

    /// Per-notification state kept so "Looks good" can find the recording without re-deriving paths on click.
    private struct DoneEntry {
        let stem: String
        let recordingsDir: URL
        let pageURL: URL?
    }
    private var doneEntries: [String: DoneEntry] = [:]

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                Log.main.warning("Notification auth error: \(error.localizedDescription)")
            }
            Log.main.info("Notification auth granted: \(granted)")
        }
    }

    // MARK: Posting

    func notifyRecordingStarted(file: URL) {
        post(title: "Recording started", body: file.lastPathComponent)
    }

    func notifyProcessing(file: URL) {
        post(title: "Recording stopped", body: "Processing \(file.lastPathComponent)…")
    }

    /// Post the "meeting done" notification. If `stem`+`recordingsDir` are supplied and `<stem>.run.json` exists, surfaces a "Looks good" correction action. Otherwise falls back to legacy behaviour (Open in Notion only, or plain "Local Markdown ready" under regulated mode).
    func notifyDone(
        stem: String? = nil,
        recordingsDir: URL? = nil,
        pageURL: URL?
    ) {
        let canCorrect = Self.canCorrect(stem: stem, recordingsDir: recordingsDir)

        let content = UNMutableNotificationContent()
        content.sound = .default

        let id = "done-\(UUID().uuidString)"

        if let url = pageURL {
            content.title = "Meeting published"
            content.body = canCorrect ? "Open in Notion. How did this summary look?"
                                      : "Open in Notion"
            content.categoryIdentifier = canCorrect
                ? Self.doneCorrectableCategory
                : Self.doneCategory
            doneEntries[id] = DoneEntry(
                stem: stem ?? "",
                recordingsDir: recordingsDir ?? URL(fileURLWithPath: "/"),
                pageURL: url
            )
        } else if canCorrect, let stem = stem, let dir = recordingsDir {
            content.title = "Meeting processed"
            content.body = "Local Markdown ready. How did this summary look?"
            content.categoryIdentifier = Self.doneCorrectableLocalCategory
            doneEntries[id] = DoneEntry(stem: stem, recordingsDir: dir, pageURL: nil)
        } else {
            // No corrections, no Notion page: keep the legacy plain banner.
            post(title: "Meeting processed", body: "Local Markdown ready (regulated mode)")
            return
        }

        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// A run that finished but intentionally produced no summary: no speech, or a
    /// transcript that looked unreliable (PIPE3 / AUD-16a). An honest, quiet
    /// terminal banner with no correction action and no Notion, replacing the
    /// misleading "Local Markdown ready (regulated mode)" the generic done path
    /// posted for these (the recording was neither regulated nor summarized).
    func notifyEmptySkip(reason: EmptyReason) {
        post(title: reason.notificationTitle, body: reason.notificationBody)
    }

    /// True when `<stem>.run.json` exists (pipeline produced a gradeable summary). Skipped paths (no_speech, byo, too_long) never write the run sidecar, so the correction action is correctly disabled for them.
    private static func canCorrect(stem: String?, recordingsDir: URL?) -> Bool {
        guard let stem = stem, let dir = recordingsDir else { return false }
        let runURL = dir.appendingPathComponent("\(stem).run.json")
        return FileManager.default.fileExists(atPath: runURL.path)
    }

    func notifyError(_ message: String) {
        post(title: "MeetingPipe error", body: message)
    }

    /// Posted when a detection prompt times out and the meeting is skipped (UX10 /
    /// AUD-12). The timeout-skip otherwise discards a detected meeting with no
    /// surface at all (every other failure branch notifies). "Start recording"
    /// begins a late recording, bypassing the reprompt cooldown + skip latch the
    /// skip armed; the app identity rides in `userInfo` so the action still works
    /// minutes later. A stable per-bundle id coalesces repeat skips of one app.
    func notifySkippedMeeting(source: AppSource) {
        let content = UNMutableNotificationContent()
        content.title = "Skipped \(source.displayName)"
        content.body = "Meeting prompt timed out. Start recording?"
        content.categoryIdentifier = Self.skipLateCategory
        content.userInfo = source.notificationUserInfo
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "\(Self.skipLateIDPrefix)\(source.bundleID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    /// Posted by the idle backstop (TECH-END3) after a long VAD-silent stretch. "Keep recording" (and a plain banner tap) restart the idle countdown; "Stop recording" ends it now. For a native meeting still tracked live, the auto-stop stands down on its own and this nudge just re-surfaces.
    func notifyStillMeeting() {
        let content = UNMutableNotificationContent()
        content.title = "Still in a meeting?"
        content.body = "No audio for a while. Recording continues, keep it going or stop."
        content.categoryIdentifier = Self.stillMeetingCategory
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "\(Self.stillMeetingIDPrefix)\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    /// Posted at startup when Accessibility TCC is missing. Without it, detector window probes degrade to nil and native meetings (Teams / Zoom / Webex / Slack) never auto-end. Action button opens System Settings -> Accessibility.
    func notifyAccessibilityBlocked() {
        let content = UNMutableNotificationContent()
        content.title = "Accessibility disabled"
        content.body = "Without it, Teams / Zoom / Webex meetings won't auto-stop when the call ends. Enable in System Settings."
        content.categoryIdentifier = Self.accessibilityCategory
        content.sound = .default
        let req = UNNotificationRequest(identifier: "perm-accessibility-startup", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Posted at startup when Screen Recording TCC is denied; recordings will be mic-only until the user grants it. Action button opens System Settings.
    func notifySystemAudioBlocked() {
        let content = UNMutableNotificationContent()
        content.title = "Screen Recording disabled"
        content.body = "MeetingPipe will record your microphone only. The other side of the call won't be captured."
        content.categoryIdentifier = Self.permCategory
        content.sound = .default
        let req = UNNotificationRequest(identifier: "perm-startup", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Posted when a recording stops with no system-audio samples. Stronger than the startup banner because the user just lost half a meeting. `permissionState` shapes the message - `.unknown` is included (not just `.denied`) because a fresh launch with no prewarm silently produced mic-only recordings with no surface (regression: May 5 18:30 recording).
    func notifyMicOnlyRecording(
        file: URL,
        permissionState: SystemAudioCapture.PermissionState
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Recording was mic-only"
        switch permissionState {
        case .denied:
            content.body = "Screen Recording permission is off, so only your voice was captured. Enable it in System Settings to record both sides."
            content.categoryIdentifier = Self.permCategory
        case .unknown:
            content.body = "Screen Recording wasn't available at recording start, so only your voice was captured. Open Settings to grant the permission for next time."
            content.categoryIdentifier = Self.permCategory
        case .granted:
            content.body = "Permission is granted but no system audio reached the recorder. Check ~/Library/Logs/MeetingPipe/recorder.log for SCStream errors."
            // No "Open Settings" action - it's not a permission problem.
        }
        content.sound = .default
        // The `.granted` case is not a permission problem, so it must not carry
        // the `perm-` id namespace: it sets no category, a plain tap is
        // therefore the only interaction, and `perm-` + a default tap used to
        // open the Screen Recording pane, which is the one place that cannot
        // help someone whose permission is already granted (found by T3's
        // routing table). The other two states keep the permission namespace.
        let prefix = permissionState == .granted
            ? NotificationRouter.micOnlyIDPrefix
            : "perm-stop-"
        let req = UNNotificationRequest(identifier: "\(prefix)\(file.lastPathComponent)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// The system-audio (SCStream) capture died part-way through a recording and did not
    /// recover, so the call's remote side is missing from that point on (REC4 / AUD-13).
    /// Distinct from `notifyMicOnlyRecording`, which is the whole-recording mic-only case
    /// ("only your voice was captured" would be wrong here: the first part had both sides).
    func notifyRemoteAudioInterrupted(file: URL) {
        let content = UNMutableNotificationContent()
        content.title = "System audio interrupted"
        content.body = "The other side of the call stopped being captured part-way through, so the recording is mic-only from that point. See ~/Library/Logs/MeetingPipe/recorder.log for SCStream errors."
        content.sound = .default
        let req = UNNotificationRequest(identifier: "sysaudio-interrupted-\(file.lastPathComponent)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Posted when the mic channel stayed at the noise floor across an un-muted stretch while
    /// the system side captured fine (MIC15). The likeliest cause is the OS default input being
    /// a device other than the one the user speaks into (e.g. a Bluetooth headset idle in A2DP),
    /// which the daemon records faithfully but cannot detect while it happens.
    func notifyMicRecordedNothing(file: URL) {
        let content = UNMutableNotificationContent()
        content.title = "Your mic recorded almost nothing"
        content.body = "The other side was captured, but your microphone stayed silent. Check System Settings, Sound, Input - the wrong input device may be selected."
        content.sound = .default
        let req = UNNotificationRequest(identifier: "mic-silent-\(file.lastPathComponent)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Posted before a recording starts when the OS default input we are about to capture sits
    /// idle while another input device is active (MIC15 layer c): the meeting client likely opened
    /// a different mic, so warn early rather than discover the dead recording after the call.
    func notifyInputDeviceMismatch() {
        let content = UNMutableNotificationContent()
        content.title = "Recording a possibly-wrong microphone"
        content.body = "Another app appears to be using a different microphone than the one MeetingPipe will record. Check System Settings, Sound, Input if your voice should be captured."
        content.sound = .default
        let req = UNNotificationRequest(identifier: "input-mismatch-\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Posted when a mid-recording input device change was recovered; capture continued with a short silent gap.
    func notifyCaptureRecovered() {
        post(
            title: "Input device changed",
            body: "MeetingPipe switched to the new input device and kept recording. There is a short gap where the device changed."
        )
    }

    /// Posted when a mid-recording input device change could not be recovered; microphone capture has stopped.
    func notifyCaptureLost() {
        post(
            title: "Microphone capture stopped",
            body: "The input device changed and MeetingPipe could not resume the microphone. Stop and restart the recording to capture the rest."
        )
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: Categories

    private func registerCategories() {
        let open = UNNotificationAction(identifier: Self.actionOpen, title: "Open in Notion", options: [.foreground])
        let looksGood = UNNotificationAction(identifier: Self.actionLooksGood, title: "Looks good", options: [])
        let edit = UNNotificationAction(identifier: Self.actionEditSummary, title: "Edit summary", options: [.foreground])
        // MP_DONE: pre-Phase-2 fallback (Open in Notion only).
        // MP_DONE_CORRECTABLE: Notion + correction actions.
        // MP_DONE_CORRECTABLE_LOCAL: regulated/local-only + correction actions.
        let done = UNNotificationCategory(
            identifier: Self.doneCategory,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )
        let doneCorrectable = UNNotificationCategory(
            identifier: Self.doneCorrectableCategory,
            actions: [open, looksGood, edit],
            intentIdentifiers: [],
            options: []
        )
        let doneCorrectableLocal = UNNotificationCategory(
            identifier: Self.doneCorrectableLocalCategory,
            actions: [looksGood, edit],
            intentIdentifiers: [],
            options: []
        )
        let openSettings = UNNotificationAction(identifier: Self.actionOpenSettings, title: "Open Settings", options: [.foreground])
        let perm = UNNotificationCategory(
            identifier: Self.permCategory,
            actions: [openSettings],
            intentIdentifiers: [],
            options: []
        )
        let openAccessibilitySettings = UNNotificationAction(
            identifier: Self.actionOpenAccessibilitySettings,
            title: "Open Settings",
            options: [.foreground]
        )
        let accessibility = UNNotificationCategory(
            identifier: Self.accessibilityCategory,
            actions: [openAccessibilitySettings],
            intentIdentifiers: [],
            options: []
        )
        let keep = UNNotificationAction(identifier: Self.actionKeepRecording, title: "Keep recording", options: [])
        let stop = UNNotificationAction(identifier: Self.actionStopRecording, title: "Stop recording", options: [.foreground])
        let stillMeeting = UNNotificationCategory(
            identifier: Self.stillMeetingCategory,
            actions: [keep, stop],
            intentIdentifiers: [],
            options: []
        )
        let startLate = UNNotificationAction(identifier: Self.actionStartLate, title: "Start recording", options: [.foreground])
        let skipLate = UNNotificationCategory(
            identifier: Self.skipLateCategory,
            actions: [startLate],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories(
            [done, doneCorrectable, doneCorrectableLocal, perm, accessibility, stillMeeting, skipLate]
        )
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let entry = doneEntries[id]

        // The whole matrix lives in `NotificationRouter.route`, which is pure and
        // table-tested (T3). This method is the effect half: look up state, ask
        // for the routes, call the delegate.
        let decision = NotificationRouter.route(
            id: id,
            action: response.actionIdentifier,
            isDefault: response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            doneEntry: entry.map { .init(stem: $0.stem, hasPageURL: $0.pageURL != nil) }
        )

        for route in decision.routes {
            switch route {
            case .markLooksGood(let stem):
                guard let entry else { continue }
                delegate?.notifier(self, didMarkLooksGoodFor: stem, recordingsDir: entry.recordingsDir)
            case .editSummary(let stem):
                guard let entry else { continue }
                delegate?.notifier(self, didRequestEditSummaryFor: stem, recordingsDir: entry.recordingsDir)
            case .openPage:
                guard let url = entry?.pageURL else { continue }
                delegate?.notifier(self, didOpenPage: url)
            case .openAccessibilitySettings:
                delegate?.notifierDidRequestAccessibilitySettings(self)
            case .openScreenRecordingSettings:
                delegate?.notifierDidRequestScreenRecordingSettings(self)
            case .stopRecording:
                delegate?.notifierDidRequestStopRecording(self)
            case .keepRecording:
                delegate?.notifierDidRequestKeepRecording(self)
            case .startLate:
                // The host still owns the decode, so an undecodable payload
                // drops the route rather than starting an unattributed recording.
                guard let source = AppSource(
                    notificationUserInfo: response.notification.request.content.userInfo
                ) else { continue }
                delegate?.notifier(self, didRequestStartLate: source)
            }
        }

        if decision.consumeDoneEntry {
            doneEntries.removeValue(forKey: id)
        }
        completionHandler()
    }
}
