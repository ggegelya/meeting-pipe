import Foundation
import MeetingPipeCore

/// END28: a split waiting for the stop it triggered to finish. `source` is the same app carrying the
/// new call's title, so the prompt, the workflow match and the second stem's sidecar name call B,
/// not call A.
struct PendingCallSplit {
    let source: AppSource
    let stem: String
}

/// END28: one recording per call. A quick switch from one Teams call to another makes every
/// app-level end signal live again within seconds, so END17's hold reverted and the second call
/// recorded into the first call's stem (`20261112-172307`, three calls in one note). The window that
/// holds the call's Leave control carries the meeting subject; when it changes to another window
/// with another title, and holds (`CallIdentityTracker`), the recording ends there and the record
/// prompt is raised for the new call. The owner's decision (2026-11-16): split, then prompt. An
/// ignored prompt falls to DET18's one-click offer like any other, so the second call is recorded
/// only on a yes.
extension MeetingSessionController {

    /// How often the running recording's call window is read. The Leave signal throttles its own
    /// window read to the same rate, so a faster tick would only see the same cached read.
    static let callIdentityTickSec: TimeInterval = 2

    /// Armed at a native recording's commit, so a change of call can split it. A browser meeting
    /// has no Leave control to read (and is out of END28's scope); a manual recording has no app.
    func armCallIdentityWatch(file: URL, source: AppSource?) {
        assertMainQueue()
        disarmCallIdentityWatch()
        callIdentity = CallIdentityTracker()
        guard let source, source.kind == .native else { return }
        let interval = MeetingSessionController.callIdentityTickSec
        cancelCallIdentityTimer = Schedulers.mainRunLoopRepeating(
            every: interval,
            firstFire: Date().addingTimeInterval(interval),
            tolerance: 0.5
        ) { [weak self] in
            self?.callIdentityTick(file: file, now: Date())
        }
    }

    func disarmCallIdentityWatch() {
        assertMainQueue()
        cancelCallIdentityTimer?()
        cancelCallIdentityTimer = nil
    }

    /// One read of the call window against the recording's identity. Internal so tests drive it on
    /// a virtual clock instead of the timer.
    func callIdentityTick(file: URL, now: Date) {
        assertMainQueue()
        guard case .recording(let current, let source, let mode) = coordinator.stateMachine.current,
              current == file, let source else { return }
        // A split stops the recording, and resetting it would close an off-the-record span the
        // owner opened on purpose; the identity is read again once the span is closed.
        if isOffTheRecord { return }
        let read = coordinator.lifecycleCoord.callWindow
        let action = callIdentity.observe(read, appName: source.displayName, holdOpen: holdPolicy.isOpen, at: now)
        switch action {
        case .none:
            return
        case .adopted(let identity):
            Log.event(category: "signal", action: "call_identity_observed", attributes: [
                "bundle_id": source.bundleID,
                // SEC38: the title's shape class, never the meeting subject; `window` tells a split apart.
                "shape": MeetingTitlePatterns.windowShape(bundleID: source.bundleID, title: identity.title),
                "window": Int(identity.windowID),
                "subrole": identity.subrole ?? NSNull(),
                "change": "adopted",
            ])
        case .split(let from, let to):
            let stem = file.deletingPathExtension().lastPathComponent
            var attributes: [String: Any] = [
                "bundle_id": source.bundleID,
                "split_from": stem,
                "from_shape": MeetingTitlePatterns.windowShape(bundleID: source.bundleID, title: from.title),
                "to_shape": MeetingTitlePatterns.windowShape(bundleID: source.bundleID, title: to.title),
            ]
            if let hold = holdPolicy.hold {
                attributes["since_hold_start_sec"] = now.timeIntervalSince(hold.startedAt)
            }
            Log.event(category: "signal", action: "call_identity_observed", attributes: [
                "bundle_id": source.bundleID,
                "shape": MeetingTitlePatterns.windowShape(bundleID: source.bundleID, title: to.title),
                "window": Int(to.windowID),
                "subrole": to.subrole ?? NSNull(),
                "change": "split",
            ])
            Log.event(category: "coordinator", action: "recording_split_on_call_change", attributes: attributes)
            Log.writeLine("daemon", "\(source.bundleID) changed call → ending \(stem) and prompting for the new one")
            pendingSplit = PendingCallSplit(
                source: AppSource(
                    bundleID: source.bundleID,
                    displayName: source.displayName,
                    kind: source.kind,
                    meetingTitle: to.title
                ),
                stem: stem
            )
            stopRecording(file: file, source: source, summaryMode: mode, stopRoute: "call_changed")
        }
    }

    /// Whether the prompt up for `source` was raised by a split. Its timeout always becomes DET18's
    /// one-click offer, whatever `default_prompt_action` says: the owner's decision is that the
    /// second call is recorded only on a yes. The offer does not carry `split_from` on (a link that
    /// outlived the prompt could attach to a later call of the same app), so a recording started
    /// from it is unlinked; the link is informational.
    func isSplitPrompt(for source: AppSource) -> Bool {
        assertMainQueue()
        return pendingSplitFrom?.source == source
    }

    /// The tail of a split's stop: prompt for the new call. Called from `resetAfterStop`, so it
    /// runs once the first stem is flushed whichever stop path finished it. Only from `.idle` with
    /// no start in flight; a Stop pressed meanwhile already dropped the split.
    func raisePendingSplitPrompt() {
        assertMainQueue()
        guard let split = pendingSplit else { return }
        pendingSplit = nil
        guard case .idle = coordinator.stateMachine.current, !startLatch.isInFlight else {
            Log.event(category: "coordinator", action: "recording_split_prompt_skipped", attributes: [
                "bundle_id": split.source.bundleID,
                "split_from": split.stem,
                "state": DetectionStateMachine.label(coordinator.stateMachine.current),
            ])
            return
        }
        // The stop that ended the first call armed the re-prompt cooldown for this app, and a
        // just-withdrawn prompt's backoff may still cover it; neither is about this new call.
        coordinator.stateMachine.clearSuppression(bundleID: split.source.bundleID)
        if promptBackoff?.bundleID == split.source.bundleID { promptBackoff = nil }
        presentPrompt(for: split.source)
        // After `presentPrompt`, whose routing reset would drop it: keyed to this prompt's source
        // and cleared on every prompt exit, so it reaches only a start this prompt answers.
        pendingSplitFrom = (source: split.source, stem: split.stem)
    }
}
