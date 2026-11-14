---
id: MIC23
title: A source-less recording never engages MicGate and MicGate keeps lastVerdict across stop, so a recording's first verdict can be swallowed and under the regulated gate a manual recording's mic can stay zero-filled
category: Recording
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). 4 manual recordings in the field pack never started MicGate and got their first verdict 0.09 to 48.35 s in, and MicGate.stop keeps lastVerdict so a recording's first verdict is deduped against the previous one's last (14 of 16 sourced recordings, at most 3.3 s); under the regulated gate the recorder zero-fills the mic until a verdict lands. Give MicGate a session: start it for every recording, reset and always publish the first verdict at start, ignore RMS ingest outside a session, publish from current state so verdicts cannot land out of order; promote before enabling regulated or NDA.
---

# MIC23: a source-less recording never engages MicGate, and MicGate keeps lastVerdict across stop

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

**Sources.** [Independent audit](../../audits/2026-11-12-independent-audit.md) F004 (high) and F144 (folded in below); [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) D042 and its [evidence](../../audits/2026-11-13-recording-reliability-evidence.md) D052 (folded in); [field evidence](../../audits/2026-11-13-field-evidence.md) "Manual recordings run with no gate and inherit the previous call's verdict" and "F004 precondition: manual recordings never started the mic gate, yet verdict rows kept flowing".

**The code, re-verified at HEAD (3a2da4fc) on 2026-11-13.** Three paths reach a live recording without ever calling `MicGate.start`:

- Source-less. `MeetingSessionController.startManual` calls `beginRecording(source: nil, ...)` when there is no live suppressed candidate; `beginRecording` builds `recordStartBuild = source.map { beginRecordStartBuild(for: $0) }`, so it is nil, and the only route to the engage, `if let source = source, let recordStartBuild = recordStartBuild { self.attachWhenBuilt(...) }`, is skipped. `engageMicGate(source: AppSource, ...)` takes a non-optional source, and its doc comment ("Manual / browser-no-AX sources fall through to HAL VAD + RMS only (empty handles)") describes a path the code does not have.
- `honor_app_mute = false`. `engageMicGate` opens with `guard coordinator.liveHonorAppMute else { return }`, before `coordinator.micGate.start(context:handle:)`, so with app mute turned off no recording starts the gate at all, sourced or not.
- No pid at the deadline. `recordStartBuildDeadlinePassed` builds empty handles only when `engageSeams.resolveContext(attach.source)` returns a context; nil reaches `engageMicGate`'s `micgate_engage_skipped` (`reason: "no_pid"`) branch, which also returns before the start.

Meanwhile the recorder resets to `.uncertain(reasons: ["not_started"])` at every start (`MeetingRecorder`, the `gateAccess.withLock` block in its start path), and `resetMicGateBackstop` sets `latestVerdict = nil`. Only the `micGate.verdicts` consumer in `startConsumers` writes either again. Under `.regulatedGate` only `.hot` passes (`MicGateVerdict.passesLiveAudio`), so the mic is zero-filled until a verdict lands, and the idle backstop's 1 Hz feed in `armSystemLevelMirror` (`guard ..., let verdict = self.latestVerdict else { return }`) skips every tick until then (D042).

`MicGate` has no session. `lastVerdict` starts as `.uncertain(reasons: ["not_started"])` and is written only in `publish()`, which drops any verdict equal to it (`if verdict == self.lastVerdict { return false }`). `stop()` resets `state`, the probes and `lastLogReadingAt`, but not `lastVerdict`. `start()` calls `stop()`, then `update { $0.rmsState = .closed }`, which with no app reading decides `.silentByRMS(dwellMillis: 0)` (`rmsCloseDwellMillis` is never assigned anywhere, so `dwell_ms` is always 0); if the previous recording ended on that verdict the first one is dropped (D052).

**What emits verdicts with no gate attached (the field report's open question).** `Coordinator` wires `recorder.onMicRmsDb = { ... self?.micGate.ingest(rmsDb: db) }` for every recording, and `MicGate.init` wires `rmsGate.onChange` to `update`, which has no started check. So the RMS gate publishes on its own whenever the level crosses its thresholds: during a manual recording, between recordings (the mic tap is torn down in `MeetingRecorder`'s engine teardown, after `micGate.stop()` has run), and on a sourced recording before its engage lands. That is where the 16, 68, 114 and 179 `verdict_changed` rows inside the four manual recordings came from. It also means PERF15's stated invariant ("The recorder's verdict is `.uncertain(not_started)` until MicGate engages", the comment in `beginRecording`) holds in `EngageOffMainTests` only because no level is fed there.

**Verdicts can also land out of order (F144).** `update` and `applyMuteReading` compute `MicGate.decide(state:)` under `lock`, release it, then call `publish`, which enqueues on `publishQueue`. Two sources on different threads (the RMS tap, the AX probe, the log adapter, the HAL listeners) can therefore enqueue in the opposite order to their state writes, and the older verdict is the one left latched in `lastVerdict`, the recorder and the backstop until some later input changes the decision.

**Field evidence (work laptop, 74 recordings, 2026-09-29 to 2026-11-13).** The 4 manual recordings (20261012-103055, 20261021-103054, 20261106-172834, 20261111-155951) have 0 `mute_poller_started`, `system_mute_state` or `vad_unsupported` rows, against 70 of 70 sourced recordings; their first verdict arrived 48.35 s, 11.46 s, 0.09 s and 22.12 s after the start. All four were capture-first, so no audio was lost and their transcripts are normal (55 to 81 segments); the regulated gate was not in use on any of the 113 sidecars. Across the 74 recordings the verdict carried in from the previous recording was `muted_by_app` 18 times. On sourced recordings the dedupe is real (14 of the 16 recordings that followed a last verdict of `silent_by_rms` dwell 0 did not emit it first; the 2 exceptions followed a daemon relaunch) but cost at most 3.3 s, because the AX read or the RMS gate produced a different verdict almost at once.

**Correction at filing.** F004's headline scenario (the previous recording ended on hot `rms_above_open_threshold`, so the next one's first RMS open is deduped) was not observed: the four manual recordings carried in `muted_by_app` once and hot `confidently_unmuted` three times, neither equal to the first RMS verdict. Their long verdict-less starts come from the missing `start()` (no initial publish, and the RMS gate's carried-over state means no transition fires until the level crosses a threshold), not from the dedupe. The dedupe is demonstrated only on sourced recordings, where it cost seconds; D042's whole-call backstop starvation is not seen in the pack. Resetting `lastVerdict` alone would therefore not fix F004: the manual path needs a `start()`, and the reset has to be a session boundary that a queued `publishQueue` block or a post-stop RMS ingest cannot undo.

**Related.** [MIC18](./MIC18.md) (P1) decides whether the regulated gate survives; on its GO the zero-fill leg is moot but the backstop leg (D042) and the ordering leg (F144) still stand. [END11](./END11.md) (partial) decided a source-less recording engages no lifecycle adapter and is silent on MicGate. [PERF15](./PERF15.md) (done) split the engage off the record start and restated the `not_started` zero-fill. [ARCH7](./ARCH7.md) would move MicGate into the controller; this task does not depend on it. [MIC24](./MIC24.md) changes `applyMuteReading` for the log-versus-AX fusion; land in either order, but the publish path below is shared.

## Scope

1. **Start MicGate for every recording.** Add a context-free entry to `MicGate` (for example `startAudioOnly()`) that runs `start(context:handle:)`'s body minus the adapter loop: the HAL system-mute and VAD probes, `rmsGate.reset()`, and the session start of item 2. `MeetingSessionController.beginRecording` calls it for a nil source in the same main-actor run as `resetMicGateBackstop`; `engageMicGate` calls it instead of returning when `liveHonorAppMute` is false (no adapters, no `MeetingAXWindowWatcher`) and when the deadline path has no pid. Fix `engageMicGate`'s doc comment to match.
2. **A session boundary inside MicGate.** `start` and the new entry bump a session counter and, under `lock`, reset `lastVerdict` and mark the next publish as forced, so the first verdict of every recording reaches the stream even when it equals the previous recording's last. A `publishQueue` block from an earlier session is dropped. `ingest(rmsDb:)` is ignored outside a session (between `stop()` and the next start), which ends the gate-less verdict rows and makes PERF15's invariant true by construction for sourced recordings.
3. **Publish from current state (F144).** The `publishQueue` block recomputes `MicGate.decide(state:)` from `state` under `lock` when it runs, instead of carrying the snapshot taken before the hop, so the last block to run always publishes the latest state. `decide` stays pure; nothing new runs on the render thread (TECH-CONC1's assertion stays).
4. **Backstop.** `armSystemLevelMirror`'s `onMicLevel` feed treats a nil `latestVerdict` as `.uncertain(reasons: ["not_started"])` (which `IdleStopBackstop.isSilent` already counts as silent) instead of skipping the tick, so the backstop counts from the first second even if the forced first publish has not hopped back yet (D052's direction).
5. **One engage row per recording.** Every recording emits exactly one `micgate_attached` row; the source-less one carries `bundle_id: "manual"` and `via: "manual"`, and the honor-off and no-pid ones carry `app_mute: false`. Document it in `CONVENTIONS.md` beside PERF15's `micgate_attached` paragraph.

## Explicitly not

- Deleting or keeping the regulated gate: [MIC18](./MIC18.md).
- Lifecycle end detection for a source-less recording: [END11](./END11.md).
- The idle backstop's ceiling and its reading of a muted verdict as silence: [END25](./END25.md). A speech detector that works without HAL VAD: [MIC21](./MIC21.md).
- Pushing `micGate.current` into the recorder at start (F004's alternative direction): the forced first publish reaches the recorder and the backstop through the one existing consumer, so a second write path is not needed.
- Observed, not filed: `rmsCloseDwellMillis` is never assigned, so every `silent_by_rms` row logs `dwell_ms: 0`. Harmless today; whoever next reads that attribute should fill it from `RMSGateProbe` or drop it.

## Acceptance

- `MicGateTests`, two sessions through one `MicGate`: (a) session 1 ends on hot `rms_above_open_threshold`, session 2 started through the context-free entry receives an RMS open and the stream yields hot as its first verdict; (b) session 1 ends on `silent_by_rms`, session 2's `start` yields `silent_by_rms` again; (c) levels ingested after `stop()` and before the next start publish nothing.
- `MicGateTests`, ordering (F144): two sources interleaved from two threads with a test hook that delays the first one's enqueue; the stream's last verdict equals `decide` of the final state.
- Host test (`MeetingPipeTests`), two consecutive manual recordings under `.regulatedGate` with a fake recorder: the first stops while the level is hot, the second receives speech-level input, and the recorder's verdict becomes `.hot` (the mic is not left on `not_started`).
- Host tests: `startManual` with no candidate starts MicGate once; `honor_app_mute = false` on a sourced recording starts it with no adapter and no watcher; the deadline path with no pid starts it; each writes one `micgate_attached` row with the attributes above.
- Host test: the backstop is fed on the first `onMicLevel` tick of a recording before any verdict arrives.
- `EngageOffMainTests` stays green, and its "no verdict reaches the recorder before MicGate engages" assertion is extended to feed levels during the build and still hold.
- `swift build`, `swift test` and `bash scripts/ci-local.sh` green, with the number of tests added stated in the commit body.

## Low findings folded in

- **F144** ([independent audit](../../audits/2026-11-12-independent-audit.md), confirmed medium): out-of-order publish, verified at HEAD as described in Context. Scope item 3 and the ordering test.
- **D052** ([evidence](../../audits/2026-11-13-recording-reliability-evidence.md)): independent confirmation of the cross-recording dedupe through `start()`'s `update { $0.rmsState = .closed }` deciding `silentByRMS(dwellMillis: 0)`. Scope items 2 and 4 and the two-session test.
- **Field** ([field evidence](../../audits/2026-11-13-field-evidence.md), "Manual recordings run with no gate..." and "F004 precondition..."): the four manual stems above, first verdict 0.09 to 48.35 s in, carried-in `muted_by_app` 18 times in 74 recordings. The question "what emits `verdict_changed` while no gate is attached" is answered in Context (the unconditional RMS ingest) and closed by scope item 2.
