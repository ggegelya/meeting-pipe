---
id: END19
title: Switching quickly from one Teams call to another keeps recording into the first call's stem, because every signal that reverts a hold is about the app rather than the call
category: Detection
status: new
priority: P1
comment: Filed 2026-11-12. `20261112-172307` (15:23 to 15:45Z) holds three Teams calls (standup, a switch to "<SSO call subject>" at 15:29:11Z, back to a "<standup subject>" window at 15:39:38Z) and published as one note mixing both meetings' people and topics: each switch opened an END17 hold that a returning app-level live signal reverted in 8 s and 22 s, and Teams' teardown line was not on disk either time. Broken promise: one recording, and one note, per meeting. Scope: carry a call identity per recording (the call window's title) and split into a new stem when it changes. P1; owner may re-band. [Spec](./END19.md)
---

# END19: switching quickly from one Teams call to another keeps recording into the first call's stem, because every signal that reverts a hold is about the app rather than the call

Band origin: filed 2026-11-12 from the owner's report "when I switch between two meetings quickly, the new one still writes as the first one", traced in-session the same day. A gap in [END17](./END17.md)'s revert rule, which is behaving as designed; [END18](./END18.md) is the same afternoon's other END17 defect. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

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
- **Not END18's wedge**, which is the same afternoon's other END17 defect and lands independently.
- **Observed, not filed:** browser meetings have the same shape (switching Meet tabs keeps one tab-title signal's app identity), and the tab title is the analogous identity. Out of scope until a browser meeting is recorded at all (the owner's meetings are Teams-only).

## Acceptance

- `PromotionEngineTests` or the coordinator's tests (wherever the identity lives), failing first: a recording whose call identity changes from A to B while `.inMeeting` produces a split; a change from A to B during a hold produces a split, not a revert into A's stem; A to nil (title unreadable) and A to A produce no split; a hold whose title stays A still reverts as today.
- A lifecycle replay of 2026-11-12 15:23:03 to 15:45:28 extracted with `scripts/extract_detection_trace.py --raw` into `DetectionCorpusTests`, asserting splits at the 15:29 and 15:39 switches (three stems), and the existing END9 to END15 corpus traces unchanged.
- Sidecar round trip: a `split_from` written by Swift is read by Python, pinned in `test_workflow_overlay.py`; the Library offers no merge for a `split_from` pair.
- `cd daemon && swift test` and `cd pipeline && uv run --extra dev pytest -q` green with the new tests (counts left to the implementing session); `bash scripts/ci-local.sh` green. `docs/GUIDE.md` updated in the same commit if a recipe mentions one recording per call.
- Field check, after the build is installed (not a precondition): switch between two Teams calls inside 30 s; two stems, a `recording_split_on_call_change` row between them, two notes.
