import Foundation

/// PRIMARY signal kinds the promotion engine recognises. The string
/// values double as `leadingSignal` / `confirmedBy` entries in
/// `EndingReason`, so they appear verbatim in events.jsonl and the
/// dogfood report.
public enum PrimarySignalKind: String, Equatable, CaseIterable {
    case shareableContentWindow = "shareable_content_window_gone"
    case processAudioIsRunningInput = "process_audio_is_running_input_false"
    case axLeaveButton = "ax_leave_button_invalid"
    case browserTabTitle = "browser_tab_title_left_meet_pattern"
}

/// Per-signal state passed into `PromotionEngine`. `.live` means the
/// signal observes the meeting as ongoing; `.ended` means the signal
/// observes that the meeting has ended.
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

/// Pure-logic promotion rules for `MeetingLifecycleCoordinator`.
///
/// The engine fuses PRIMARY signal events from per-app adapters and
/// produces `MeetingLifecycleVerdict` transitions. The rules:
///
///   - `.idle` -> `.starting` on the first PRIMARY `.live` event for
///     a context.
///   - `.starting` -> `.inMeeting` only when the coordinator calls
///     `confirmRecording()` after arming the recorder. Further PRIMARY
///     `.live` events while `.starting` are absorbed, not promoted:
///     `.inMeeting` means "recording confirmed", not "a signal fired".
///   - `.starting` -> `.ended` on the first PRIMARY `.ended` (the
///     meeting ended before the recorder was armed; no debounce).
///   - `.inMeeting` -> `.endingProvisional(leading:)` on the first
///     PRIMARY emitting `.ended`; `leadingSignal` is that signal's
///     name.
///   - `.endingProvisional` -> `.ended(confirmedBy:)` when (a) a
///     second PRIMARY emits `.ended` before the debounce elapses,
///     or (b) `tick(at:)` is called past `endingStartedAt + debounce`
///     and the leading signal is still `.ended`.
///   - `.endingProvisional` -> `.inMeeting` if the leading signal
///     flips back to `.live` before the debounce elapses (absorbs a
///     spurious flicker without ending the recording).
///
/// All decisions are returned as `Decision` so the caller can publish
/// the verdict + record the per-signal state change in events.jsonl.
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

    /// Ingest a PRIMARY signal event and return the verdict transition
    /// it triggered, if any. Returns nil when the event is consistent
    /// with the current phase and does not change the verdict.
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

    /// Check whether the debounce has elapsed for an in-flight
    /// `.endingProvisional` phase and promote to `.ended` when it has.
    /// No-op for every other phase. Returns the promoted verdict so
    /// the coordinator can publish it.
    public func tick(at now: Date) -> Decision? {
        guard case .endingProvisional(let context, let leading, let startedAt, let observed) = phase else {
            return nil
        }
        guard now.timeIntervalSince(startedAt) >= debounce else { return nil }
        let confirmedBy = Array(observed.subtracting([leading]).map { $0.rawValue }).sorted()
        let reason = EndingReason(leadingSignal: leading.rawValue, confirmedBy: confirmedBy)
        phase = .ended(context: context)
        return Decision(verdict: .ended(context: context, reason: reason))
    }

    /// Promote an in-flight `.starting` phase to `.inMeeting`. Called by
    /// the coordinator once the recorder is armed, so `.inMeeting`
    /// means "recording confirmed" rather than merely "a signal fired".
    /// No-op in every other phase.
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
            // Absorb the corroborating signal but stay `.starting`.
            // Promotion to `.inMeeting` is `confirmRecording()`'s job,
            // so `.inMeeting` tracks the recorder, not the signals.
            observed.insert(event.kind)
            phase = .starting(context: context, observed: observed)
            return nil
        case .ended:
            // The meeting ended before the recorder was armed (slow
            // prompt answer, or a stale discovery scan). End directly
            // so the consumer dismisses the prompt.
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
