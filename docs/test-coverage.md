# Test coverage - Coordinator + Coordination/

TECH-H4 audit of the unit-test surface for `Coordinator.swift` and its three
post-extraction subordinates (`DetectionStateMachine`, `MuteProbeSubsystem`,
`SinkDispatcher`). Each seam is listed with its current status and the explicit
reason when something is deferred.

Status legend:

- `✓` - at least one happy-path and one failure-path test exist.
- `⊝` - deferred; rationale stated. Re-evaluate when the constraint that makes
  it integration-heavy moves (TECH-G-MIC, TECH-C13, TECH-P4).
- `✗` - gap. Not deferred; should be filled.

Suite runtime budget (per `acceptance: CI runs in under five minutes`):
`swift test` on macos-14 currently completes in ~30 s for 305 tests. No
file-system fixtures over 1 MB.

---

## DetectionStateMachine

[`Sources/MeetingPipe/Coordination/DetectionStateMachine.swift`](../daemon/Sources/MeetingPipe/Coordination/DetectionStateMachine.swift)
- tests in [`DetectionStateMachineTests.swift`](../daemon/Tests/MeetingPipeTests/DetectionStateMachineTests.swift) (10 cases).

| Seam | Status | Tests |
|---|---|---|
| Initial state is `.idle` and accepts prompts | ✓ | `test_starts_idle_and_accepts_prompts` |
| `setPrompting` blocks further prompts | ✓ | `test_setPrompting_blocks_further_prompts` |
| `setRecording` / `setStopping` carry payload | ✓ | `test_setRecording_and_setStopping_carry_payload` |
| `onIdleTransition` fires on each idle entry | ✓ | `test_setIdle_fires_onIdleTransition_each_time` |
| Cooldown facade (record / clear / isCoolingDown) | ✓ | `test_cooldown_facade_round_trips` |
| Pending refresh: idle-gated, idempotent | ✓ | `test_pending_refresh_is_idempotent_and_idle_gated` |
| Prompt timeout fires when source unchanged (happy) | ✓ | `test_prompt_timeout_fires_only_when_still_prompting_same_source` |
| Prompt timeout: cancelled before fire (failure) | ✓ | `test_prompt_timeout_cancelled_does_not_fire` |
| Prompt timeout: state changed before fire (failure) | ✓ | `test_prompt_timeout_skipped_when_state_changed` |
| `label(_:)` JSONL stability | ✓ | `test_label_is_stable_for_jsonl_events` |

No outstanding gaps.

## MuteProbeSubsystem

[`Sources/MeetingPipe/Coordination/MuteProbeSubsystem.swift`](../daemon/Sources/MeetingPipe/Coordination/MuteProbeSubsystem.swift)
- tests in [`MuteProbeSubsystemTests.swift`](../daemon/Tests/MeetingPipeTests/MuteProbeSubsystemTests.swift) (8 cases).

The AX `evaluator` and `windowCapture` are closure-typed and injectable, so
no AX trust or real meeting client is needed at test time.

| Seam | Status | Tests |
|---|---|---|
| `arm(source:enabled:)` no-op when disabled (failure) | ✓ | `test_arm_no_op_when_disabled` |
| `arm` no-op for browser sources (failure) | ✓ | `test_arm_no_op_for_browser_source` |
| `arm` no-op when window-capture returns nil (failure) | ✓ | `test_arm_no_op_when_window_capture_returns_nil` |
| `arm` succeeds for native source with handle (happy) | ✓ | `test_arm_succeeds_when_handle_captured` |
| `tick` emits paused/resumed transitions (happy) | ✓ | `test_tick_emits_pause_on_muted` |
| `tick` ignores `.unknown` verdict (failure) | ✓ | `test_tick_ignores_unknown_verdict` |
| `disarm` resets cache so a re-arm re-emits | ✓ | `test_disarm_resets_state_so_a_fresh_arm_re_emits` |
| `tick` before `arm` is a no-op (failure) | ✓ | `test_tick_before_arm_is_a_no_op` |

⊝ Real AX walk against a live meeting client. Deferred to manual smoke + the
TECH-C6 detection corpus. The injected-closure tests pin the precedence and
caching logic; the integration tier verifies the AX subtree mapping.

## SinkDispatcher

[`Sources/MeetingPipe/Coordination/SinkDispatcher.swift`](../daemon/Sources/MeetingPipe/Coordination/SinkDispatcher.swift)
- tests in [`SinkDispatcherTests.swift`](../daemon/Tests/MeetingPipeTests/SinkDispatcherTests.swift) (5 cases).

| Seam | Status | Tests |
|---|---|---|
| `enqueue` starts first job + emits depth callback (happy) | ✓ | `test_enqueue_starts_first_job_and_updates_depth` |
| Second `enqueue` waits for first to finish (serialization) | ✓ | `test_second_enqueue_does_not_start_until_first_completes` |
| `onJobCompleted` fires on success (happy) | ✓ | `test_success_fans_out_via_onJobCompleted_on_main` |
| `onJobCompleted` fires on failure + queue advances | ✓ | `test_failure_fans_out_and_advances_queue` |
| Depth callback fires on completion too | ✓ | `test_queue_depth_callback_fires_for_completion_too` |
| `startStreaming` / `stopStreaming` lifecycle | ⊝ | `StreamingTranscriber` is a `final class` that spawns `mp transcribe-stream`. Subprocess-bound; a protocol seam would let us inject a fake but adds churn beyond TECH-H1's scope. Covered by manual smoke and the `dogfood-report` script (TECH-E4). |

## Coordinator

[`Sources/MeetingPipe/Coordinator.swift`](../daemon/Sources/MeetingPipe/Coordinator.swift)
- no dedicated unit-test file. Each delegate / subsystem invariant the
Coordinator orchestrates is covered through the type it owns.

| Seam | Status | Reason / fixture |
|---|---|---|
| `init` / property wiring | ⊝ | Constructing a `Coordinator` requires `StatusBarController`, `Notifier`, `MeetingRecorder`, `HotkeyManager`, `LibraryWindow`. NSWorkspace + AppKit + LaunchAgent surfaces that can't run headless on CI without a desktop session. |
| `start()` | ⊝ | Side-effecting: registers global hotkeys (Carbon), spawns permission prompts, attaches the model-download supervisor. Behaviour is observable via `events.jsonl` (`permission_granted`, `dry_run_enabled`) and exercised by manual smoke. |
| `shutdown()` | ⊝ | Best-effort cleanup; same constraints. |
| `@objc menuStart / menuStop` | ⊝ | Pure delegation to `toggleManual`. State machine is covered in `DetectionStateMachineTests`. |
| `@objc menuOpenLogs / menuOpenRecordings / menuPreferences / menuOpenLibrary` | ⊝ | NSWorkspace.open / NSWindow.show pass-throughs. |
| `retryMeeting(stem:)` | ⊝ | `FileManager.exists` + `SinkDispatcher.enqueue`. The enqueue path is covered in `SinkDispatcherTests`; the file-existence branch is a one-liner. |
| `regenerateMeeting(stem:completion:)` | ⊝ | Wraps `PipelineLauncher.summarize`; covered indirectly via the launcher fake in `PipelineLauncherTests`. |
| `softDeleteMeeting(stem:)` | ⊝ | `FileManager.trashItem` against the user's recordings dir. Side-effecting; manual smoke. |
| `exportMeeting(stem:to:)` | ⊝ | File copy across two URLs. Side-effecting; manual smoke. |
| `republishMeeting(stem:completion:)` | ⊝ | `PipelineLauncher.publish` wrapper; covered indirectly. |
| `recentCorrectableMeetings(limit:)` | ⊝ | Reads `<stem>.run.json` mtimes from `liveOutputDir`. Pure I/O; lifts cleanly to a static helper, but the call sites that read it (status-bar submenu, library window) are integration-tested manually. |
| `setPendingWorkflowOverride(_:)` / `currentActiveWorkflow` / `workflowForPrompt` | ✓ | Forwards to `WorkflowMatcher.resolve`; covered in `WorkflowMatcherTests`. |
| `DetectorDelegate.detector(_:event:)` | ⊝ | Routes detector events into the state machine + cooldown facade. Both are covered in `DetectionStateMachineTests`. The route itself is a 12-line switch. |
| `NotifierDelegate.didChooseRecord / didChooseSkip / didChooseAlways` | ⊝ | Same pattern: each just calls a state-machine setter and optionally the cooldown facade. Pin-tested at the subordinate level. |
| `MeetingPromptDelegate` extension | ⊝ | Funnels into `NotifierDelegate` handlers. |
| `RecordingHUDDelegate.recordingHUDDidRequestStop` | ⊝ | One-line `toggleManual` forward. |
| Mute-probe wiring (`onTransition` → `recorder.micPaused`) | ⊝ | Two-line closure inside `wireSubsystems`. The probe's transition emission is covered in `MuteProbeSubsystemTests`; the recorder side gets the same `Bool` write it got pre-refactor. Replaced wholesale by TECH-G-MIC's `MicGateWriter.apply`. |

### Decisions

- **No `CoordinatorTests.swift`.** The post-extraction orchestrator is mostly
  a wiring shell. Every block of branching logic lives on a type that has
  its own test file. Constructing a real `Coordinator` to test those
  shells would need a deep stub harness (statusbar, recorder, notifier,
  hotkey, library, prefs) for no behavioural coverage gain.
- **No protocol seam for `StreamingTranscriber`.** Adds API surface
  (TranscriberDriver, fake) for one untested method (`startStreaming`).
  TECH-G-MIC and TECH-P4 are likely to reshape the streaming path entirely,
  so wait for that refactor rather than locking in a contract now.
- **Per the spec's stop-and-ask gates** (no fixtures > 1 MB, no new
  dependencies), nothing in this audit triggers a halt.

## Other types under audit

Existing test files already cover the major non-Coordination types
(`RepromptCooldown`, `MeetingMuteProbe`, `MeetingWindowProbe`,
`SilenceDetector`, `MeetingFilter`, `WorkflowMatcher`, etc.). Their seams
are at-least-one-of-each per the existing tests; no gaps surfaced during
this audit.
