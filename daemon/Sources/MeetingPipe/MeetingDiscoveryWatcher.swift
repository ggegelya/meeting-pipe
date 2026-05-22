import AppKit
import AVFoundation
import Foundation
import MeetingPipeCore

/// Cold-start meeting discovery (TECH-C13 step 5).
///
/// Workspace-observer + mic-KVO + 3 s-poll wiring that drives the
/// `MeetingSourceScanner` and reports the winning source through
/// `onDiscovered`. Each winner change is also logged as
/// `discovery_shadow_pick` for the event log.
final class MeetingDiscoveryWatcher {

    /// Called on the main queue each time a scan finds a winning
    /// meeting source. The owner gates on its own state to decide
    /// whether to act; leaving this nil keeps the watcher silent.
    var onDiscovered: ((AppSource) -> Void)?

    private let scanner = MeetingSourceScanner()

    private var nsObservers: [NSObjectProtocol] = []
    private var avObservation: NSKeyValueObservation?
    private var pollTimer: Timer?

    /// Coalesces bursts of triggers (Cmd+Tab fires didDeactivate +
    /// didActivate back to back) into a single scan.
    private var coalesceWork: DispatchWorkItem?
    private static let coalesceWindow: TimeInterval = 0.08

    /// Off-main, serial: AX cross-process reads can take tens of ms, so
    /// running the scan on main would stall the UI on every workspace
    /// activation. Serial so the scanner's sticky-winner pin is never
    /// touched concurrently.
    private let scanQueue = DispatchQueue(
        label: "com.meetingpipe.MeetingDiscoveryWatcher.scan",
        qos: .userInitiated
    )

    func start() {
        wireWorkspaceObservers()
        wireMicObserver()
        // Polling backstop: AVCapture KVO has historically been flaky
        // across macOS versions, and browser tabs can change without a
        // workspace event. Re-scan every 3 s.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.scheduleScan(triggerBundle: nil)
        }
        // Initial pass so a meeting already in progress is seen at launch.
        scheduleScan(triggerBundle: nil)
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

    /// Kick an immediate scan, bypassing the poll interval. The
    /// Coordinator calls this on a permission grant so an in-progress
    /// meeting is picked up the moment Accessibility / Mic flips on.
    func refreshNow() {
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
                let bid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                self?.scheduleScan(triggerBundle: bid)
            }
            nsObservers.append(obs)
        }
    }

    private func wireMicObserver() {
        if let mic = AVCaptureDevice.default(for: .audio) {
            avObservation = mic.observe(\.isInUseByAnotherApplication, options: [.new, .initial]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    // Mic KVO has no triggering bundle id; pass nil so the
                    // fast-exit is bypassed and the scan always runs.
                    self?.scheduleScan(triggerBundle: nil)
                }
            }
        }
    }

    /// Schedule a coalesced scan. Skips entirely when a workspace
    /// notification names an app that is neither a known meeting app, a
    /// browser, nor a Chromium PWA, so Cmd+Tab between unrelated apps
    /// never triggers an AX walk. A nil `triggerBundle` (mic KVO, poll,
    /// initial pass) always scans. Caller must be on the main run loop.
    private func scheduleScan(triggerBundle: String?) {
        if let bid = triggerBundle,
           !scanner.nativeBundles.contains(bid),
           !scanner.browserBundles.contains(bid),
           !BrowserMeetingLifecycleAdapter.isPWABundleID(bid) {
            return
        }
        coalesceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runScan() }
        coalesceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceWindow, execute: work)
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
            // Report every scan that has a winner; the owner gates on
            // its own state. This keeps re-discovery working when a
            // meeting ends and the same app is rejoined.
            let source = winner.source
            DispatchQueue.main.async { [weak self] in
                self?.onDiscovered?(source)
            }
        }
    }
}
