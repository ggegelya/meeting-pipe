import Foundation

/// Pure state machine for mic-busy spans (DET3, extended for DET1). The host
/// (`MeetingDiscoveryWatcher`) feeds a boolean "the mic is held by another process" sample (from the
/// `AVCaptureDevice` `isInUseByAnotherApplication` KVO and the backstop poll) plus the frontmost
/// app; this returns the `mic_busy_started` / `mic_busy_ended` transition to log, so the span logic
/// is unit-testable without AVFoundation.
///
/// Attribution is best-effort: the frontmost app captured when the mic was first observed busy. The
/// daemon cannot read *which* process holds the mic from `isInUseByAnotherApplication` (the API only
/// says "another app does"), so the frontmost app is the plausible holder, the attribution DET1's
/// catch-all tier also uses.
///
/// Release is debounced (`releaseDebounceSec`): the mic must read idle for that long before a span
/// closes. `isInUseByAnotherApplication` flaps briefly on a Bluetooth / HAL audio-route
/// renegotiation, and an un-debounced close would churn the span - re-prompting a call DET1 already
/// prompted (its once-per-span latch keys on the span's start), and splitting a DET3 span. A rising
/// sample inside the debounce window cancels the pending close, so a flap is absorbed.
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

    /// When the mic first read idle inside the current open span; nil while actively busy. The span
    /// closes only once the mic has stayed idle for `releaseDebounceSec` past this.
    private var pendingCloseSince: Date?

    /// Idle dwell required before a span is considered ended, absorbing brief mic-in-use flaps.
    var releaseDebounceSec: TimeInterval = 5

    init(releaseDebounceSec: TimeInterval = 5) {
        self.releaseDebounceSec = releaseDebounceSec
    }

    /// Feed one mic-busy sample. Returns the transition to log on a rising edge or a debounced
    /// falling edge, else nil (including inside the release-debounce window).
    mutating func update(
        busy: Bool,
        at now: Date,
        frontmostBundle: String?,
        frontmostName: String?
    ) -> Transition? {
        if busy {
            pendingCloseSince = nil // mic active: cancel any pending close (absorbs a flap)
            guard open == nil else { return nil }
            open = Span(bundleID: frontmostBundle, displayName: frontmostName, since: now)
            return .started(bundleID: frontmostBundle, displayName: frontmostName)
        }
        guard let span = open else { return nil }
        let releasedAt = pendingCloseSince ?? now
        pendingCloseSince = releasedAt
        guard now.timeIntervalSince(releasedAt) >= releaseDebounceSec else { return nil }
        open = nil
        pendingCloseSince = nil
        return .ended(
            bundleID: span.bundleID,
            displayName: span.displayName,
            durationSec: max(0, releasedAt.timeIntervalSince(span.since))
        )
    }

    /// Force-close an open span, bypassing the debounce, so its duration is logged at daemon
    /// shutdown rather than lost. Does not represent a real mic release, so the host must not treat
    /// it as a DET1 end signal.
    mutating func forceClose(at now: Date) -> Transition? {
        guard let span = open else { return nil }
        let releasedAt = pendingCloseSince ?? now
        open = nil
        pendingCloseSince = nil
        return .ended(
            bundleID: span.bundleID,
            displayName: span.displayName,
            durationSec: max(0, releasedAt.timeIntervalSince(span.since))
        )
    }

    /// Seconds the current span has been open, or nil when idle. For DET1's sustained-dwell gate.
    func openDuration(at now: Date) -> TimeInterval? {
        guard let span = open else { return nil }
        return max(0, now.timeIntervalSince(span.since))
    }
}
