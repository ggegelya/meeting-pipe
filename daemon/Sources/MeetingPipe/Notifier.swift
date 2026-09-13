import AppKit
import UserNotifications

/// Coordinator callback protocol. Both `MeetingPromptWindow` and notification actions route here so the state machine has one entry point per outcome regardless of which surface fired it.
protocol NotifierDelegate: AnyObject {
    func notifier(_ notifier: Notifier, didRequestFailure failure: FailurePresentation, stem: String?)
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

extension NotifierDelegate {
    func notifier(_ notifier: Notifier, didRequestFailure failure: FailurePresentation, stem: String?) {}
}

/// Why a detected meeting was not recorded, which decides how loudly the skip banner
/// asks about it (UX10 + DET7).
enum SkipOrigin: Equatable {
    /// The prompt timed out with the skip default. The user may never have seen the
    /// prompt at all, so the banner is the first surface and it makes a sound.
    case timedOut
    /// The user pressed Skip, or the prompt's × close. That is a decision, not a miss,
    /// so the banner is a silent undo affordance rather than an alert.
    case dismissed
}

/// Wraps UNUserNotificationCenter for informational banners (started / processing / done / error). The "Record this meeting?" prompt lives in `MeetingPromptWindow` - banners are silenced by Focus mode and are the secondary surface.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    weak var delegate: NotifierDelegate?

    // `NotificationRouter` owns the identifier vocabulary: it is the type that
    // interprets these, and the routing table's test needs them without
    // reaching into this class. Aliased so every `Self.x` call site below reads
    // the same as before.
    // The two open-capable done categories are composed per Open phrase by
    // `NotificationRouter.doneCategory(for:canCorrect:)` since UX49, so only the
    // local one (which carries no Open action) is aliased here.
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
    private var failures: [String: (FailurePresentation, String?)] = [:]

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

    /// Post the "meeting done" notification. If `stem`+`recordingsDir` are supplied and `<stem>.run.json` exists, surfaces a "Looks good" correction action.
    ///
    /// Every user-facing string here comes from `DoneNotificationCopy`, over the
    /// sink that actually landed (UX49). It used to name Notion unconditionally,
    /// in the body and on the action button, so a filesystem publish, the common
    /// case for this library, announced a sink that never ran and offered to open
    /// a local Markdown file as if it were a Notion page. The action was always
    /// correct: it opens `pageURL`, which is whatever published.
    func notifyDone(
        stem: String? = nil,
        recordingsDir: URL? = nil,
        pageURL: URL?
    ) {
        let canCorrect = Self.canCorrect(stem: stem, recordingsDir: recordingsDir)
        let landing = PublishLanding.decide(
            publish: Self.publishResult(stem: stem, recordingsDir: recordingsDir),
            pageURL: pageURL
        )
        let copy = DoneNotificationCopy.make(landing: landing, canCorrect: canCorrect)

        let content = UNMutableNotificationContent()
        content.sound = .default
        content.title = copy.title
        content.body = copy.body

        let id = "done-\(UUID().uuidString)"

        if let url = pageURL,
           let category = NotificationRouter.doneCategory(for: landing, canCorrect: canCorrect) {
            content.categoryIdentifier = category
            doneEntries[id] = DoneEntry(
                stem: stem ?? "",
                recordingsDir: recordingsDir ?? URL(fileURLWithPath: "/"),
                pageURL: url
            )
        } else if canCorrect, let stem = stem, let dir = recordingsDir {
            // Nothing landed anywhere, so there is nothing to open; the summary
            // is still gradeable.
            content.categoryIdentifier = Self.doneCorrectableLocalCategory
            doneEntries[id] = DoneEntry(stem: stem, recordingsDir: dir, pageURL: nil)
        } else {
            // Nothing to open and nothing to grade: a plain terminal banner.
            post(title: copy.title, body: copy.body)
            return
        }

        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// A run that finished but intentionally produced no summary: no speech, or a
    /// transcript that looked unreliable (PIPE3 / AUD-16a). An honest, quiet
    /// terminal banner with no correction action and no publish claim, replacing
    /// the misleading "Local Markdown ready (regulated mode)" the generic done
    /// path posted for these (the recording was neither regulated nor
    /// summarized).
    func notifyEmptySkip(reason: EmptyReason) {
        post(title: reason.notificationTitle, body: reason.notificationBody)
    }

    /// True when `<stem>.run.json` exists (pipeline produced a gradeable summary). Skipped paths (no_speech, byo, too_long) never write the run sidecar, so the correction action is correctly disabled for them.
    private static func canCorrect(stem: String?, recordingsDir: URL?) -> Bool {
        guard let stem = stem, let dir = recordingsDir else { return false }
        let runURL = dir.appendingPathComponent("\(stem).run.json")
        return FileManager.default.fileExists(atPath: runURL.path)
    }

    /// This run's publish outcome, when the caller named a meeting.
    ///
    /// The same file `pageURL` was read out of, read again here because *which*
    /// sink produced that URL is what the copy names, and only the sidecar knows
    /// (`page_url` alone says what to open, not who wrote it). Nil is a real
    /// answer: every `run-all` short-circuit stops before publish and writes no
    /// sidecar at all.
    private static func publishResult(stem: String?, recordingsDir: URL?) -> PublishResult? {
        guard let stem = stem, let dir = recordingsDir else { return nil }
        return PublishResult.load(stem: stem, in: dir)
    }

    func notifyError(_ message: String) {
        notifyFailure(FailurePresentation(diagnostics: message))
    }

    func notifyFailure(_ failure: FailurePresentation, stem: String? = nil) {
        guard failure.metadata.cause != .cancelled else { return }
        let id = NotificationRouter.failureIDPrefix + UUID().uuidString
        if failures.count >= 30, let first = failures.keys.sorted().first { failures.removeValue(forKey: first) }
        failures[id] = (failure, stem)
        let content = UNMutableNotificationContent()
        content.title = failure.title
        content.body = stem == nil ? "Review failure details." : "Review in Library."
        content.categoryIdentifier = NotificationRouter.failureCategory
        if let stem { content.userInfo = ["failureStem": stem] }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Posted when a detected meeting is not recorded (UX10 / AUD-12, extended by DET7).
    /// The skip otherwise discards a detected meeting with no surface at all (every other
    /// failure branch notifies). "Start recording" begins a late recording, bypassing the
    /// reprompt cooldown + skip latch the skip armed; the app identity rides in `userInfo`
    /// so the action still works minutes later. A stable per-bundle id coalesces repeat
    /// skips of one app.
    ///
    /// DET7 added the `.dismissed` origin: an explicit Skip or × is exactly the regret case
    /// the owner reported, and the plumbing behind this banner was already end to end, so
    /// it gets the same offer. It stays silent and says something different, because the
    /// user made that call deliberately and does not need to be alerted to their own click.
    func notifySkippedMeeting(source: AppSource, origin: SkipOrigin) {
        let content = UNMutableNotificationContent()
        content.title = "Skipped \(source.displayName)"
        switch origin {
        case .timedOut:
            content.body = "Meeting prompt timed out. Start recording?"
            content.sound = .default
        case .dismissed:
            content.body = "Meeting is still running. Start recording?"
        }
        content.categoryIdentifier = Self.skipLateCategory
        content.userInfo = source.notificationUserInfo
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

    /// Posted at startup when Accessibility TCC is missing. Without it every window and control probe returns nothing, so native meetings (Teams / Zoom / Webex / Slack) are never detected at all and browser tabs never become candidates: the prompt does not appear, nothing records itself, and nothing auto-ends because nothing started (DET11, correcting the end-detection-only claim this banner shipped with). Action button opens System Settings -> Accessibility.
    func notifyAccessibilityBlocked() {
        let content = UNMutableNotificationContent()
        content.title = "Accessibility disabled"
        content.body = "Meetings won't be detected: no prompt and no automatic recording. You can still record by hand. Enable in System Settings."
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
    ///
    /// "mic-only from that point" is true only because of REC9's merge length policy.
    /// Until it landed, the merge ended at the SHORTER capture channel, so a system
    /// channel that died at minute 3 of a 40-minute call ended the recording there
    /// too: this banner told the owner they still had their own voice for the rest of
    /// the meeting while that audio was being deleted. Anything that weakens the
    /// length policy makes this copy a lie again.
    func notifyRemoteAudioInterrupted(file: URL) {
        let content = UNMutableNotificationContent()
        content.title = "System audio interrupted"
        content.body = "The other side of the call stopped being captured part-way through, so the recording is mic-only from that point. See ~/Library/Logs/MeetingPipe/recorder.log for SCStream errors."
        content.sound = .default
        let req = UNNotificationRequest(identifier: "sysaudio-interrupted-\(file.lastPathComponent)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Posted when a finished recording holds materially less audio than the meeting it
    /// spanned (REC9). The check behind it is old; until REC9 its only output was one line
    /// in `recorder.log`, so the 2026-07-15 recording that kept 5.28 s of a 41.2 s meeting
    /// was announced to the owner as a clean success and its intermediates were deleted.
    /// Informational, so it carries no category and no action button: its own id namespace
    /// routes it nowhere, like `sysaudio-interrupted-`.
    func notifyShortRecording(file: URL, audioSec: Double, wallclockSec: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Recording is shorter than the meeting"
        let audio = RecordingDurationParity.clockPhrase(audioSec)
        let wallclock = RecordingDurationParity.clockPhrase(wallclockSec)
        content.body = "Only \(audio) of audio was saved for a \(wallclock) recording. Play it back before you rely on it, and see ~/Library/Logs/MeetingPipe/recorder.log for capture errors."
        content.sound = .default
        let req = UNNotificationRequest(identifier: "short-recording-\(file.lastPathComponent)", content: content, trigger: nil)
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
        let looksGood = UNNotificationAction(identifier: Self.actionLooksGood, title: "Looks good", options: [])
        let edit = UNNotificationAction(identifier: Self.actionEditSummary, title: "Edit summary", options: [.foreground])
        // MP_DONE[_<SINK>]: Open only.
        // MP_DONE_CORRECTABLE[_<SINK>]: Open + correction actions.
        // MP_DONE_CORRECTABLE_LOCAL: nothing landed, correction actions only.
        //
        // One pair per Open phrase (UX49): an action's title is fixed when its
        // category is registered, so the sink's name can only reach the button
        // through the category the banner picks. The Open action identifier is
        // the same in all of them, so `NotificationRouter` still routes on one
        // string and none of this reaches the response side.
        let doneCategories: [UNNotificationCategory] = PublishLanding.openable.flatMap {
            landing -> [UNNotificationCategory] in
            guard let phrase = landing.openPhrase else { return [] }
            let open = UNNotificationAction(
                identifier: Self.actionOpen, title: phrase, options: [.foreground]
            )
            return [(false, [open]), (true, [open, looksGood, edit])].compactMap {
                canCorrect, actions in
                guard let id = NotificationRouter.doneCategory(
                    for: landing, canCorrect: canCorrect
                ) else { return nil }
                return UNNotificationCategory(
                    identifier: id, actions: actions, intentIdentifiers: [], options: []
                )
            }
        }
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
            Set(doneCategories + [doneCorrectableLocal, perm, accessibility, stillMeeting, skipLate,
                UNNotificationCategory(identifier: NotificationRouter.failureCategory,
                    actions: [UNNotificationAction(identifier: NotificationRouter.actionOpenFailure, title: "Review failure", options: [.foreground])],
                    intentIdentifiers: [], options: [])])
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
            case .openFailure:
                let failure = failures.removeValue(forKey: id)
                let stem = failure?.1 ?? response.notification.request.content.userInfo["failureStem"] as? String
                delegate?.notifier(self, didRequestFailure: failure?.0 ?? FailurePresentation(diagnostics: ""), stem: stem)
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
