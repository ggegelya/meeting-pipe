import AppKit
import AVFoundation
import Foundation
import MeetingPipeCore

/// Drives `MeetingSourceScanner` via workspace observers, mic KVO, and a 3 s poll, reporting the winning source through `onDiscovered` (TECH-C13 step 5). Winner changes are logged as `discovery_shadow_pick`.
final class MeetingDiscoveryWatcher {

    /// Called on main queue when a scan finds a winner. Owner gates on its own state; nil keeps the watcher silent.
    var onDiscovered: ((AppSource) -> Void)?

    private let scanner = MeetingSourceScanner()

    private var nsObservers: [NSObjectProtocol] = []
    private var avObservation: NSKeyValueObservation?
    private var pollTimer: Timer?

    /// PERF6: the backstop poll runs `active` (3 s) while workspace/mic activity is arriving and backs
    /// off to `idle` (12 s) once a poll passes quiet, so an idle meeting app (e.g. Teams in the
    /// background) is no longer AX-walked every 3 s all day. Driven on main only (see the type's note).
    private var cadence = DiscoveryScanCadence(active: 3, idle: 12)

    /// Coalesces bursts (Cmd+Tab fires didDeactivate + didActivate back to back) into a single scan.
    private var coalesceWork: DispatchWorkItem?
    private static let coalesceWindow: TimeInterval = 0.08

    /// AX cross-process reads can take tens of ms; off-main prevents UI stalls. Serial so the scanner's sticky-winner pin is never touched concurrently.
    private let scanQueue = DispatchQueue(
        label: "com.meetingpipe.MeetingDiscoveryWatcher.scan",
        qos: .userInitiated
    )

    func start() {
        wireWorkspaceObservers()
        wireMicObserver()
        // AVCapture KVO has been flaky across macOS versions; browser tabs change without workspace events,
        // so an adaptive backstop poll covers the gaps (PERF6: 3 s active, 12 s idle). Just-launched counts
        // as activity so the first backstop runs fast, then it backs off if nothing is happening.
        cadence.noteActivity()
        armPollTimer()
        scheduleScan(triggerBundle: nil) // initial pass for a meeting already in progress at launch
    }

    /// Arm the backstop poll for the cadence's next interval. The timer is one-shot and re-arms itself,
    /// so the interval adapts each fire (active while workspace/mic activity arrives, idle once quiet).
    private func armPollTimer() {
        pollTimer?.invalidate()
        let interval = cadence.intervalAfterPoll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.scheduleScan(triggerBundle: nil)
            self.armPollTimer()
        }
    }

    func stop() {
        for o in nsObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        nsObservers.removeAll()
        avObservation?.invalidate()
        avObservation = nil
        pollTimer?.invalidate()
        pollTimer = nil
        coalesceWork?.cancel()
        coalesceWork = nil
    }

    /// Immediate scan, bypassing the poll interval. Called by Coordinator on permission grant so an in-progress meeting is picked up the moment Accessibility/Mic flips on.
    func refreshNow() {
        cadence.noteActivity()
        scheduleScan(triggerBundle: nil)
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
            let obs = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self = self else { return }
                let bid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                if let bid = bid, self.isMeetingBundle(bid) { self.cadence.noteActivity() }
                self.scheduleScan(triggerBundle: bid)
            }
            nsObservers.append(obs)
        }
    }

    private func wireMicObserver() {
        if let mic = AVCaptureDevice.default(for: .audio) {
            avObservation = mic.observe(\.isInUseByAnotherApplication, options: [.new, .initial]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.cadence.noteActivity() // mic grabbed/released: a meeting may be starting
                    self.scheduleScan(triggerBundle: nil) // nil bypasses the fast-exit so the scan always runs
                }
            }
        }
    }

    /// Schedule a coalesced scan. Skips when `triggerBundle` is a non-meeting app (prevents an AX walk on every Cmd+Tab). A nil trigger (mic KVO, poll, initial pass) always scans. Must be called on the main run loop.
    private func scheduleScan(triggerBundle: String?) {
        if let bid = triggerBundle, !isMeetingBundle(bid) {
            return
        }
        coalesceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runScan() }
        coalesceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceWindow, execute: work)
    }

    /// A bundle whose windows we scan: a native meeting app, a browser, or a Chromium PWA.
    private func isMeetingBundle(_ bid: String) -> Bool {
        scanner.nativeBundles.contains(bid)
            || scanner.browserBundles.contains(bid)
            || BrowserMeetingLifecycleAdapter.isPWABundleID(bid)
    }

    private func runScan() {
        scanQueue.async { [weak self] in
            guard let self = self else { return }
            let result = self.scanner.scan(keepStickyOnEmpty: false)
            guard let winner = result.winner else { return }
            if result.winnerChanged {
                Log.event(category: "detector", action: "discovery_shadow_pick", attributes: [
                    "winner_bundle_id": winner.source.bundleID,
                    "winner_kind": winner.source.kind == .browser ? "browser" : "native",
                    "winner_score": winner.score,
                    "candidate_count": result.candidateCount,
                    "calling_controls_toolbar": winner.signals.callingControlsToolbar,
                    "leave_button": winner.signals.leaveButton,
                    "mute_button": winner.signals.muteButton,
                    "title_match": winner.signals.titleMatch,
                    "process_audio_active": winner.signals.processAudioActive,
                ])
            }
            // Report every winner, not just changes; keeps re-discovery working when the same app is rejoined.
            let source = winner.source
            DispatchQueue.main.async { [weak self] in
                self?.onDiscovered?(source)
            }
        }
    }
}
