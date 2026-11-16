import Foundation
import MeetingPipeCore

/// END23: the Teams mic-release ceiling at the session spine. `MicReleaseCeiling` (Core, pure)
/// decides; this side owns the per-recording timer, the read of DET23's monitor, the wall-clock
/// anchor of the cut, and the stop. It is independent of the end engine by design: it reads no
/// verdict, and stops a recording whose engine is live, holding, ended or never engaged.
extension MeetingSessionController {

    /// The monitor publishes once a second; reading it faster sees the same sample.
    static let micReleaseCeilingTickSec: TimeInterval = 1

    /// Armed at the commit of a native Teams recording (prompt, explicit, resumed or split start all
    /// commit here). Anything else is left to the engine, the idle backstop and END11.
    func armMicReleaseCeiling(file: URL, source: AppSource?) {
        disarmMicReleaseCeiling()
        guard MicReleaseCeiling.applies(toBundleID: source?.bundleID, isNative: source?.kind == .native) else { return }
        micReleaseCeiling = MicReleaseCeiling(recordingStartedAt: coordinator.micHolderFeed.currentSnapshot().at)
        let interval = MeetingSessionController.micReleaseCeilingTickSec
        cancelMicReleaseCeilingTimer = Schedulers.mainRunLoopRepeating(
            every: interval,
            firstFire: Date().addingTimeInterval(interval),
            tolerance: 0.2
        ) { [weak self] in
            self?.micReleaseCeilingTick(file: file, now: Date())
        }
    }

    func disarmMicReleaseCeiling() {
        cancelMicReleaseCeilingTimer?()
        cancelMicReleaseCeilingTimer = nil
        micReleaseCeiling = nil
        micReleaseCutAt = nil
    }

    /// One read of the monitor against the running recording. Internal so tests drive it with a
    /// stated snapshot instead of the timer; `now` is the wall clock the cut is anchored on.
    func micReleaseCeilingTick(file: URL, now: Date) {
        // The recording this timer was armed for, still running: a stop already in flight, a split,
        // or a newer recording all leave this tick with nothing to do.
        guard case .recording(let current, let source, let mode) = coordinator.stateMachine.current,
              current == file, var ceiling = micReleaseCeiling else { return }
        let snapshot = coordinator.micHolderFeed.currentSnapshot()
        let decision = ceiling.observe(snapshot)
        micReleaseCeiling = ceiling
        switch decision {
        case .none:
            return
        case .releaseStarted(let cut):
            // Anchored now, about a second after the release, so a sleep before the stop (the
            // monitor's clock stops across it, the wall clock does not) cannot move the cut.
            micReleaseCutAt = now.addingTimeInterval(-(snapshot.at - cut))
        case .stop(let cut, let releasedSeconds):
            let cutAt = micReleaseCutAt ?? now.addingTimeInterval(-(snapshot.at - cut))
            stopForMicReleaseCeiling(file: file, source: source, mode: mode, cutAt: cutAt, countedSeconds: releasedSeconds, now: now)
        }
    }

    private func stopForMicReleaseCeiling(
        file: URL, source: AppSource?, mode: SummaryMode, cutAt: Date, countedSeconds: Double, now: Date
    ) {
        let holdOpen = holdPolicy.isOpen
        Log.event(category: "coordinator", action: "mic_release_ceiling_stop", attributes: [
            "bundle_id": source?.bundleID ?? "manual",
            "file": file.lastPathComponent,
            "released_at": cutAt,
            "released_sec": now.timeIntervalSince(cutAt),
            "counted_sec": countedSeconds,
            "engine_phase": Self.enginePhase(coordinator.lifecycleCoord),
            "hold_open": holdOpen,
            // What the cross-class signal said, so a ceiling stop over a live Leave button is
            // findable at the owner's walkthrough.
            "live_signal": coordinator.liveCallSignal.rawValue,
        ])
        Log.writeLine(
            "daemon",
            "Teams has not held the microphone for \(Int(MicReleaseCeiling.ceilingSeconds)) s → stopping (END23)"
        )
        // Released, not concluded: END21's Stop rule would refuse the cut whenever the engine still
        // reads the mic live, and this stop's evidence is the monitor, not the engine. Releasing first
        // also stops the hold's timer and clears the HUD's Confirming end before the stop.
        releaseTeardownHold()
        pendingEndTrimAt = cutAt
        stopRecording(file: file, source: source, summaryMode: mode, stopRoute: "mic_release_ceiling")
    }

    static func enginePhase(_ lifecycle: MeetingLifecycleCoordinator) -> String {
        guard lifecycle.isEngaged else { return "not_engaged" }
        switch lifecycle.current {
        case .idle: return "idle"
        case .starting: return "starting"
        case .inMeeting: return "in_meeting"
        case .endingProvisional: return "ending_provisional"
        case .ended: return "ended"
        }
    }
}
