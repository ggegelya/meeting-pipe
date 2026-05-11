import AppKit
import AVFoundation
import ApplicationServices
import CoreAudio
import Foundation
import TOMLKit

protocol DetectorDelegate: AnyObject {
    func detector(_ detector: Detector, event: DetectorEvent)
}

/// Pure function describing the detector's signal-composition rules.
///
/// Lifted out of `Detector` so it can be unit-tested without the real
/// NSWorkspace / AVCapture / Accessibility plumbing. Each input is a
/// boolean derived elsewhere; this enum makes the start/end decision.
enum SignalDecision: Equatable {
    case shouldStart
    case shouldEnd
    case noChange
}

/// Inputs to the signal composer — three independent probes plus the
/// "are we currently recording" bit.
struct DetectorSignals: Equatable {
    /// Signal A — a known meeting app is running OR a meeting tab is frontmost.
    var meetingAppPresent: Bool
    /// Signal B — some application is currently capturing the mic.
    var micActive: Bool
    /// Signal C — a meeting *window* is currently open (best-effort probe).
    /// On unsupported apps this stays `true` so we don't spuriously stop
    /// recording. False is only returned when the probe is confident.
    var meetingWindowOpen: Bool
    /// Have we already emitted `.started`? Determines start vs. end semantics.
    var hasFiredStart: Bool
    /// Is the Coordinator's MeetingRecorder actively holding the input
    /// device right now? Mutually informative with `hasFiredStart`: the
    /// detector fires `.started` first and the user spends up to
    /// `prompt_timeout_sec` deciding before our tap engages. Defaults to
    /// false so existing call sites and tests covering pre-recording
    /// semantics keep working without churn.
    var recorderActive: Bool = false

    /// Decide whether the current signal snapshot should fire start or end.
    ///
    ///   - Start fires when both meeting app + mic are present.
    ///     Window state is intentionally ignored at start: many meeting
    ///     apps open the mic before any window is visible.
    ///   - End fires when EITHER mic releases OR the window closes,
    ///     UNLESS our recorder is already running. Once our own
    ///     `AVAudioEngine.inputNode` tap holds the input device, Apple's
    ///     `AVCaptureDevice.isInUseByAnotherApplication` flips false
    ///     even while the meeting app still holds the mic, because
    ///     Apple stops counting the meeting app as "another app" once
    ///     we participate in the same device. So post-record, the
    ///     mic-release signal is a structural false-positive and the
    ///     window probe alone drives end detection. Pre-record (during
    ///     the prompt window) the mic signal stays live as a fast path.
    func decide() -> SignalDecision {
        if hasFiredStart {
            if recorderActive {
                return !meetingWindowOpen ? .shouldEnd : .noChange
            }
            return (!micActive || !meetingWindowOpen) ? .shouldEnd : .noChange
        }
        return (meetingAppPresent && micActive) ? .shouldStart : .noChange
    }
}

/// Two-signal AND with debounce (SPEC §5):
///   A. Meeting app frontmost / running (native bundle ID, or browser tab title).
///   B. Microphone in use somewhere.
/// Both must hold for `debounceStartSec` before .started fires; either
/// going false for `debounceEndSec` fires .ended.
///
/// Once recording, a third signal (meeting-window-closed) also triggers
/// end. This catches the common case where Zoom/Teams keeps the input
/// device opened for a few extra seconds after a hangup.
final class Detector {
    /// Closure form of the window probe so tests can inject a fake without
    /// running Accessibility. Returns `true` when a known meeting window
    /// is currently visible, `false` only when the probe is confident
    /// the window is gone, `nil` when the probe can't tell (treated as
    /// "still open" by the composer to avoid false-stops).
    typealias WindowProbe = (AppSource) -> Bool?

    weak var delegate: DetectorDelegate?

    private let debounceStartSec: Double
    private let debounceEndSec: Double
    private let nativeBundles: Set<String>
    private let browserBundles: Set<String>
    private let browserURLFragments: [String]
    private let windowProbe: WindowProbe

    /// Signal A — last seen meeting app source (or nil).
    private var meetingApp: AppSource?
    /// Signal B — mic in use anywhere.
    private var micActive: Bool = false

    private var startTimer: Timer?
    private var endTimer: Timer?
    private var pollTimer: Timer?

    private var hasFiredStart: Bool = false
    /// True only while the Coordinator's MeetingRecorder is actually
    /// holding the input device. Distinct from `hasFiredStart`: the
    /// detector fires `.started` first, the user then sits in the
    /// prompting state for up to `prompt_timeout_sec`, and only after
    /// they click Record does our own AVAudioEngine.inputNode tap
    /// engage. The mic-probe gating (`micInUse`) keys off this, not
    /// `hasFiredStart`, so the broader CoreAudio probe stays useful
    /// during the prompt window.
    private var recorderActive: Bool = false
    private var pendingSource: AppSource?
    /// The `AppSource` that drove the current recording. Pinned at .started
    /// so the window probe knows which app to inspect.
    private var recordingSource: AppSource?

    private var nsObservers: [NSObjectProtocol] = []
    private var avObservation: NSKeyValueObservation?

    init(
        debounceStartSec: Double,
        debounceEndSec: Double,
        windowProbe: WindowProbe? = nil
    ) {
        self.debounceStartSec = debounceStartSec
        self.debounceEndSec = debounceEndSec
        let apps = Detector.loadMeetingApps()
        self.nativeBundles = apps.native
        self.browserBundles = apps.browsers
        self.browserURLFragments = apps.urlFragments
        // The default probe needs the URL fragments for the browser branch,
        // so we bake them into a closure rather than reloading the TOML
        // resource on every probe call. Tests still inject a fake.
        self.windowProbe = windowProbe ?? Detector.makeDefaultWindowProbe(
            browserURLFragments: apps.urlFragments
        )
    }

    func start() {
        wireWorkspaceObservers()
        wireMicObserver()

        // Polling backstop: AVCapture KVO has historically been flaky across
        // macOS versions (SPEC §11), and browser tabs can change without
        // workspace events. Re-evaluate every 3s.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.reevaluate()
        }
        // Run an initial evaluation so we don't miss a meeting that's already in progress.
        reevaluate()
    }

    func stop() {
        for o in nsObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        nsObservers.removeAll()
        avObservation?.invalidate()
        avObservation = nil
        pollTimer?.invalidate()
        pollTimer = nil
        startTimer?.invalidate(); startTimer = nil
        endTimer?.invalidate(); endTimer = nil
    }

    // MARK: Recorder lifecycle hooks
    //
    // The Coordinator calls these when MeetingRecorder.start succeeds /
    // when stopping flushes. They serve two purposes:
    //   1. Gate `micInUse`'s CoreAudio probe on whether OUR tap is
    //      actually holding the device, instead of on `hasFiredStart`
    //      (which becomes true the moment .started fires, before the
    //      user has even clicked Record).
    //   2. Cancel any in-flight `endTimer` armed during the prompt
    //      window from a transient pre-recording mic flicker. Without
    //      this, an endTimer armed at, say, t=2s of the prompt fires
    //      ~5s into a fresh recording and stops it within seconds.

    /// Called by the Coordinator after `recorder.start` succeeds.
    /// Threading: must be invoked on the main run loop.
    func recorderDidStart() {
        recorderActive = true
        endTimer?.invalidate()
        endTimer = nil
    }

    /// Called by the Coordinator after `recorder.stop` flushes.
    /// Threading: must be invoked on the main run loop.
    func recorderDidStop() {
        recorderActive = false
    }

    // MARK: Wiring

    private func wireWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification
        ]
        for name in names {
            let obs = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reevaluate()
            }
            nsObservers.append(obs)
        }
    }

    private func wireMicObserver() {
        // Primary: KVO on AVCaptureDevice.isInUseByAnotherApplication.
        // Secondary: Core Audio property in reevaluate() poll.
        // The KVO callback just kicks reevaluate() — that already re-runs
        // micInUse() (AV + CoreAudio) so duplicating the probes here is wasted.
        if let mic = AVCaptureDevice.default(for: .audio) {
            avObservation = mic.observe(\.isInUseByAnotherApplication, options: [.new, .initial]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.reevaluate()
                }
            }
        }
    }

    // MARK: Evaluation

    private func reevaluate() {
        // Refresh signals.
        let app = scanMeetingApp()
        let mic = micInUse()
        // Only run the AX window probe once we've fired .started — before
        // that, `decide()` ignores `meetingWindowOpen` (start fires on
        // app+mic alone) and the AX traversal is wasted work on the main
        // run loop. Pass `true` (the safe "still open" default) so the
        // composer's start path stays unaffected.
        let windowOpen = hasFiredStart ? currentWindowOpen(app: app) : true

        meetingApp = app
        micActive = mic

        let signals = DetectorSignals(
            meetingAppPresent: app != nil,
            micActive: mic,
            meetingWindowOpen: windowOpen,
            hasFiredStart: hasFiredStart,
            recorderActive: recorderActive
        )

        switch signals.decide() {
        case .shouldStart:
            // Cancel any pending end-debounce; arm start-debounce if not already firing.
            endTimer?.invalidate(); endTimer = nil
            if startTimer == nil {
                pendingSource = app
                startTimer = Timer.scheduledTimer(withTimeInterval: debounceStartSec, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.startTimer = nil
                    // Confirm both signals still on at fire time. Window
                    // state is intentionally NOT re-checked here — many
                    // meeting apps don't paint the call window until you
                    // unmute, but the detector's job is to capture from
                    // the moment audio is exchanged.
                    if self.scanMeetingApp() != nil && self.micInUse(), let src = self.pendingSource {
                        let enriched = self.enrichWithMeetingTitle(src)
                        self.hasFiredStart = true
                        self.recordingSource = enriched
                        Log.detector.info("→ started: \(enriched.bundleID)")
                        Log.writeLine("detector", "started bundle=\(enriched.bundleID) name=\(enriched.displayName) title=\(enriched.meetingTitle ?? "(none)")")
                        Log.event(category: "detector", action: "started", attributes: [
                            "bundle_id": enriched.bundleID,
                            "display_name": enriched.displayName,
                            "kind": enriched.kind == .browser ? "browser" : "native",
                            "meeting_title": enriched.meetingTitle ?? NSNull(),
                        ])
                        self.delegate?.detector(self, event: .started(enriched))
                    }
                }
            }
        case .shouldEnd:
            startTimer?.invalidate(); startTimer = nil
            pendingSource = nil
            if endTimer == nil {
                endTimer = Timer.scheduledTimer(withTimeInterval: debounceEndSec, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.endTimer = nil
                    let confirmApp = self.scanMeetingApp()
                    let confirmMic = self.micInUse()
                    let confirmWindow = self.currentWindowOpen(app: confirmApp)
                    let reFired = DetectorSignals(
                        meetingAppPresent: confirmApp != nil,
                        micActive: confirmMic,
                        meetingWindowOpen: confirmWindow,
                        hasFiredStart: true,
                        recorderActive: self.recorderActive
                    ).decide()
                    if reFired == .shouldEnd {
                        self.hasFiredStart = false
                        let endedSource = self.recordingSource
                        self.recordingSource = nil
                        Log.detector.info("→ ended (mic=\(confirmMic) window=\(confirmWindow))")
                        Log.writeLine("detector", "ended mic=\(confirmMic) window=\(confirmWindow)")
                        Log.event(category: "detector", action: "ended", attributes: [
                            "bundle_id": endedSource?.bundleID ?? NSNull(),
                            "mic_active": confirmMic,
                            "window_open": confirmWindow,
                        ])
                        self.delegate?.detector(self, event: .ended)
                    }
                }
            }
        case .noChange:
            // Snapshot is consistent with steady state, so any debounce
            // timer armed by a transient flicker is now stale and must
            // be canceled. Without this, a brief mic blip pre-recording
            // (Teams switching audio sessions when joining a call) arms
            // a 5s endTimer that fires shortly after the user clicks
            // Record, killing the recording within seconds.
            startTimer?.invalidate()
            startTimer = nil
            endTimer?.invalidate()
            endTimer = nil
            pendingSource = nil
        }
    }

    /// Resolve the window probe for the current state. Falls back to
    /// `true` when there's no app to inspect or the probe can't tell —
    /// the composer treats unknown as "still open" so we never stop
    /// recording on an inconclusive signal.
    private func currentWindowOpen(app: AppSource?) -> Bool {
        let target = recordingSource ?? app
        guard let target = target else { return true }
        return windowProbe(target) ?? true
    }

    // MARK: Signal A

    private func scanMeetingApp() -> AppSource? {
        // Browser tab with a meeting URL fragment is the more specific
        // signal: "user is actively in meet.google.com" beats "Teams is
        // sitting idle in the dock". Without this ordering, an autostarted
        // Teams in the background outranked the real Google Meet call
        // and the recordingSource got pinned to the wrong app — which
        // also broke the window-probe end signal (it inspected Teams
        // windows that had no relation to the actual call).
        if let browser = scanBrowserTab() { return browser }
        if let native = scanNativeApp() { return native }
        return nil
    }

    private func scanNativeApp() -> AppSource? {
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier else { continue }
            if nativeBundles.contains(bid) {
                return AppSource(bundleID: bid, displayName: app.localizedName ?? bid, kind: .native)
            }
        }
        return nil
    }

    /// Locate a browser whose tab title contains a known meeting URL
    /// fragment. Tries the frontmost browser's focused window first
    /// (cheap; the common case), then falls back to walking every running
    /// browser's window list — covers the user clicking another app
    /// mid-call. Degrades to nil when AX permission is missing.
    private func scanBrowserTab() -> AppSource? {
        guard AXIsProcessTrusted() else { return nil }

        // Frontmost-focused fast path.
        if let front = NSWorkspace.shared.frontmostApplication,
           let bid = front.bundleIdentifier,
           browserBundles.contains(bid),
           let title = focusedWindowTitle(forPID: front.processIdentifier),
           titleMatchesMeetingFragment(title) {
            return AppSource(bundleID: bid, displayName: front.localizedName ?? "Browser", kind: .browser)
        }

        // Background-window slow path: any running browser may host the
        // call in a window that isn't currently focused. Scoped to known
        // browser bundles so the AX traversal stays bounded.
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier,
                  browserBundles.contains(bid) else { continue }
            if anyWindowMatchesMeetingFragment(pid: app.processIdentifier) {
                return AppSource(bundleID: bid, displayName: app.localizedName ?? "Browser", kind: .browser)
            }
        }
        return nil
    }

    private func focusedWindowTitle(forPID pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let win = windowRef else { return nil }
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else { return nil }
        return title
    }

    private func anyWindowMatchesMeetingFragment(pid: pid_t) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }
        for win in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String,
                  !title.isEmpty else { continue }
            if titleMatchesMeetingFragment(title) { return true }
        }
        return false
    }

    private func titleMatchesMeetingFragment(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return browserURLFragments.contains(where: { lowered.contains($0) })
    }

    // MARK: Signal B

    private func micInUse() -> Bool {
        if let mic = AVCaptureDevice.default(for: .audio), mic.isInUseByAnotherApplication { return true }
        // Once OUR recorder is active, our own AVAudioEngine.inputNode tap
        // holds the input device, so the broad CoreAudio probe (which
        // checks kAudioDevicePropertyDeviceIsRunningSomewhere across all
        // input devices and cannot exclude self) is permanently true and
        // masks the meeting app releasing the mic. `isInUseByAnotherApplication`
        // above already excludes self by design and is sufficient to detect
        // the other app releasing, so let it carry the end signal post-record.
        //
        // Important: gate on `recorderActive`, NOT `hasFiredStart`. The
        // .started event fires the moment we detect a meeting; the user
        // then sits in the prompt for up to `prompt_timeout_sec`. During
        // that window, our tap is NOT yet engaged, so the CoreAudio probe
        // stays useful as a backup for AVCapture KVO flakiness.
        if recorderActive { return false }
        return Detector.coreAudioMicRunning()
    }

    /// Fallback Core Audio probe for kAudioDevicePropertyDeviceIsRunningSomewhere
    /// across all input devices — catches cases AVCaptureDevice misses.
    private static func coreAudioMicRunning() -> Bool {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) != noErr {
            return false
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) != noErr {
            return false
        }

        for dev in devices {
            // Only look at devices that have input streams.
            var streamSize: UInt32 = 0
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyDataSize(dev, &streamAddr, 0, nil, &streamSize) != noErr || streamSize == 0 {
                continue
            }

            var running: UInt32 = 0
            var runningSize: UInt32 = UInt32(MemoryLayout<UInt32>.size)
            var runningAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(dev, &runningAddr, 0, nil, &runningSize, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }

    // MARK: Window probe (Signal C)

    /// End-detection signal #2 (secondary). Primary is mic-release via
    /// `isInUseByAnotherApplication`, see `micInUse()`. The window probe
    /// catches the few-second tail where the meeting app keeps the input
    /// device open after hangup, and the case where AX permission is
    /// missing on the meeting app but not the mic.
    ///
    /// Branches by `source.kind`:
    ///   - `.native` apps use a per-bundle recognizer
    ///     (`isActiveMeetingWindow`) that distinguishes active call windows
    ///     from chat threads, launchers, and "Schedule Meeting" dialogs.
    ///     Unknown native bundles fall through to `nil` (inconclusive),
    ///     so mic-release alone drives end detection for them.
    ///   - `.browser` sources match the meeting URL fragments loaded from
    ///     `meeting_apps.toml`, the same signal that started detection.
    ///
    /// Returns nil when the probe can't tell (AX denied, AX read failed,
    /// or unknown-shape native bundle), so the composer treats the call
    /// as still in progress, preferring over-record to silent mid-call
    /// stops.
    private static func makeDefaultWindowProbe(
        browserURLFragments: [String]
    ) -> WindowProbe {
        return { source in
            switch source.kind {
            case .native:
                return Detector.nativeWindowProbe(source)
            case .browser:
                return Detector.browserWindowProbe(source, fragments: browserURLFragments)
            }
        }
    }

    private static func nativeWindowProbe(_ source: AppSource) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        guard let pid = pidFor(bundleID: source.bundleID) else {
            Log.writeLine("detector", "windowprobe(native) app=\(source.bundleID) NOT_RUNNING → ended")
            return false
        }
        let titles = collectAXWindowTitles(pid: pid)
        // AX read failed (transient). Keep it inconclusive so we don't
        // false-stop on a one-off failure.
        guard let titles = titles else { return nil }

        // Unknown-shape bundle: defer to mic-release. The recognizer's
        // conservative default is `false` for unknown apps, which would
        // wrongly fire end the moment the probe runs. Returning nil keeps
        // the composer in "still open" mode and lets Part 1 handle end.
        if !isKnownShapeApp(source.bundleID) {
            Log.writeLine(
                "detector",
                "windowprobe(native) app=\(source.bundleID) UNKNOWN_SHAPE → inconclusive"
            )
            return nil
        }

        let recognized = titles.first { title in
            isActiveMeetingWindow(bundleID: source.bundleID, kind: source.kind, title: title)
        }
        Log.writeLine(
            "detector",
            "windowprobe(native) app=\(source.bundleID) titles=[\(titles.joined(separator: " | "))] activeWindow=\(recognized ?? "(none)")"
        )
        if titles.isEmpty { return false }
        return recognized != nil
    }

    /// Recognize whether a window title belongs to an *active meeting
    /// window* for the given app. Distinct from the per-app extractors
    /// (`extractZoomNativeTitle` etc.): those try to pull a usable topic
    /// and return nil for valid-but-bare meeting windows. Recognition
    /// must be permissive about the bare case, because a false negative
    /// here cuts the recording mid-call.
    ///
    /// Returns `true` on positive match. The probe upstream returns true
    /// if ANY title in the app's window list recognizes; this function
    /// alone never ends recording.
    static func isActiveMeetingWindow(bundleID: String, kind: AppSourceKind, title: String) -> Bool {
        let lowered = title.lowercased().trimmingCharacters(in: .whitespaces)

        switch (bundleID, kind) {
        case ("us.zoom.xos", _):
            // Active meeting windows always end in "zoom meeting" (with
            // or without topic prefix). Idle launcher and chrome dialogs
            // are explicitly rejected so a future title format change
            // can't sneak through.
            if lowered == "zoom" { return false }                    // launcher
            if lowered.hasPrefix("schedule meeting") { return false } // dialog
            if lowered.hasPrefix("join meeting") { return false }     // dialog
            return lowered.contains("zoom meeting")

        case ("com.microsoft.teams2", .native), ("com.microsoft.teams", .native):
            // Modern Teams active meeting windows always end in
            // "| microsoft teams" AND have a meeting/call marker in the
            // leading segment. Chat threads share the suffix but their
            // lead is the chat subject, which can naturally contain
            // "meeting" or "call" as a word. Use prefix/exact match,
            // not contains, so "Sprint planning meeting" does not match.
            // "huddle" / "breakout" are rare enough in chat titles to
            // tolerate substring match.
            guard lowered.hasSuffix("| microsoft teams") else { return false }
            let lead = String(lowered.dropLast("| microsoft teams".count))
                .trimmingCharacters(in: .whitespaces)
            if lead.isEmpty { return false }                         // bare app chrome
            return lead == "meeting"
                || lead.hasPrefix("meeting in ")
                || lead.hasPrefix("meeting with ")
                || lead.hasPrefix("call with ")
                || lead == "calling"
                || lead.hasPrefix("calling ")
                || lead.contains("huddle")
                || lead.contains("breakout")

        case ("com.cisco.webexmeetingsapp", _):
            // Webex active meeting always contains "webex meeting".
            // Idle is "Webex" or "Cisco Webex".
            return lowered.contains("webex meeting")

        case ("com.tinyspeck.slackmacgap", _):
            // Slack huddles: "huddle" as a whole word, not as substring
            // of channel name. Word-boundary regex so "team-huddles"
            // (plural channel name) does not match: `s` after `huddle`
            // is alphanumeric, so the trailing word boundary fails.
            return title.range(of: #"\bhuddle\b"#, options: [.regularExpression, .caseInsensitive]) != nil

        case ("com.skype.skype", _):
            return lowered.contains("call with") || lowered.contains("group call")

        case ("com.google.meet", _):
            return lowered.contains("google meet")

        default:
            // Unknown native bundle. The probe upstream short-circuits
            // before reaching the recognizer for unknown shapes, so this
            // path is dead under normal operation; kept as a safety net.
            return false
        }
    }

    private static func isKnownShapeApp(_ bundleID: String) -> Bool {
        [
            "us.zoom.xos",
            "com.microsoft.teams2",
            "com.microsoft.teams",
            "com.cisco.webexmeetingsapp",
            "com.tinyspeck.slackmacgap",
            "com.skype.skype",
            "com.google.meet",
        ].contains(bundleID)
    }

    private static func browserWindowProbe(_ source: AppSource, fragments: [String]) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        guard let pid = pidFor(bundleID: source.bundleID) else {
            Log.writeLine("detector", "windowprobe(browser) app=\(source.bundleID) NOT_RUNNING → ended")
            return false
        }

        // Inspect the tab strip first (TECH-C3). Window titles alone
        // expose only the focused tab; if the user clicks another tab in
        // the same window, the title changes and the window probe can no
        // longer tell "tab still open in background" apart from "tab
        // closed". Tab-level AX gives each open tab its own title, so the
        // Meet tab stays detectable while unfocused — switching tabs
        // becomes a noChange and only an actual close ends the recording.
        if let tabTitles = collectAXTabTitles(pid: pid) {
            let match = anyTitleMatchesFragment(tabTitles, fragments: fragments)
            Log.writeLine(
                "detector",
                "windowprobe(browser) app=\(source.bundleID) tabs=[\(tabTitles.joined(separator: " | "))] fragmentMatch=\(match)"
            )
            // Empty tab list with a successful AX read = no tabs open
            // (last window closed, all-tabs-closed gesture). End it.
            if tabTitles.isEmpty { return false }
            return match
        }

        // AX tab traversal failed (Safari multi-window layouts that hide
        // the AXTabGroup, Edge PWAs with no tab strip, transient AX read
        // failures). Fall back to window titles so a closed last window
        // still ends the recording — we lose the in-window tab-switch
        // fidelity, which is acceptable for these niche cases.
        let titles = collectAXWindowTitles(pid: pid)
        guard let titles = titles else { return nil }
        let sawFragment = anyTitleMatchesFragment(titles, fragments: fragments)
        Log.writeLine(
            "detector",
            "windowprobe(browser) app=\(source.bundleID) windowTitles=[\(titles.joined(separator: " | "))] fragmentMatch=\(sawFragment) (tab-strip unavailable)"
        )
        if titles.isEmpty { return false }
        return sawFragment
    }

    /// Pure-string matcher lifted out so it can be unit-tested without AX.
    /// Returns true when any title contains any fragment, case-insensitive.
    static func anyTitleMatchesFragment(_ titles: [String], fragments: [String]) -> Bool {
        let lowered = fragments.map { $0.lowercased() }
        for t in titles {
            let lt = t.lowercased()
            if lowered.contains(where: { lt.contains($0) }) {
                return true
            }
        }
        return false
    }

    /// Walk the AX hierarchy of every top-level browser window for `pid`
    /// and return the title of every open tab. Returns `nil` when AX
    /// reads fail outright (Accessibility permission revoked mid-session,
    /// process gone, etc.) — distinct from "found zero tabs", which
    /// returns an empty array and means "no tabs open".
    ///
    /// Chrome / Edge expose tabs as children of the window's `AXTabGroup`
    /// (typically `AXRadioButton` items, each with the tab title as
    /// `AXTitle`). Safari uses the same role with `AXTab` items. The
    /// recursive scan bottoms out at the first `AXTabGroup` it finds in
    /// each subtree, so the traversal stays cheap.
    private static func collectAXTabTitles(pid: pid_t) -> [String]? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }
        var titles: [String] = []
        var foundAnyTabGroup = false
        for win in windows {
            findTabTitles(in: win, into: &titles, foundTabGroup: &foundAnyTabGroup, depth: 0)
        }
        // If we walked every window and never even saw a tab strip, the
        // browser layout doesn't expose tabs this way — kick to the
        // window-title fallback by returning nil rather than misreporting
        // "empty tab list" (which would falsely end the recording).
        return foundAnyTabGroup ? titles : nil
    }

    private static let maxTabScanDepth = 8

    private static func findTabTitles(
        in element: AXUIElement,
        into titles: inout [String],
        foundTabGroup: inout Bool,
        depth: Int
    ) {
        guard depth < maxTabScanDepth else { return }
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String
        if role == (kAXTabGroupRole as String) {
            foundTabGroup = true
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    var titleRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef) == .success,
                       let title = titleRef as? String, !title.isEmpty {
                        titles.append(title)
                    }
                }
            }
            return  // don't recurse into the tab strip itself
        }
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                findTabTitles(in: child, into: &titles, foundTabGroup: &foundTabGroup, depth: depth + 1)
            }
        }
    }

    /// Helpers shared by both probe variants. Extracted so the two paths
    /// stay narrow and readable, and so the AX traversal lives in one place.
    private static func pidFor(bundleID: String) -> pid_t? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID
        }?.processIdentifier
    }

    private static func collectAXWindowTitles(pid: pid_t) -> [String]? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }
        var titles: [String] = []
        for win in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String, !title.isEmpty else { continue }
            titles.append(title)
        }
        return titles
    }

    // MARK: Meeting title extraction
    //
    // Best-effort: walk the source app's AX windows once at start-fire
    // time and pull a human-readable meeting name out of the window /
    // tab title chrome. Each app has its own conventions, so the
    // extractors are per-bundle. Failures (AX denied, no match, junk
    // like a raw room code) return nil — the pipeline falls back to
    // the LLM-derived title.

    private func enrichWithMeetingTitle(_ src: AppSource) -> AppSource {
        guard AXIsProcessTrusted(),
              let pid = Detector.pidFor(bundleID: src.bundleID),
              let titles = Detector.collectAXWindowTitles(pid: pid) else {
            return src
        }
        let title = Detector.extractMeetingTitle(bundleID: src.bundleID, kind: src.kind, titles: titles)
        return AppSource(
            bundleID: src.bundleID,
            displayName: src.displayName,
            kind: src.kind,
            meetingTitle: title
        )
    }

    /// Pure function: given a bundle ID and a list of titles, return the
    /// first useful meeting name we can extract. Lifted out so it's
    /// trivially unit-testable without AX.
    static func extractMeetingTitle(bundleID: String, kind: AppSourceKind, titles: [String]) -> String? {
        switch (bundleID, kind) {
        case ("us.zoom.xos", _):
            return titles.lazy.compactMap(extractZoomNativeTitle).first
        case ("com.microsoft.teams2", .native), ("com.microsoft.teams", .native):
            return titles.lazy.compactMap(extractTeamsNativeTitle).first
        case ("com.cisco.webexmeetingsapp", _):
            return titles.lazy.compactMap(extractWebexNativeTitle).first
        case ("com.tinyspeck.slackmacgap", _):
            return titles.lazy.compactMap(extractSlackTitle).first
        default:
            if kind == .browser {
                return titles.lazy.compactMap(extractBrowserMeetingTitle).first
            }
            return nil
        }
    }

    private static func extractZoomNativeTitle(_ t: String) -> String? {
        // "<Topic> | Zoom Meeting" / "<Topic> - Zoom Meeting" / bare "Zoom Meeting"
        if let topic = firstCaptureGroup(t, pattern: #"^\s*(.+?)\s*[|\-]\s*Zoom Meeting\s*$"#),
           !topic.isEmpty, topic.lowercased() != "zoom" {
            return topic
        }
        return nil
    }

    private static func extractTeamsNativeTitle(_ t: String) -> String? {
        // Modern Teams: "Meeting in <Channel> | Microsoft Teams"
        //               "Meeting with <Person> | Microsoft Teams"
        if let topic = firstCaptureGroup(t, pattern: #"^\s*Meeting (?:in|with)\s+(.+?)\s*\|\s*Microsoft Teams\s*$"#) {
            return topic
        }
        return nil
    }

    private static func extractWebexNativeTitle(_ t: String) -> String? {
        if let topic = firstCaptureGroup(t, pattern: #"^\s*Webex Meeting\s*\|\s*(.+?)\s*$"#) {
            return topic
        }
        if let topic = firstCaptureGroup(t, pattern: #"^\s*(.+?)\s*-\s*Webex\s*$"#) {
            return topic
        }
        return nil
    }

    private static func extractSlackTitle(_ t: String) -> String? {
        // "<Channel> Huddle" → "<Channel>". Slack also uses titles like
        // "Slack | <Channel> | Huddle" depending on version; cover both.
        if let topic = firstCaptureGroup(t, pattern: #"^\s*(.+?)\s+Huddle\s*$"#) {
            return topic
        }
        if let topic = firstCaptureGroup(t, pattern: #"^\s*Slack\s*\|\s*(.+?)\s*\|\s*Huddle\s*$"#) {
            return topic
        }
        return nil
    }

    private static func extractBrowserMeetingTitle(_ t: String) -> String? {
        let lower = t.lowercased()

        if lower.contains("google meet") || lower.hasPrefix("meet ") || lower.contains(" meet -") {
            // "<Calendar event or RoomCode> - Google Meet"
            if let topic = firstCaptureGroup(t, pattern: #"^\s*(.+?)\s*-\s*Google Meet\s*$"#) {
                return isJustMeetRoomCode(topic) ? nil : topic
            }
            // Older / alternate format: "Meet - <name>"
            if let topic = firstCaptureGroup(t, pattern: #"^\s*Meet\s*-\s*(.+?)\s*$"#) {
                return isJustMeetRoomCode(topic) ? nil : topic
            }
        }

        if lower.contains("microsoft teams") {
            if let topic = firstCaptureGroup(t, pattern: #"^\s*(.+?)\s*\|\s*Microsoft Teams\s*$"#),
               topic.lowercased() != "microsoft teams" {
                return topic
            }
        }

        if lower.contains("webex") {
            if let topic = firstCaptureGroup(t, pattern: #"^\s*(.+?)\s*-\s*Webex\s*$"#) {
                return topic
            }
        }

        // Zoom web client. Skip if title is just the generic chrome.
        if lower.contains("zoom") {
            if let topic = firstCaptureGroup(t, pattern: #"^\s*(.+?)\s*[|\-]\s*Zoom\s*$"#),
               topic.lowercased() != "zoom" {
                return topic
            }
        }

        return nil
    }

    /// Google Meet ad-hoc room codes look like `abc-defg-hij`. They make
    /// terrible Notion titles, so reject them and let the LLM-derived
    /// title win as a fallback.
    private static func isJustMeetRoomCode(_ s: String) -> Bool {
        return s.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil
    }

    private static func firstCaptureGroup(_ s: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let match = regex.firstMatch(in: s, options: [], range: range), match.numberOfRanges > 1 else { return nil }
        let g = match.range(at: 1)
        guard let r = Range(g, in: s) else { return nil }
        let captured = String(s[r]).trimmingCharacters(in: .whitespaces)
        return captured.isEmpty ? nil : captured
    }

    // MARK: Resource loading

    private struct MeetingApps {
        let native: Set<String>
        let browsers: Set<String>
        let urlFragments: [String]
    }

    private static func loadMeetingApps() -> MeetingApps {
        // Bundled inside the SPM resource bundle.
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "meeting_apps", withExtension: "toml"),
              let data = try? String(contentsOf: url, encoding: .utf8),
              let toml = try? TOMLTable(string: data) else {
            Log.detector.warning("meeting_apps.toml not found; using empty lists")
            return MeetingApps(native: [], browsers: [], urlFragments: [])
        }

        let nativeArr = toml["native"]?.table?["bundle_ids"]?.array?.compactMap { $0.string } ?? []
        let urlArr = toml["browser"]?.table?["url_fragments"]?.array?.compactMap { $0.string } ?? []
        let browserArr = toml["browser"]?.table?["bundles"]?.table?["ids"]?.array?.compactMap { $0.string } ?? []

        return MeetingApps(
            native: Set(nativeArr),
            browsers: Set(browserArr),
            urlFragments: urlArr.map { $0.lowercased() }
        )
    }
}
