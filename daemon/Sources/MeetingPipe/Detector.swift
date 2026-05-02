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

    /// Decide whether the current signal snapshot should fire start or end.
    ///
    ///   - Start fires when both meeting app + mic are present.
    ///     Window state is intentionally ignored at start: many meeting
    ///     apps open the mic before any window is visible.
    ///   - End fires when EITHER mic releases OR the window closes
    ///     (the meeting app staying alive in the dock isn't enough to
    ///     keep us recording — that's the regression the user hit).
    func decide() -> SignalDecision {
        if hasFiredStart {
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
        self.windowProbe = windowProbe ?? Detector.defaultWindowProbe
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
            hasFiredStart: hasFiredStart
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
                        self.hasFiredStart = true
                        self.recordingSource = src
                        Log.detector.info("→ started: \(src.bundleID)")
                        Log.writeLine("detector", "started bundle=\(src.bundleID) name=\(src.displayName)")
                        self.delegate?.detector(self, event: .started(src))
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
                        hasFiredStart: true
                    ).decide()
                    if reFired == .shouldEnd {
                        self.hasFiredStart = false
                        self.recordingSource = nil
                        Log.detector.info("→ ended (mic=\(confirmMic) window=\(confirmWindow))")
                        Log.writeLine("detector", "ended mic=\(confirmMic) window=\(confirmWindow)")
                        self.delegate?.detector(self, event: .ended)
                    }
                }
            }
        case .noChange:
            // Nothing to arm; either we're already in steady state or
            // the previous timer is still pending.
            break
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
        if let native = scanNativeApp() { return native }
        if let browser = scanBrowserTab() { return browser }
        return nil
    }

    private func scanNativeApp() -> AppSource? {
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier else { continue }
            if nativeBundles.contains(bid) {
                return AppSource(bundleID: bid, displayName: app.localizedName ?? bid)
            }
        }
        return nil
    }

    /// Reads the frontmost browser tab title via Accessibility. Degrades gracefully
    /// (returns nil) when permission isn't granted.
    private func scanBrowserTab() -> AppSource? {
        guard AXIsProcessTrusted() else { return nil }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bid = front.bundleIdentifier,
              browserBundles.contains(bid) else { return nil }

        let axApp = AXUIElementCreateApplication(front.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let win = windowRef else { return nil }

        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else { return nil }

        let lowered = title.lowercased()
        if browserURLFragments.contains(where: { lowered.contains($0) }) {
            return AppSource(bundleID: bid, displayName: front.localizedName ?? "Browser")
        }
        return nil
    }

    // MARK: Signal B

    private func micInUse() -> Bool {
        if let mic = AVCaptureDevice.default(for: .audio), mic.isInUseByAnotherApplication { return true }
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

    /// Default probe: walks the target app's AX window list looking for a
    /// "meeting word" in any window's title. When it sees one, the call
    /// is still active. When it doesn't, the call has ended (the launcher
    /// / chat / settings windows survive but lose the meeting language).
    /// When the probe genuinely can't tell — AX permission missing, AX read
    /// failed — it returns nil so the composer treats the meeting as still
    /// in progress (better to over-record than to false-stop on a missing
    /// permission).
    ///
    /// Why "no meeting word ⇒ ended" works: while the daemon is recording,
    /// our own AVAudioEngine mic capture keeps `micInUse()` returning true,
    /// so the mic signal can NEVER drop and the window probe is the only
    /// signal that can fire `.ended`. Returning nil for "windows exist but
    /// none has a meeting word" was the bug — it left recordings running
    /// for hours after the user hung up. The end-debounce (default 2-5s)
    /// absorbs transient title flips while screen-sharing or switching
    /// windows mid-call.
    private static func defaultWindowProbe(_ source: AppSource) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }

        guard let pid = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == source.bundleID
        })?.processIdentifier else {
            // App not running anymore. The meeting is definitively over.
            Log.writeLine("detector", "windowprobe app=\(source.bundleID) NOT_RUNNING → ended")
            return false
        }

        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            // AX read failed (transient). Keep it inconclusive so we don't
            // false-stop on a one-off failure.
            return nil
        }

        let meetingWords = ["meeting", "zoom meeting", "call", "huddle", "webex meeting"]
        var sawMeetingWord = false
        var anyVisible = false
        var titles: [String] = []
        for win in windows {
            var titleRef: CFTypeRef?
            let titleStatus = AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            guard titleStatus == .success, let title = titleRef as? String,
                  !title.isEmpty else { continue }
            anyVisible = true
            titles.append(title)
            let lowered = title.lowercased()
            if meetingWords.contains(where: { lowered.contains($0) }) {
                sawMeetingWord = true
            }
        }

        // Diagnostic: dump the titles we saw so we can extend the heuristic
        // if a future Teams/Zoom rev breaks the assumption. Cheap — only
        // logs while we're in a hasFiredStart context (this probe is only
        // called from currentWindowOpen, which gates on hasFiredStart).
        Log.writeLine(
            "detector",
            "windowprobe app=\(source.bundleID) titles=[\(titles.joined(separator: " | "))] meetingWord=\(sawMeetingWord) anyVisible=\(anyVisible)"
        )

        if !anyVisible { return false }
        if sawMeetingWord { return true }
        // Windows exist but none has a meeting word — the call is over.
        return false
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
