import Foundation

/// Register a block-based notification observer whose handler runs on the main
/// queue and which NEVER makes the poster wait.
///
/// This is the direct fix for REC13. `NotificationCenter.addObserver(forName:object:queue:using:)`
/// with a **non-nil** queue does not simply schedule the handler: it wraps it in an
/// `NSOperation`, enqueues that on the given queue, and has the **poster** block on
/// `-[NSOperation waitUntilFinished]` until it drains. Whoever posts therefore inherits
/// the handler's latency, and inherits it on the posting thread, which is usually not
/// a thread the app owns.
///
/// On 2026-08-14 the poster was AVFAudio's internal `engine` serial queue, posting
/// `.AVAudioEngineConfigurationChange` from `AVAudioEngineImpl::IOUnitConfigurationChanged()`
/// during a sleep/wake plus display-topology storm. A live `sample` caught that queue
/// blocked in 2516 of 2516 samples, three frames deep:
///
/// ```
/// invocation function for block in AVAudioEngineImpl::IOUnitConfigurationChanged()
///   -[NSNotificationCenter postNotificationName:object:userInfo:]
///     _CFXNotificationPost
///       -[NSOperation waitUntilFinished]        <- blocked here
/// ```
///
/// Every `AVAudioEngine` call serializes on that queue, so once it was blocked the
/// stop path's engine calls queued behind a wait that never ended: the recording sat
/// in `.stopping` for 52 minutes while system capture kept writing at ~394 KB/s, and
/// escaping it took a `kill -9`.
///
/// **What is NOT established, and must not be asserted:** why `OperationQueue.main`
/// never drained that operation. The main thread was idle in `__CFRunLoopRun` and
/// still servicing timers throughout the sample, which refutes the tidy story (main
/// blocked in `removeObserver` holding the notification-center lock). The fix does not
/// depend on knowing: with a nil queue there is no `NSOperation` and no
/// `waitUntilFinished`, so `_CFXNotificationPost` returns as soon as the handler has
/// been scheduled, whatever the main queue is doing.
///
/// The explicit `DispatchQueue.main.async` preserves both properties the `queue: .main`
/// registration was chosen for: the handler still runs on the main queue, and the
/// handler closure is still formed outside an async region, so the `@Sendable` capture
/// of a weak `self` stays quiet.
///
/// Cost of the hop: the handler is no longer serialized against the post, so two posts
/// in flight schedule two handlers. Every handler wired through here is main-queue
/// confined and re-reads live state rather than trusting the notification payload, so a
/// coalesced or doubled delivery is a no-op rather than a hazard.
func addMainQueueObserver(
    on center: NotificationCenter,
    forName name: Notification.Name,
    object: Any?,
    handler: @escaping @Sendable () -> Void
) -> NSObjectProtocol {
    center.addObserver(forName: name, object: object, queue: nil) { _ in
        DispatchQueue.main.async(execute: handler)
    }
}
