import AppKit
import AVFoundation
import ApplicationServices
import CoreAudio
import Foundation
import TOMLKit

protocol DetectorDelegate: AnyObject {
    func detector(_ detector: Detector, event: DetectorEvent)
}

/// Two-signal AND with debounce (SPEC §5):
///   A. Meeting app frontmost / running (native bundle ID, or browser tab title).
///   B. Microphone in use somewhere.
/// Both must hold for `debounceStartSec` before .started fires; either
/// going false for `debounceEndSec` fires .ended.
final class Detector {
    weak var delegate: DetectorDelegate?

    private let debounceStartSec: Double
    private let debounceEndSec: Double
    private let nativeBundles: Set<String>
    private let browserBundles: Set<String>
    private let browserURLFragments: [String]

    /// Signal A — last seen meeting app source (or nil).
    private var meetingApp: AppSource?
    /// Signal B — mic in use anywhere.
    private var micActive: Bool = false

    private var startTimer: Timer?
    private var endTimer: Timer?
    private var pollTimer: Timer?

    private var hasFiredStart: Bool = false
    private var pendingSource: AppSource?

    private var nsObservers: [NSObjectProtocol] = []
    private var avObservation: NSKeyValueObservation?

    init(debounceStartSec: Double, debounceEndSec: Double) {
        self.debounceStartSec = debounceStartSec
        self.debounceEndSec = debounceEndSec
        let apps = Detector.loadMeetingApps()
        self.nativeBundles = apps.native
        self.browserBundles = apps.browsers
        self.browserURLFragments = apps.urlFragments
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
        // Refresh both signals.
        let a = scanMeetingApp()
        let b = micInUse()

        meetingApp = a
        micActive = b

        let bothOn = (a != nil) && b

        if bothOn {
            // Cancel any pending end-debounce; arm start-debounce if not already firing.
            endTimer?.invalidate(); endTimer = nil
            if hasFiredStart {
                // Already in a meeting. Don't re-emit .started even if the
                // user switches from Zoom to a Meet tab mid-call — Coordinator
                // owns the active recording and treats it as one meeting.
                return
            }
            if startTimer == nil {
                pendingSource = a
                startTimer = Timer.scheduledTimer(withTimeInterval: debounceStartSec, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.startTimer = nil
                    // Confirm both still on at fire time.
                    if self.scanMeetingApp() != nil && self.micInUse(), let src = self.pendingSource {
                        self.hasFiredStart = true
                        Log.detector.info("→ started: \(src.bundleID)")
                        Log.writeLine("detector", "started bundle=\(src.bundleID) name=\(src.displayName)")
                        self.delegate?.detector(self, event: .started(src))
                    }
                }
            }
        } else {
            startTimer?.invalidate(); startTimer = nil
            pendingSource = nil
            if hasFiredStart && endTimer == nil {
                endTimer = Timer.scheduledTimer(withTimeInterval: debounceEndSec, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.endTimer = nil
                    if self.scanMeetingApp() == nil || !self.micInUse() {
                        self.hasFiredStart = false
                        Log.detector.info("→ ended")
                        Log.writeLine("detector", "ended")
                        self.delegate?.detector(self, event: .ended)
                    }
                }
            }
        }
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
