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

/// Correlation grouping for end signals (END6 / AUD-10). Signals in the SAME class can fail
/// together from one root cause, so a second signal in the same class is not independent
/// corroboration of the first. Only ax-leave + window-gone are grouped (a Teams share re-render
/// invalidates the Leave button and drops the call window together); every other signal is its
/// own class, so the cross-class corroboration that already works is unchanged.
public enum EndEvidenceClass: Equatable {
    case callWindowOrControl
    case processAudio
    case browserTabTitle
    case workspaceTermination
    case windowTitle
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

    /// The evidence class this signal belongs to (END6 / AUD-10). End corroboration must come
    /// from a DIFFERENT class to count as genuinely independent: ax-leave + window-gone share a
    /// class (correlated), so neither corroborates the other; every other signal is its own class.
    var evidenceClass: EndEvidenceClass {
        switch self {
        case .axLeaveButton, .shareableContentWindow:
            return .callWindowOrControl
        case .processAudioIsRunningInput:
            return .processAudio
        case .browserTabTitle:
            return .browserTabTitle
        case .workspaceAppTerminated:
            return .workspaceTermination
        case .windowTitleLeftPattern:
            return .windowTitle
        }
    }

    /// END5: the minimum time a `.endingProvisional` led by this signal must hold before the
    /// debounce alone promotes it to `.ended`. A plain browser meeting exposes no end signal but
    /// the active tab title (`browserTabTitle`), which flips to `.ended` on any tab switch, not
    /// just a real leave. With the short configured end-debounce a >5 s mid-call tab switch
    /// promoted straight to `.ended` and chopped the recording. No cross-class corroborator exists
    /// for a plain browser (only a full browser quit fires the cross-class `workspaceAppTerminated`),
    /// so a genuine tab-switch end can be told from a transient excursion only by waiting: hold a
    /// tab-title-led end for minutes so a returning tab reverts to `.inMeeting` (recording never
    /// stops), while a real end still promotes once the title stays gone past the floor. A browser
    /// quit (`workspaceAppTerminated`) still ends promptly on the cross-class fast path, and the
    /// idle-silence backstop remains the ceiling. Zero for every other signal, so native ends keep
    /// the configured debounce unchanged.
    var endDebounceFloor: TimeInterval {
        switch self {
        case .browserTabTitle:
            return 120
        case .shareableContentWindow, .processAudioIsRunningInput, .axLeaveButton,
             .workspaceAppTerminated, .windowTitleLeftPattern:
            return 0
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

    /// True while the engine holds a provisional end awaiting the debounce (or a
    /// corroborating signal): the only phase in which `tick(at:)` can do work.
    /// The lifecycle coordinator reads this to arm the periodic tick only when it
    /// can matter, instead of running it for the whole meeting (PERF5).
    public var hasPendingEndDeadline: Bool {
        if case .endingProvisional = phase { return true }
        return false
    }

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
        // END5: a tab-title-led browser end holds for a minutes-long floor, not the short
        // configured end-debounce, so a mid-call tab switch no longer chops the recording. Every
        // other lead uses the configured debounce (floor 0). A cross-class corroborator still
        // promotes immediately via `handleEndingProvisional`, unaffected by this floor.
        let effectiveDebounce = max(debounce, leading.endDebounceFloor)
        guard now.timeIntervalSince(startedAt) >= effectiveDebounce else { return nil }
        let confirmedBy = Array(observed.subtracting([leading]).map { $0.rawValue }).sorted()
        // TECH-END2 + END6/AUD-10: a staleness-prone leading signal (ax-leave) must not confirm
        // an end on the debounce alone, and a SAME-class signal (window-gone for an ax-leave
        // lead) is correlated, not independent, so it does not satisfy the guard either: the
        // 2026-06-09 screen-share re-render invalidated the Leave button and dropped the call
        // window together, which would otherwise chop one meeting into fragments. A genuine
        // native end is promoted promptly by `confirmProvisionalEnd`, which the daemon calls
        // once its Leave-button re-walk verifies the control is really gone; this guard is the
        // backstop for the debounce path until that re-walk (or a genuinely independent,
        // cross-class signal) corroborates. Reliable signals keep `requiresCorroboration ==
        // false` and promote here on their own.
        let crossClassCorroborated = observed.contains {
            $0 != leading && $0.evidenceClass != leading.evidenceClass
        }
        if leading.requiresCorroboration && !crossClassCorroborated {
            return nil
        }
        let reason = EndingReason(leadingSignal: leading.rawValue, confirmedBy: confirmedBy)
        phase = .ended(context: context)
        return Decision(verdict: .ended(context: context, reason: reason))
    }

    /// The daemon re-walked the AX tree and verified the leading signal's control is genuinely
    /// gone (not transient staleness; see `MeetingSessionController.rescueProvisionalEnd`). That
    /// re-walk IS the corroboration `tick()` would otherwise wait for, so promote
    /// `.endingProvisional` to `.ended` now instead of holding for a second signal that can lag
    /// minutes on native clients. `rewalkSignal` is recorded in `confirmedBy` so the end reads as
    /// corroborated. No-op in any other phase (a concurrent revert or end already handled it).
    public func confirmProvisionalEnd(rewalkSignal: String = "ax_leave_rewalk") -> Decision? {
        guard case .endingProvisional(let context, let leading, _, let observed) = phase else {
            return nil
        }
        var confirmedBy = observed.subtracting([leading]).map { $0.rawValue }
        confirmedBy.append(rewalkSignal)
        let reason = EndingReason(leadingSignal: leading.rawValue, confirmedBy: confirmedBy.sorted())
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
            // START1/AUD-1: a staleness-prone signal (ax-leave) must not single-handedly end a
            // meeting that has not started recording yet. The Teams compact/mini-window swap
            // invalidates the Leave button on a re-render; honoring it here drove the engine to a
            // terminal `.ended` while the prompt was still up, after which it absorbed every later
            // signal and the genuine end never produced a verdict (the prompt/suppression wedge).
            // Mirror the `tick()` corroboration rule: hold a lone, uncorroborated ax-leave in
            // `.starting` so the engine stays live. A later Record press still arms via
            // `confirmRecording`, discovery is never wedged, and the prompt's own timeout/Skip is
            // the bound on the held state. A reliable signal (window-gone, app-terminated,
            // title-left) keeps `requiresCorroboration == false` and still ends directly.
            if event.kind.requiresCorroboration {
                return nil
            }
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
            // END6/AUD-10: a distinct second signal confirms the end on this fast path only
            // when it is in a DIFFERENT evidence class than the leading signal. ax-leave and
            // window-gone are one class (a Teams share re-render invalidates the Leave button
            // and drops the call window together), so the pair can no longer instant-confirm
            // each other; a same-class second signal is absorbed, and the AX re-walk
            // (confirmProvisionalEnd) or a genuinely independent signal must corroborate.
            if event.kind != leading && event.kind.evidenceClass != leading.evidenceClass {
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
        case .live where event.kind.evidenceClass == leading.evidenceClass:
            // END8: a returning signal reverts the provisional when it shares the leading
            // signal's evidence class, not only when it is the same kind. A window-gone lead
            // (an off-screen native window, `onScreenWindowsOnly`) is reverted by the AX
            // rescue's healthy Leave button (both `.callWindowOrControl`), so minimizing a
            // meeting no longer chops the recording. A cross-class `.live` still cannot revert.
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
