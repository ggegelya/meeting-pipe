import Foundation
import ScreenCaptureKit

/// `SCShareableContent`-backed PRIMARY signal. Polls at 2 Hz while a meeting window exists (sub-second
/// reaction to window disappearance, the leading signal for Teams "click Leave") and 1 Hz otherwise
/// to keep ScreenCaptureKit overhead minimal. Probe is injectable so tests run without Screen Recording TCC.
/// Threading: `start`/`stop` on main; probe and `onChange` on the scheduler's queue.
public final class ShareableContentSignal {

    /// Window fields the signal needs, decoupled from `SCWindow` so tests don't have to construct one.
    public struct ShareableWindowSummary: Equatable {
        public let bundleIdentifier: String?
        public let title: String?
        public init(bundleIdentifier: String?, title: String?) {
            self.bundleIdentifier = bundleIdentifier
            self.title = title
        }
    }

    /// Returns current shareable windows, or nil on TCC denial/transient error. nil leaves prior state in place rather than flapping.
    public typealias Probe = () -> [ShareableWindowSummary]?

    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    public var onChange: ((Bool) -> Void)?
    public private(set) var lastValue: Bool?

    public static let activePollInterval: TimeInterval = 0.5
    public static let idlePollInterval: TimeInterval = 1.0

    /// Predicate applied to window title to distinguish call windows from chat threads.
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
            // Log the bundle's window titles to distinguish "no window" from "title mismatch"; deduped to avoid noise.
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

    /// Bridge `SCShareableContent.excludingDesktopWindows` synchronously via a semaphore-gated wait.
    /// Safe because the scheduler dispatches probes off main in production.
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
