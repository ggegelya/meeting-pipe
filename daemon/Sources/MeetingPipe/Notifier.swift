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

    private static let doneCategory = "MP_DONE"
    private static let doneCorrectableCategory = "MP_DONE_CORRECTABLE"
    private static let doneCorrectableLocalCategory = "MP_DONE_CORRECTABLE_LOCAL"
    private static let actionOpen = "MP_OPEN_PAGE"
    private static let actionLooksGood = "MP_LOOKS_GOOD"
    private static let actionEditSummary = "MP_EDIT_SUMMARY"
    private static let permCategory = "MP_PERM"
    private static let actionOpenSettings = "MP_OPEN_SETTINGS"
    private static let stillMeetingCategory = "MP_STILL_MEETING"
    /// Separate from `permCategory` so "Open Settings" routes to Accessibility instead of Screen Recording.
    private static let accessibilityCategory = "MP_ACCESSIBILITY"
    private static let actionOpenAccessibilitySettings = "MP_OPEN_ACCESS_SETTINGS"
    private static let actionStopRecording = "MP_STOP_RECORDING"
    private static let actionKeepRecording = "MP_KEEP_RECORDING"
    private static let stillMeetingIDPrefix = "still-meeting-"
    private static let skipLateCategory = "MP_SKIP_LATE"
    private static let actionStartLate = "MP_START_LATE"
    private static let skipLateIDPrefix = "skip-late-"

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
        let req = UNNotificationRequest(identifier: "perm-stop-\(file.lastPathComponent)", content: content, trigger: nil)
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
        let action = response.actionIdentifier
        let isDefault = action == UNNotificationDefaultActionIdentifier

        if let entry = doneEntries[id] {
            switch action {
            case Self.actionLooksGood:
                if !entry.stem.isEmpty {
                    delegate?.notifier(
                        self,
                        didMarkLooksGoodFor: entry.stem,
                        recordingsDir: entry.recordingsDir
                    )
                }
                doneEntries.removeValue(forKey: id)
            case Self.actionEditSummary:
                if !entry.stem.isEmpty {
                    delegate?.notifier(
                        self,
                        didRequestEditSummaryFor: entry.stem,
                        recordingsDir: entry.recordingsDir
                    )
                }
                doneEntries.removeValue(forKey: id)
            case Self.actionOpen:
                if let url = entry.pageURL {
                    delegate?.notifier(self, didOpenPage: url)
                }
                doneEntries.removeValue(forKey: id)
            default:
                if isDefault, let url = entry.pageURL {
                    delegate?.notifier(self, didOpenPage: url)
                    doneEntries.removeValue(forKey: id)
                }
            }
        }

        // Permission notifications: any tap opens System Settings. The `perm-` prefix disambiguates from the done category handled above.
        if id == "perm-accessibility-startup",
           action == Self.actionOpenAccessibilitySettings || isDefault {
            delegate?.notifierDidRequestAccessibilitySettings(self)
        } else if id.hasPrefix("perm-"),
                  action == Self.actionOpenSettings || isDefault {
            delegate?.notifierDidRequestScreenRecordingSettings(self)
        }

        // TECH-C2: only the explicit "Stop recording" action stops. "Keep
        // recording" and a plain banner tap restart the silence countdown, so
        // an accidental tap can no longer kill an active meeting.
        if id.hasPrefix(Self.stillMeetingIDPrefix) {
            if action == Self.actionStopRecording {
                delegate?.notifierDidRequestStopRecording(self)
            } else if action == Self.actionKeepRecording || isDefault {
                delegate?.notifierDidRequestKeepRecording(self)
            }
        }

        // UX10: "Start recording" (or a banner tap) on a timeout-skip notification
        // rebuilds the source from `userInfo` and starts the recording late.
        if id.hasPrefix(Self.skipLateIDPrefix),
           action == Self.actionStartLate || isDefault,
           let source = AppSource(notificationUserInfo: response.notification.request.content.userInfo) {
            delegate?.notifier(self, didRequestStartLate: source)
        }
        completionHandler()
    }
}
