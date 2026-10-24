# ADR 0017: End detection holds long and trims later

| Property            | Value                              |
| ------------------- | ---------------------------------- |
| **Status**          | Accepted                           |
| **Date**            | 2026-10-24                         |
| **Decision Makers** | Project owner                      |
| **Technical Area**  | Detection / lifecycle / recording  |
| **Related Tasks**   | END17 (folds in END15); builds on END9 to END14; verified against T8 once it lands |
| **Supersedes**      | The end-side promotion rules of ADR 0008 (cross-class fast path, the end debounce, END5's 120 s browser floor) and END9/END13's hold bounds (the 150 s cap, the 7200 s ceiling, the unreadable-log confirm) |

## Context

The promise is that a live meeting is recorded whole. Seven consecutive P1 tasks, END9 to END15 (2026-08-04 to 2026-10-22), were each filed from a meeting chopped by a false end, and each fix replaced or patched the rule the previous one shipped. One Teams title change on 2026-10-08 produced 217 `shareable_content_window_gone` ends that day. The 2026-10-24 go-live assessment named the pattern rather than the next instance: every branch of the end policy decided in real time, on signals a third-party UI change can fake (an accessibility blackout, a title format, a device switch), and a wrong decision was unrecoverable lost audio.

The asymmetry runs one way. Ending a recording late costs minutes of extra audio, which the trim from END9 already knew how to remove. Ending it early costs the rest of the meeting. The policy was tuned the other way: a weak cross-class pair ended at once, a lone signal ended on a 5 s debounce, a held end confirmed on a 150 s wall clock or on an unreadable log, and the 60 s reprompt cooldown then suppressed the way back.

## Decision Drivers

- **No end signal the app reads is under its control.** Accessibility trees, window titles, tab titles and a client's microphone use all change with the client's UI, so any of them can lie, and the next lie is a new shape nobody has filed yet.
- **A wrong late decision is recoverable; a wrong early one is not.** Kept audio can be trimmed, restored, or merged. Audio never recorded cannot.
- **Privacy postures still bind.** Under regulated mode and NDA workflows, ADR 0016 says post-call audio must not exist at rest, so recording long cannot mean keeping long there.
- **Each incident should extend a table, not add a rule.** Seven rules on one promise is the failure mode this replaces.

## Options Considered

### Option 1: Keep patching per incident

END15's narrow dwell on process audio, then the next shape. Rejected: it is the seven-task history, and it leaves every other weak signal able to end a meeting alone.

### Option 2 (chosen): Two evidence tiers, a hold that keeps recording, and a trim afterwards

A **definitive** end stops the recording at once. A **weak** end opens a hold with the recorder running and the HUD reading Confirming end, and the hold confirms only on evidence that has had time to be wrong. Anything held is marked as the trim point and is left out of the transcript.

### Option 3: Never end automatically

Rejected: an unattended recording would run until the idle backstop on every call, and the owner's notes would begin each time with the tail of the previous one.

## Decision

**The tier table.** A new false-end shape is answered by moving a signal between rows or adding one, never by a rule beside the table.

| Tier | Signal | What it does |
|---|---|---|
| Definitive | `workspace_app_terminated` (the meeting app or browser quit) | Ends at once, from a hold or without one |
| Definitive | Teams' `UnregisterCall` teardown line for this recording (`CallTeardownOracle`, host-side) | Ends a hold at once (`confirmed_by: call_teardown_observed`) |
| Definitive | An explicit user Stop | Ends at once |
| Weak | `ax_leave_button_invalid`, `shareable_content_window_gone`, `window_title_left_pattern`, `browser_tab_title_left_meet_pattern`, `process_audio_is_running_input_false` | Opens a hold; never ends a recording alone |

**How a hold confirms** (`PromotionEngine.tick`):

- **The pair:** weak signals from two evidence classes have both stayed ended for `confirm_dwell` (60 s). Pinned above DET8's measured 11.4 s for Teams to clear its input after a real leave and above END15's in-call mic-switch gap (the 2026-10-22 incident re-acquired the mic inside 22 s; the exact gap is still to be measured by the owner). Ax-leave and window-gone remain one class (END6), so they never pair with each other.
- **The lone dwell:** the hold has run `lone_dwell` (12 min, the owner's decision of 2026-10-24) with nothing returning. Above a ten-minute tab share, below the 15 minute idle backstop.
- **The veto:** neither route fires while process audio reads live. Teams holding the mic is the one reading that says the call is up whatever the window or the tree claims (END13, END14).
- **The revert:** any signal returning live inside the hold reverts it: the lead's own class (END8), any signal that had itself gone ended (END15's mic switch, either order), and process audio (END14).
- **The backstop:** the idle backstop (`mic_only_silence_seconds`, 900 s) is unchanged and remains the ceiling for a silent tail.

**What a confirmed hold does to the audio.** The hold's start is the trim point. Under a lossless capture (every workflow that is not NDA, with regulated mode off) the WAV keeps the tail and `<stem>.meta.json` records `held_end_trim_sec`; transcription leaves out every word after it, so the summary and every sink see the meeting and not the minutes after it, and the Library's Audio tab says "Trimmed N min after the call ended" with a Restore that re-transcribes and regenerates from the whole file. Under regulated and NDA the tail is cut at stop, as END9 did.

**The way back.** A lifecycle end leaves a resume candidate for 120 s. If the same app's call is sighted again inside it, the reprompt cooldown is bypassed and recording resumes without a prompt into a new stem carrying `resumed_from: <stem>`; the Library header offers a Merge that restores the earlier recording's held tail and then runs FEAT9's merge.

**Retired:** the end debounce (`detection.debounce_end_sec` and its Preferences slider), END5's 120 s browser floor, the cross-class fast path, END14's instant clean-leave pair, and END9/END13's 150 s cap, 7200 s ceiling and `oracle_unavailable` confirm. An unreadable teardown log is now "no evidence".

## Consequences

**Positive.** Every shape END9 to END15 recorded now holds instead of ending, by construction rather than by a rule per shape, and the synthetic incident traces in the detection corpus pin each as `no_end`. A Teams leave still ends with no added latency, because the teardown line leads the AX edge and the hold's first consult reads it. A wrong end costs a click (Restore, or Merge) rather than a meeting.

**Negative, accepted.** After a leave that only a weak signal saw, the recording and the HUD run on for up to 12 minutes; on an app with no teardown oracle (Zoom, Webex, Slack, every browser) a normal leave runs on for the 60 s pair dwell or, with only one signal class, the lone dwell. The extra audio is kept on disk under ordinary workflows until the retention policy reclaims it. A genuine back-to-back call in the same app inside two minutes now starts recording without a prompt and carries a merge offer the owner can ignore.

**Verification.** The engine and host rules are pinned by `PromotionEngineTests`, `CallTeardownOracleTests`, `CallTeardownHoldTests`, `HeldEndSessionTests` and the synthetic incident traces. They are synthetic: T8's raw extracted traces of the END9 and END12 to END15 incidents are what this decision is to be re-verified against once T8 lands.
