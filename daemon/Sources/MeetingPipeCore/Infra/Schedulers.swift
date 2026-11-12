import Foundation

/// The two main-run-loop `Timer` schedulers (CONC10). Both have the shape every type's nested
/// `Scheduler` alias already names: take an interval and an action, return a cancel closure.
///
/// They differ from a bare `Timer.scheduledTimer` in one way, which is the point: the timer is
/// added to `RunLoop.main` in the common modes, not the default mode only. AppKit runs main in
/// the modal-panel mode for the whole of an app-modal session (`NSAlert.runModal()`,
/// `NSApp.runModal(for:)`, an `NSOpenPanel`) and in the event-tracking mode while a menu is open,
/// and a default-mode timer does not fire in either, so one alert left up behind Teams used to
/// stall the discovery backstop, the end-of-call tick and the HUD clock until it was dismissed.
///
/// A `Timer` only fires on a thread whose run loop is running, which off the main queue is none
/// of them: a repeat scheduled from a GCD worker needs a `DispatchSourceTimer` instead (the
/// `daemon/CLAUDE.md` timer rule). These install on main explicitly, and the cancel closure has to
/// be called on main too, since `Timer.invalidate()` must run on the thread that installed it.
public enum Schedulers {

    /// A repeating timer on the main run loop, live during alerts and menu tracking.
    public static let mainRunLoopRepeating: (TimeInterval, @escaping () -> Void) -> () -> Void = { interval, action in
        commonModeTimer(interval: interval, repeats: true, action: action)
    }

    /// A one-shot timer on the main run loop, live during alerts and menu tracking.
    public static let mainRunLoopOnce: (TimeInterval, @escaping () -> Void) -> () -> Void = { delay, action in
        commonModeTimer(interval: delay, repeats: false, action: action)
    }

    /// A repeating common-mode timer whose first fire is `firstFire` rather than one interval from
    /// now, with a `tolerance` the system may use to coalesce it with other wakeups (PERF26). The
    /// HUD's clock uses the first to land its ticks on whole seconds of the recording, and both HUD
    /// tickers the second, since a timer with no tolerance is one the system can never batch.
    public static func mainRunLoopRepeating(
        every interval: TimeInterval,
        firstFire: Date,
        tolerance: TimeInterval,
        _ action: @escaping () -> Void
    ) -> () -> Void {
        commonModeTimer(interval: interval, repeats: true, firstFire: firstFire, tolerance: tolerance, action: action)
    }

    private static func commonModeTimer(
        interval: TimeInterval,
        repeats: Bool,
        firstFire: Date? = nil,
        tolerance: TimeInterval = 0,
        action: @escaping () -> Void
    ) -> () -> Void {
        let timer = Timer(
            fire: firstFire ?? Date(timeIntervalSinceNow: interval),
            interval: interval,
            repeats: repeats
        ) { _ in
            action()
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
