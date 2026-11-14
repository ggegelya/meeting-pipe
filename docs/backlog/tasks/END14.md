---
id: END14
title: A lone window-gone ends a Teams call while Teams still holds the mic, and a Teams title change made it fire on every call
category: Detection
status: partial
priority: P1
comment: Filed 2026-10-12 from the owner finding their meetings stopping on their own on 2026-10-09. From 2026-10-08 about 14:31 UTC Teams dropped the `\| Microsoft Teams` title suffix, so `MeetingTitlePatterns.teams` rejects the call window (`Kintavo Daily Standup call`) and `ShareableContentSignal` reports it gone; `shareableContentWindow` is not `requiresCorroboration`, so `PromotionEngine` ends `.starting` directly and promotes `.endingProvisional` on the 2 s debounce while `process_audio_is_running_input` reads `true` (217 false ends on 2026-10-08, 89 on 2026-10-09, `confirmed_by: []`; recordings cut 7 to 86 s in; the prompt flashed every ~12 s). END8's revert cannot fire because the healthy Leave button emits nothing on re-arm. **P1 because the broken promise is that a recording lasts as long as the meeting**; the owner may re-band. Scope: per-kind current state in `PromotionEngine`; a live `processAudioIsRunningInput` vetoes a lone non-corroboration end (not `workspaceAppTerminated`) in `.starting`, `.inMeeting` and `tick`; a held `.starting` end re-evaluates when the mic is released; `lifecycle/end_vetoed` emitted. Explicitly not: widening the title match, making window-gone `requiresCorroboration`, seeding a process-audio provisional with the remembered window-gone, or a new engine ceiling. Spec in [`tasks/END14.md`](./END14.md). **Shipped 2026-10-12.** `PromotionEngine` phases carry `SignalStates` (each kind's last reading and its time); `vetoesLoneEnd` (process audio only) and `yieldsToLiveVeto` (non-corroboration, not `workspaceAppTerminated`) on `PrimarySignalKind`; a vetoed end is absorbed in `.starting` and `.inMeeting`, a held `.starting` end re-evaluates on every later `.ended`, and process audio turning `.live` reverts a window-gone provisional (reversing END8's cross-class no-revert for that one pair). **One deviation from the spec:** a vetoed window-gone younger than the debounce corroborates the mic release and ends at once, which keeps the clean-leave fast path the corpus pins; older ones are still not seeded. `takeVeto()` is drained by `MeetingLifecycleCoordinator`, which emits `lifecycle`/`end_vetoed` (`bundle_id`, `leading_signal`, `vetoed_by`). Tests: 9 new `PromotionEngineTests` plus 1 `MeetingLifecycleCoordinatorTests`; END8's `test_window_gone_provisional_not_reverted_by_cross_class_live` rewritten to the new expectation, `test_second_distinct_ended_signal_promotes_to_ended_with_confirmation` lost its prior process-audio `.live` so it still pins the window-led fast path, and three corpus traces lost their `ending_provisional` row (same end, same event). 7 tests measured red against the unfixed engine (19 assertions) and 2 pass both ways by design. `swift build`, `swift build -c release` clean with no new warnings; `swift test` 2988 executed, 1 skipped, 0 failures; truth fences green. Docs: `daemon/docs/gotchas.md` section, one `daemon/CLAUDE.md` rule line, ARCHITECTURE debounce glossary; README, GUIDE, CONVENTIONS and `design/` checked, no change needed. **Not installed:** the binary at `~/Applications/MeetingPipe.app` is still the 2026-09-02 build, so END13 and this need `./scripts/rebuild.sh`. Remainder is owner-only: the walkthrough in `tasks/END14.md`. Amended 2026-11-13 by the audit band: tick pairs a class whose sibling reads live or whose ended stamp is arbitrarily old (a remembered window-gone, present on 5 of 5 era-3 Teams recordings), and two PWA title reads sit in different classes; require an in-hold edge with no live sibling and merge the title classes (F031, G024, F158).
---

# END14: a lone window-gone ends a Teams call while Teams still holds the mic, and a Teams title change made it fire on every call

Band origin: filed 2026-10-12 after the owner noticed on 2026-10-09 that their meetings were stopping on their own when they had been fine before. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## What is wrong

`PromotionEngine` lets a signal with `requiresCorroboration == false` end a meeting on its own, and it never asks whether any other signal is still saying the call is up. For a native Teams call that signal is `shareableContentWindow` (`shareable_content_window_gone`). The engine keeps only `observed: Set<PrimarySignalKind>`, the kinds it has seen, not what each one last said, so a `processAudioIsRunningInput` reading `.live` the whole time cannot stop the end. Two places act on that:

- `PromotionEngine.handleStarting`, `.ended` branch: anything that is not `requiresCorroboration` ends `.starting` directly (`EndingReason(leadingSignal: event.kind.rawValue, confirmedBy: [])`). That is what dismisses the record prompt.
- `PromotionEngine.tick`: a provisional led by a non-corroboration signal promotes on the 2 s debounce alone.

[END8](../q6-final.md) built a revert for an off-screen call window: the AX rescue's healthy Leave button is in the same `EndEvidenceClass` (`.callWindowOrControl`) and reverts the provisional. It does not fire here. `AXLeaveButtonSignal` emits only on change, the button was already `healthy`, and `MeetingSessionController.rescueProvisionalEnd` calling `armLeaveButton` on an armed healthy signal produces no event. So `lifecycle_provisional_end_rescued` is logged and the debounce promotes anyway, about 2 s later.

## What made it fire on every call

From 2026-10-08 about 14:31 UTC, Teams stopped putting the ` | Microsoft Teams` suffix on its window titles. The call window is now titled with the bare meeting subject (`Kintavo Daily Standup call`, `Claude Team Pilot - Feedback session`, `Leadership Sync`), and chat windows read `Chat | Max Doleh`. `MeetingTitlePatterns.teams` accepts a window only when its lowered title contains a localised "meeting" stem or `"microsoft teams"` (`teamsTokens`), so `ShareableContentSignal.evaluate` finds no matching window and reports `.ended`.

Evidence, all from `~/Library/Logs/MeetingPipe/events*.jsonl`:

- `signal/shareable_content_no_match` with Teams candidate titles: zero rows from 2026-09-10 to 2026-10-08 14:30 UTC (only empty lists, meaning no Teams window on screen), then 300+ rows from 2026-10-08 14:31 UTC on, every one listing a Teams window whose title has no token.
- `lifecycle/ended` by `leading_signal`, per day: every end from 2026-09-10 through 2026-10-08 morning was `process_audio_is_running_input_false` (most confirmed by `ax_leave_button_invalid`) or the browser `browser_tab_title_left_meet_pattern`. Then `shareable_content_window_gone` 217 times on 2026-10-08 and 89 on 2026-10-09, all with `confirmed_by: []`.
- At every one of those ends `signal/process_audio_is_running_input` had last reported `value: true` (Teams holding the mic), for example the 2026-10-08 14:31:17 to 14:36:54 UTC run where it re-reported `true` on each engage.
- The installed daemon binary has an mtime of 2026-09-02 17:16 and the process has run since 2026-10-03 22:54. Teams (pid 687) has run since 2026-10-03 22:53 and its app bundle is dated 2026-09-30. So nothing local changed. Teams' `ecs_settings.dat64` (its server-pushed config) was rewritten on 2026-10-09, which fits a server-side change; that cause is unverified.

What the owner saw (local time, UTC+3):

- 2026-10-08 from 17:31 and 2026-10-09 from about 12:15: the record prompt appeared and vanished roughly every 12 s, each one a `.starting` ended by `handleStarting`.
- `20261009-121708.wav` stopped about 22 s after `recording_started`, `20261009-121844.wav` about 7 s after (the empty marker was written for it), and `20261009-173127.wav` about 7 s after. `20261008-173712.wav` stopped 86 s in. Each had `lifecycle_provisional_end_rescued` with `leave_buttons_found: 1` followed by `lifecycle/ended` `confirmed_by: []`.

## Scope

Make the end decision read what each signal currently says, and let a live `processAudioIsRunningInput` veto a lone end that does not require corroboration. The seam is `PromotionEngine` only (`daemon/Sources/MeetingPipeCore/Lifecycle/PromotionEngine.swift`), plus one event emitted from `MeetingLifecycleCoordinator`.

1. Track the last reported state per kind (`[PrimarySignalKind: PrimarySignalState]`) across `.starting`, `.inMeeting` and `.endingProvisional`, alongside the existing `observed`.
2. **Vetoer:** `processAudioIsRunningInput` currently `.live`. That is the only vetoer. Its own doc names it the control that never fires without a real teardown, and the 2026-08-05 probe measured that a client-side Teams mute leaves the OS mic running, so muting cannot release the veto. Browser adapters never emit it, and neither do Webex or Slack (`usesProcessAudio` false), so their behaviour is unchanged by construction.
3. **Vetoed:** an end led by a kind with `requiresCorroboration == false`, except `workspaceAppTerminated` (an app quit is definitive). In practice that means `shareableContentWindow` on the native path.
4. `.starting`: a vetoed end is held (no verdict). Every later `.ended` re-evaluates: if a held unvetoed non-corroboration end exists, end with that kind as the leading signal and the trigger in `confirmedBy`. So a hang-up before the prompt is answered still ends: the mic is released, the veto lifts, and the held window-gone ends it.
5. `.inMeeting`: a vetoed end does not open a provisional. It is absorbed and the state remembered. When the mic is later released, today's path runs unchanged: a `processAudioIsRunningInput`-led provisional, corroborated by `ax_leave_button_invalid` or by the rescue re-walk and the END9 hold. That is the path every real end took between 2026-09-10 and 2026-10-08.
6. `.endingProvisional` and `tick`: a vetoed lead does not promote on the debounce. This covers a lead that went provisional before the mic reported `.live`.
7. Observability: emit `lifecycle/end_vetoed` with `bundle_id`, `leading_signal` and `vetoed_by` once per vetoed transition (not once per poll), so the field can tell this path from a quiet call.

## Explicitly not

- **Making the Teams title match wider** (accept any Teams window but `Chat…`). It is the same localized-label scraping that just broke, and with the veto it is not needed for correctness. A matcher that stays permanently wrong costs only the window signal's contribution, which was zero on every real end in the month before the change. It can be filed separately if the owner wants the window signal back.
- **Making `shareableContentWindow` `requiresCorroboration`.** That still leaves a non-native or no-process-audio context ending on window-gone (Webex, Slack, a resolver that never emits), and it would pull a reliable signal into a rail that exists for staleness. The veto is keyed to positive evidence instead.
- **Seeding a later process-audio-led provisional with the remembered window-gone as a corroborator.** That would end on the debounce if a minimised window combined with a DET8 object-churn blip, which is a new false-end path. The real-end path stays exactly as it was. One exception, added while building it: a vetoed window-gone *younger than the debounce* does corroborate the mic release, and ends at once with the window leading. Without it, the corpus' three clean-leave traces (`teams_native_clean_leave_en`, `zoom_native_clean_leave_en`, `teams_native_post_call_chat_grab_en`: window gone 0.2 to 0.4 s before the mic) lose their fast path. Inside that window the pre-veto engine would have reached the same end, so it is not a new false-end path.
- **A new ceiling in the engine.** A stale `.live` after a real end is bounded already: the Leave button goes invalid, the AX rescue opens the END9 hold, and END13's 7200 s ceiling plus `IdleStopBackstop` sit above it.
- **`call_teardown_source_missing`** (`NSCocoaErrorDomain 256` on the SlimCore `Logs` directory), which fires all day and predates this. It is noted, not filed.
- END13 shipped 2026-09-04 but is **not installed** (binary dated 2026-09-02), so its veto on the hold cap has never run in the field. It is a different seam (`CallTeardownOracle`, coordinator level) and does not overlap.

## Acceptance

- New `PromotionEngineTests`, each measured red against the unfixed engine first, except the last two which must pass both ways:
  - 2026-10-08 replay in `.inMeeting`: process audio `.live`, window `.ended`, Leave stays healthy (no event). Expect no verdict, and `tick` well past the debounce still yields nothing.
  - Then process audio `.ended`: a `processAudioIsRunningInput`-led `.endingProvisional`, and `axLeaveButton` `.ended` confirms `.ended`, the historical real-end shape.
  - `.starting` replay: process audio `.live`, then window `.ended` yields no verdict (the prompt is not dismissed); `confirmRecording` still reaches `.inMeeting`.
  - `.starting` hang-up: process audio `.live`, window `.ended` (held), process audio `.ended` ends with `leading_signal` `shareable_content_window_gone` and `confirmed_by` `process_audio_is_running_input_false`.
  - A provisional led by window-gone that opened before process audio reported `.live`: once process audio reports `.live`, `tick` past the debounce does not promote.
  - Unchanged: window-gone with no process-audio reading still ends `.starting` directly and still promotes on the debounce in `.endingProvisional`.
  - Unchanged: `workspaceAppTerminated` ends even while process audio is `.live`.
- A `MeetingLifecycleCoordinatorTests` case pins that `lifecycle/end_vetoed` is emitted once for a vetoed window-gone with `vetoed_by: process_audio_is_running_input_false`.
- `swift build`, `swift build -c release` clean with no new warnings; `swift test` green where Xcode is present (CI otherwise); `python3 scripts/truth_fences.py` green.
- Docs updated in the same commit: the ARCHITECTURE debounce/end glossary clause, CONVENTIONS if it lists lifecycle actions, and `README.md` / `docs/GUIDE.md` only if a user-visible behaviour they describe changes.
- Owner walkthrough (confirms after landing, does not gate it): run `./scripts/rebuild.sh`, take one Teams call, and confirm the prompt stays up, the recording runs to the hang-up, `lifecycle/end_vetoed` rows appear, and the end reads `leading_signal: process_audio_is_running_input_false`.

## Amendment 2026-11-13 (audit band)

From the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) F031, G024 and F158 (low), and the [field evidence](../../audits/2026-11-13-field-evidence.md) sessions finding "The window signal has read gone on Teams calls since 2026-10-08, so the era-3 pair rule rests on process audio alone". Verified in code on 2026-11-14. END14 already is P1 (a lone or stale weak signal still ends a live call).

**The pair dwell counts stale and contradicted classes (F031).** `PromotionEngine.tick` builds `endedSince` from `states where reading.state == .ended`, keeping `min(endedSince[kind.evidenceClass] ?? reading.at, reading.at)` per class, and confirms on `dwelled.count >= 2`. So a class counts as ended when one member is ended while its sibling reads `.live` (`axLeaveButton` and `shareableContentWindow` share `.callWindowOrControl`), and its stamp can be arbitrarily old, because `states` keeps a vetoed window-gone from `.inMeeting` (the vetoed branch's comment: "this remembered window-gone pairs with once both have dwelled"). "Two classes held 60 s" reduces to one fresh signal held 60 s plus any remembered stamp. Scenario from the audit: a Teams window minimised at minute 2 (vetoed, remembered), process audio reads false for 60 s at minute 22 (stale object id, slow device switch), Leave healthy throughout; `tick` confirms a pair and ends the recording with `confirmed_by` `shareable_content_window_gone`.

**This undoes END14's own design, and END17's claim does not hold for it.** END14's gotchas entry ("A signal allowed to end a meeting alone must yield to one saying the call is up", [`daemon/docs/gotchas.md`](../../../daemon/docs/gotchas.md)) says a vetoed window-gone older than the debounce "deliberately does not" corroborate, "so a minimised window plus a DET8 object-churn blip cannot end a live call". END17 (01e904a5) removed the debounce and the remembered stamp now pairs after the dwell; END17 and ADR 0017 say a hold confirms only when two evidence classes both stayed ended, which this shape satisfies with one.

**The test pins the defect (G024).** `test_real_end_after_a_veto_takes_the_process_audio_path_END14` ingests window-gone at 1, process audio ended at 600 and Leave ended at 600.4, and asserts `.ended` at `600 + dwell`. That holds only through the window stamp from 599 s earlier, since Leave's own edge is 0.4 s short of the dwell. No test has a live sibling in the same class.

**One PWA title change satisfies the pair (F158, low).** `BrowserMeetingLifecycleAdapter` emits `.browserTabTitle` from the shareable-content snapshot's title match and, for a PWA, `.windowTitleLeftPattern` from the AX window title, both against the same `titleMatchers`; their classes are `.browserTabTitle` and `.windowTitle`. A class test pins the split: `XCTAssertNotEqual(PrimarySignalKind.windowTitleLeftPattern.evidenceClass, PrimarySignalKind.browserTabTitle.evidenceClass)`.

**Field: the precondition is standing.** Share of Teams recording time with `shareable_content_window_present` false: 0.0% before 2026-10-08 (14 recordings), 54.9% in era 2 (40 recordings), 99.7% in era 3 (5 of 5 Teams recordings, 3,906 s), so the remembered window-gone stamp is present on every newest-build Teams recording. When process audio went false for the last time, the window already read gone and Leave healthy in 18 of 34 era-2 and 4 of 4 era-3 mic-led ends. No wrong end has been observed yet: all 4 era-3 ends list `ax_leave_button_invalid` and `shareable_content_window_gone` in `confirmed_by`, with Leave following the mic by 0.24 to 2.65 s. The same build absorbed a 22.0 s mic drop on `20261112-172307` (mic-led hold reverted); had it lasted 60 s, the stale stamp would have paired and ended the call with Leave healthy. G025 is consistent (0 of 381 ended rows carry `workspace_app_terminated`); that half is not this amendment's. Why the window reads gone on Teams at all is [END24](./END24.md).

Added scope:

1. **A class counts only on a fresh, uncontradicted edge.** In `tick`, an evidence class counts toward the pair only when no member of that class present in `states` reads `.live`, and its ended edge falls inside the current hold or no more than the old 2 s debounce before it opened (END14's "younger than the debounce" rule, which keeps the corpus' clean-leave traces where the window goes 0.2 to 0.4 s before the mic). The class's edge is the earliest qualifying member edge, not the oldest stamp in `states`. The lone dwell is unchanged here.
2. **Put both title reads in one class.** `browserTabTitle` and `windowTitleLeftPattern` map to the same `EndEvidenceClass`.
3. **Replace the pinning test** with the cases below, and correct the vetoed branch's comment, the gotchas entry and ADR 0017 to say the second class must be fresh.

Land together with, or rebase onto, [END18](./END18.md), which rewrites the same `tick`. [END17](./END17.md) (partial) owns the tier table this edits. T8's traces are re-run after.

Added acceptance:

- `test_real_end_after_a_veto_takes_the_process_audio_path_END14` rewritten: with window-gone at 1 and Leave ended at 600.4, no verdict at `600 + dwell`, and `.ended` at `600.4 + dwell` on Leave's edge.
- New `PromotionEngineTests`, each red against HEAD first: live sibling (process audio leads a hold, window-gone ended, Leave `.live`: no pair at any tick past the dwell); stale stamp (window-gone vetoed at 120 s, process audio ended at 1320 s for 61 s, Leave healthy: no `.ended` at `1320 + dwell`); PWA title (`browserTabTitle` and `windowTitleLeftPattern` ended together do not pair).
- Unchanged and green: the clean-leave corpus traces (`teams_native_clean_leave_en`, `zoom_native_clean_leave_en`, `teams_native_post_call_chat_grab_en`) and the lone-dwell tests.
- The class-separation assertion for the two title kinds becomes an equality.
- `swift build`, `swift build -c release` clean with no new warnings; `swift test` green; `python3 scripts/truth_fences.py both` green.
