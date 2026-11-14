---
id: CONC12
title: PermissionsCenter writes @Published state off the main thread, contrary to its own header
category: Concurrency
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). PermissionsCenter's header says mutations run on main, but its async refresh and request methods are nonisolated, so under tools 5.9 they leave main and commit() writes the four @Published statuses and deferredToSettings from the cooperative pool, at launch (requestPermissionsAtStartup) and every 2 s while the Permissions pane is open, racing the menu's main-thread refreshMenuRelevantSync(). Make the class main-isolated so the compiler holds the invariant, with tests that every commit lands on main.
---

# CONC12: PermissionsCenter writes @Published state off the main thread, contrary to its own header

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: finding F048 in the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) (lens quality, confirmed). Re-read in code at HEAD 3a2da4fc on 2026-11-13; every part of the claim holds.

**The stated invariant.** `daemon/Sources/MeetingPipe/PermissionsCenter.swift` opens with `final class PermissionsCenter: ObservableObject` and the header "Not `@MainActor` so the Coordinator (also not main-isolated) can read published state synchronously; mutations run on the main queue by convention." It holds `@Published private(set) var microphone`, `screenRecording`, `accessibility`, `notifications` and `@Published private(set) var deferredToSettings: Set<Kind>`, and every write goes through the private `commit(_:kind:status:)`, which also sends `permissionGranted` and removes from `deferredToSettings`.

**Why the convention does not hold.** `daemon/Package.swift` is `// swift-tools-version:5.9` with no upcoming features enabled, so a non-isolated `async` method runs on the generic executor (SE-0338), not on its caller's actor. `refreshAll()`, `refreshMic()`, `refreshNotifications()`, `requestMic()`, `requestScreenRecording()` and `requestNotifications()` are all non-isolated `async` methods of a non-isolated class, so a call from a main-actor context hops off main before it reaches `commit`. `refreshAll()` then calls the synchronous `refreshScreenRecording()` and `refreshAccessibility()` from that pool context too, and `requestScreenRecording()` / `requestNotifications()` call `markDeferredAndOpenSettings`, which inserts into `deferredToSettings` and calls `NSWorkspace.shared.open` off main.

**Where it runs.**
- At launch: `Coordinator.requestPermissionsAtStartup()` does `Task { @MainActor in await PermissionsCenter.shared.requestNotifications(); await PermissionsCenter.shared.requestMic(); ... }`. Both awaited calls leave main and commit from the pool.
- With Preferences open: `startPolling()` schedules a 2 s `Timer` whose block runs `Task { @MainActor in await self.refreshAll() }`, which again leaves main. Meanwhile `StatusBarController.refreshMenuBeforeDisplay` calls `PermissionsCenter.shared.refreshMenuRelevantSync()` on main at every menu open, so two threads can run `commit` on the same key path at once.
- Also: the Permissions pane's Re-check and Request buttons (`PreferencesView+Permissions`), the onboarding step's `.task { await perms.refreshAll() }` and its request rows (`OnboardingStepPermissions`), and `Coordinator.onboardingDidComplete()`.

**Who reads it.** `StatusBarController.menuInputs` and `Coordinator.setupChecklistInputs` read the statuses synchronously on main; the Permissions pane and onboarding step observe the object through `@ObservedObject`, so `objectWillChange` fires from a pool thread into SwiftUI. The one subscriber that is already safe is `Coordinator`'s `permissionGrantedCancellable`, which uses `.receive(on: DispatchQueue.main)`.

**Why nothing catches it.** Both targets build with `.unsafeFlags(["-strict-concurrency=targeted"])` (CONC4 for the executable), which does not diagnose a non-isolated class's own methods writing its own stored properties. The header comment is the only guard.

No field symptom is attributed to this in the 2026-11-13 field pack; this is a data race on a published `enum` and a `Set`, found by reading code, not an observed crash.

## Scope

1. **Main-isolate the type.** Mark `PermissionsCenter` `@MainActor`, so every method, including the `async` ones and `commit`, runs on main and the compiler enforces it. Update the header comment to say so, and drop the "by convention" sentence.
2. **Fix the readers the annotation surfaces.** The synchronous readers (`StatusBarController.menuInputs`, `Coordinator.setupChecklistInputs`, `Coordinator.requestPermissionsAtStartup`'s accessibility call, the `startPolling` timer block) already run on main. Mark each calling method `@MainActor` where it is main-only, or wrap the read in `MainActor.assumeIsolated` where the enclosing type cannot be annotated yet. Whichever the pickup session picks, the commit body says why.
3. **Fallback if the class annotation cascades too far.** If `@MainActor` on the class forces annotations across a large part of `Coordinator` in this change, annotate the six `async` methods and `commit` `@MainActor` instead, and put `dispatchPrecondition(condition: .onQueue(.main))` at the top of `commit`. The point either way is that `commit` provably runs on main from every entry point; record which shape was taken in the commit body.
4. **Tests move with it.** `PermissionsCenterTests` becomes `@MainActor` (or awaits on the main actor) wherever it touches `PermissionsCenter.shared`, including `simulateStatusForTesting`.

## Explicitly not

- `SystemAudioCapture`'s unguarded statics (`permissionState`, `cachedContent`), which `requestScreenRecording()` and `refreshScreenRecording()` read and `prewarm()` writes from the pool, and the session controller's debug `dispatchPrecondition`: [CONC6](./CONC6.md).
- The unchanged-status publish and the `permission_changed` event in `commit`: [OBS5](./OBS5.md) item 3 and its 2026-10-25 amendment edit the same function. Whichever of OBS5 and CONC12 lands second rebases onto the other; this task does not add the guard or the event.
- A `complete`-mode strict-concurrency sweep of the executable (CONC6 measures it on Core). The `AVAudioFormat` Sendable warnings: [CONC11](./CONC11.md).
- No `@unchecked Sendable`, `nonisolated(unsafe)` or lock added to silence the race; the fix is isolation, not a mutex around published state.

## Acceptance

- `PermissionsCenter` (or, under scope item 3, `commit` and every `async` method) is `@MainActor`, and `cd daemon && swift build` emits no new concurrency warning for it.
- `PermissionsCenterTests` gains tests that, called from `Task.detached`, `await center.refreshMic()` and a `simulateStatusForTesting` grant each fire `objectWillChange` and `permissionGranted` on the main thread (a sink records `Thread.isMainThread`, the test asserts every recorded value is true). The tests avoid `refreshAll()` and `requestNotifications()`, since `UNUserNotificationCenter.current()` needs an app bundle the test host does not have.
- The existing `PermissionsCenterTests` cases (initial-grant broadcast, no broadcast on a repeat grant) stay green unchanged in intent.
- `cd daemon && swift test` green with the number of new tests in the commit body; `bash scripts/ci-local.sh` green.
- `daemon/docs/gotchas.md` or the type's header (not both) states the rule: `PermissionsCenter` is main-actor isolated, and a new `async` probe added to it inherits that.
