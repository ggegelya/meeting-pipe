import Foundation

/// PRIMARY signal kinds. Raw values appear verbatim in `EndingReason` and events.jsonl.
public enum PrimarySignalKind: String, Equatable, CaseIterable {
    case shareableContentWindow = "shareable_content_window_gone"
    case processAudioIsRunningInput = "process_audio_is_running_input_false"
    case axLeaveButton = "ax_leave_button_invalid"
    case browserTabTitle = "browser_tab_title_left_meet_pattern"
    /// Meeting-app process termination (`WorkspaceSignal`). Closing a PWA's meeting window quits its process - a definitive end that needs no TCC permission.
    case workspaceAppTerminated = "workspace_app_terminated"
    /// AX window-title transition off the meeting pattern (`WindowTitleSignal`). Browser/PWA path only.
    case windowTitleLeftPattern = "window_title_left_pattern"
}

public extension PrimarySignalKind {
    /// TECH-END2: signals whose `.ended` is prone to transient AX staleness and so
    /// must not single-handedly confirm a meeting end. `axLeaveButton` reads invalid
    /// on a Teams call-UI re-render (the confirmed 2026-06-09 screen-share repro that
    /// chopped one meeting into 4 fragments); a lone, uncorroborated invalid must be
    /// held in provisional, not promoted to `.ended`, until a reliable signal
    /// (window-gone) corroborates. Reliable signals stay false here so they keep
    /// promoting on their own via the debounce, preserving the ends that already work.
    var requiresCorroboration: Bool {
        switch self {
        case .axLeaveButton:
            return true
        case .shareableContentWindow, .processAudioIsRunningInput, .browserTabTitle,
             .workspaceAppTerminated, .windowTitleLeftPattern:
            return false
        }
    }
}

/// Per-signal state fed to `PromotionEngine`.
public enum PrimarySignalState: Equatable {
    case live
    case ended
}

public struct PrimarySignalEvent: Equatable {
    public let kind: PrimarySignalKind
    public let state: PrimarySignalState
    public let timestamp: Date
    public let context: MeetingLifecycleContext

    public init(
        kind: PrimarySignalKind,
        state: PrimarySignalState,
        timestamp: Date,
        context: MeetingLifecycleContext
    ) {
        self.kind = kind
        self.state = state
        self.timestamp = timestamp
        self.context = context
    }
}

/// Pure-logic verdict state machine for `MeetingLifecycleCoordinator`.
///
/// Fuses PRIMARY signal events from per-app adapters into `MeetingLifecycleVerdict` transitions.
/// Promotion rules: `.idle` -> `.starting` on first PRIMARY `.live`; `.starting` -> `.inMeeting`
/// only via `confirmRecording()` (so `.inMeeting` means "recorder armed", not just "signal fired");
/// `.starting` -> `.ended` directly when PRIMARY `.ended` arrives before the recorder arms;
/// `.inMeeting` -> `.endingProvisional` on first PRIMARY `.ended`; `.endingProvisional` -> `.ended`
/// when a second PRIMARY confirms or the debounce elapses; `.endingProvisional` -> `.inMeeting`
/// if the leading signal flips back to `.live` (absorbs spurious flickers).
/// All decisions are returned as `Decision` so the caller can publish the verdict and log the transition.
public final class PromotionEngine {

    public static let defaultDebounce: TimeInterval = 2.0

    private enum Phase {
        case idle
        case starting(context: MeetingLifecycleContext, observed: Set<PrimarySignalKind>)
        case inMeeting(context: MeetingLifecycleContext, observed: Set<PrimarySignalKind>)
        case endingProvisional(
            context: MeetingLifecycleContext,
            leading: PrimarySignalKind,
            startedAt: Date,
            observed: Set<PrimarySignalKind>
        )
        case ended(context: MeetingLifecycleContext)
    }

    public struct Decision: Equatable {
        public let verdict: MeetingLifecycleVerdict
    }

    public let debounce: TimeInterval
    private var phase: Phase = .idle

    public init(debounce: TimeInterval = PromotionEngine.defaultDebounce) {
        self.debounce = debounce
    }

    public var debounceInterval: TimeInterval { debounce }

    public func reset() { phase = .idle }

    /// Ingest a PRIMARY signal event. Returns the verdict transition it triggered, or nil if the event doesn't change the phase.
    public func ingest(_ event: PrimarySignalEvent) -> Decision? {
        switch phase {
        case .idle:
            return handleIdle(event)
        case .starting(let context, var observed):
            return handleStarting(event, context: context, observed: &observed)
        case .inMeeting(let context, var observed):
            return handleInMeeting(event, context: context, observed: &observed)
        case .endingProvisional(let context, let leading, let startedAt, var observed):
            return handleEndingProvisional(
                event, context: context, leading: leading,
                startedAt: startedAt, observed: &observed
            )
        case .ended:
            return nil
        }
    }

    /// Promote `.endingProvisional` to `.ended` if the debounce has elapsed. No-op for every other phase.
    public func tick(at now: Date) -> Decision? {
        guard case .endingProvisional(let context, let leading, let startedAt, let observed) = phase else {
            return nil
        }
        guard now.timeIntervalSince(startedAt) >= debounce else { return nil }
        let confirmedBy = Array(observed.subtracting([leading]).map { $0.rawValue }).sorted()
        // TECH-END2: a staleness-prone leading signal (ax-leave) must not confirm an end
        // on the debounce alone. With no corroborating signal, hold in `.endingProvisional`
        // rather than emit a bare `.ended`: a transient invalid self-heals when the signal's
        // re-walk finds the control live (-> `.inMeeting`), and a real end normally corroborates
        // via window-gone (the fast path). This (with the AXLeaveButtonSignal re-walk) stops the
        // screen-share restart loop. Provisional keeps `isLive == false`, so the idle backstop's
        // native stand-down does not block it; but that backstop bounds a held end only under
        // sustained silence, so a real end whose window signal is ALSO blind (Screen-Recording
        // TCC denied, or a lingering window whose title still matches) can bleed past the end
        // while audio keeps flowing. That residual is the accepted capture-first / miss-favouring
        // trade (see the class-level note); the alternative, promoting a lone ax-leave, is the
        // screen-share false-stop this guard exists to remove.
        if leading.requiresCorroboration && confirmedBy.isEmpty {
            return nil
        }
        let reason = EndingReason(leadingSignal: leading.rawValue, confirmedBy: confirmedBy)
        phase = .ended(context: context)
        return Decision(verdict: .ended(context: context, reason: reason))
    }

    /// Promote `.starting` to `.inMeeting` once the recorder is armed. No-op in every other phase.
    public func confirmRecording() -> Decision? {
        guard case .starting(let context, let observed) = phase else { return nil }
        phase = .inMeeting(context: context, observed: observed)
        return Decision(verdict: .inMeeting(context: context))
    }

    // MARK: - Phase handlers

    private func handleIdle(_ event: PrimarySignalEvent) -> Decision? {
        guard event.state == .live else { return nil }
        phase = .starting(context: event.context, observed: [event.kind])
        return Decision(verdict: .starting(context: event.context))
    }

    private func handleStarting(
        _ event: PrimarySignalEvent,
        context: MeetingLifecycleContext,
        observed: inout Set<PrimarySignalKind>
    ) -> Decision? {
        guard event.context == context else { return nil }
        switch event.state {
        case .live:
            // Absorb; promotion to `.inMeeting` is `confirmRecording()`'s job so `.inMeeting` tracks the recorder, not signals.
            observed.insert(event.kind)
            phase = .starting(context: context, observed: observed)
            return nil
        case .ended:
            // Meeting ended before the recorder armed (slow prompt, stale discovery scan). End directly.
            let reason = EndingReason(leadingSignal: event.kind.rawValue, confirmedBy: [])
            phase = .ended(context: context)
            return Decision(verdict: .ended(context: context, reason: reason))
        }
    }

    private func handleInMeeting(
        _ event: PrimarySignalEvent,
        context: MeetingLifecycleContext,
        observed: inout Set<PrimarySignalKind>
    ) -> Decision? {
        guard event.context == context else { return nil }
        switch event.state {
        case .live:
            if observed.contains(event.kind) {
                phase = .inMeeting(context: context, observed: observed)
                return nil
            }
            observed.insert(event.kind)
            phase = .inMeeting(context: context, observed: observed)
            return nil
        case .ended:
            let reason = EndingReason(leadingSignal: event.kind.rawValue, confirmedBy: [])
            phase = .endingProvisional(
                context: context,
                leading: event.kind,
                startedAt: event.timestamp,
                observed: [event.kind]
            )
            return Decision(verdict: .endingProvisional(context: context, reason: reason))
        }
    }

    private func handleEndingProvisional(
        _ event: PrimarySignalEvent,
        context: MeetingLifecycleContext,
        leading: PrimarySignalKind,
        startedAt: Date,
        observed: inout Set<PrimarySignalKind>
    ) -> Decision? {
        guard event.context == context else { return nil }
        switch event.state {
        case .ended:
            observed.insert(event.kind)
            if event.kind != leading {
                let confirmedBy = Array(observed.subtracting([leading]).map { $0.rawValue }).sorted()
                let reason = EndingReason(leadingSignal: leading.rawValue, confirmedBy: confirmedBy)
                phase = .ended(context: context)
                return Decision(verdict: .ended(context: context, reason: reason))
            }
            phase = .endingProvisional(
                context: context, leading: leading,
                startedAt: startedAt, observed: observed
            )
            return nil
        case .live where event.kind == leading:
            phase = .inMeeting(context: context, observed: observed.subtracting([leading]))
            return Decision(verdict: .inMeeting(context: context))
        case .live:
            phase = .endingProvisional(
                context: context, leading: leading,
                startedAt: startedAt, observed: observed
            )
            return nil
        }
    }
}
