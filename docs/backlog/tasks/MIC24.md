---
id: MIC24
title: A Teams log line of any age outranks the live mute button for 5 s, and the AX reading it suppresses is never re-delivered, so the gate held a wrong mute state for up to 1,999 s while the owner spoke
category: Recording
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). 38 log_mute_event rows arrived a median 41.9 s after their own line_ts (max 2,607 s); MicGate stamps the log's freshness at arrival, so a late line overwrites a newer button reading and refuses AX for 5 s, and a refused AX reading is not re-sent: the gate disagreed with the button for over 5 s 17 times in 15 recordings (5,139 s), once for 1,999 s with 896 s of owner speech. MIC8's 5 s correction bound does not hold. Carry the line's own time so it cannot overwrite a newer AX reading or open a window from arrival, apply a refused AX reading when the window lapses, add lag_ms and a timed MicGate corpus trace; promote before enabling regulated or NDA.
---

# MIC24: a Teams log line of any age outranks the live mute button, and the AX reading it suppresses is not re-delivered

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

**Sources.** [Independent audit](../../audits/2026-11-12-independent-audit.md) F036 and G027; [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) D106 (NEW-1), D093, D060 and its plan's stage 12 ("the rule that a Teams log line of any age beats the live mute button for 5 s"), with the long form in the [evidence](../../audits/2026-11-13-recording-reliability-evidence.md); [field evidence](../../audits/2026-11-13-field-evidence.md) "Late SlimCore log lines outrank the live mute button, and the button reading they suppress is never replayed", "F036 consistent: suppressed mute readings are rarely followed by a correction" and "Two of the gate's inputs never spoke on this Mac".

**A done task's fix does not hold.** MIC8 (done 2026-08-04, archived in [q6-final.md](../q6-final.md)) shipped `MuteSourceFusion` with the claim that the 5 s log freshness window "bounds the un-correctable window to five seconds in the bad one" and that "the AX read carries whenever the log has been quiet for 5 s". Neither holds in the code, and the field shows windows of up to 1,999 s. [END12](./END12.md) named the cause on 2026-09-02 under "Observed, unfiled": the SlimCore log is buffered, lines reach disk 0.2 s to 17 m 59 s after their own stamp, and "a `log_mute_event` can apply a mute state 10 to 18 minutes late and ... veto the AX reading for 5 s after it lands". This is that filing.

**The code, re-verified at HEAD (3a2da4fc) on 2026-11-13.**

- `LogMuteAdapter.consume` keeps only the last parsed line of a batch, dedupes it against its own `lastMuted`, emits `log_mute_event` with `line_ts` from `reading.at`, and calls the sink with an `AXMuteButtonProbe.Event(state:label:locale:)`, which has no timestamp. The line's own time never reaches `MicGate`.
- `MicGate.applyMuteReading` stamps `let timestamp = now()` and, for a log reading, `lastLogReadingAt = timestamp`: freshness is measured from arrival. `MuteSourceFusion.accepts` returns `true` for `.log` unconditionally and refuses `.ax` while `now.timeIntervalSince(last) <= freshness` (5.0 s). A refused reading is logged as `mute_reading_suppressed` and dropped; `applyMuteReading` returns nothing to its caller.
- Both AX producers record a reading as delivered before the gate decides: `MeetingAXWindowWatcher`'s poll sets `lastEmitted = fused` and then calls `onMuteEvent`, and only re-sends when `fused != lastEmitted`; `AXMuteButtonProbe` sets `lastEvent = event` before its sink and returns `.steady` for `event == lastEvent`. So a refused AX reading is not re-sent while the button stays in the same state.
- `MuteSourceFusionTests.test_ax_carries_once_the_log_reading_is_stale` shows AX carrying only because it injects a second AX event by hand after advancing the clock (G027); no test wires a real producer into `MicGate`.
- The MIC10 VAD-contradiction rescue keys on the watcher's own fused AX state being `.muted`, so it cannot fire when the log forced muted while AX reads unmuted, and HAL VAD is unsupported on this Mac anyway.
- `DetectionCorpusTests.replayMicGate` replays `engine: "micgate"` traces as static `states` through `MicGate.decide(state:)`; there is no timed trace of producer readings, so none of this sequence can be pinned in the corpus (D093).

**Field evidence (work laptop, 2026-09-29 to 2026-11-13, Teams).** 38 `micgate` `log_mute_event` rows in 31 recordings; event ts minus `line_ts`: min 0.2 s, median 41.9 s, p90 1,337.9 s, max 2,606.7 s, 26 of 38 over 5 s. 21 of those 26 were stamped after `log_mute_watch_started`, so they are late flushes, not replayed history. The stamps are accurate: in 20261110-162917 the line reads 14:34:37.012Z, the AX notification for the same toggle is logged at 14:34:37.050Z, and the line was delivered at 14:36:02.929Z. 32 of the 38 lines trailed a button reading of the same state. Against the 1 Hz poller, the gate disagreed for over 5 s 17 times in 15 recordings (5,139 s), 15 of them starting within 1 s of a `log_mute_event` (12 with a line over 5 s old). Gate muted while the button read unmuted: 8 intervals, 2,886 s, 1,294 s of owner speech in the diarized transcript; gate unmuted while the button read muted: 9 intervals, 2,253 s, owner speech 2.1 s.

Three shapes, all from the evidence:

- **Late line over a newer AX reading, then the AX correction refused.** 20261012-182939: `recording_started` 15:29:39.622Z, poller read unmuted at 15:29:47.531Z, a line stamped 15:29:36.225Z (before the recording started) arrived at 15:30:35.631Z and set `muted_by_app`, the AX probe's unmuted reading at 15:30:39.002Z was logged `mute_reading_suppressed` 3 ms later, and nothing corrected the gate for 1,999 s until stop; owner speech in that span 896 s; `silence_notified` at 15:43:37Z after the owner had spoken 230.1 of the prior 240 s.
- **Late line over a newer AX reading, nothing suppressed.** 2026-11-06T15:04:13Z (stem 20261106-170021): AX read muted twice within 0.85 s, then an unmuted line 45.6 s old arrived, the verdict went hot, and nothing changed for 1,325 s until `recording_stopped`. No AX reading was refused here, so replaying refused readings alone would not fix it.
- **Very old line.** 2026-10-07T13:22:01Z: AX unmuted at -0.2 s, then a muted line 1,170 s old, `muted_by_app`, the next AX unmuted refused, and no correction until +282 s.

Even a fresh line can start it: in 20261016-163013 a 1.8 s old line started a 208 s interval, which is the F036 shape (the refused AX reading not re-sent). By build era: before 2026-10-12, 8 of 9 lines stale and 6 intervals over 5 s; 2026-10-12 to 2026-11-12, 18 of 27 and 10; after 2026-11-12, 0 of 2 and 1 interval of 7 s (a 4.1 s line). The fusion code is unchanged at HEAD, and 1.39 h on the newest build is too little to call it gone.

**What it cost.** Every recording on this Mac ran capture-first, where a verdict alters no audio: the cost was one false silence nudge (the 15:43:37Z row above, also counted under [END25](./END25.md)). Under `.captureFirstRedact` (opt-in per workflow, unused in the pack) the 2,886 s of wrong `muted_by_app` would be redacted from the consumed WAV, recoverable from the kept original. Under `.regulatedGate` the 1,294 s of owner speech would be zero-filled at capture with no recovery, and the 2,253 s of gate-hot-while-muted would put muted audio at rest.

**Correction at filing.** "Never re-delivered" is too strong. F036's verifier found recovery is incidental, not absent: the watcher clears `lastEmitted` after a muted-plus-voice contradiction and after three blind polls, and then re-emits the current state. D060 counts 16 refused AX readings that contradicted the gate: 0 corrected within 5.5 s, 10 corrected after 7 to 993 s, 6 never. The field report's daemon-health check counts 25 `mute_reading_suppressed` rows, 19 with no follow-up within 5 s. The bound MIC8 documents is still not implemented, and [MIC19](./MIC19.md)'s option (a) (keep the latch while blind under the regulated gate) would remove the blind-clear recovery path, which makes this fix a precondition there. The counts also differ between reports by definition: the field report has 17 disagreements over 5 s in 15 recordings (5,139 s); the reliability audit's checker had 16 of 17 (5,121 s) starting at a log line, which D106's own verifier could not reproduce, re-deriving instead 11 of 38 log events landing on a newer opposite AX reading. Not every interval is provably wrong, since the poller is treated as ground truth; the 1,294 s of owner speech against 2.1 s supports that it mostly is. The trigger is a late line, not the missing line MIC8 and the audits assumed.

**Related.** [MIC18](./MIC18.md) (P1) may delete the regulated real-time gate, which removes the irreversible half of the cost but not the redaction or backstop halves. [MIC19](./MIC19.md) covers the blind clear on the same producers. [MIC23](./MIC23.md) changes `MicGate`'s publish path; land in either order. [MIC7](./MIC7.md) owns browser mute. [PERF16](./PERF16.md) (done) reshaped `LogMuteAdapter`'s buffer and is untouched here.

## Scope

1. **Carry the line's time and compare it.** `LogMuteAdapter.consume` passes `reading.at` with the event (a time field on the event, or a source-specific entry on `MicGate`). `MicGate` records the time of the newest accepted AX reading under `lock`. In `MuteSourceFusion`, a log reading is accepted only when its own time is not older than the newest accepted AX reading, and the freshness window is measured from the line's time, not its arrival, so a line already older than `defaultLogFreshness` opens no suppression window. A line refused this way is logged as `mute_reading_suppressed` with `source: "log"` and its age. `MuteSourceFusion` stays pure; its doc comment is corrected to state the rule it now implements.
2. **Apply a refused AX reading when the window lapses.** `MicGate` keeps the last AX reading the fusion refused (with its time) and applies it when the log window lapses without a newer log reading, scheduled on `publishQueue`, so both producers are covered without changing their dedupe. This is what makes MIC8's 5 s bound true.
3. **`lag_ms` on `log_mute_event`.** Arrival minus `line_ts`, in milliseconds, documented in `CONVENTIONS.md` beside the other `micgate` rows.
4. **A timed MicGate trace kind in the corpus (D093).** A new `engine` value (for example `micgate_sequence`) in `DetectionCorpusTests`: timed producer readings in (source `ax` or `log`, state, own time, arrival time; RMS open and close), expected verdict spans out, replayed through a real `MicGate` with the injected `now` clock and a drained `publishQueue`. Seed it with the three field shapes above and the F036 missing-line shape, registered in the corpus `INDEX.json` and described in the corpus `README.md`.
5. **Mark, do not clear, on speech under a mute.** When the verdict is `muted_by_app` from AX or log, HAL VAD is unsupported, and the RMS gate stays open for a sustained stretch inside that span (threshold set by the pickup from the replay and logged on the row), emit one `micgate` `mute_reading_unverified` row for the span. No verdict change: MIC19 folds in F035's rule that voice alone is not grounds to clear a mute.

## Explicitly not

- Demoting the log to a confirm-only tiebreak (the field report's suggestion, since 32 of 38 lines trailed the button): item 1 already stops a trailing line from overriding anything, and the log still leads by p50 46 ms when it is prompt. If the field bar below fails, demotion is the next filing.
- The blind clear: [MIC19](./MIC19.md). A speech detector that works without HAL VAD: [MIC21](./MIC21.md). The idle backstop reading a muted verdict as silence: [END25](./END25.md). Deleting the regulated gate: [MIC18](./MIC18.md). Browser mute and D093's Safari clause (the home Mac's two Safari recordings, none on the work laptop): [MIC7](./MIC7.md).
- The teardown oracle's use of the same log as a flush clock: [END12](./END12.md).
- Changing `defaultLogFreshness`: with item 1 a late line opens no window, and a fresh one still needs the 5 s against AX's measured late notifications.

## Acceptance

- `MuteSourceFusionTests`: a log line older than the newest AX reading is refused; a log line newer than it is accepted; a line whose own time is more than `defaultLogFreshness` old opens no suppression window; a prompt log line 50 ms ahead of an AX reading of the same state behaves as today.
- `MicGateTests`: a refused AX reading is applied when the window lapses, with no second AX event injected (the G027 gap); a newer log reading inside the window cancels it.
- `DetectionCorpusTests` replays of the new trace kind, built from the offsets above: 20261012-182939 stays unmuted throughout; the 2026-11-06 shape stays muted; the 2026-10-07 shape stays unmuted; the F036 missing-line shape is muted within `defaultLogFreshness` plus one second of the refused reading.
- A producer-to-MicGate test: a real `MeetingAXWindowWatcher` poll and a `LogMuteAdapter` fed from a fixture file, wired into one `MicGate`, reproducing the 20261012-182939 sequence.
- `log_mute_event` carries `lag_ms`; `mute_reading_unverified` is emitted in a test with RMS open under `muted_by_app` and HAL VAD unsupported, and the verdict is unchanged. Both documented in `CONVENTIONS.md`.
- Existing `MuteSourceFusionTests`, `LogMuteAdapterTests`, `MeetingAXWindowWatcherTests` and `MicGateTests` stay green; `swift build`, `swift test` and `bash scripts/ci-local.sh` green, with the number of tests added stated in the commit body.
- Field bar: over the first 30 Teams recordings on the landed build, gate-versus-poller disagreements over 5 s that start within 1 s of a `log_mute_event` number at most 1 (field report baseline: 15 of 17 over the pack's 66 Teams recordings).

## Low findings folded in

- **D060** ([evidence](../../audits/2026-11-13-recording-reliability-evidence.md)): the producer end of F036 and G027, verified at HEAD as in Context (`lastEvent` and `lastEmitted` set before the sink decides, nothing returned). Scope item 2.
- **Field** ([field evidence](../../audits/2026-11-13-field-evidence.md), "F036 consistent..." and "Two of the gate's inputs never spoke on this Mac"): 19 of 25 suppressed AX readings had no follow-up within 5 s; `vad_unsupported` on 70 of 70 gate starts and `system_mute_state` read `muted=false` on 76 of 76, so nothing contradicted a wrong `muted_by_app`. Scope item 5 marks the reading unverified.

## Owner walkthrough

1. [owner] Install the landed build (`./scripts/rebuild.sh`) and use Teams as usual; nothing to do in the calls.
2. [session] After 30 Teams recordings, recount from `events.jsonl`: `log_mute_event` `lag_ms` distribution, `mute_reading_suppressed` by source, and the disagreements over 5 s against `mute_state_polled` that start within 1 s of a `log_mute_event`. Write the counts and the pass or fail of the field bar into this file.
