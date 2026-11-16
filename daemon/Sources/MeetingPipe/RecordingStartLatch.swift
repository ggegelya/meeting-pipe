import Foundation
import MeetingPipeCore

/// END20: a recording start in flight, as one value rather than a private Bool and a side field.
///
/// `beginRecording` commits to a start and then awaits the recorder, and for that whole bring-up
/// the state machine still reads whatever it read before: `.prompting` for a Record press, `.idle`
/// for END17's resume, auto-consent, the hotkey and start-late. REC7 latched an end that arrived
/// meanwhile, but only under `.prompting`, so an idle-origin start dropped it and committed onto a
/// meeting that was already over (`20261112-174606`, 2026-11-12). A Stop pressed meanwhile was a
/// no-op from `.idle` and abandoned the prompt from `.prompting` while the start still committed.
///
/// The latch holds what happened during the bring-up, and `resolve()` says, once the recorder is
/// up, whether the start may commit. Pure: the controller supplies every input and acts on the
/// outcome.
struct RecordingStartLatch: Equatable {

    /// Where the start came from, for the event log only.
    enum Origin: String, Equatable {
        /// The user answered the prompt (Record, Record BYO, Always).
        case prompt
        /// END17's no-prompt resume after an end.
        case resume
        /// Every other start from `.idle`: auto-consent, the hotkey or menu row, the URL scheme,
        /// start-late.
        case idle
    }

    enum Outcome: Equatable {
        /// Nothing happened during the bring-up: commit the recording.
        case commit
        /// The meeting ended during the bring-up (REC7, now for every origin).
        case endedDuringStart(EndingReason)
        /// The user stopped it during the bring-up; `by` is the stop's reason (`toggle`, `hotkey`,
        /// `low_space`, ...).
        case cancelled(by: String)
    }

    struct InFlight: Equatable {
        let origin: Origin
        /// The start's own app, nil for a source-less (manual) start.
        let bundleID: String?
        var end: EndingReason?
        var cancelledBy: String?
    }

    private(set) var inFlight: InFlight?

    var isInFlight: Bool { inFlight != nil }

    /// A start has committed to the bring-up. A new start replaces nothing: the controller refuses
    /// a second start while one is in flight, so this is only ever called from idle.
    mutating func begin(origin: Origin, bundleID: String?) {
        inFlight = InFlight(origin: origin, bundleID: bundleID)
    }

    /// What an end that arrived during the bring-up does to it.
    enum EndDisposition: Equatable {
        /// No start is in flight; the caller handles the end as it always did.
        case notInFlight
        /// The end is this start's own meeting: it is latched, and the start stops at commit.
        case latched
        /// The end belongs to another app, or the start has no source to compare it with. It is
        /// dropped: it must neither stop the start nor fall through to dismissing a prompt the
        /// start is answering. A source-less start never takes a foreign end, which is END19's
        /// question for a source-less recording and stays with it.
        case ignored
    }

    mutating func noteEnd(bundleID: String, reason: EndingReason) -> EndDisposition {
        guard var current = inFlight else { return .notInFlight }
        guard let own = current.bundleID, own == bundleID else { return .ignored }
        if current.end == nil { current.end = reason }
        inFlight = current
        return .latched
    }

    /// The user stopped during the bring-up. Returns false when no start is in flight.
    mutating func cancel(by reason: String) -> Bool {
        guard var current = inFlight else { return false }
        if current.cancelledBy == nil { current.cancelledBy = reason }
        inFlight = current
        return true
    }

    /// The recorder is up: what the start does now, and the latch is cleared. A cancel outranks an
    /// end, since both stop the recording and the user's reason is the one worth logging.
    mutating func resolve() -> Outcome {
        defer { inFlight = nil }
        guard let current = inFlight else { return .commit }
        if let by = current.cancelledBy { return .cancelled(by: by) }
        if let end = current.end { return .endedDuringStart(end) }
        return .commit
    }

    /// The start failed: nothing to commit or stop.
    mutating func clear() { inFlight = nil }
}
