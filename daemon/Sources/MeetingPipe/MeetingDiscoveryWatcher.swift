import AppKit
import AVFoundation
import Foundation
import MeetingPipeCore

/// Drives `MeetingSourceScanner` via workspace observers, mic KVO, and a 3 s poll, reporting the winning source through `onDiscovered` (TECH-C13 step 5). Winner changes are logged as `discovery_shadow_pick`.
final class MeetingDiscoveryWatcher {

    /// Called on main queue when a scan finds a winner. Owner gates on its own state; nil keeps the watcher silent.
    var onDiscovered: ((AppSource) -> Void)?

    /// DET1: called on main when a sustained mic-busy dwell with no whitelist winner should raise a
    /// quiet generic prompt. The owner routes it through the normal prompt path so the skip-latch,
    /// reprompt cooldown, and auto-consent all apply.
    var onMicInUseDwell: ((AppSource) -> Void)?

    /// DET1: reports, on main every scan/poll, the bundle whose mic is currently held (the open,
    /// debounced mic-busy span), or nil when the mic is idle. The owner stops a DET1-initiated
    /// recording once its bundle is no longer the held one - a LEVEL check, not a one-shot edge, so
    /// it also catches a recording that started AFTER its span already closed (a late prompt answer,
    /// a slow recorder bring-up). This is the reliable end for a permission-light DET1 recording,
    /// which engages no lifecycle and can starve the idle backstop of a mic-gate verdict. The
    /// release debounce means a brief flap keeps the span open, so this never false-stops.
    var onMicBusyBundle: ((String?) -> Void)?

    private let scanner = MeetingSourceScanner()

    /// DET1: the mic-busy span start for which the tier has already prompted, so it fires at most
    /// once per span (the session's cooldown / skip-latch then govern any repeat). Main-queue only.
    private var micTierFiredForSpanSince: Date?
    /// DET1: the "catch-all" set - browsers (an unlisted-domain call has no whitelist title match)
    /// and the adapterless mic-plausible apps (FaceTime/Discord/WhatsApp/Telegram). Native whitelist
    /// apps are DELIBERATELY excluded: discovery owns them, and a native pre-join holds the mic
    /// before its meeting window appears, so letting DET1 prompt there would pre-empt the real
    /// detection (blocking its lifecycle end-detection) and could name the wrong frontmost app. DET1
    /// catches only what the whitelist structurally cannot see.
    private lazy var plausibleBundles: Set<String> =
        scanner.browserBundles
            .union(MeetingAppRegistry.shared.micPlausibleBundles)

    private var nsObservers: [NSObjectProtocol] = []
    private var avObservation: NSKeyValueObservation?
    private var pollTimer: Timer?

    /// The default audio input, retained so both the KVO and the backstop poll can sample its
    /// busy state (DET3). Resolved once in `wireMicObserver`.
    private var micDevice: AVCaptureDevice?
    /// DET3: mic-busy span state machine. Fed on every mic KVO fire and every poll; emits
    /// `mic_busy_started` / `mic_busy_ended`. Main-queue only.
    private var micBusyTracker = MicBusySpanTracker()

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
            self.sampleMicBusy() // DET3: poll-driven backstop for a missed mic KVO edge
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
        // DET3: force-close any open mic-busy span so its duration is recorded, not lost at
        // shutdown. Force (bypasses the debounce) and does NOT fire onMicBusyBundle: a shutdown is
        // not a call ending, so it must not stop a recording.
        emitMicBusy(micBusyTracker.forceClose(at: Date()))
        micDevice = nil
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
        guard let mic = AVCaptureDevice.default(for: .audio) else { return }
        micDevice = mic
        avObservation = mic.observe(\.isInUseByAnotherApplication, options: [.new, .initial]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.sampleMicBusy() // DET3: record the mic-busy span
                self.cadence.noteActivity() // mic grabbed/released: a meeting may be starting
                self.scheduleScan(triggerBundle: nil) // nil bypasses the fast-exit so the scan always runs
            }
        }
    }

    /// DET3: sample the mic-busy state and log a `mic_busy_started` / `mic_busy_ended` span
    /// transition. Driven by the mic KVO and the backstop poll (the KVO has been flaky across
    /// macOS versions, so the poll is the reliability backstop, and the tracker is idempotent so a
    /// double-sample is a no-op). Main-queue only.
    private func sampleMicBusy() {
        guard let mic = micDevice else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let transition = micBusyTracker.update(
            busy: mic.isInUseByAnotherApplication,
            at: Date(),
            frontmostBundle: front?.bundleIdentifier,
            frontmostName: front?.localizedName
        )
        emitMicBusy(transition)
        // DET1: report the currently-held bundle (nil when released) so the owner can stop a DET1
        // recording whose app is no longer holding the mic. A level check, so it also catches a
        // recording that started after its span closed. `open` is the debounced span, so a flap
        // (still open) reports the same bundle and never false-stops.
        onMicBusyBundle?(micBusyTracker.open?.bundleID)
    }

    private func emitMicBusy(_ transition: MicBusySpanTracker.Transition?) {
        switch transition {
        case .started(let bundle, let name):
            Log.event(category: "detector", action: "mic_busy_started", attributes: [
                "bundle_id": bundle ?? "unknown",
                "display_name": name ?? "",
            ])
        case .ended(let bundle, let name, let dur):
            Log.event(category: "detector", action: "mic_busy_ended", attributes: [
                "bundle_id": bundle ?? "unknown",
                "display_name": name ?? "",
                "duration_sec": dur,
            ])
        case nil:
            break
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
            if let winner = result.winner, result.winnerChanged {
                Log.event(category: "detector", action: "discovery_shadow_pick", attributes: [
                    "winner_bundle_id": winner.source.bundleID,
                    "winner_kind": winner.source.kind == .browser ? "browser" : "native",
                    "winner_score": winner.score,
                    "candidate_count": result.candidateCount,
                    "calling_controls_toolbar": winner.signals.callingControlsToolbar,
                    "leave_button": winner.signals.leaveButton,
                    "mute_button": winner.signals.muteButton,
                    "title_match": winner.signals.titleMatch,
                ])
            }
            // Report every winner, not just changes; keeps re-discovery working when the same app is
            // rejoined. Hop to main even on a no-winner scan, because that is exactly when DET1's
            // mic-in-use tier fires.
            let winnerSource = result.winner?.source
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let winnerSource { self.onDiscovered?(winnerSource) }
                self.evaluateMicInUseTier(hasWinner: winnerSource != nil)
            }
        }
    }

    /// DET1: after a scan, check whether the current mic-busy dwell (with no whitelist winner)
    /// warrants a quiet generic prompt for the plausible holder. Fires at most once per span; the
    /// session's cooldown / skip-latch then govern any repeat. Main-queue only.
    private func evaluateMicInUseTier(hasWinner: Bool) {
        guard let span = micBusyTracker.open else {
            micTierFiredForSpanSince = nil // mic idle: reset the per-span latch
            return
        }
        guard micTierFiredForSpanSince != span.since else { return } // already prompted this span
        let now = Date()
        let kind: AppSourceKind = scanner.browserBundles.contains(span.bundleID ?? "") ? .browser : .native
        guard let source = MicInUseTier.decide(
            dwellSec: max(0, now.timeIntervalSince(span.since)),
            threshold: MicInUseTier.defaultDwellSec,
            hasScannerWinner: hasWinner,
            bundleID: span.bundleID,
            displayName: span.displayName,
            kind: kind,
            plausibleBundles: plausibleBundles
        ) else { return }
        micTierFiredForSpanSince = span.since
        Log.event(category: "detector", action: "mic_in_use_prompt", attributes: [
            "bundle_id": source.bundleID,
            "display_name": source.displayName,
            "kind": source.kind == .browser ? "browser" : "native",
            "dwell_sec": now.timeIntervalSince(span.since),
        ])
        onMicInUseDwell?(source)
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
            ])
        }
    }
}
