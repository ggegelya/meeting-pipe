import XCTest
@testable import MeetingPipe

/// REC13(1): the poster of a notification must never wait on the handler.
///
/// The incident this pins: `MeetingRecorder` registered its
/// `.AVAudioEngineConfigurationChange` observer with `queue: .main`, which makes
/// NotificationCenter wrap the handler in an `NSOperation` and have the POSTER block
/// on `-[NSOperation waitUntilFinished]`. The poster was AVFAudio's own engine serial
/// queue, so the engine wedged (2516 of 2516 samples) and every engine call behind
/// it, including the whole stop path, wedged with it: 52 minutes in `.stopping` with
/// `system.wav` still growing.
///
/// These run against a private `NotificationCenter`, so nothing here touches the
/// app's real observers.
final class MainQueueObserverTests: XCTestCase {

    /// How long the handler holds the main thread. Long enough that a blocking post
    /// is unambiguous against the assertion below, short enough not to slow the suite.
    private let handlerHoldSeconds: TimeInterval = 0.6

    /// The load-bearing test, and the one that fails against `main`: with `queue: .main`
    /// the post blocks for the handler's whole duration, so `postDuration` comes back at
    /// ~`handlerHoldSeconds` instead of ~0.
    func test_post_returns_without_waiting_for_the_handler() {
        let center = NotificationCenter()
        let name = Notification.Name("mp.test.engine-configuration-change")
        let handlerFinished = expectation(description: "handler finished")
        let postFinished = expectation(description: "post returned")
        let hold = handlerHoldSeconds

        let observer = addMainQueueObserver(on: center, forName: name, object: nil) {
            // Blocks the main thread, the way a handler that cannot make progress does.
            Thread.sleep(forTimeInterval: hold)
            handlerFinished.fulfill()
        }
        defer { center.removeObserver(observer) }

        let postDuration = OSAllocatedUnfairLockBox<TimeInterval>(0)
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            center.post(name: name, object: nil)
            postDuration.value = Date().timeIntervalSince(started)
            postFinished.fulfill()
        }

        wait(for: [postFinished, handlerFinished], timeout: 10)
        XCTAssertLessThan(
            postDuration.value, hold / 2,
            "the post waited on the handler; a non-nil observer queue reintroduces the REC13 deadlock"
        )
    }

    /// The handler still lands on the main queue, which is the property the original
    /// `queue: .main` registration was chosen for and which the explicit hop preserves.
    func test_handler_runs_on_the_main_queue() {
        let center = NotificationCenter()
        let name = Notification.Name("mp.test.handler-thread")
        let ran = expectation(description: "handler ran")
        let wasMain = OSAllocatedUnfairLockBox<Bool>(false)

        let observer = addMainQueueObserver(on: center, forName: name, object: nil) {
            wasMain.value = Thread.isMainThread
            ran.fulfill()
        }
        defer { center.removeObserver(observer) }

        DispatchQueue.global(qos: .userInitiated).async {
            center.post(name: name, object: nil)
        }
        wait(for: [ran], timeout: 5)
        XCTAssertTrue(wasMain.value)
    }

    /// The observer is scoped to its `object`, so an unrelated engine's posts do not
    /// drive this recorder's recovery. Pins the `object:` pass-through.
    func test_observer_is_scoped_to_its_object() {
        let center = NotificationCenter()
        let name = Notification.Name("mp.test.scoped")
        let subject = NSObject()
        let other = NSObject()
        let ran = expectation(description: "handler ran for the subject only")
        ran.expectedFulfillmentCount = 1
        ran.assertForOverFulfill = true

        let observer = addMainQueueObserver(on: center, forName: name, object: subject) {
            ran.fulfill()
        }
        defer { center.removeObserver(observer) }

        center.post(name: name, object: other)
        center.post(name: name, object: subject)
        wait(for: [ran], timeout: 5)
    }
}

/// Minimal box so a test can hand a value back from a background closure without
/// tripping strict concurrency. Test-only; production code uses
/// `OSAllocatedUnfairLock` directly.
final class OSAllocatedUnfairLockBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ initial: Value) { self.stored = initial }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
