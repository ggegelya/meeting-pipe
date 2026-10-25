# OBS5: the logs cannot say why a recording stopped, why the daemon exited, which backend a run expected, which mic took over mid-meeting, or that a permission or the meeting-apps overlay was lost

Band origin: filed 2026-10-25 from the 2026-10-25 observability audit band ([audit](../../audits/2026-10-25-observability-audit.md) row O11; finders LG-6, LG-1 remainder, LG-3, LG-9, LG-12, LG-16). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

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
