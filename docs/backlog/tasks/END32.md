---
id: END32
title: A Teams screen share reads as a call end for the whole share: the Leave button and the locked call window both go, the HUD says Confirming end throughout, and the recording survives on the process-audio veto alone
category: Detection
status: new
priority: P2
comment: Filed 2026-11-23 from the owner's report that a call where they shared their screen showed Confirming end for almost the whole meeting (stem 20261123-115244). Two seconds into the share the Leave element went invalid and the END24 window lock read gone, the pair agreed for 1,621 s, and only `process_audio_is_running_input` reading live kept the call recording; nothing was lost (trim at the real mic release, 167 of 167 segments kept). Scope: (a) the HUD shows a vetoed hold as recording, not Confirming end (END13's deferred "distinct state, not silence"); (b) a Teams share stops reading as an end pair, via the window lock and the Leave re-resolution; (c) the incident's raw trace joins the corpus. P2 because no audio was lost; the owner may promote, since a share leaves the recording on one veto END17's amendment can lift.
---

# END32: A Teams screen share reads as a call end for the whole share: the Leave button and the locked call window both go, the HUD says Confirming end throughout, and the recording survives on the process-audio veto alone

Band origin: filed 2026-11-23 from the owner's report that a Teams call where they shared their screen showed Confirming end for almost the whole meeting, traced in-session the same day against `~/Library/Logs/MeetingPipe/events.jsonl` on the installed 2026-11-20 12:37 build (which includes `main` at `42cc7d35`). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## What happened

Recording `20261123-115244` (Teams native, pid 1254, workflow Personal). Times are the event log's UTC `ts`; local time is UTC+2, so the stem's 11:52:44 is 09:52:44Z.

- 09:52:45.100Z `recording_started`, `in_meeting`. `ax_handles_built` found Leave and Mute; `shareable_content_window_present` true on one locked window (`call_identity_observed` adopted `bare_single_segment`, `AXStandardWindow`).
- 09:54:41.768Z the owner starts sharing. `signal`/`ax_leave_button_state` `healthy -> invalid` (`reason: health_poll`); `lifecycle`/`ending_provisional` `leading_signal: ax_leave_button_invalid`; `coordinator`/`lifecycle_end_held` with `live_signal: call_is_up`, `confirm_dwell_sec: 60`, `lone_dwell_sec: 720`. The HUD switches to Confirming end here (`MeetingSessionController` calls `coordinator.hud.setConfirmingEnd(true)` once the hold is open).
- 09:54:43.732Z `shareable_content_window_present` `true -> false`, `appeared_matching: 1`, `locked_windows: 1`. From then until 10:21:42Z there are 66 `shareable_content_no_match` rows, each with `candidate_count` 2 or 3 and every `candidate_shapes` entry `matches`: Teams put up new windows of the call window's own shape, and the END24 lock, which by design never relocks from a gone reading, stayed on the vanished one.
- No `ax_leave_button_rearmed` or `healthy` row at all during the share: the Leave element stayed invalid for 27 minutes while the call was live, the asymmetric re-arm already seen after a11y blackouts (Mute re-armed at 09:54:57.647Z, `ax_mute_button_rearmed`).
- `process_audio_is_running_input` stayed `true` throughout, so `PromotionEngine` refused to confirm the pair; `TeardownHoldPolicy` consulted the oracle 1,621 times with nothing to confirm.
- 10:21:42.763Z the locked window reads present again (the share ended and Teams restored the call window); `in_meeting`, `lifecycle_teardown_consult` `resolution: reverted`, `held_sec: 1620.99`, `lifecycle_end_hold_released`.
- 10:21:43.8Z `mic_holder_changed` `held -> released`; 10:21:46.652Z `process_audio_is_running_input` false; a new hold opens with `live_signal: call_is_down` and confirms 60 s later, 10:22:46.668Z `ended`, `confirmed_by: [ax_leave_button_invalid, shareable_content_window_gone]`.
- `recorder`/`held_end_trimmed` `limit_sec: 1741.60`, `transcription`/`held_end_excluded` `segments_before: 167`, `segments_after: 167`: the cut sits at the real mic release and the transcript lost nothing.

The same day's other Teams recording, `20261123-093430` (no share), held 60 s on a mic-led end and confirmed normally, so the share is the discriminator.

## Why each layer did what it did

1. **HUD.** `MeetingSessionController` raises Confirming end whenever a hold is open and drops it only when the hold concludes. A hold that process audio is vetoing cannot confirm, yet reads the same. [END13](./END13.md) left that deliberately ("a vetoed hold shows `Confirming end` for its whole length, which can now be hours ... if it reads as alarming the fix is a distinct state, not silence"). This is that report.
2. **Window.** `ShareableContentSignal` (END24 identity mode) locks the call window's SCWindow ids at the first present reading and, per the END24 amendment, relocks only "while the lock still reads present, so a window appearing after a real end cannot turn gone back to present". A Teams share replaces or hides the locked window while the call goes on, so the lock reads gone for the whole share while matching-shape windows sit beside it. The rule is right for a real end and wrong for a share; nothing in the signal can tell the two apart today.
3. **Leave.** `AXLeaveButtonSignal`'s re-arm path (`ax_leave_button_rearmed`, the END28 window cache) never found a live Leave element in the sharing layout. Whether Teams' sharing UI exposes a Leave control under a different container, or none at all, is unmeasured.
4. **Engine.** Both weak signals agreed from 09:54:43Z, so the pair dwell was satisfied after 09:55:43Z and only `process_audio_is_running_input` stood between the live call and `.ended`. [END17](./END17.md)'s amendment item 8 turns a running reading whose objects vanish or become unreadable into `.unknown`, which lifts that veto. Reading the rules (not tested): had that happened mid-share, the next tick would have ended a live meeting with a minute of dwell long since met. That is why the HUD fix alone is not enough.

## Scope

One task, three parts, landed as one commit or as a short sequence under this ID:

- **(a) HUD.** While a hold is open and the live signal reads `call_is_up` (process audio running), the HUD shows Recording, not Confirming end, and switches to Confirming end as soon as the veto lifts (the 1 Hz consult already runs; re-evaluate there). The decision goes on its own pure type (a `decide` beside `TeardownHoldPolicy`, or a method on it) with the hold state and `liveCallSignal` as explicit inputs, per the daemon's pure-logic rule; `MeetingSessionController` only forwards. If the owner prefers a distinct label over plain Recording (END13's wording), take the copy through `docs/GUIDE.md`'s "Stopping" section and its "The recording did not stop when the call did" entry in the same commit, both of which describe Confirming end today.
- **(b) Detection.** A Teams screen share must not read as an end pair. Start by capturing what Teams shows during a share (window titles and shapes from the `shareable_content_no_match` rows, which already log `candidate_shapes`; the AX tree of the sharing layout for a Leave control). Then the smallest change that fixes the class, in `ShareableContentSignal`'s relock rule and/or `AXLeaveButtonSignal`'s re-resolution. The constraint the pickup must hold: END24's "never relock from gone" protects a real end from a popped-out chat reverting it, so any relock-from-gone has to be gated on evidence the call is still up (for example process audio reading live at that moment, or a same-shape window whose identity END28's `CallIdentityTracker` accepts as the same call), never on shape alone.
- **(c) Corpus.** Extract the incident with `scripts/extract_detection_trace.py --raw` (09:52:40Z to 10:22:50Z, `com.microsoft.teams2`), redact with `scripts/redact_detection_trace.py`, and add it to `daemon/Tests/MeetingPipeCoreTests/Fixtures/detection-corpus/` as a `no_end` until 10:21:46Z then `ended`, per the corpus README's rule that an END change lands with an incident's raw trace.

## Explicitly not

- Not a change to the veto itself, the 60 s pair dwell or the 720 s lone dwell (ADR 0017's tier table); not END21's trim rule, which behaved correctly here.
- Not a share-specific end rule keyed on a localized label or a "you are sharing" title string: the daemon rules forbid a new rule per false-end shape, and labels drift.
- Not END28's split: no `call_changed` split fired during this share, which is one field data point for END28's remainder (a share started and stopped gives no split row); record it there, do not reopen it here.
- Adjacent, filed: [END31](./END31.md) adds a 5 s `full_agreement` confirm when the mic release, Leave invalid and window gone all agree. During a share Leave and window already read ended, so the mic release alone would complete that rule; whichever lands second checks that a share followed by a real hang-up still ends promptly and that (b) leaves no stale ended edge for END31's rule to pick up mid-share.
- Adjacent, unfiled: END29's named residual (a minimised call inside a missed-return hold) has the same single-veto shape; if (b) adds a cross-signal relock, check it does not change END29's traces.

## Acceptance

- (a) Tests in `TeardownHoldPolicyTests` (or the new type's own file) and `CallTeardownHoldTests`: a hold opened with `call_is_up` shows Recording; the same hold flips to Confirming end within one consult of process audio reading `call_is_down` or `unknown`; a hold opened with `call_is_down` shows Confirming end from its first second as today; a hold that confirms on its first consult never shows either (END9's no-flicker rule). Each measured red against the unfixed code first.
- (b) `ShareableContentSignalTests` and/or `AXLeaveButtonSignalTests`: a locked window replaced by a same-shape window while the call is up keeps reading present (or relocks, emitting `shareable_content_window_relocked`); the END24 amendment's existing test that a window appearing after a real end does not revert it stays green unchanged.
- (c) `DetectionCorpusTests` green with the new trace: no `.ended` before 10:21:46Z, `.ended` within 90 s after it.
- `bash scripts/ci-local.sh` green, with the number of new tests stated in the ship note.
- Field: after `./scripts/rebuild.sh`, one Teams call with a screen share of at least five minutes: the HUD reads Recording during the share, and that recording's rows show either no `ending_provisional` during the share or one that resolves without a 60 s-satisfied pair standing on the veto alone.
