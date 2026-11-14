---
id: DET21
title: CoreAudioHALBus discards a listener removal's status and ProcessAudioSignal re-subscribes every process object on each list change, so leaked listeners multiply re-resolve storms that fill half the event log
category: Detection
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). RealCoreAudioBackend assigns AudioObjectRemovePropertyListenerBlock's status to _ and the bus logs unsubscribed regardless, and the field shows the listeners stayed registered (27 mute-listener bursts outside any recording, sized to the default-input subscribes since launch in 26 of 27); ProcessAudioSignal drops and re-adds every per-object listener on each system-wide list change, uncoalesced, so halbus rows are 64,374 (56.2 percent of the log) and one minute on 2026-10-12 held 15,020 rows. CONC9's generation guards make stale deliveries inert, which hides the leak. Scope: check and log the removal's status, one listener per object and selector for the daemon's lifetime fanned out inside CoreAudioHALBus, coalesce list-change re-resolves and keep unchanged object ids, back off after an unresolved resolve, one summary row per re-resolve plus a rate-limited stale-delivery count. [Spec](./DET21.md)
---

# DET21: CoreAudioHALBus discards a listener removal's status and ProcessAudioSignal re-subscribes every process object on each list change, so leaked listeners multiply re-resolve storms that fill half the event log

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Sources: three field findings in [2026-11-13-field-evidence.md](../../audits/2026-11-13-field-evidence.md), "HAL listeners keep firing after unsubscribe" and "Per-process subscribe churn is a re-resolve loop" (Mic, mute and capture health) and "HAL process-list changes cause re-subscribe storms that dominate the event log" (Daemon health); F159 in [2026-11-12-independent-audit.md](../../audits/2026-11-12-independent-audit.md) ("re-resolves and re-subscribes on every system-wide audio client change, uncoalesced, with 3N+1 log appends each time"); and the low D057 (confirmed, demonstrated) in [2026-11-13-recording-reliability-audit.md](../../audits/2026-11-13-recording-reliability-audit.md). Re-verified in code at HEAD `3a2da4fc` on 2026-11-13.

**The removal's result is thrown away.** `RealCoreAudioBackend.register` returns a teardown closure that runs `_ = AudioObjectRemovePropertyListenerBlock(address.objectID, &teardownAddr, queue, listenerBlock)`. `CoreAudioHALBus.unsubscribe` calls `sub.teardown()` and then emits `halbus/unsubscribed` unconditionally, so the log balances (net zero subscriptions per daemon lifetime except +4, -1 and two +1) while the HAL keeps calling the old blocks. Why the removal fails is still an inference (block identity across the closure bridge is the leading guess); no test runs against the real backend.

**The field shows the leak.** Between 2026-11-04T12:20Z and 2026-11-07T08:48Z, 27 bursts of mute-listener subscribes (110 subscribes) happened outside any recording, although a gated recording makes exactly 1 mute-listener and 1 default-input subscribe (70 of 70) and the bus logs them unsubscribed at stop. Burst size equalled the number of default-input subscribes since that daemon's launch (2026-10-30T21:44Z) in 26 of 27 bursts, stepping 1, 3, 4, 7, 8, 10 as recordings accumulated, with 6 `system_mute_state` and 5 `verdict_changed` rows and no recording running. On the process-list listener, burst sizes are an exact multiple of the list listeners subscribed since launch in 27 of 53 (era 1) and 39 of 116 (era 2) bursts, for example 496 resolves at 2026-10-09T09:17:08Z with 248 listeners subscribed.

**The re-resolve loop that the leak multiplies (F159).** `ProcessAudioSignal.subscribeProcessObjectList` subscribes `kAudioHardwarePropertyProcessObjectList`, and its handler calls `resolve(context:generation:)` then `evaluate(reason: "list_changed", ...)` on every system-wide audio client change. `resolve` starts `for token in halTokens { halBus.unsubscribe(token) }`, re-runs the resolver, emits `signal/process_audio_object_resolved`, and re-subscribes `kAudioProcessPropertyIsRunningInput` on every object, each subscribe logging `subscribe_attempt` and `subscribed` and each removal `unsubscribed`: 3N+1 rows per list change, with no coalescing and no check whether the object ids changed. Its own doc comment records six re-resolves inside 33 ms on 2026-10-13. Field: 4,540 `process_audio_object_resolved` rows against 20,791 per-process subscribe attempts, 20,786 subscribed and 20,783 unsubscribed; halbus rows are 64,374 of 114,553 (56.2 percent of rows, 48.5 percent of bytes), 50,128 of them inside recordings; in-recording re-resolves per recorded hour 151.5, 82.9 and 12.9 by era (646 in the 0.6 min `20261009-173127`). On 2026-10-12T08:20, with 340 list listeners subscribed in one daemon lifetime, 15,020 rows landed in one minute (7,637 `process_audio_object_unresolved` in 4.9 s, one pid, OSStatus 0, and 3 `subscribe_failed` with OSStatus 560947818 `!obj`) and the daemon relaunched 125 s later. Era 3 still shows it: 6 unresolved rows in 75 ms on 2026-11-12T15:19:50Z for Zoom.

**Why the newest build looks quieter.** CONC9 (done) gave `ProcessAudioSignal` and `HALSystemMuteProbe` a `generation` checked by every handler (`guard let self, self.isCurrent(generation) else { return }`, `guard let self, self.generation == generation else { return }`), so a stale delivery does nothing. Before CONC9 each stale default-input handler re-subscribed the mute listener, which is the burst growth above (D057). At HEAD the backend is unchanged, so the listeners presumably still accumulate per daemon lifetime, now invisibly: the 12x drop in the in-recording rate after 2026-11-12 fits a masked leak, over only 1.39 recorded hours.

Correction at filing: the attribution of the 2026-10-12 storm to the leak fits the multiplier signature and is not proven, and the field check could not observe the leak after 2026-11-12 because the guards make it silent; the scope therefore starts by making it observable.

## Scope

1. **See the removal.** `RealCoreAudioBackend.register`'s teardown returns the `OSStatus` of `AudioObjectRemovePropertyListenerBlock`; `CoreAudioHALBus.unsubscribe` emits `halbus/unsubscribe_failed` with `osstatus` and `osstatus_4cc` when it is not `noErr`, and `unsubscribed` only when it is.
2. **One HAL listener per object and selector for the daemon's lifetime.** `CoreAudioHALBus` registers a single backend listener the first time an `Address` is subscribed and keeps it until `reset()` at shutdown; `subscribe` and `unsubscribe` add and remove handlers in a fan-out table inside the bus, so nothing above the bus ever removes a HAL listener and a failed removal can no longer leak a handler that runs.
3. **Coalesce and diff list-change re-resolves.** `ProcessAudioSignal`'s list handler schedules at most one re-resolve per short window (about 250 ms), and `resolve` keeps the per-object handlers whose object ids are unchanged, subscribing only new ids and dropping vanished ones.
4. **Back off after an unresolved resolve** instead of retrying on the next list change, so a pid whose object will not resolve cannot produce thousands of rows in seconds.
5. **Log a summary, not every object.** Replace the per-object `subscribe_attempt`, `subscribed` and `unsubscribed` rows on the re-resolve path with one `signal/process_audio_reresolved` row per re-resolve (`bundle_id`, `pid`, `kept`, `added`, `removed`, `coalesced` count), keep `subscribe_failed` rows, and emit a rate-limited `halbus/stale_delivery_count` (at most once a minute while non-zero) from the generation guards in `ProcessAudioSignal` and `HALSystemMuteProbe`, so the next field pack shows whether anything still leaks. New actions go in `CONVENTIONS.md`'s event table.

## Explicitly not

- The always-on microphone-holder monitor: DET23, filed by this band, shares the coalesced list listener from item 3 and must not grow its own.
- Event-log retention and noise budgets in general: OBS9, filed by this band; this task removes the largest single source.
- A vanished process-audio object vetoing an end forever (F033): the END17 amendment from this band.
- The mic-busy device binding: [DET10](./DET10.md).

## Acceptance

- `CoreAudioHALBusTests` on a fake backend: (a) a removal that returns a non-zero status emits `unsubscribe_failed` with the status and no `unsubscribed`; (b) two subscribers on one `Address` register one backend listener, both handlers fire, and unsubscribing one leaves the other firing; (c) after the last handler unsubscribes no handler runs on a later backend delivery.
- `ProcessAudioSignalTests`: (a) N list-change deliveries inside one second cause one re-resolve; (b) a re-resolve that finds the same object ids makes no unsubscribe or subscribe call; (c) an unresolved resolve is not retried on the next list change inside the back-off; (d) one `process_audio_reresolved` row per re-resolve and no per-object rows.
- One test against `RealCoreAudioBackend` (D057): register and remove a listener on the default-input selector and assert the removal returns `noErr`; if the HAL refuses, the test documents why, which settles the block-identity question.
- A stale-generation delivery increments the counter and `halbus/stale_delivery_count` is emitted at most once a minute.
- `python3 scripts/truth_fences.py events` green; `cd daemon && swift build` and `swift test` green, N new tests named in the commit body; `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [session] Land, rebuild with `./scripts/rebuild.sh`.
2. [owner] Use the app normally for one working week, then hand over the event log.
3. [session] From that log: zero `unsubscribe_failed` rows or, if any, the status they carry; `halbus` rows per recorded hour below era 3's 275 (eras 1 and 2: 3,391 and 1,333); `stale_delivery_count` at zero. Record the result here.
