---
id: OBS7
title: No click, first-paint or window-open event exists, so click-to-feedback latency cannot be measured from the logs, and nothing fences main-thread blockers in view and controller code
category: Observability
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). daemon/Sources has no os_signpost, OSSignposter or run-loop observer and no event at a prompt, HUD, menu or hotkey click or at a first paint, so the responsiveness audit timed Record from completion-side rows and could time no Library or Preferences action. Scope: ui_action at each entry point and ui_feedback at the first visible state (systemUptime ms, shared sequence), first-paint rows for HUD and prompt, window_opened with cold and ms_to_key, a read-only scripts/latency_report.py, and a main-thread blocker fence (Fence B) with a reasoned allowlist.
---

# OBS7: No click, first-paint or window-open event exists, so click-to-feedback latency cannot be measured from the logs, and nothing fences main-thread blockers in view and controller code

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Sources: the "Instrumentation" section and the "Cannot be known without measuring" list of [2026-11-13-responsiveness-audit.md](../../audits/2026-11-13-responsiveness-audit.md), plus its findings P005 and P047 (folded in below). Every code claim was re-read at HEAD `3a2da4fc` on 2026-11-13.

**Nothing marks a click.** A grep of `daemon/Sources` finds no `os_signpost`, `OSSignposter` or `CFRunLoopObserver`, and no `ui_action`, `ui_feedback`, `first_paint` or `window_opened` row. The four prompt handlers in `MeetingPromptWindow` (`handleRecord`, `handleSkip`, `handleAlways`, `handleRecordBYO`) call the delegate and then `dismiss()` and log nothing; `RecordingHUDWindow.handleStop` fires a haptic and calls `delegate?.recordingHUDDidRequestStop(self)`; `Coordinator+MenuActions` is `@objc func menuStart() { session.toggleManual() }` and the same for `menuStop`; the hotkey closure registered in `Coordinator` is `DispatchQueue.main.async { self?.session.toggleManual() }`, so even the main-queue hop before the work is unmeasured. Two entry points already log at the click: `Coordinator.handleAutomation` emits `automation`/`command` with `verb` and `source` (the URL scheme and Quick Find handoff), and an idle attach emits `record_attached`. Everything else is visible only from the completion side.

**What that cost the audit.** For Record, the audit had to start every figure at the recorder.log `start:` line, which is written inside the start Task after an unlogged synchronous prefix (bounded at 6 to 241 ms, median 46, only from the 8 `record_attached` rows); on 74 work-laptop starts between 2026-09-29 and 2026-11-13 it measured `start:` to a paintable HUD at median 553 ms (era A, n=24) and 702 ms with p90 4.4 s and max 17.3 s (era B, n=44), and 104 to 137 ms plus once 3,270 ms (era C since 2026-11-12, n=6, stem `20261112-163040`). For Stop it used `state_change` to stopping up to the first teardown row. No Library, Preferences, Guide, Diagnostics or Quick Find action could be timed at all; the audit's cold-window figures (100 to 500 ms) are code-read guesses.

**P005 and P047, folded in (low).** On Stop, `MeetingSessionController.stopRecording` runs `coordinator.hud.dismiss()` and then, in the same main-thread job, `coordinator.lifecycleCoord.disengage()` and `coordinator.micGate.stop()`. `MicGate.stop()` calls `halSystemMuteProbe.stop()` and `halVadProbe.stop()`, and each is `runSync { teardown() }`, a synchronous hop onto the probe's queue that unsubscribes its HAL listeners. So the HUD fade cannot start until that teardown returns. Measured (state_change to stopping until the first lifecycle-disengage row): era C 28, 70, 169, 246, 262 and 337 ms (n=6, median 208), era B median 336 ms, p90 1,050 ms, max 1,289 ms (n=40). PERF15 and PERF24 removed most of the rest of that job (the AX walk and the status-menu rebuild), so at HEAD the residue is expected to be small, but HEAD has never run in the field and the HAL probe hops still hold. Correction at filing: the audit grades P005 "fixed at head not installed"; at HEAD the two `runSync` teardowns are still in the same main job as `hud.dismiss()`, so it is mostly fixed and unmeasured, not fixed.

**Adjacent, not this task.** The main-thread stall probe the audit lists as its item 3 is [PERF11](./PERF11.md) (amended by this band to a 100 ms threshold and to carry the last `ui_action` sequence). Build identity on each launch (its item 5) is [DIST6](./DIST6.md) and [OBS5](./OBS5.md)'s launch row. The visible Starting state and its Fence A test are [UX106](./UX106.md).

## Scope

1. **`ui_action` and `ui_feedback`.** A small `UILatency` helper in `daemon/Sources/MeetingPipe` (main-actor, a monotonically increasing sequence number, timestamps from `ProcessInfo.processInfo.systemUptime`, not wall clock). Call `UILatency.action(_:surface:)` as the first line of each entry point: the four prompt handlers, `RecordingHUDWindow.handleStop`, `menuStart`, `menuStop`, the hotkey closure (before the `DispatchQueue.main.async` hop, so the hop is inside the measurement), `notifierDidRequestStopRecording`, and the `.toggle`, `.record` and `.stop` arms of `handleAutomation`. It emits `ui_action` with `action`, `surface` and `seq`, and returns the sequence. Call `UILatency.feedback(seq:)` where the first visible state for that action is set (today `statusUI.setRecording` / `hud.present` on start and `hud.dismiss()` on stop; after [UX106](./UX106.md) lands, its Starting setter), which queues one `DispatchQueue.main.async` block and emits `ui_feedback` with `seq` and `ms` from inside it. Measuring on the next main turn rather than at the setter is the point: the state can paint only once the job that set it returns, so a synchronous tail after the setter (P005/P047's HAL teardown after `hud.dismiss()`) is inside `ms`. The completion side keeps its existing rows (`recording_started`, `recording_stopped`).
2. **First paint.** One row when the HUD and the prompt first draw (their content view's first `viewDidMoveToWindow` or `updateLayer` after `present`), and one when the prompt orders out, each carrying the triggering `seq` when one exists. With item 1, click to first pixel is a subtraction.
3. **Window opens.** In each opener (`LibraryWindow.show`, `PreferencesWindow.show`, `GuideWindow.show`, `DiagnosticsWindow.show`, `QuickFindWindow.show`) stamp a `ui_action` and log `window_opened` with `window`, `cold` (whether the window object was built on this call) and `ms_to_key`, measured to the window's `NSWindow.didBecomeKeyNotification`.
4. **`scripts/latency_report.py`.** Read-only, beside `scripts/dogfood_report.py`, reading every `events.jsonl` generation through the same reader the dogfood report uses: per action and per build (from [DIST6](./DIST6.md)'s build stamp when present, else split at `app_rebuild` rows), print n, median, p90 and max of `ui_feedback.ms`, of `ui_action` to first paint, of `ui_action` to the completion row, and of `window_opened.ms_to_key`.
5. **Fence B.** A check that fails on `waitUntilExit`, `DispatchQueue.main.sync`, semaphore and group `.wait(`, `Data(contentsOf:` and `contentsOfDirectory` in daemon view and controller files (a glob the pickup states: `*View*.swift`, `*Window*.swift`, `*Controller*.swift`, `*Pane*.swift`, the menu builders) outside an allowlist whose every entry carries a one-line reason. On 2026-11-13 the patterns hit 11, 0, 4, 48 and 26 times across `MeetingPipe/`, five view files among them (`MeetingDetailView`, `MeetingDetailView+Header`, `DigestsView`, `PreferencesView+Pipeline`, `PreferencesView+General`), so the seed list is short. It lives where [HYG10](./HYG10.md)'s `sources` allowlist fences live if that has landed (`scripts/truth_fences.py`, run by `scripts/ci-local.sh`), otherwise as a `scripts/ci-local.sh` step beside the design-token greps; one mechanism either way.
6. **P005/P047 decision, after the rows exist.** Read `ui_action` to `ui_feedback` for HUD Stop on an installed HEAD. If the residue between `hud.dismiss()` and the end of that main job is over one frame, make `HALSystemMuteProbe.stop()` and `HALVoiceActivityProbe.stop()` asynchronous (`queue.async`, generation bump first, as PERF15 did for the AX signals), so `MicGate.stop()` returns without waiting.

Every new row carries no meeting title, display name or text; `action`, `surface`, `window` and `seq` are fixed vocabulary. Each new category or action gets its row in `CONVENTIONS.md`'s event table in the same commit.

## Explicitly not

- The main-thread stall probe: [PERF11](./PERF11.md), which reads this task's `seq` when present and ships without it otherwise.
- Build identity on the launch row: [DIST6](./DIST6.md) and [OBS5](./OBS5.md).
- The Starting state, the prompt acknowledgement order and the answer to a press during Starting or Stopping: [UX106](./UX106.md), which also owns Fence A. Whichever of the two lands second wires `UILatency.feedback` into the Starting setter.
- Re-listing `Process()` sites or migrating them: [HYG10](./HYG10.md)'s allowlist and [CONC5](./CONC5.md)'s `ProcessRunner`. Fence B names patterns those two do not (`waitUntilExit` in a view is the only overlap, and its allowlist entry points at CONC5).
- `OSSignposter` intervals for Instruments. Useful for an owner-run trace, but the events above are what a field pack can read; add signposts only if a trace needs them.
- Library selection, Play, search, Trash and Cancel entry points. Same helper, added by the task that changes each control; the list above is the start, stop and window set the audit could not measure.

## Acceptance

- `UILatencyTests`: sequence numbers increase per action; `feedback` with a sequence emits `ms` from an injected uptime clock (no wall-clock subtraction) on the next main turn, so work done synchronously after the `feedback` call in the same job is counted; `feedback` for an unknown or already-answered sequence emits nothing.
- Controller tests with `FakeSessionHost`: a prompt Record, a HUD Stop, `menuStart`, the hotkey closure and an automation `.toggle` each emit exactly one `ui_action` before any other row of that action, and the matching `ui_feedback` carries the same `seq`.
- A window test per opener (or one parameterized): `window_opened` carries `cold: true` on the first `show()` and `cold: false` on the second.
- `latency_report.py` has a pytest over a canned two-build `events.jsonl` pair (rotated generation plus base) checking n, median, p90 and max per action and per build, and that it reads only.
- Fence B: a pytest (beside the truth-fence tests) shows a new `waitUntilExit` in a scratch view file fails the fence, an allowlisted site passes, an allowlist entry with no reason fails, and a removed listed site fails.
- New categories and actions in `CONVENTIONS.md`; `python3 scripts/truth_fences.py events` green.
- `cd daemon && swift build` and `swift test` green, `cd pipeline && uv run --extra dev pytest -q` green, N new tests named in the commit body; `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [session] Install the landing build on the work laptop (`./scripts/rebuild.sh`) and confirm a `ui_action` row appears on the first prompt Record.
2. [owner] Use the app normally for a week: at least five prompted recordings, two hotkey or menu starts, and one open each of Library, Preferences and Guide. Cost: none beyond normal use.
3. [session] Run `scripts/latency_report.py` on that week and paste the per-action table into this file; for HUD Stop, apply Scope item 6 only if `ui_action` to `ui_feedback` exceeds 16 ms at the median.
