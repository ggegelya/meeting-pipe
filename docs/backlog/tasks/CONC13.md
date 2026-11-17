---
id: CONC13
title: Every read of the lock-guarded level callbacks wraps the stored closure in two more thunks, so a recording past about 30 minutes overflows the main thread's stack and crashes the daemon
category: Concurrency
status: partial
priority: P1
comment: Shipped 2026-11-17: both level-callback locks hold a LevelSink struct, 2 no-growth tests (red at +20,002 frames before the fix, green after, TSan clean), ci-local green. Owed: the owner's 45-minute recording walkthrough on an installed build (no new .ips, normal recording_stopped).
---

# CONC13: Every read of the lock-guarded level callbacks wraps the stored closure in two more thunks, so a recording past about 30 minutes overflows the main thread's stack and crashes the daemon

Band origin: filed 2026-11-17 (crash triage of `MeetingPipe-2026-11-17-170438.ips`, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

**The crash.** `~/Library/Logs/DiagnosticReports/MeetingPipe-2026-11-17-170438.ips`, captured 2026-11-17 17:04:30 +0200, process launched 12:32:33 the same day. `EXC_BAD_ACCESS` / `SIGSEGV`, `KERN_PROTECTION_FAILURE`, message "Thread stack size exceeded due to excessive recursion", faulting thread 0 (main queue). The reported frames are an alternating chain of compiler-generated thunks, `partial apply for thunk for @escaping @callee_guaranteed (@unowned Float) -> ()` and `thunk for @escaping @callee_guaranteed (@in_guaranteed Float) -> (@out ())`, under `closure #1 in static MeetingRecorder.accumulateAndEmit(addSumSq:addSamples:sumSq:frames:threshold:callback:)`, which is the `DispatchQueue.main.async { cb(db) }` that delivers the ~1 Hz level. The leaf frame is still a thunk: the stack ran out while descending, before reaching the controller's closure. The report's `bug_type` is 309, which per project memory is read by `exception.type`, not by `bug_type`.

**The incident.** Recording `20261117-162938` (Teams, `recording_started` at `2026-11-17T14:29:38.988Z`) crashed about 35 minutes in. On relaunch orphan recovery picked it up (`orphan_recovered_without_offset` with `reason: absent`, then `orphan_recording_recovered`), FluidAudio transcribed 2087.36 s of audio into 182 segments and the pipeline published it at 17:05 local. No audio was lost, but the far-side merge offset was absent, so that recording's channel placement came from the recovery fallback rather than the live merge.

**The causal chain.**
1. CONC6 (commit `78b72306`, 2026-11-17 01:35 +0200, item 6 / finding F166) moved both level callbacks behind a lock so `armSystemLevelMirror` and `disarmSystemLevelMirror` can swap them on main while the capture threads read them. `MeetingRecorder.onMicLevel` is `private let micLevelCallback = OSAllocatedUnfairLock<((Float) -> Void)?>(uncheckedState: nil)` with `get { micLevelCallback.withLockUnchecked { $0 } }` and `set { micLevelCallback.withLockUnchecked { $0 = newValue } }`; `SystemAudioChannel.onSystemLevel` is the same shape over `systemLevelCallback`.
2. A function type stored as a generic parameter (`State`) lives at maximal abstraction, so the setter stores a reabstraction thunk around the controller's closure. That part is a constant cost.
3. The getter is the defect. `withLockUnchecked` hands its body the state `inout`; the body `{ $0 }` is written at the substituted type, so the inout access converts the stored closure to the substituted form, runs the body, then converts it back and **writes it back into the lock**. Each read leaves the stored value wrapped in two more thunks than before, permanently.
4. The capture paths read the callback once per buffer: `MeetingRecorder` passes `callback: onMicLevel` to `accumulateAndEmit` from the mic tap, and `SystemAudioChannel` passes `callback: self.onSystemLevel` from the SCStream handler. Tens of reads a second for the whole recording, each growing the chain (and each allocating two thunk contexts that are never freed until the next assignment, so it is also a steady heap leak).
5. When `accumulateAndEmit` crosses its ~1 s threshold it calls the current chain on main. The call recurses once per thunk; past roughly half an hour of reads the chain is deeper than main's stack.
6. `disarmSystemLevelMirror` sets both callbacks to `nil` at stop, which resets the chain. That is why the two short recordings earlier that day (`20261117-123246`, about 8 min; `20261117-125943`, about 7.5 min) survived on the same process, and why recordings before CONC6 landed did not crash at any length (2026-11-09 61.9 min, 2026-11-10 46.8 min, 2026-11-11 43.5 min, 2026-11-16 117.9 min, all from `events.jsonl`).

**Standalone repro (2026-11-17).** A 20-line Swift program with the same `OSAllocatedUnfairLock<((Float) -> Void)?>` property, measuring `Thread.callStackSymbols.count` inside the callback after N reads of the getter: 7, 9, 27, 207 at N = 0, 1, 10, 100 with `-Onone`, and 6, 8, 26, 206 with `-O`. Two frames per read, linear, optimisation level irrelevant.

**The fix, measured in the same repro.** Lock a nominal wrapper instead of the bare function type: `struct Sink { let call: (Float) -> Void }`, state `OSAllocatedUnfairLock<Sink?>`, getter `lock.withLockUnchecked { $0 }?.call`, setter `let s = newValue.map(Sink.init); lock.withLockUnchecked { $0 = s }`. A stored property of function type inside a non-generic struct is kept at its natural abstraction, so no thunk is ever written back: call depth stayed at 3 (`-O`) and 5 (`-Onone`) after 0, 1,000 and 100,000 reads.

**Why the CONC6 tests did not catch it.** `CaptureThreadHygieneTests.test_arming_and_disarming_the_level_callbacks_while_a_capture_thread_reads_them_is_clean` reassigns both callbacks 5,000 times while a background loop reads them, so the chain is reset continuously and never grows; it checks for data races under TSan, which it does correctly, not for what a long run of reads does to the stored value.

## Scope

1. In `MeetingRecorder` (`micLevelCallback` / `onMicLevel`) and `SystemAudioChannel` (`systemLevelCallback` / `onSystemLevel`), store a small non-generic struct wrapping the closure (one shared `LevelSink`-style type is fine, its name is the pickup's call) instead of the bare optional function type, with the getter returning `?.call` and the setter wrapping `newValue` before taking the lock. The public property types, the CONC6 locking, and the read-once-per-emit behaviour of both capture paths stay exactly as they are.
2. Update the CONC6 comments on both properties to say why the closure is wrapped, so the next person does not "simplify" it back.

## Explicitly not

- Not reverting CONC6 item 6. The race it closed (main swapping the closure while a capture thread reads it) is real; the lock stays, only the stored type changes.
- Not the CONC6 item 6 alternative shape (install the callbacks once and gate them on a locked flag). It would also avoid the bug, but it is a larger change to the arm/disarm contract than a P1 crash fix needs.
- Checked on 2026-11-17 and not affected, so not in scope: the signal `onChange` properties (`ProcessAudioSignal`, `AXLeaveButtonSignal`, `ShareableContentSignal`, `HALSystemMuteProbe`, `HALVoiceActivityProbe`, `AXMuteButtonProbe`) keep the closure in an ordinary stored `_onChange` behind `NSLock` / `withLock { _onChange }`, which reabstracts only the returned value and writes nothing back; `CallTeardownWatcher.cancelBox` is an `OSAllocatedUnfairLock<(() -> Void)?>` but every access either calls and sets it to `nil` or assigns a fresh closure, so nothing accumulates. A repo-wide grep for `OSAllocatedUnfairLock<` with a function-typed state found only these three sites.
- The `orphan_recovered_without_offset` on `20261117-162938` is the expected recovery fallback when the process dies before the merge placement is persisted; whether REC36's persisted placement should have been present 35 minutes in is a REC question, not part of this fix.

## Acceptance

- New regression test (in `CaptureThreadHygieneTests` or a sibling): for each of `MeetingRecorder.onMicLevel` and `MeetingRecorder.onSystemLevel` (which forwards to `SystemAudioChannel.onSystemLevel`), assign a callback that records `Thread.callStackSymbols.count`, invoke it once to take a baseline, read the getter 10,000 times without reassigning, invoke it again, and assert the depth is unchanged. Before the fix this fails by about 20,000 frames; it must fail on the pre-fix code when the pickup session demonstrates red.
- The existing `CaptureThreadHygieneTests` arm/disarm race test stays green, and stays clean under `swift test --sanitize=thread` as CONC6 recorded.
- `cd daemon && swift build` and `swift test` green, with the new tests counted in the commit body (2 expected, one per property).
- `bash scripts/ci-local.sh` green.
- Owner walkthrough after install (confirms, does not gate building): record or leave running a meeting longer than 45 minutes on a build containing the fix, and confirm no new `MeetingPipe-*.ips` in `~/Library/Logs/DiagnosticReports/` and a normal `recording_stopped` for that stem in `events.jsonl`.

**Progress (2026-11-17):** `LevelSink` (in `SystemAudioChannel.swift`) is what `micLevelCallback` and `systemLevelCallback` now lock; the getters return `?.call`, the setters wrap before taking the lock. `CaptureThreadHygieneTests` gained `test_reading_onMicLevel_many_times_does_not_deepen_its_call` and `test_reading_onSystemLevel_many_times_does_not_deepen_its_call`; against the pre-fix sources both failed with depth 20079 against a baseline of 77. The other closure-typed `OSAllocatedUnfairLock`s were re-checked: `CallTeardownWatcher.cancelBox` (named above) and `UILatency.windowOpened`'s `cancelKey`, which the 2026-11-17 grep missed because its state is `(@Sendable () -> Void)?`; it is local to one window open and read once, so it cannot accumulate and was left alone. The story is in `daemon/docs/gotchas.md#a-locked-bare-closure-grows-per-read`.
