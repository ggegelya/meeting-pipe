---
id: CONC6
title: SystemAudioCapture's statics are written from the cooperative pool and main with no lock, and the spine's main-queue invariant is not checked at runtime either
category: Concurrency
status: new
priority: P2
comment: Filed 2026-10-24 (audit band, arch M10, go-live SA-3 + PD-14 runtime half): cachedContent, permissionState and displayReconfigObserver are written from Task.detached prewarm and nonisolated start() on the pool and from main, unguarded, and MeetingSessionController's main-queue rule is only a comment. Put them behind OSAllocatedUnfairLock, add a debug dispatchPrecondition on the controller's entry points, measure complete mode on Core once. [Spec](./CONC6.md) Amended 2026-11-13 by the audit band: four more unsynchronized cross-thread accesses: the AX and ShareableContent onChange closures, the AX HandlerBox released off main, the recorder level callbacks swapped during capture, plus a synchronous log write on each first capture buffer (F157, F161, F162, F166).
---

# CONC6: SystemAudioCapture's statics are written from the cooperative pool and main with no lock, and the spine's main-queue invariant is not checked at runtime either

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) M10, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) SA-3 and PD-14 runtime half). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

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

## Amendment 2026-11-13 (audit band)

From the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md), findings F157, F161, F162 and F166, all in its "Low findings, not verified" table. Each was re-verified in code at HEAD on 2026-11-14. They are the same class as the `SystemAudioCapture` statics: state written on one thread and read on another with no synchronisation, which `-strict-concurrency=targeted` does not diagnose (F161 says so explicitly), so item 3's `complete`-mode measurement on Core should report whether it sees the two Core ones below.

**F161: two signals' `onChange` closures are plain stored vars.** `AXLeaveButtonSignal` declares `public var onChange: ((State) -> Void)?` and `ShareableContentSignal` `public var onChange: ((Bool) -> Void)?`. Both are invoked on the signal's private serial queue in production (`onChange?(state)`, and `onChange?(transition.value)` outside `lock`). Both are assigned on main in `NativeLifecycleAdapter.start` (and `BrowserMeetingLifecycleAdapter.start` for `shareableContent`), and those adapters are built once in `Coordinator` and reused, so `start` reassigns the closures every session while a walk or poll from the previous session can still be running on the queue (the class's own doc says `_stop` runs after `stop()` returns). `ProcessAudioSignal` already fixed exactly this: its `onChange` is a computed property over `_onChange` under `lock.withLock`, with the comment "Guards `generation` and `_onChange`, the only fields touched off the queue".

**F162: the AX handler box is released off main while main may be dereferencing it.** `RealAXBackend.register` boxes the handler with `Unmanaged.passRetained(handlerBox)`, and `AXBackendCallback`, which runs on the main run loop, unboxes it with `takeUnretainedValue()`. The teardown it returns calls `removeNotification` then `Unmanaged<HandlerBox>.fromOpaque(userInfo).release()` on whatever thread calls `AXObserverBus.unsubscribe`, which runs it inside `queue.sync`. `AXLeaveButtonSignal._stop` makes that call from the signal's serial queue. Correction at filing: the audit says the box is released "on the bus queue"; it is released on the caller's thread inside the bus queue's `sync`, which for the Leave signal is its own serial queue. Either way it is off main, so a callback already running on main can read a box that is being freed.

**F166: the recorder's level callbacks are swapped during capture.** `MeetingSessionController.armSystemLevelMirror` assigns `coordinator.audioRecorder.onSystemLevel` and `onMicLevel` after the recorder has started (it runs beside `recording_started`), and `disarmSystemLevelMirror` sets both to `nil` in `stopRecording` before the recorder stops. Meanwhile the mic tap reads `onMicLevel` (`callback: onMicLevel` in `accumulateAndEmit`) and the system-audio closure reads `self.onSystemLevel` on its capture thread. `MeetingRecorder.onMicLevel` is a plain var and `onSystemLevel` forwards to the plain `SystemAudioChannel.onSystemLevel`.

**F157: a synchronous log write on the first buffer, inside the capture callbacks.** The system-audio closure in `SystemAudioChannel` writes `Log.writeLine("recorder", "system tap first fired: ...")` when `systemFires == armBaseline &+ 1`, and the mic tap path writes `"mic tap first fired: ..."` when `micFires == 1`. `Log.writeLine` goes through `Log.append`, which takes the process-wide `writer` lock, may rotate the file, and does `open`, `write` and `close`, all on the capture thread, so that buffer waits behind any main-thread log write holding the lock. Correction at filing: the batch named only the system closure; the mic tap does the same. It happens once per source per recording (and per system retry), so it is a one-off stall, not a per-buffer cost: low.

### Added scope

4. `AXLeaveButtonSignal.onChange` and `ShareableContentSignal.onChange` take `ProcessAudioSignal`'s shape: a private `_onChange` read and written under the lock each already owns (`generationLock` and `lock`), read into a local under the lock and invoked outside it.
5. In `RealAXBackend`, a `HandlerBox` is never released while a callback on main can be using it. Two acceptable shapes, the pickup picks one and states it: release the box on main after `removeNotification` (main is serial with the callback), or have the `ObserverEntry` own its boxes so they go when the entry's source is detached. If a message already queued on the observer's port can still be delivered after the release, the chosen shape must cover it or the spec records why it cannot occur.
6. The level mirror stops swapping closures under a running capture: either install the two callbacks once and gate them on a locked flag that `arm` and `disarm` flip, or put both stored closures behind an `OSAllocatedUnfairLock` read once per emit.
7. The two "first fired" lines are handed to a utility queue (or a logger async entry point) instead of being written on the capture thread; the text is unchanged.

### Added acceptance

- A test per signal that reassigns `onChange` from main in a loop while the signal's queue invokes it, clean under `swift test --sanitize=thread` for that test (the `SystemAudioCaptureStateTests` shape).
- A `RealAXBackend` test with injected `calls`: a teardown invoked from a background queue releases the box on main (record the thread in a box `deinit` hook), or, for the entry-owned shape, the box outlives the teardown until the entry is discarded.
- A level-mirror test: `arm` and `disarm` on main in a loop while a background loop drives the emit path is clean under TSan.
- The "first fired" lines still reach `recorder.log` after a first buffer (a test waits for the line), and a source fence finds no `Log.writeLine` call inside the mic tap handler or the `SystemAudioCapture` buffer closure.
