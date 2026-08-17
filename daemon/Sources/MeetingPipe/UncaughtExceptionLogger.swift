import Foundation

/// Write an uncaught Objective-C exception's name and reason to the logs before the
/// process dies.
///
/// REC12(3), and it is the cheapest item in that task by a wide margin. Reconstructing the
/// four aborts of 2026-08-13 and 08-14 took reading four `.ips` reports, correlating each
/// against `events.jsonl`, and still ended with the raise condition **inferred rather than
/// read**: a crash report's `Application Specific Information` holds only "abort() called",
/// and `NSException.reason` (the string that says exactly which of `InstallTapOnNode`'s
/// preconditions failed) is nowhere in it. This handler is the difference between that
/// reconstruction and reading one line.
///
/// It does not prevent the abort, and cannot: the handler runs after the exception is
/// already unwinding, immediately before `objc_terminate`. Preventing it is what the
/// format guard in `GuardedTapInstall` is for.
enum UncaughtExceptionLogger {

    /// How many backtrace frames the line carries. Enough to name the raising call and its
    /// couple of Swift callers, short enough that the line stays one grep-able row.
    static let frameLimit = 12

    /// The line written to `daemon.log`. Pure so the shape is pinned by a test rather than
    /// discovered on the next crash, which is the whole failure mode this exists to fix.
    static func line(name: String, reason: String?, frames: [String]) -> String {
        let head = "FATAL: uncaught ObjC exception \(name): \(reason ?? "<no reason given>")"
        guard !frames.isEmpty else { return head }
        return head + " | " + frames.prefix(frameLimit).joined(separator: " < ")
    }

    /// Record `exception` on both logs. Split from `install` so the test drives the real
    /// recording path with a real `NSException` without installing a process-wide handler
    /// in the test runner.
    ///
    /// `Log.writeLine` first and deliberately: it is unbuffered and lands even if the
    /// event write does not, and a process one instruction from `abort()` gets exactly one
    /// chance at each.
    static func record(_ exception: NSException) {
        Log.writeLine("daemon", line(
            name: exception.name.rawValue,
            reason: exception.reason,
            frames: exception.callStackSymbols
        ))
        Log.event(category: "daemon", action: "uncaught_exception", attributes: [
            "name": exception.name.rawValue,
            "reason": exception.reason ?? "",
        ])
    }

    /// Install the process-wide handler. Called once from `applicationDidFinishLaunching`.
    ///
    /// The closure captures nothing, which is required (`NSSetUncaughtExceptionHandler`
    /// takes a C function pointer) and is also the right shape here: whatever this process
    /// was doing is no longer trustworthy by the time it runs.
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            UncaughtExceptionLogger.record(exception)
        }
    }
}
