import Foundation
import ScreenCaptureKit

/// `SCShareableContent`-backed PRIMARY signal. Determines whether a
/// meeting window currently exists for the target bundle by polling
/// the shareable-content snapshot at 2 Hz while a meeting is active
/// and 1 Hz otherwise.
///
/// The 2 Hz active cadence gives a sub-second reaction to window
/// disappearance (the leading signal for the Teams "click Leave →
/// window closes" path); the 1 Hz idle cadence keeps the
/// `SCShareableContent` overhead minimal between meetings.
///
/// `SCShareableContent` is queried via an injectable closure so tests
/// can run without Screen Recording TCC and without invoking
/// ScreenCaptureKit. Production wires `SCShareableContent
/// .excludingDesktopWindows` and maps the resulting `[SCWindow]` into
/// `[ShareableWindowSummary]`.
///
/// Threading: `start` and `stop` must run on the main queue. Probe
/// invocations and `onChange` callbacks fire on the scheduler's queue.
public final class ShareableContentSignal {

    /// Lightweight summary the signal needs from each window. Keeps
    /// the probe interface decoupled from `SCWindow` so tests don't
    /// have to construct one.
    public struct ShareableWindowSummary: Equatable {
        public let bundleIdentifier: String?
        public let title: String?
        public init(bundleIdentifier: String?, title: String?) {
            self.bundleIdentifier = bundleIdentifier
            self.title = title
        }
    }

    /// Probe returns the current shareable windows, or nil if the
    /// fetch failed (e.g. TCC denied, transient error). nil leaves
    /// the prior state in place rather than flapping to "absent".
    public typealias Probe = () -> [ShareableWindowSummary]?

    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    public var onChange: ((Bool) -> Void)?
    public private(set) var lastValue: Bool?

    public static let activePollInterval: TimeInterval = 0.5
    public static let idlePollInterval: TimeInterval = 1.0

    /// Optional regex applied against window title. Adapters supply a
    /// locale-tolerant regex (the Teams "Meeting" / "Reunión" / …
    /// matcher) to distinguish call windows from chat threads.
    public typealias TitleMatch = (String?) -> Bool

    private let eventLog: EventLog
    private let probe: Probe
    private let scheduler: Scheduler
    private let activeInterval: TimeInterval
    private let idleInterval: TimeInterval

    private var context: MeetingLifecycleContext?
    private var titleMatch: TitleMatch?
    private var cancelTick: (() -> Void)?
    private var currentInterval: TimeInterval = 0
    private var lastUnmatchedCandidates: [String]?

    public init(
        eventLog: EventLog = NoopEventLog(),
        probe: @escaping Probe = ShareableContentSignal.defaultProbe,
        scheduler: @escaping Scheduler = ShareableContentSignal.defaultScheduler,
        activeInterval: TimeInterval = ShareableContentSignal.activePollInterval,
        idleInterval: TimeInterval = ShareableContentSignal.idlePollInterval
    ) {
        self.eventLog = eventLog
        self.probe = probe
        self.scheduler = scheduler
        self.activeInterval = activeInterval
        self.idleInterval = idleInterval
    }

    public func start(
        context: MeetingLifecycleContext,
        titleMatch: @escaping TitleMatch = { _ in true }
    ) {
        stop()
        self.context = context
        self.titleMatch = titleMatch
        startTick(interval: idleInterval)
        evaluate(reason: "initial")
    }

    public func stop() {
        cancelTick?(); cancelTick = nil
        context = nil
        titleMatch = nil
        lastValue = nil
        currentInterval = 0
        lastUnmatchedCandidates = nil
    }

    func evaluate(reason: String) {
        guard let context = context, let titleMatch = titleMatch else { return }
        guard let summaries = probe() else {
            eventLog.emit(category: "signal", action: "shareable_content_unavailable", attributes: [
                "bundle_id": context.bundleID,
                "reason": reason
            ])
            return
        }
        let present = summaries.contains { summary in
            summary.bundleIdentifier == context.bundleID && titleMatch(summary.title)
        }
        adjustCadence(forActive: present)
        if present {
            lastUnmatchedCandidates = nil
        } else {
            // Diagnostic: distinguish "no window" from "title mismatch" by logging the bundle's window titles, deduped on the set.
            let candidates = summaries
                .filter { $0.bundleIdentifier == context.bundleID }
                .map { $0.title ?? "<nil>" }
            if candidates != lastUnmatchedCandidates {
                lastUnmatchedCandidates = candidates
                eventLog.emit(category: "signal", action: "shareable_content_no_match", attributes: [
                    "bundle_id": context.bundleID,
                    "candidate_titles": candidates,
                    "reason": reason
                ])
            }
        }
        if lastValue == present { return }
        let previous = lastValue
        lastValue = present
        eventLog.emit(category: "signal", action: "shareable_content_window_present", attributes: [
            "bundle_id": context.bundleID,
            "value": present,
            "reason": reason,
            "previous": previous as Any
        ])
        onChange?(present)
    }

    private func startTick(interval: TimeInterval) {
        cancelTick?()
        currentInterval = interval
        cancelTick = scheduler(interval) { [weak self] in
            self?.evaluate(reason: "poll")
        }
    }

    private func adjustCadence(forActive active: Bool) {
        let target = active ? activeInterval : idleInterval
        guard currentInterval != target else { return }
        startTick(interval: target)
    }

    // MARK: - Default seams

    public static let defaultScheduler: Scheduler = { interval, action in
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            action()
        }
        return { timer.invalidate() }
    }

    /// Default probe: synchronously bridge `SCShareableContent
    /// .excludingDesktopWindows` into the summary form. The fetch is
    /// async on `SCShareableContent`, so we run a semaphore-gated wait
    /// here; the caller's scheduler dispatches this off the main queue
    /// in production so the wait doesn't block UI.
    public static let defaultProbe: Probe = {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [ShareableWindowSummary]?
        SCShareableContent.getExcludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ) { content, _ in
            defer { semaphore.signal() }
            guard let content = content else { return }
            result = content.windows.map { window in
                ShareableWindowSummary(
                    bundleIdentifier: window.owningApplication?.bundleIdentifier,
                    title: window.title
                )
            }
        }
        semaphore.wait()
        return result
    }
}
