import Foundation

/// Pure state machine for mic-busy spans (DET3). The host (`MeetingDiscoveryWatcher`) feeds a
/// boolean "the mic is held by another process" sample (from the `AVCaptureDevice`
/// `isInUseByAnotherApplication` KVO and the backstop poll) plus the frontmost app; this returns
/// the `mic_busy_started` / `mic_busy_ended` transition to log, so the span logic is unit-testable
/// without AVFoundation.
///
/// Attribution is best-effort: the frontmost app captured when the mic was first observed busy.
/// The daemon cannot read *which* process holds the mic from `isInUseByAnotherApplication` (the API
/// only says "another app does"), so DET3 records the frontmost app as the plausible holder, the
/// same attribution DET1's catch-all tier uses. Idempotent: repeated `busy` / `idle` samples inside
/// a span return nil, so the poll can sample every tick without duplicate events.
struct MicBusySpanTracker {

    struct Span: Equatable {
        var bundleID: String?
        var displayName: String?
        var since: Date
    }

    enum Transition: Equatable {
        case started(bundleID: String?, displayName: String?)
        case ended(bundleID: String?, displayName: String?, durationSec: Double)
    }

    /// The currently-open span, or nil when the mic is idle. Exposed so DET1's mic-in-use tier can
    /// read how long the current span has been open without a second observer.
    private(set) var open: Span?

    /// Feed one mic-busy sample. Returns the transition to log on a rising / falling edge, else nil.
    mutating func update(
        busy: Bool,
        at now: Date,
        frontmostBundle: String?,
        frontmostName: String?
    ) -> Transition? {
        if busy {
            guard open == nil else { return nil }
            open = Span(bundleID: frontmostBundle, displayName: frontmostName, since: now)
            return .started(bundleID: frontmostBundle, displayName: frontmostName)
        } else {
            guard let span = open else { return nil }
            open = nil
            return .ended(
                bundleID: span.bundleID,
                displayName: span.displayName,
                durationSec: max(0, now.timeIntervalSince(span.since))
            )
        }
    }

    /// Seconds the current span has been open, or nil when idle. For DET1's sustained-dwell gate.
    func openDuration(at now: Date) -> TimeInterval? {
        guard let span = open else { return nil }
        return max(0, now.timeIntervalSince(span.since))
    }
}
