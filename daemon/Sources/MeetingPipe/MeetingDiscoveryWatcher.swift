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
            // DET5: log candidates that were running with evidence but did not win, before the
            // winner short-circuit, so a no-winner scan (the DET3 miss case) still records why.
            self.emitDroppedCandidates(result.droppedCandidates, hadWinner: result.winner != nil)
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

    /// Signature of the last `candidate_dropped` batch, so a dropped candidate that persists
    /// across polls is logged once, not every 3-12 s. Touched only on `scanQueue`.
    private var lastDroppedSignature: String?

    /// DET5: emit `candidate_dropped` for each running candidate that carried a meeting signal
    /// but did not win, so DET3's `mp analyze-detection` can correlate a mic-busy span with
    /// "an app was running with evidence and nothing fired" (a whitelist gap or recognizer rot).
    /// Throttled by a batch signature: a stable set of drops logs once, and the signature clears
    /// when the drops go away so a later recurrence re-logs. Runs on `scanQueue` (serial), so the
    /// signature field needs no further synchronisation. Mirrors `discovery_shadow_pick`'s attrs.
    private func emitDroppedCandidates(_ dropped: [MeetingSourceCandidate], hadWinner: Bool) {
        guard !dropped.isEmpty else { lastDroppedSignature = nil; return }
        let reason = hadWinner ? "outscored_by_winner" : "no_confident_winner"
        // Include the reason in the signature: the same dropped set with the winner-presence
        // flipped is a different fact for DET3's auditor (a candidate that went from losing to a
        // winner to being dropped with nothing firing), so it must re-log, not be throttled.
        let signature = reason + "|" + dropped
            .map { "\($0.source.bundleID):\($0.score)" }
            .sorted()
            .joined(separator: ",")
        guard signature != lastDroppedSignature else { return }
        lastDroppedSignature = signature
        for c in dropped {
            Log.event(category: "detector", action: "candidate_dropped", attributes: [
                "bundle_id": c.source.bundleID,
                "kind": c.source.kind == .browser ? "browser" : "native",
                "score": c.score,
                "reason": reason,
                "calling_controls_toolbar": c.signals.callingControlsToolbar,
                "leave_button": c.signals.leaveButton,
                "mute_button": c.signals.muteButton,
                "title_match": c.signals.titleMatch,
                "process_audio_active": c.signals.processAudioActive,
            ])
        }
    }
}
