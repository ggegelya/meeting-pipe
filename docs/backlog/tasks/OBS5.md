---
id: OBS5
title: The logs cannot say why a recording stopped, why the daemon exited, which backend a run expected, which mic took over mid-meeting, or that a permission or the meeting-apps overlay was lost
category: Observability
status: new
priority: P2
comment: Filed 2026-10-25 (observability band, O11: LG-6, LG-1, LG-3, LG-9, LG-12, LG-16): five stop paths share toggleManual with no trigger, exit writes nothing, each launch logs 4 fake grants and no revocation, saves and expected backend go unlogged, a mic change names no device, a bad overlay is silent. Stop trigger, daemon terminating, permission_changed, expectedBackend, names-only save events, registry_loaded. Amended 2026-10-25 (performance review): UI-13: `PermissionsCenter.commit` assigns every probe result unconditionally, so the 2 s Permissions-pane poll fires four `objectWillChange` per tick with nothing changed (three more per menu open); item 3's `commit` starts with `guard prev != status else { return }`, before the assignment and both sends. [Spec](./OBS5.md) Amended 2026-11-13 by the audit band: 10 of 74 field stops have no cause, so stop_cause covers every stop route, the stop banner names it, and a launch row with commit and launch id plus an hourly heartbeat are added; the reliability plan sequences this first.
---

# OBS5: the logs cannot say why a recording stopped, why the daemon exited, which backend a run expected, which mic took over mid-meeting, or that a permission or the meeting-apps overlay was lost

Band origin: filed 2026-10-25 from the 2026-10-25 observability audit band ([audit](../../audits/2026-10-25-observability-audit.md) row O11; finders LG-6, LG-1 remainder, LG-3, LG-9, LG-12, LG-16). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Verified in code on 2026-10-25 (base `01e904a`); runtime lines are from the owner's logs on this Mac.

**Why a recording stopped.** `MeetingSessionController.stopRecording(file:source:summaryMode:)` emits `coordinator` / `recording_stopped` with `file`, `bundle_id`, `system_audio_frames` and `produced_final` only. The menu's Stop row (`Coordinator.menuStop`), the manual hotkey, the HUD's Stop (`recordingHUDDidRequestStop`), the notification's Stop (`notifierDidRequestStopRecording`) and the automation `toggle` verb all call `toggleManual()`, which writes nothing of its own. The automatic stops do log a row first (`force_stop`, `mic_in_use_stop`, `auto_stop_silence`, `recording_ended_during_start`, and the lifecycle `ended` row before `handleMeetingEnded`), so "why" is answered by elimination, and one lost row defeats it. That happened on 2026-10-16: 20261016-122748 stopped at 09:46:28.257Z after `lifecycle` `ending_provisional` at 09:46:08Z, with no `ended`, no `force_stop`, no auto-stop row, and the only torn line in `events.jsonl` at 09:46:28.265Z. Whether the owner pressed Stop or the end engine confirmed cannot be established.

**Why the daemon exited.** `AppDelegate` logs `"MeetingPipe starting"` and `"SIGTERM received - flushing recorder before exit"` with `Log.main.info`, which macOS does not persist, and `flushAndExit` writes nothing before `exit(relaunch ? EXIT_FAILURE : EXIT_SUCCESS)`. The 2026-10-18 11:59:56Z relaunch (pid 60078 gone, 77137 up a second later) is visible only in loginwindow's system log. The LG skeptic downgraded the finder's high: launches can be reconstructed from `engine_resolved` plus the `permission_granted` rows, so what is missing is the termination reason. The launch identity event belongs to [DIST6](./DIST6.md) item 2 and the requested-relaunch marker to [UX82](./UX82.md) item 1.

**Grants that never happened, revocations never logged.** `PermissionsCenter.commit` sends `permissionGranted` only when `status == .granted && prev != .granted`, and every status starts `.unknown`, so each launch's first observation is reported as a grant: 4 `coordinator` / `permission_granted` rows at 2026-10-18T11:59:58Z for grants made months earlier. A transition away from granted sends nothing, so a Screen Recording revocation shows up only as `system_audio_frames: 0` later. No pipeline or script reader uses `permission_granted` (grep of `pipeline/src` and `scripts/`).

**Which backend, and when settings changed.** `pipeline_started` carries `file` and `kind`; `retry_requested` carries `stem` and `scope`. Nothing logs a config, workflow or secret save. On 2026-10-16 the owner hit an Apple Intelligence `unsupported language` failure at 07:33:59Z, changed the global backend (config.toml mtime 07:36:04Z), retried twice into the same failure because the meeting's `meta.json` pinned `workflow_backend: apple_intelligence`, and the next meeting failed on a missing Anthropic key. The edit linking them exists only in file mtimes. `PipelineLauncher.cloudSecretPolicy(for:backendOverride:configURL:)` already resolves regulated, override, sidecar and global in that order, and throws the answer away after choosing tokens.

**Which mic took over.** `InputDeviceRecovery` emits `configuration_change_recovered` with `live_sample_rate`, `used_converter` and `gap_frames`; the device is named only at start (`input_device_resolved`, from `InputDeviceResolver.resolveDefaultInput()`). Reached 4 times on 2026-10-16 (07:33:11Z, 07:33:19Z, 09:46:10Z, 09:46:24Z).

**The meeting-apps overlay.** `MeetingAppRegistry.load(overlayURL:)` unions the overlay only `if let ... try? String(contentsOf: overlayURL ...), let overlay = parse(...)`, with no else branch, and a missing bundled list is `Log.detector.warning("meeting_apps.toml not found; using empty lists")`. README tells the owner to drop an overlay to fix a missed meeting; one TOML typo gives the same miss and no line anywhere.

## Scope

Failure-shaped rows below go through OBS1's `Log.failure`; the rest are `Log.event` plus a `Log.writeLine`, the CONVENTIONS pair.

1. **Stop trigger.** A `StopTrigger` enum (`menu`, `hotkey`, `hud`, `notification`, `automation`, `lifecycle_end`, `end_during_start`, `force_stop`, `silence`, `mic_release`) passed through `toggleManual(trigger:)` and `stopRecording(...trigger:)` from each caller named above, written as `trigger` on `recording_stopped` and in its `daemon.log` line. `forceStop(reason:)` passes `force_stop` and keeps its own `reason`.
2. **Termination reason.** `flushAndExit` takes a reason (`quit` from `applicationWillTerminate`, `sigterm` from the signal source) and writes `daemon` / `terminating` with `reason`, `relaunch` (the resolved exit choice) and `uptime_sec` as its first statement, before `coordinator?.shutdown()`. If UX82 lands first, `relaunch` reads its requested-relaunch marker. A launch with no `terminating` row before it is then a crash or a kill, readable from the log alone.
3. **Permission transitions.** `PermissionsCenter.commit` emits `coordinator` / `permission_changed` (`kind`, `from`, `to`, `at_launch` when `prev == .unknown`) on every change, and `Coordinator`'s `permission_granted` row is retired. The `refreshNow` and menu-refresh side effects stay exactly as they are.
4. **Expected backend.** Factor the resolution out of `cloudSecretPolicy` into `PipelineLauncher.expectedBackend(for:backendOverride:configURL:) -> (backend, source)` with `source` one of `regulated`, `override`, `sidecar`, `global`, and put both on `pipeline_started` and every `retry_requested`. `cloudSecretPolicy` calls it, so the two cannot drift. Named "expected" because Python's `auto` may still fall back (OBS2 records that).
5. **Save events, names only.** `daemon` / `config_saved` with the dotted key paths whose serialized value changed since the last persist (`summarization.backend`, `modes.regulated_mode`), `workflow` / `workflow_saved` with the workflow id and changed field names, and `daemon` / `secret_saved` with the account and `set: true|false`. Never a value: config values include paths and workflow names, and secrets are secrets.
6. **Device on recovery.** `configuration_change_recovered` adds the re-resolved device's `eventAttributes` (name, uid, transport, sample rate) under `device_` keys, and its `recorder.log` line names the device.
7. **Registry load.** `detector` / `registry_loaded` at launch with `native`, `browser` and `fragment` counts and `overlay: absent | applied | rejected`; `rejected` and a missing bundled list go through `Log.failure` with the parse error.
8. CONVENTIONS.md lists the new actions and the retired `permission_granted` in the same commit; all categories already exist.

## Explicitly not / out of scope

- The launch event with version, build and commit: DIST6 item 2. The relaunch-versus-crash marker and the crash-loop breaker: UX82.
- Recording device changes in `<stem>.meta.json`. A sidecar schema change touches both trees and the contract fixture; the event is enough to answer the question, and [MIC17](./MIC17.md) owns what the stop-time device name drives.
- Run id and stem on these rows: OBS4.
- `mp analyze-detection` reading `trigger`. It pairs starts and stops by `file` and keeps working; using the trigger in its false-end report is a follow-up.
- A per-poll permission row. Only transitions are logged.

## Acceptance

- `recording_stopped` carries the right `trigger` for each of the ten paths, driven through `MeetingSessionController` with the existing fakes.
- `flushAndExit`'s reason reaches a `terminating` row before shutdown runs (with `terminationCeilingExits` off, as `AppDelegateRelaunchTests` does).
- `PermissionsCenter`: unknown to granted emits `at_launch: true`; granted to denied emits a row; an unchanged status emits nothing.
- `expectedBackend` table test over regulated, override, sidecar and global, and `cloudSecretPolicy` unchanged for each.
- `config_saved` names only the changed key after a one-field edit and carries no value; `secret_saved` carries no secret.
- `registry_loaded` for an absent, a valid and a malformed overlay.
- `cd daemon && swift test` green, `python3 scripts/truth_fences.py` green, `bash scripts/ci-local.sh` green. N new tests in the commit body.

## Amended 2026-10-25 (performance review)

The 2026-10-25 performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified) found the re-render cost of the function item 3 edits, in its finding UI-13 (verified low). Re-checked against the tree on 2026-10-25.

`PermissionsCenter.commit(_:kind:status:)` reads `let prev = self[keyPath: keyPath]` and then assigns `self[keyPath: keyPath] = status` unconditionally, so every probe fires `objectWillChange` even when nothing changed. `startPolling` runs `refreshAll()` every 2 s while the Permissions pane is visible, four commits per tick, so the pane's `@ObservedObject` body (and the onboarding permissions step while it is shown) re-renders four times every 2 s with no change, and each status-menu open adds three more through `refreshMenuRelevantSync()`. The status bar is not affected: its `CombineLatest4` pipeline applies `removeDuplicates`.

Item 3 additionally must start `commit` with `guard prev != status else { return }`, before the assignment, the new `permission_changed` event and the existing `permissionGranted` send. The granted side effect already requires `prev != .granted`, so it is unchanged, and the guard makes item 3's "an unchanged status emits nothing" true by construction rather than by a second check.

Added acceptance:

- A `PermissionsCenterTests` case: committing an unchanged status fires no `objectWillChange` (a subscriber counts zero) and no event; `.unknown` to `.granted` fires exactly one `objectWillChange` and still sends `permissionGranted`.

## Amendment 2026-11-13 (audit band)

Added from the [2026-11-13 recording-reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) (its plan's Patch A and stage 1, and lows D070, D087 and D088; D070's full entry is in the [evidence](../../audits/2026-11-13-recording-reliability-evidence.md)) and the [field evidence](../../audits/2026-11-13-field-evidence.md) findings "The log cannot answer several questions this audit needed" (Sessions section, class key sessions-and-lifecycle#13) and "No start, stop or heartbeat event; uptime cannot be measured" (Daemon health section, daemon-health-and-audit-crosscheck#8). Re-verified in code at HEAD (`3a2da4fc`) on 2026-11-13.

**Field evidence (work laptop, 2026-09-29 to 2026-11-13, 74 recordings).** 10 of 74 stops have no cause row; D070's 3 s look-back before each recording-to-stopping transition finds 62 `lifecycle/ended`, 1 `auto_stop_silence` and 11 with nothing (2 in build A, 6 in B, 2 in C). Both cause-less stops of the newest build are on 2026-11-12, including stem 20261112-174606 stopped at 15:56:54Z. `coordinator/force_stop` never appears. The only launch marker is `transcription/engine_resolved`; there is no shutdown row, two relaunches (2026-09-30T13:18 and 2026-10-22T20:19) have no recorded cause, and 3 of 12 launches in 45.9 days have no cause at all. `permission_granted` fires for all four kinds at every launch (item 3 already covers it). No `detector/mic_busy_*` row exists in 38 days, so a prompt cannot be timed against mic activity. In eras 1 and 2, 28 of 74 `lifecycle_end_held` rows were logged while the state was already stopping; era 3 has 0 of 9 and the D audit reads them as log-order artefacts, so that needs no scope here. Working out which code produced each failure took first-seen event names plus `git log`.

**The plan sequences this first.** Patch A (stage 1, about a day, one commit) is "make the log attributable": a launch row with the build commit and a launch id, a cause on every `recording_stopped`, and a row when a lifecycle end withdraws a prompt, because every later stage's exit is judged from these rows. Its exit: one working week in which every `recording_stopped` carries a cause and every launch names a commit, with the new names in `scripts/truth_fences.py` in the same commit.

**Verified at HEAD.** `stopRecording(file:source:summaryMode:)` has six callers, all in `MeetingSessionController`: `toggleManual` (menu Start/Stop, the manual hotkey, the HUD and notification Stop, the automation `toggle`), `forceStop(reason:)` (reasons `hotkey`, `url_scheme`, `low_space` from REC20's `handleLowSpace`, and `write_failure_<channel>` from `Coordinator`'s `recorder.onWriteFailure`, the route REC25's `writer_stalled` decision takes), the REC7 ended-during-start path, `handleMicBusyBundle`, `handleMeetingEnded` (the lifecycle end), and `handleIdleAutoStop`. `Coordinator.shutdown` does not call it: it runs `recorder.flushIntermediatesForTermination()` and the next launch's orphan sweep merges the recording (`orphan_recording_recovered`). `Notifier.notifyProcessing(file:)` posts the same "Recording stopped" title for every route. `Log.event` writes `ts`, `category` and `action` plus the caller's attributes, with no build or launch identity, and `RebuildTagger.runOnce` emits `main` / `app_rebuild` with `prev_cdhash` and `new_cdhash` only when the cdhash changes; a cdhash maps to no commit. None of `stop_cause`, a launch row, a heartbeat, `prompt_withdrawn` or `prompt_dismissed` exists in `daemon/Sources`.

Corrections at filing: D070 and the class summary count seven `stopRecording` call sites; there are six at HEAD. `shutdown` cannot be a `recording_stopped` cause because shutdown never reaches `stopRecording`; it belongs on item 2's `terminating` row and on the recovery row. `low_space` and the writer stall already log `force_stop` with a reason, so the gap there is only that item 1 would fold them into one `force_stop` value. The HUD is dismissed at stop, so D070's "carry the cause into the HUD" has nowhere to show; the stop notification is the surface. The plan's `prompt_withdrawn` and the field's `prompt_dismissed` are already one row in [DET18](./DET18.md) item 6 (`prompt_dismissed` with reasons including `withdrawn_definitive` and `withdrawn_mic_released`, and `pointer_over`), so this task adds no second name.

**Scope additions.**

1. **Item 1 becomes `stop_cause`.** The attribute on `recording_stopped` (and in its `daemon.log` line) is named `stop_cause`, the name the plan's stage exits and D070 use, and the enum `StopCause`. Values: `user_stop` and `user_stop_during_hold` (a user stop while `coordinator.lifecycleCoord.current` is `.endingProvisional`), each with `stop_surface` (`menu`, `hotkey`, `hud`, `notification`, `automation`); `lifecycle_end`; `ended_during_start`; `idle_backstop` (item 1's `silence`); `mic_release`; `force_stop` with `force_reason` (`hotkey`, `url_scheme`); `low_space`; `writer_stalled` (any `onWriteFailure` force-stop, with `channel`). Item 2's `terminating` row carries `recording_open: true` when a recording was live, and `orphan_recording_recovered` carries `stop_cause: shutdown` when the recovered stem was open at a logged `terminating`, else `unclean_exit`.
2. **The cause reaches the owner.** `notifyProcessing` takes the cause and its title says which route stopped the recording (the call ended, you stopped it, the mic went quiet, the disk is nearly full, writing stalled), so a wrong automatic end is visible at the moment it happens. GUIDE.md's recipe for the stop notification changes in the same commit. A Library row badge needs the cause in `<stem>.meta.json`, a both-trees sidecar change this task declines above; it is named here as the follow-up.
3. **A launch row.** `main` / `launched`, emitted right after `RebuildTagger.runOnce`, with `pid`, `cdhash`, `commit` and `pipeline_commit` (from [DIST6](./DIST6.md) item 2's plist stamp; `unknown` until it lands), `launch_id` (a fresh UUID), and `previous_exit` (item 2's last `terminating` reason, persisted at that row, or `unclean` when the previous launch wrote none). `Log.event` stamps `launch_id` on every row. DIST6 item 2's launch event is this row, extended there with version and build, not a second row; whichever lands first defines the name `main` / `launched`.
4. **An hourly heartbeat.** `main` / `heartbeat` once an hour with `launch_id`, `uptime_sec`, the controller state, and the mic-holder reading [DET10](./DET10.md)'s amendment routes through DET23's monitor (absent until that lands), so uptime and a silent detector are measurable from the log.
5. **Prompt rows.** If this lands before DET18, `handleMeetingEndedDuringPrompt` emits DET18's `prompt_dismissed` with `reason: withdrawn_definitive` under DET18's exact schema, and DET18 adds the other reasons.
6. CONVENTIONS.md and `scripts/truth_fences.py` list every new action and attribute in the same commit.

**Acceptance additions.**

- `recording_stopped` carries the right `stop_cause` (and `stop_surface` or `force_reason` where it applies) for each of the six callers, including a user stop with a fake lifecycle in `.endingProvisional` yielding `user_stop_during_hold`, `handleLowSpace`'s stop yielding `low_space`, and an `onWriteFailure` decision yielding `writer_stalled`.
- `notifyProcessing` copy differs for `lifecycle_end`, `user_stop` and `idle_backstop` (a presentation test).
- A launch writes exactly one `launched` row with a `launch_id` that every later row in the test carries; `previous_exit` reads the persisted `terminating` reason, and `unclean` without one.
- A heartbeat decision test (pure clock in, emit or not out) emits once per hour and not on a shorter gap.
- Field bar, read from `events.jsonl` after install on the work laptop: one working week in which every `recording_stopped` carries a `stop_cause` and every launch row names a commit (the plan's stage 1 exit), against 10 of 74 stops and 0 of 12 launches today.
- `cd daemon && swift test` green, `python3 scripts/truth_fences.py` green, new test count in the commit body.

Related: [UX82](./UX82.md) (requested-relaunch marker), [OBS4](./OBS4.md), [REC20](./REC20.md), REC25 (done), [DET19](./DET19.md) (the detection report can then read `stop_cause` instead of inferring hand stops by elimination), [OBS7](./OBS7.md) (click rows).
