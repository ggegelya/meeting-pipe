# CONC6: SystemAudioCapture's statics are written from the cooperative pool and main with no lock, and the spine's main-queue invariant is not checked at runtime either

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) M10, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) SA-3 and PD-14 runtime half). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Both targets compile with `swiftSettings: [.unsafeFlags(["-strict-concurrency=targeted"])]` under `swift-tools-version:5.9` (CONC4, 2026-07-18, which scoped `complete` mode out as a separate decision). Targeted checking does not diagnose unsynchronized global or static mutable state, so the following is invisible to the compiler today.

**`SystemAudioCapture` statics.** `final class SystemAudioCapture: NSObject, @unchecked Sendable` declares:

- `private static var cachedContent: SCShareableContent?`
- `static private(set) var permissionState: PermissionState = .unknown`, documented as "Reads: any thread; writes: only from prewarm() / start()"
- `private static var displayReconfigObserver: NSObjectProtocol?`

Who touches them, read on 2026-10-24:

- `static func prewarm() async` is a nonisolated async function on a non-actor type, so it runs on the cooperative pool. It is launched by `Task.detached { await SystemAudioCapture.prewarm() }` from `AppDelegate` at launch and from `Coordinator+MenuActions`, and awaited by `PermissionsCenter`. It writes `cachedContent` and `permissionState`, and calls `observeDisplayReconfiguration()`, whose `guard displayReconfigObserver == nil` then assignment is a check-then-set that two concurrent prewarms can both pass, registering two observers.
- `func start() async throws` (instance, nonisolated async, pool) reads `Self.cachedContent`, writes `Self.cachedContent` and `Self.permissionState`, and clears the cache on failure.
- The display-reconfiguration observer's block runs on `.main` and writes `cachedContent = nil`.
- `permissionState` is read on main by `StatusBarController`, `MeetingPromptWindow`, `Coordinator`, `MeetingSessionController` and `PermissionsCenter`, and by `MeetingRecorder`.

The one static in that file that is guarded is `didRequestScreenCaptureThisLaunch`, through `requestLock` (an `NSLock`). `OSAllocatedUnfairLock` is already used for the same kind of state in `SystemCaptureStartAttempt`, `GuardedTapInstall` (`condemnedEngines`), `MeetingRecorder` (`gateAccess`) and Core's `CallTeardownWatcher`.

**The spine's main-queue invariant is a comment.** `MeetingSessionController` is `@unchecked Sendable`, and its doc comment states the invariant that makes that sound: "All methods run on the main queue, like Coordinator's ... every stored property is touched only on the main queue". `Coordinator` is a plain `NSObject` subclass, not `@MainActor`. Nothing checks either claim at runtime: the only `Thread.isMainThread` guards in the executable are in `SecretsStore`, `ConfigStore` and `GlossaryStore`, and there is no `dispatchPrecondition` anywhere in `daemon/Sources`. The controller has 36 non-private methods. A future hop that calls one of them from a pool continuation (the CI8 class of mistake) would race the session state silently.

## Scope

1. **Guard the three statics.** Put `cachedContent`, `permissionState` and `displayReconfigObserver` behind one `OSAllocatedUnfairLock` (`SCShareableContent` is not `Sendable`, so it needs `uncheckedState:` with a one-line reason), exposing small synchronous accessors. The lock is never held across an `await` (the same rule the `requestLock` comment states). `observeDisplayReconfiguration` claims the slot under the lock before registering, so a second concurrent prewarm registers nothing.
2. **Runtime main-queue check on the spine.** One `assertMainQueue()` helper, `dispatchPrecondition(condition: .onQueue(.main))` compiled under `#if DEBUG` only, called first in each non-private `MeetingSessionController` method and in the `SessionHost` conformance's mutating entry points. Debug-only, so a wrong hop fails a test or a dev build, never a release recording.
3. **Measure `complete` mode on `MeetingPipeCore` only.** Build Core once with `-strict-concurrency=complete` in a scratch change, record the warning count and the top categories in the commit body and in this spec, and revert the flag. No fixes are in scope; the number decides whether a follow-up is filed.

## Explicitly not / out of scope

- Turning on `complete` mode for either target, or Swift 6 language mode. CONC4 measured `@MainActor` on the controller turning 2 warnings into 22; item 3 measures the island, not the app.
- Making `Coordinator` or `MeetingSessionController` `@MainActor`. Same cascade; ARCH7 shrinks the seam first.
- The false comments and count-style rules about concurrency ("Two @unchecked Sendable, don't add a third", with 16 occurrences in 9 files on 2026-10-24) and an allowlist fence for `@unchecked Sendable`: HYG10.
- The blocking `Task.detached` work in `Coordinator` and the raw `Process()` sites: CONC5.

## Acceptance

- `SystemAudioCaptureStateTests` (new): concurrent writers from a `DispatchQueue.concurrentPerform` loop and a main-queue reader never observe a torn value and the run is clean under `swift test --sanitize=thread` for this test; two concurrent `observeDisplayReconfiguration()` calls register one observer. At least 3 tests.
- A test pins the helper's predicate: false from a background queue, true on main. A trapping precondition cannot be caught in-process, so the test pins the predicate rather than the trap, and a source fence checks that every non-private `MeetingSessionController` method calls the helper first.
- `cd daemon && swift build` and `swift build -c release` warning-clean under the existing targeted flag, `swift test` green, `bash scripts/ci-local.sh` green, N new tests in the commit body.
- The Core `complete`-mode warning count and its date are recorded in this spec's last section by the session that lands item 3.
