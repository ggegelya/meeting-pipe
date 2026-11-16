---
id: END28
title: Switching quickly from one Teams call to another keeps recording into the first call's stem, because every signal that reverts a hold is about the app rather than the call
category: Detection
status: partial
priority: P1
comment: Shipped 2026-11-16 on the owner's decision (b), split then prompt. `AXLeaveButtonSignal` caches the Leave button's window (hash, title, subrole); the pure `CallIdentityTracker` splits when both the window and the title change and hold for two reads 4 s apart; a 2 s per-recording tick ends the stem (`stop_route: call_changed`) and raises the record prompt for the new call, whose stem carries `split_from` (sidecar schema 5). Remainder: the field check after an install, the owner's (two quick Teams switches give two stems and two notes; a screen share started and stopped, and one call held while another is joined, give no split row), since a share toolbar or a held call carrying its own Leave window would split a live meeting and that is unverified; the 2026-11-12 replay is a hand-built session test because the raw rows carry no Leave-window title.
---

# END28: switching quickly from one Teams call to another keeps recording into the first call's stem, because every signal that reverts a hold is about the app rather than the call

Band origin: filed 2026-11-12 from the owner's report "when I switch between two meetings quickly, the new one still writes as the first one", traced in-session the same day. A gap in [END17](./END17.md)'s revert rule, which is behaving as designed; [END27](./END27.md) is the same afternoon's other END17 defect. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## What happened

All times UTC from `~/Library/Logs/MeetingPipe/events.jsonl` (the owner is UTC+2). The call window titles (meeting subjects and chat names redacted here; verbatim in the log) come from `signal`/`shareable_content_no_match` rows, whose `candidate_titles` list the Teams windows `ShareableContentSignal` saw; it logs them on change, and only while the title match fails, which since the 2026-10-08 Teams title change is always ([END14](./END14.md)).

| Time (UTC) | Rows | Reading |
|---|---|---|
| 15:23:03.544 | `lifecycle`/`starting`; 15:23:07.433 `recording_started` `20261112-172307.wav` | Call 1: `candidate_titles: ["<standup subject>"]` |
| 15:29:11.019 | `ending_provisional` lead `ax_leave_button_invalid`; `lifecycle_end_held` `live_signal: call_is_up`, `log_written_sec_ago: 488.7` | The owner switches calls. Process audio stays live across the switch |
| 15:29:19.297 | `lifecycle`/`in_meeting` (hold reverted after 8 s) | The new call's Leave button reads healthy |
| 15:29:19.661 | `shareable_content_no_match` `["<SSO call subject>"]` | Call 2's window, 364 ms after the revert |
| 15:39:16.643 | `ending_provisional` lead `process_audio_is_running_input_false`; `lifecycle_end_held` `live_signal: call_is_down`, `log_written_sec_ago: 588.8` | The owner leaves call 2 |
| 15:39:38.663 | `lifecycle`/`in_meeting` (hold reverted after 22 s) | Teams holds the mic again |
| 15:39:42.648 | `shareable_content_no_match` `["<standup subject>", "Chat | <person>"]` | Call 3's window |
| 15:44:27 to 15:45:27.963 | hold opened, then `lifecycle`/`ended` on the 60 s pair dwell; `recorder`/`held_end_trimmed` `limit_sec: 1280.5` | The owner leaves call 3 |

The pipeline published one note for the whole stem, `2026-11-12 sso-troubleshooting-dms-release-verification-sync.md`, attendees and topics from both meetings mixed. The owner's only recourse today is a manual split.

## Why it happens

`PromotionEngine.handleEndingProvisional` reverts a hold to `.inMeeting` when a `.live` reading arrives from the lead's evidence class, a returning signal, or a vetoer. That is END17's design, built to absorb the false ends of END9 to END15 (an AX blackout, a mic switch, a title format). Every input to it describes the app: is the Leave button there, does the app hold the mic, does it have a call window. A new call in the same app makes all three live again within seconds, so to the engine a quick switch looks exactly like a false end that recovered, which is the case the hold exists to absorb.

The only per-call evidence the engine has is `CallTeardownOracle`'s SlimCore `UnregisterCall` line, which confirms a hold at once when it is on disk. It was not on disk in time either time (`log_written_sec_ago` 488.7 and 588.8; Teams buffers that log, see [END12](./END12.md)). It cannot be relied on to separate two calls, and the hold must not wait on it.

The call window's title does carry call identity, and the daemon already reads it every poll: it changed at both switches (`<standup subject>` to `<SSO call subject>` to `<standup subject>`). Nothing consumes it since the title match broke. The title is the meeting subject, set by the organiser, so it survives Teams UI changes in a way a localized control label does not.

## Scope

1. **A call identity per recording.** When recording starts, record the call window's title as the recording's call identity, and keep observing it. Source it from the window that holds the call controls (the AX window the Leave/Mute handles were built from, `MeetingAXHandleBuilder`), not by filtering `ShareableContentSignal`'s candidate list. That list also carries chat windows (`"Chat | <person>"`, `"Chat | <group>"`), and telling them apart by a `Chat | ` prefix would be localized-label scraping. If the AX window title is unavailable, fall back to no identity, never to a guess.
2. **Split on change.** When the observed call identity changes to a different non-nil value while recording (in `.inMeeting` or in a hold), end the current stem at the change and start a new stem without a prompt, under the same workflow and summary mode. The check must not hang off the hold's revert: at 15:29 the revert came 364 ms before the new title was readable, so the trigger is the title change itself. The new stem records `split_from: <stem>` in its sidecar (not `resumed_from`, which tells the Library to offer a merge, the wrong suggestion for two meetings), and the event log gets `coordinator`/`recording_split_on_call_change` with `bundle_id`, `split_from`, and both titles. Titles go only into the event log and sidecar, which already hold meeting titles.
3. **Same title is not proof of the same call.** A recurring meeting can be rejoined under the same title (call 3 above may be exactly that), so an unchanged title never vetoes an end and never reverts a hold by itself. This task adds a split signal only; it does not make the title a liveness signal.
4. **Sidecar contract.** `split_from` is a new sidecar key: Swift writer, Python reader and `test_workflow_overlay.py` together, per `CONVENTIONS.md#sidecar-schema-stem-metajson`.

**Decision the pickup session must put to the owner before building item 2's no-prompt split:** [DET13](./DET13.md) recorded "any policy here returns prompt, never record" for back-to-back meetings, and END17 item 5 overrode it for resumes on 2026-10-24. Splitting under the current workflow is no worse than today, which records the second call under the first call's workflow anyway, so it is the default this spec proposes; prompting on the split is the alternative. The owner picks.

## Explicitly not

- **Not one WAV with split markers resolved in the pipeline.** It would be gapless, but it touches the recorder, the merge, the transcript, and every stem-keyed surface. A stop and start costs a gap of the order the resume path already accepts.
- **Not SlimCore call IDs.** They are the stronger identity, but the log is buffered and flushes late (`log_written_sec_ago` above), and the shell harness cannot even read it (TCC). Revisit only if the window title proves unreliable in the field.
- **Not re-splitting `20261112-172307` or its note.** The owner splits it by hand if wanted; this task changes recordings made after it lands.
- **Not END27's wedge**, which is the same afternoon's other END17 defect and lands independently.
- **Observed, not filed:** browser meetings have the same shape (switching Meet tabs keeps one tab-title signal's app identity), and the tab title is the analogous identity. Out of scope until a browser meeting is recorded at all (the owner's meetings are Teams-only).

## Acceptance

- `PromotionEngineTests` or the coordinator's tests (wherever the identity lives), failing first: a recording whose call identity changes from A to B while `.inMeeting` produces a split; a change from A to B during a hold produces a split, not a revert into A's stem; A to nil (title unreadable) and A to A produce no split; a hold whose title stays A still reverts as today.
- A lifecycle replay of 2026-11-12 15:23:03 to 15:45:28 extracted with `scripts/extract_detection_trace.py --raw` into `DetectionCorpusTests`, asserting splits at the 15:29 and 15:39 switches (three stems), and the existing END9 to END15 corpus traces unchanged.
- Sidecar round trip: a `split_from` written by Swift is read by Python, pinned in `test_workflow_overlay.py`; the Library offers no merge for a `split_from` pair.
- `cd daemon && swift test` and `cd pipeline && uv run --extra dev pytest -q` green with the new tests (counts left to the implementing session); `bash scripts/ci-local.sh` green. `docs/GUIDE.md` updated in the same commit if a recipe mentions one recording per call.
- Field check, after the build is installed (not a precondition): switch between two Teams calls inside 30 s; two stems, a `recording_split_on_call_change` row between them, two notes.

## Owner decision (2026-11-16)

Option (b): on a change of call, end the current stem, then show the record prompt for the new call. Never start the second recording silently; an ignored prompt falls to DET18's span-bound one-click offer, so the second call is recorded only on a yes. This holds for an auto-consented app too (the split always asks).

**Progress (2026-11-16): shipped.** Designed first with an opus architect review, which moved the draft away from a stop-then-start (`beginRecording` refuses while `.stopping`, and the stop task still reads the first stem's workflow), a cross-queue poll and a title-only rule.

- **Source.** `AXLeaveButtonSignal` reads the window of its armed Leave element (`kAXWindowAttribute`, else the nearest `AXWindow` up the parent chain, 0.25 s element timeout) on a healthy read at most every `windowReadInterval` (2 s), caches it behind a lock, and clears it on an invalid read or `stop`. `LifecycleAdapter.callWindow` (nil by default, the Leave signal's for natives) and `MeetingLifecycleCoordinator.callWindow` forward it. Not END24's SCWindow lock, which never re-locks within a session, and not `ShareableContentSignal`'s candidate list, as the spec says.
- **Rule.** `CallIdentityTracker` (Core, pure): adopt the first usable read while no hold is open; split only on a different window AND a different title, held for 2 reads at least 4 s apart; a nil read (no window, empty title, the app's display name, the `AXSystemDialog` call panel) or a third value restarts the count; the same title in a new window is followed, never split; the same window retitled is never split. Cost of the window rule: a call that reuses its window under a new subject is not split (today's behaviour).
- **Host.** `MeetingSessionController+CallSplit.swift`: a 2 s common-mode tick armed at a native recording's commit and disarmed in `stopRecording`. A split logs `recording_split_on_call_change`, sets `pendingSplit` and stops with `stop_route: call_changed` (END21's stop rule concludes any open hold, so there is no split-specific cut). `resetAfterStop` raises the prompt for the new call (`presentPrompt`, lifted out of `handleMeetingStarted`), past the cooldown that stop armed; `pendingSplitFrom` is keyed to that prompt's source and cleared on every prompt exit (`clearPromptRouting`), so only a start the prompt answers carries `split_from`. A Stop or toggle during the split's flush drops it; no split while off the record.
- **Sidecar.** `split_from` (schema 5), the `split-from` contract fixture read by both sides, Python informational (`mp.workflow` docstring). The Library merges only on `resumed_from`, so a split pair gets no merge offer.
- **Acceptance gap, by construction.** The 2026-11-12 rows carry no Leave-window title (`extract_detection_trace.py` keeps titles out of its output, and the only titles in the log are `ShareableContentSignal`'s candidate lists, which the spec rules out), so `--raw` extraction cannot replay the split. `CallSplitSessionTests` is the hand-built shape instead, and `signal`/`call_identity_observed` now logs each identity so a future trace can.
- **Final review fixes (advisor, before landing).** The rule counted host ticks, not AX reads: the 2 s host tick re-read the Leave signal's cached window while that poll backs off to 5 s, so one read of window B seen three times confirmed a split. Each read now carries a `serial` and the tracker counts a serial once; the window id is a generation the signal bumps when `CFEqual` says the window element changed (no reliance on `CFHash`). An ignored split prompt always becomes DET18's offer, even under `default_prompt_action = "record"` (`prompt_timeout` logs `split: true`); a recording started from the offer carries no `split_from`, since a link outliving its prompt could attach to a later call of the same app. `call_identity_observed` logs the window generation and subrole for the field check.
- **Not built from the review:** nil on two or more Leave windows. Reading it needs the walk to return every Leave window, which the signal does not hold; the field check is where a second Leave window (share toolbar, held call) would show, as a split row with a different subrole or window.
- **Tests.** 10 `CallIdentityTrackerTests` (one cached read ticked for 60 s never splits), 1 `AXLeaveButtonSignalTests` (window cache, throttle, `CFEqual` window id, serials, invalid clears, stop clears), 1 `NativeAppQuitTests` (the production wire: real Leave signal through `NativeLifecycleAdapter` to `MeetingLifecycleCoordinator.callWindow`), 8 `CallSplitSessionTests` (adding: one cached read never splits; an ignored split prompt offers and records nothing under `record`) (split then prompt naming call B and `split_from` on the second stem; same call and nil reads keep recording; Stop during the split drops the prompt; a skipped split prompt leaks no link; no split off the record; a browser recording arms no watch), `MetaContractFixtureTests.test_split_from_matches_fixture` and `test_contract_fixture_split_from_is_informational`. They do not compile against the pre-END28 tree (new types); the behaviour they pin was absent there. The END9 to END15 corpus traces are unchanged and green.
- **Docs.** `daemon/docs/gotchas.md` (new section), ARCHITECTURE (CallIdentity line), CONVENTIONS (`split_from` row, schema 5, the three new actions), `docs/GUIDE.md` (back-to-back recipe); README checked, no change.
