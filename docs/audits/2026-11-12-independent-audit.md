# Independent audit, 2026-11-12

Whole-repo, read-only audit covering architecture, security, data handling, code quality, performance and antipatterns, plus test quality and the build. It was run outside the project's own harness: no project slash commands or skills, and the finders were told not to read `.claude/`, `docs/audits/` or `docs/backlog/`, and to treat comments, `ARCHITECTURE.md`, `CONVENTIONS.md` and the ADRs as claims to test rather than facts. The backlog was consulted only after verification, to label each finding as new, already known, or claimed fixed.

**Extended on 2026-11-13.** Three companion reports were added at the owner's request after the main audit, each in its own file in this folder: `2026-11-13-field-evidence.md` (three months of daily use on the work laptop), `2026-11-13-recording-reliability-audit.md` with its two appendices (how meetings are detected, how ends are decided, mic and mute) and `2026-11-13-responsiveness-audit.md` (perceived latency). The main audit below was code-only; the companions are grounded in real logs. Their conclusions are folded into the executive summary.

Nothing in the repo was changed apart from this file and its companion files. No backlog task was filed; that decision is the owner's. The live meeting library, transcripts, summaries, secrets and Keychain were not read.

Sections: How to read this; Executive summary; Scorecard; Claimed fixed, not holding; Critical and high findings; Medium findings; Low findings (verified, then not verified); Refuted; Build and test results; Coverage of the audit itself; Method. Search for a finding by its ID.

## How to read this

- Finding IDs: `F` came from the first round (22 finders), `G` from the gap round (6 finders pointed at what the first round missed).
- Severity is the verified one, not the finder's. `confirmed` means an independent agent re-opened the file, found the quoted snippet and traced the path. `partially confirmed` means the defect is real but narrower than first claimed; the corrected claim is the one printed.
- Backlog status: **New** (nothing filed covers it), **Known, open** (a task exists), **Claimed fixed, not holding** (a task or commit says it is fixed and the code does not deliver it), **Known, accepted trade-off** (an ADR or task chose this on purpose).
- Lows: 41 were verified because they were demoted from a higher severity; 86 were reported as low and never verified. The second group is listed separately and should be read as leads.

## Executive summary

### Update of 2026-11-13: what three months of daily use add

The main audit below was code-only. The owner then supplied three months of logs and meeting files from the work laptop where the app is used every day (74 recordings in the log window, 113 meetings, 114,553 daemon events, three build eras) and asked for two focused audits: how recording starts and stops, and how fast the app reacts. The detail is in the companion files; this is what it changes. Two layers of checking apply. The headline metrics of the field-evidence file were recomputed by an independent checker: of 60, 47 reproduced exactly, 13 reproduced under a slightly different definition, none was wrong. The detection causes quoted below are the claims as corrected by the skeptics, each of whom re-ran the count against the logs; where two analysts counted differently, both figures are given.

**The lifecycle findings of the code audit are real in daily use, and the field ranks the causes differently from the code.**

1. **The largest loss of meetings is not a detection miss.** The prompt was shown and nobody answered it: 32 of the 99 prompts that stayed on screen timed out (30 of them for Teams), the default action for an unanswered prompt is Skip, and the skip then holds that call off while the app stays visible. This is behind 29 of the 37 Teams calls of a minute or more that were not being recorded within 30 seconds of being seen: about 20 were never recorded (about 5.3 hours of call time) and 8 or 9, depending on the definition, were started by hand, between a few seconds and 33 minutes late. At 29 of the 30 Teams timeouts the microphone reading for Teams was true, so detection was right and the call was still lost. Some of those may have been deliberate declines; the log cannot tell. The setting is `detection.default_prompt_action` and the code is unchanged at HEAD.
2. **Google Meet in a browser is gated on the tab title carrying the room code.** On the work laptop the Chrome tab of a live Meet shows the meeting's name and no code, so the browser adapter's window check fails and no prompt follows. The five Chrome misses in the log (one certain, three probable, one possible, out of six call episodes) all show that shape, 1 of 7 Chrome prompts became a recording, and the mic-in-use tier that should catch what the title gate misses has never produced a reading on either machine, for a reason not yet established.
3. **End detection in the newest build (installed 2026-11-12) is late by design and has one new hole.** None of its 6 recordings ended both promptly and by itself. Four Teams ends waited a fixed 60 seconds, because the Teams call-end log the design leans on confirmed 0 of 59 Teams ends in the whole pack; the tail was trimmed correctly each time. One recording resumed after a dropped call with its lifecycle engine already ended, so nothing could end it, and it ran 380 seconds until stopped by hand (F030 and F045 reached through F046). One Zoom recording was stopped by hand.
4. **One vendor change broke the detector for days, and the root cause is still in place.** On 2026-10-08 Teams changed its window titles. The window signal began reading "gone" on live calls: 4 recordings were chopped at 7 to 86 seconds and about 300 prompts flashed and vanished within half a second (F030 in the field). The 2026-10-12 build stopped the chopping (136 vetoed ends since), but the title matcher was never repaired: the window signal read gone for 99.7% of Teams recording time in the newest build, so the end rule there rests on one signal plus a timer.
5. **Mute state is wrong for long stretches because a stale log line outranks the live button.** Teams log lines reach the app a median of 42 seconds late, are treated as current, suppress the live button reading for 5 seconds, and the suppressed reading is never delivered again. That produced 17 disagreements longer than 5 seconds across 15 recordings (5,139 seconds in total), including 1,294 seconds in which the owner is transcribed speaking while the gate said muted. In the capture-first mode in use this cost nothing audible; under the regulated gate that speech would have been written as zeros.
6. **The app feels slow because nothing visible changes on the click.** Recording state, the menu bar and the HUD are set only after the recorder has started. For the month on the October build the wait from click to a drawable HUD had a median of 0.7 seconds, 17 of 44 over 1 second, worst 17 seconds, most of it an Accessibility walk on the main thread. That walk was fixed on 2026-10-26 and reached the laptop on 2026-11-12. Still present at HEAD: the capture file is created on the main thread (the whole app frozen for 2.3 to 3.1 seconds on 4 of 74 starts), and a Record press while the app says "Stopping" is discarded (median 3.6 seconds, worst 54). There is no click event, no first-paint event and no main-thread stall probe, which is how performance could be rated 4.5 without anyone timing a click.
7. **Speaker identity is the weakest part of the transcripts.** The owner's own voice sits under an anonymous label in 35 of 111 meetings, and the owner's name is on a cluster that does not match the owner's voice in 26 of 107 (F096 in the field).
8. **One meeting silently lost its summary.** Stem `20261022-103101` hit a single 120-second cloud timeout, which is not retried, has no fallback for a workflow pinned to one backend, and was never re-run in the following 22 days; its sidecar records the cause as "unknown".
9. **The logs cannot answer the questions that matter.** Three chatter families are 79.5% of the event log, so rotation kept 46 days and lost the events for 40 of the 113 meetings. No row says which build is running, why a recording stopped, or that a prompt was withdrawn. About 85% of the pipeline log on the laptop is test-suite output.

**What the field did not show.** The destructive form of the critical finding G001 did not occur: no regulated or NDA recording exists in the pack, and the trim ran four times in its non-destructive mode, each time cutting exactly at the microphone release. No recording was lost: all 74 produced a two-channel file, there was no crash in 12 launches, and publishing succeeded on 110 of 110 notes with a median of 67 seconds from stop to published note.

**Can detection be made 100 percent reliable, as competitors seem to be?** No, and none of them is. A recorder outside the meeting client has to infer that a call is live, and vendors change their clients without notice. The competitors that feel reliable do two things this app can copy: they trigger on a known app's process holding the microphone, browsers included, and when unsure they ask instead of acting. The attainable goal is a detector whose errors are rare, visible and cheap: every call that opens the microphone is offered or recorded within seconds, no recording stops while the client still holds the microphone, the transcript is cut at the microphone release, and an unsure state is shown with one button. The recommended design, its staged plan and the measurements it needs first are in `2026-11-13-recording-reliability-audit.md`.

**On rebuilding.** Rebuilding the work laptop at HEAD helps responsiveness (the status menu is no longer rebuilt on every state change and opening it no longer runs `launchctl` on the main thread) and changes nothing in detection: the detection files at HEAD equal the newest build's. Do it between meetings, because `rebuild.sh` swaps the running binary in place (F105). The rebuild that matters for detection is the one that carries the fixes listed below. HEAD itself has never run in the field.

**Correction.** The line further down about the installed app being a 2026-09-11 binary (F021) describes the owner's home Mac, whose code matches the source only up to about 2026-08-18. The work laptop was rebuilt on 2026-10-12 and 2026-11-12. The finding itself holds on both machines: each build ran for a month or more, and nothing in the product says which commit is running.

**What to do first, in the light of the field data.** These come before the list further down; the rest of that list stands.

1. Today, with no code: set the unanswered-prompt action to Record (or to bring-your-own if an unanswered call should not go to the cloud), and test it once on a throwaway call, because that branch has never run in the field.
2. Make the log attributable: the build commit and a launch id at start, a cause on every stop, a row when a prompt is withdrawn. About a day, and every later measurement depends on it.
3. Fix the three defects seen in the newest build: the order of first readings with the end dropped during a start (F030, F045, F046), the trim point (cut at the microphone release, never at the first weak signal, which also closes G001), and recordings with no source being ended by an unrelated adapter.
4. Give every start a visible "Starting" state set on the click, and create the capture file off the main thread.
5. Mute: reject Teams log lines older than 5 seconds and let the newest reading win.
6. Google Meet: admit the named title shape as a prompt-only opener, and run two short probe calls before building microphone-based browser detection, because the pack holds no microphone reading for any browser.
7. Retry or re-queue a summary that timed out, and classify the failure by its real cause.

**Mechanically this is a careful codebase, and its defects are at the seams.** Every suite is green (3,531 Swift tests, 1,559 Python tests, ruff and pyright clean). The recorder core, the process boundary and the privacy policy core held up under adversarial reading: no finder found a path that silently loses captured audio on a crash, spawns are argv-only, the zero-egress predicate is single and fail-closed, the MCP server is stdio-only. Performance produced nothing above medium. The single refuted finding was refuted because the code had already been fixed.

**The verified findings: 194.** 1 critical, 16 high, 136 medium, 41 low, from 255 raw first-round findings plus 62 from the gap round. Of the 153 that were reconciled against the backlog (critical, high and medium): 76 are new, 48 are already open tasks, 11 are trade-offs the project chose on purpose, and **18 are claimed fixed and are not holding**.

**Where it breaks, in order of how much it should worry you:**

1. **Data handling is the weakest dimension** (70 of 194 findings, the critical and 11 of the 16 highs). Destructive operations reason from premises the rest of the code no longer satisfies. The held-tail trim cuts from the first weak end signal however long the hold ran, and under regulated or NDA mode that deletes in-call audio for good (G001). Undoing one wrong speaker name deletes that person's whole voiceprint (G003). A Notion republish wipes the page, including the owner's own notes, before a non-retried append (F017). `publish-from-paste` rewrites the pasted summary lossily before publishing (F016). The originals reaper and the default uninstall delete the only copy of held-back recordings (F001, F020).
2. **Privacy state leaks across meetings.** The per-meeting gate is sound, and features added later walk around it. The series-continuity block sends a withheld meeting's decisions and action owners to the cloud once the flag is switched off (F014, found independently by three finders). A workflow picked in the prompt and then skipped becomes the top-precedence override for the next meeting (F005). Resume-after-end pins the previous workflow over an NDA rule match (F046). `mp doctor` gives an all-clear without looking at the folder NDA meetings publish to (F018).
3. **State kept in memory or on disk goes stale and then wins.** `ConfigStore` parses `config.toml` once and writes the launch-time document over later hand edits, while the Advanced pane calls hand edits safe (F012). MicGate keeps its last verdict across recordings, so a source-less recording under the regulated gate can zero-fill the microphone (F004). Renaming a workflow orphans its meetings, its NDA scope and its vocabulary, under a comment that says a rename cannot orphan (G004).
4. **Comments, docs and instruments say more than the code does.** This is the pattern to distrust in an AI-written codebase, and it is measurable here: 18 fixes that do not hold, a README that says muted spans are redacted by default when the default mode never redacts (F041), a SETUP line that says only the summarizer sees the transcript while the default Notion sink uploads all of it (G032), a coverage script that prints 90.0% for a daemon at 51.0% (F151), and a conventions doc that says every cross-tree surface is fixture-pinned when about 10 of 30 are (F129).
5. **Tests are strong on pure logic and thin where a meeting can be lost.** `MeetingRecorder.swift` is at 17% line coverage, `Coordinator.swift` at 0.3%, no test starts, writes and stops a real recording (F110), about 90 Swift tests are source-text fences, and several tests pin the defect rather than the intent (G001, G006, G024, G025, G028).
6. **The two-tree seam is the main architectural cost.** The finder measured about 7,000 lines of Swift glue and mirrors, 16 daemon-invoked subcommands, roughly 26 shared file kinds and about 18 mirrored rules. The Apple Intelligence summarizer is a second, narrower copy of `mp.summarize`, and Regenerate and Retry always fail for meetings summarized by it (F022, F023, F108, F125). `MeetingSessionController` is 1,980 lines with 29 mutable flags (F049, known as ARCH7).

**Two facts about the installed system:** the app on the owner's home Mac is a binary dated 2026-09-11 whose code matches the source only up to about 2026-08-18, driving HEAD Python (F021, known as DIST6; the work laptop is newer, see the update above), and FluidAudio is pinned at 0.14.8 while upstream is at 0.18.3 with long-form ASR fixes and macOS 27 CoreML fixes; whether the menu-bar agent still gets the Neural Engine on macOS 27.2 is unmeasured (see Build and test results).

### What I checked myself

Before writing this I re-read nine of the 17 critical and high findings in the source at HEAD `4949c9c0`: G001, F012, F014, F017, F018, F019, G003, G004 and F009. All nine read as reported. For F004 and F005 I confirmed the cited sites exist as described; the end-to-end trace is the verifier's. The other findings rest on the verification agents alone.

### What I would fix first

This is a recommendation, not a filed plan.

1. The held-tail trim under the regulated gate: G001, with G031, G026 and F051 in the same area.
2. Cross-meeting privacy: F014, F005, F046, F018, then G037, F123, F124.
3. Destructive actions with no guard or no undo: G003, F017 with F088, F016, F015, F001 with F020, F073, F008 with G036.
4. Lost updates to configuration: F012, F095, F056, F135 with F059.
5. F004 (microphone written as zeros under the regulated gate).
6. Rename orphaning: G004 with G008.
7. The instruments that tell you whether the above is true: `coverage.sh` (F151), the README and SETUP claims (F041, G032), and the tests that pin a defect.

## Scorecard

Ratings are my judgement from the verified findings, on a 1 to 5 scale where 3 is "sound core, real defects at the edges".

| Dimension | Rating | Verified findings | Why |
|---|---|---|---|
| Data handling and integrity | 2.5 | 70 | Atomic writes and fail-closed reads where one writer owns one file. Delete, move, merge, restore, retention and republish each update only the artifacts their author knew about. Holds the critical and most highs. |
| Security and privacy | 3.5 | 35 | One zero-egress predicate, fail-closed sidecar reads, argv-only spawns, stdio-only MCP. Gaps where later features bypass the per-meeting gate, plus known open items: the `claude` CLI provider runs with tools enabled (SEC20), the egress guard authorizes on URL host so a proxy still receives requests (SEC19), TCC grants are inheritable (SEC17), 13 locked packages carry advisories (SEC31). |
| Code quality | 3 | 51 | Pure decision types are genuinely pure and well tested. The lifecycle engine reasons over edges while signals deliver levels, and per-meeting UI state survives a meeting switch. |
| Architecture | 3 | 7 | Two good islands (MeetingPipeCore; Python's egress chokepoint and provider table). The Swift and Python seam is expensive and is where behaviour exists once or twice instead of exactly once. One god object in the spine. |
| Antipatterns | 3 | 12 | `try?` collapsing unreadable into absent, then a read-modify-write that persists the loss; synchronous unbounded subprocesses on the main thread; comments describing intent the wiring does not deliver. Coverage of this lens was thin (about 48 of 780 files). |
| Performance (throughput) | 4.5 | 6 | Nothing critical or high. Recording, transcription, in-call polling and the Library scan are bounded, off main and single-flight. Two idle costs remain, both known. |
| Responsiveness (perceived latency), added 2026-11-13 | 2.5 | 43 in the companion file | No visible state is set on a click; the change waits for the work to finish. Measured on the work laptop: median 0.7 s from the Record click to a drawable HUD for a month, worst 17 s. Nothing measures or fences it. |
| Capture reliability (start, stop, mic and mute), added 2026-11-13 | 2 | 107 in the companion file, 46 confirmed against the field logs by the skeptics | The recorder itself never lost a file. Deciding when to record is the weak part: an unanswered prompt becomes Skip, Meet in a browser depends on the tab title, ends in the newest build are 60 s late by design, one vendor title change broke the detector for days, and a stale log line outranks the live mute button. |
| Tests | 3 | 11 | An estimated 75 to 80 percent of Swift test code buys real regression protection. Coverage is 90% in the pipeline and in MeetingPipeCore, 48% in the app target, and near zero in the recorder and the app spine. Python tests do not isolate HOME, config, Keychain or network. |
| Build and supply chain | 3.5 | 2 | Hash-locked Python dependencies, Dependabot, careful shell. No advisory audit step in CI, model weights float on `main` with no hash, and the installed binary is two months behind the Python it drives. |

### Counts by severity and backlog status

| Severity | New | Known, open | Claimed fixed, not holding | Accepted trade-off | Not reconciled | Total |
|---|---|---|---|---|---|---|
| Critical | 1 | 0 | 0 | 0 | 0 | 1 |
| High | 13 | 2 | 1 | 0 | 0 | 16 |
| Medium | 62 | 46 | 17 | 11 | 0 | 136 |
| Low | 0 | 0 | 0 | 0 | 41 | 41 |

## Claimed fixed, not holding

These are the findings where a backlog task or a commit says the problem is fixed and the verified code path says otherwise. In an AI-written codebase this is the list that most deserves a human read.

| ID | Severity | Task or commit | Finding | Location |
|---|---|---|---|---|
| F018 | high | SEC12, 81dc71fa | doctor's cloud-sync check never inspects the folder NDA and regulated meetings publish to | `pipeline/src/mp/doctor.py:614` |
| F002 | medium | END8, 11bac7b4 | END8 rescue is a no-op when the Leave button is already armed and healthy, so a window-gone hold runs to the lone dwell | `daemon/Sources/MeetingPipeCore/Lifecycle/Signals/AXLeaveButtonSignal.swift:232` |
| F031 | medium | END17, 01e904a5 | Pair dwell accepts an ended stamp of any age and ignores a live sibling in the same class | `daemon/Sources/MeetingPipeCore/Lifecycle/PromotionEngine.swift:285` |
| F036 | medium | MIC8, db9725db | A suppressed AX mute reading is lost for good; the documented 5 s correction bound does not exist | `daemon/Sources/MeetingPipeCore/MicGate/MicGate.swift:200` |
| F045 | medium | REC7, 3aacb666 | The in-flight start is a private Bool, not a state: ends and stops during bring-up are dropped for idle-origin starts | `daemon/Sources/MeetingPipe/MeetingSessionController.swift:1269` |
| F062 | medium | ASR3, 1c26afe2 | Index-keyed transcript overlays are applied with no drift check and are not carried when a re-transcribe fails | `daemon/Sources/MeetingPipe/TranscriptCorrectionStore.swift:115` |
| F069 | medium | UX78, 7a063e01 | A meeting without audio inherits the previous meeting's loaded recording | `daemon/Sources/MeetingPipe/TranscriptTab.swift:376` |
| F083 | medium | LOCAL9, LOCAL17 | train-adapter trains on a request shape the server never sends, and its default budget drops every pair | `pipeline/src/mp/train_adapter.py:214` |
| F099 | medium | PIPE8, dcbf94cd | merge-meetings records the merge before the audio swap, so a failure in between is resumed as if complete | `pipeline/src/mp/merge_meetings.py:228` |
| F107 | medium | FEAT3-SEGMENT, PIPE9 | All four publishers send the raw `<stem>.md`, ignoring the Library's speaker and text-correction overlays | `pipeline/src/mp/publish_notion.py:545` |
| F109 | medium | STOR3 | Backup and restore print their failure reason to stdout; the daemon reads only stderr | `pipeline/src/mp/backup.py:503` |
| G006 | medium | END8 | END8 rescue is tested with a Leave-button event production does not emit | `daemon/Tests/MeetingPipeCoreTests/PromotionEngineTests.swift:441` |
| G015 | medium | DV3 | Rename everywhere leaves the person's open actions behind | `daemon/Sources/MeetingPipe/PeopleRail.swift:110` |
| G024 | medium | END14 | Pair corroboration counts a class as ended while its sibling reads live; the test pins a remembered window-gone as the second class | `daemon/Tests/MeetingPipeCoreTests/PromotionEngineTests.swift:581` |
| G025 | medium | END17, END14 | Native app quit is asserted on a signal native sessions never receive; the live-mic veto has no freshness | `daemon/Tests/MeetingPipeCoreTests/PromotionEngineTests.swift:672` |
| G026 | medium | END9, END17 | Regulated-gate held-tail cut is skipped for single-source recordings while the event says truncated | `daemon/Sources/MeetingPipe/RecordingPostProcessor.swift:371` |
| G027 | medium | MIC8 | AX mute producers dedupe before the fusion accepts; the fusion test re-injects by hand | `daemon/Tests/MeetingPipeCoreTests/MuteSourceFusionTests.swift:109` |
| G035 | medium | FEAT15 | Tutorial step 3 points at a control that is not rendered on an empty Library or on four rails | `daemon/Sources/MeetingPipe/Tutorial/TutorialAnchor.swift:65` |

## Critical and high findings

### G001. Held-tail trim is pinned at the hold's first stamp; no test ends a long live hold genuinely

- **Severity:** critical (confirmed; reported as critical). **Lens:** data. **Found by:** gap-4. **Established by:** read.
- **Location:** `daemon/Tests/MeetingPipeCoreTests/TeardownHoldPolicyTests.swift:91`
- **Backlog:** New. ADR 0017, END17 (partial) and T8 make the first-stamp trim and the regulated cut at stop deliberate, but all assume the held span is post-call. None names or accepts in-call audio lost when an unreverted hold later ends.

**Claim.** Pins the bug. The cut is always the first provisional's stamp, however long the hold ran. A hold that never reverts (Leave invalid while the mic reads live, pinned open for 7201 s at PromotionEngineTests:561) and then ends genuinely trims every minute of live call since it opened. No lifecycle trace has a genuine end after a long live hold.

**As corrected by verification.** Holds as stated, with three narrowings. (1) The irrecoverable loss is limited to the .regulatedGate posture (regulated or NDA, or an unknown capture mode) and to a two-channel merge; the single-source branch ignores limitSeconds. (2) Under the default lossless posture the audio is kept, the transcript and summary omit the span, the Audio tab shows a "Trimmed N min" caption and Restore undoes it. (3) The trigger needs the Leave button (or the call window) not to read live again before the end; if it does, the hold is released and the trim cleared. The end does not need the teardown line: an app quit or the first engine tick after the mic releases confirms with the same stamp.

**Failure scenario.** Regulated mode. Leave button goes invalid at 31 min and never returns while Teams holds the mic; teardown ends the call at 60 min. stopRecording passes limitSeconds=1872, applyTrim caps the merge, intermediates are deleted: 29 minutes of meeting destroyed. Lossless modes drop the same span from the transcript.

**Quoted code.**

```
XCTAssertEqual(policy.trimPoint(concludingAt: at(101)), at(100))
        XCTAssertEqual(policy.trimPoint(concludingAt: at(820)), at(100), "re-entry did not move the cut")
```

**Verifier (trace): confirmed.** An ax-leave end opens a hold even with a live mic (not yieldsToLiveVeto); tick never confirms while process audio reads live, and all three native signals emit on change only, so only a returning signal reverts it. Any later end (teardown, app quit, or the first tick after mic release, since the lone dwell counts from hold start) trims at the first stamp. Regulated/NDA with both channels truncates and deletes intermediates; lossless cuts only the transcript, restorable. gotchas.md:749 records the Leave-absent state as real. No test or trace covers it.

Evidence: Snippet: daemon/Tests/MeetingPipeCoreTests/TeardownHoldPolicyTests.swift:91-92 (first-stamp trim pinned at 1 s and 720 s holds). Policy: daemon/Sources/MeetingPipeCore/Lifecycle/TeardownHoldPolicy.swift:44-48 (re-entry keeps first stamp), :68-71 (trimPoint returns hold.startedAt, only input is now). Hold opens under a live mic: PromotionEngine.swift:53-61 and :95-97 (axLeaveButton requiresCorroboration, so not yieldsToLiveVeto), :235-238, :411-428. Hold never confirms while mic is live: PromotionEngine.swift:283; pinned at PromotionEngineTests.swift:561-573 (7201 s). Nothing re-emits live: ProcessAudioSignal.swift:371 (edge only), ShareableContentSignal.swift:173-175 (edge only), AXLeaveButtonSignal.swift:311 and :322-326 (edge only), NativeLifecycleAdapter.swift:139-164. Genuine end routes all take the same stamp: CallTeardownOracle.swift:136-141 (any teardown after the stamp confirms); MeetingSessionController.swift:1887-1905 and :1910-1914; consumer :241-242 (any .ended concludes); PromotionEngine.swift:291 (lone dwell measured from hold startedAt, so first tick after mic release confirms), :450-454 (app quit). Destruction path: MeetingSessionController.swift:783-788 (trimSeconds = stamp minus recorder start), :794-804 (limitSeconds passed unless capturesLosslessly); CaptureMode.swift:42-49; MeetingRecorder.swift:1404-1407; RecordingPostProcessor.swift:88-94 (applyTrim caps target), :324-330, :353-356 (intermediates removed after promote); single-source branch :371-381 ignores the limit. Pinned for NDA at daemon/Tests/MeetingPipeTests/HeldEndSessionTests.swift:88-100. Lossless path: MeetingSessionController.swift:795, :877, :918; SinkDispatcher.swift:527-528; HeldEndTrim.swift:33-36, :45-58; restore at MeetingLibraryService.swift:599-613. Revert clears the trim: MeetingSessionController.swift:243-247; PromotionEngine.swift:469-481. Reachability recorded by the repo: daemon/docs/gotchas.md:747-749 (2026-09-04: Leave never re-armed, owner stayed 40 more minutes; Leave container absent from compact view "as long as the owner leaves the call window alone"), :755 and :759 (vetoed hold can run hours, audio "trimmed back to provisionalStartedAt on confirm either way"). No opposite test or trace: daemon/Tests/MeetingPipeCoreTests/Fixtures/detection-corpus has five lifecycle traces; only teams_native_lifecycle_teardown_leave.json (trim_at null) and zoom_native_lifecycle_pair_dwell_trim.json (61.5 s hold, mic live for 1.5 s of it) end; DetectionCorpusTests.swift:148-160, :182; CallTeardownHoldTests.swift:313-325 pins trim at openedAt.

**Verifier (reach): confirmed.** Traced end to end. An ax-leave end opens a hold even under a live mic (yieldsToLiveVeto is false for it); tick is vetoed indefinitely; only a Leave re-walk hit reverts, and the repo's own gotchas record that Leave is absent in Teams' compact view for as long as the owner stays there. Any later genuine end (teardown, mic release, quit) runs concludeTeardownHold, which cuts at the hold's stamp. Regulated/NDA: ffmpeg -t then intermediates deleted, unrecoverable. Default posture: transcript cut only, Restore exists. No test or trace covers it.

Evidence: Paths relative to the repo root. Established by reading code, not by running it. SNIPPET: daemon/Tests/MeetingPipeCoreTests/TeardownHoldPolicyTests.swift:86-93 (asserts at 91-92), exactly as reported. POLICY: daemon/Sources/MeetingPipeCore/Lifecycle/TeardownHoldPolicy.swift:44-48 (re-entry keeps first stamp), 68-71 (trimPoint returns hold.startedAt for any hold >= 1 s, no upper bound, no input about liveness; comment at 66-67 asserts "post-call audio by construction"). HOW A LONG LIVE HOLD OPENS AND STAYS OPEN: - daemon/Sources/MeetingPipeCore/Lifecycle/PromotionEngine.swift:53-61 and 95-97: axLeaveButton has requiresCorroboration true, so yieldsToLiveVeto is false; 235-238 veto() returns nil for it; 411-428 it opens .endingProvisional even while process audio reads live. - PromotionEngine.swift:283: tick returns nil while a vetoer reads live, so neither dwell fires. Pinned by daemon/Tests/MeetingPipeCoreTests/PromotionEngineTests.swift:561-573 (ax-leave ended at 1872, still held at +7201 s). - Reverts need a live EDGE (PromotionEngine.swift:461-481). Signals are edge-only: ProcessAudioSignal.swift:371, ShareableContentSignal.swift:173, AXLeaveButtonSignal.swift:311 and 322-326. The only self-heal is the 5 s Leave re-walk (AXLeaveButtonSignal.swift:291-302, 343-352) or the one-shot host rescue (MeetingSessionController.swift:1802-1824), both of which need a Leave button to exist. - daemon/docs/gotchas.md:749: "the Leave container is absent from the compact call view, so a Leave-only absence is an expected rendering state that can last as long as the owner leaves the call window alone"; measured 2026-09-04 (gotchas.md:747): ax_leave_button_rearmed never fired, owner stayed 40 more minutes. gotchas.md:759 accepts that a vetoed hold "can now be hours". - Teams and Zoom wire process audio: daemon/Sources/MeetingPipeCore/Lifecycle/Adapters/NativeLifecycleAdapter.swift:44-58. EVERY GENUINE END AFTER IT TRIMS AT THE HOLD'S START: - Teardown route: CallTeardownOracle.swift:136-143 confirms any teardown newer than holdStart-15 s regardless of hold age; MeetingSessionController.swift:1887-1905 then concludeTeardownHold. - Mic-release route: PromotionEngine.swift:291 loneHeld is measured from the provisional's startedAt, so after 720 s the first tick after process audio drops confirms. - All routes: MeetingSessionController.swift:238-242 (every .ended calls concludeTeardownHold), 1910-1914 (pendingEndTrimAt = trimPoint), 1206-1253 (handleMeetingEnded has no guard), 783-804 (trimSeconds = trimAt - recorder.startedAt; regulated passes it as limitSeconds, lossless writes it to the sidecar). DESTRUCTIVE TAIL (regulated or NDA): CaptureMode.swift:42-49; MeetingRecorder.swift:1148-1177 and 1403-1407; RecordingPostProcessor.swift:88-95 (applyTrim caps target), 489-491 (ffmpeg -t), 353-356 (mic and system intermediates removed after promote). No untrimmed copy is kept under regulatedGate. Narrowing note: the single-source branch (RecordingPostProcessor.swift:371-381) and the no-ffmpeg branch (331-349) ignore limitSeconds, so the destruction applies to the normal two-channel ffmpeg merge. LOSSLESS HALF: SinkDispatcher.swift:527-528 and Transcription/HeldEndTrim.swift:45-58 drop every segment after the stamp from the transcript, so summary and sinks lose the span; the WAV keeps it and the Audio tab offers Restore with the misleading caption at HeldEndTrim.swift:36 ("Trimmed N min after the call ended"). Recoverable, so that half alone would be high, not critical. NOT AN ACCEPTED TRADEOFF: docs/decisions/0017-hold-long-trim-later-end-detection.md:58 states the hold's start is the trim point and :68 lists accepted negatives; none covers a hold kept open by the live-mic veto and then ended genuinely. gotchas.md:755 reasons only about a late confirm of a real end. COVERAGE GAP: lifecycle traces in daemon/Tests/MeetingPipeCoreTests/Fixtures/detection-corpus: only two end (teams_native_lifecycle_teardown_leave.json trim_at null, zoom_native_lifecycle_pair_dwell_trim.json a 61.5 s hold); the other three are no_end. Host tests release the long hold instead of ending it: daemon/Tests/MeetingPipeTests/CallTeardownHoldTests.swift:249-272 and 276-293; trim tests use an un-vetoed lone-dwell hold: CallTeardownHoldTests.swift:313-326, HeldEndSessionTests.swift:57-100. Severity note: irrecoverable audio loss requires the opt-in regulated mode or an NDA workflow plus the Leave button staying unfindable until the call ends; under the default capture mode the loss is transcript and summary only and one click restores it.

**Direction.** Cut from the last moment evidence said the call was up (last live vetoer reading or last revert), not from the first weak signal, and add a lifecycle trace with a late genuine end.

### F004. Source-less recordings never engage MicGate; a stale deduped verdict leaves the regulated-gate mic zero-filled

- **Severity:** high (confirmed; reported as high). **Lens:** data. **Found by:** spine. **Established by:** read.
- **Location:** `daemon/Sources/MeetingPipe/MeetingSessionController.swift:624`
- **Backlog:** New. No task covers it. END11 decided a source-less recording engages no lifecycle adapter, and PERF15 restates the not_started zero-fill invariant, but neither names the missing MicGate engage or the lastVerdict dedupe under the regulated gate.

**Claim.** A source-less recording (hotkey or menu, no meeting app) never calls micGate.start, and honor_app_mute=false returns before it. The recorder resets its verdict to uncertain(not_started) at every start, but MicGate keeps lastVerdict across stop(). If that was hot(rms), the first RMS-open is deduped, so the regulated/NDA gate keeps zero-filling the mic.

**Failure scenario.** Regulated mode on. A manual in-person recording is stopped while people still talk (lastVerdict hot rms). In the next manual recording speech opens the RMS gate, publish() drops the duplicate, and the mic is written as zeros until 350 ms below -55 dBFS, possibly the whole meeting.

**Quoted code.**

```
if let source = source, let recordStartBuild = recordStartBuild {
                    self.attachWhenBuilt(id: recordStartBuild, source: source, file: file)
                }
```

**Verifier (both): confirmed.** Traced end to end. startManual passes source nil (:316), so :565 builds nothing and :624 skips the only route to micGate.start (:1444). RMS ingest is wired unconditionally, MicGate.stop() resets state but not lastVerdict, publish() dedupes against it, and the recorder resets to uncertain(not_started), which the regulated writer zero-fills. The tap outlives micGate.stop(), so the probe can also stay open. Needs regulated/NDA (non-default) and a prior same-process recording ending on hot(rms). Loss is irreversible until the first 350 ms below -55 dBFS; whole-meeting loss depends on room noise.

Evidence: daemon/Sources/MeetingPipe/MeetingSessionController.swift:312-317 (startManual from idle calls beginRecording(source: nil)); :532-536 (CaptureMode resolved from global regulatedMode or workflow ndaMode, applies to manual too); :565 (recordStartBuild = source.map, nil for no source); :624-626 (snippet, attachWhenBuilt only when source non-nil); :1426-1444 (engageMicGate: honor_app_mute guard at :1427 returns before the sole micGate.start call at :1444; callers only :1755 and :1763); :204-211 (verdict stream consumer is the only caller of setMicGateVerdict); :756 (micGate.stop() runs synchronously) vs :803-804 (recorder.stop awaited later). daemon/Sources/MeetingPipe/Coordinator.swift:409-411 (recorder.onMicRmsDb feeds micGate.ingest for every recording, started or not). daemon/Sources/MeetingPipeCore/MicGate/MicGate.swift:38 (lastVerdict initial uncertain(not_started)); :109-111 (rmsGate.onChange calls update with no started check); :138-148 (stop() resets state and probes, never lastVerdict, publishes nothing); :259-274 (decide: nil HAL/AX plus rms open gives hot(rmsAboveOpenThreshold), closed gives silentByRMS); :302-314 (publish drops verdict == lastVerdict, no yield). daemon/Sources/MeetingPipeCore/MicGate/Probes/RMSGateProbe.swift:33-36 (close -55 dBFS / 350 ms, open -45 dBFS / 80 ms); :47-51 (reset fires no onChange); :66-75 (close needs continuous dwell). daemon/Sources/MeetingPipe/MeetingRecorder.swift:425-428 (start resets verdict to uncertain(not_started)); :1605-1607 (only other write to the verdict); :1005-1012 (regulatedGate applies verdict in place); :1013-1024 (capture-first never zeroes, so no loss there); :1032-1035 (coverage counts uncertain as unmuted at pre-gate level, so no dead-mic signal); :184 (HUD meter reads -120, the only visible symptom); :1159-1163 and :1264-1272 (mic tap removed only in teardownEngine after two awaits, so ingest continues after micGate.stop and can leave the RMS probe open into the next recording). daemon/Sources/MeetingPipeCore/MicGate/MicGateVerdict.swift:36-39 (only .hot passes live audio); MicGateWriter.swift:42-54 (non-hot is zero-filled). daemon/Sources/MeetingPipe/CaptureMode.swift:42-45; ConfigDefaults.swift:25 (honorAppMute true), :40 (regulatedMode false); ConfigStore.swift:321-322 (regulated also forced on by a config parse error). Tests: daemon/Tests/MeetingPipeTests/EngageOffMainTests.swift:210-213 pins that the recorder stays on uncertain(not_started) until MicGate engages; no test in MicGateTests.swift or CoordinatorMicGateIntegrationTests.swift exercises lastVerdict across stop() or a second source-less recording. History: git show 200a4971^ shows engageMicGate already returned on nil source before PERF15, so the gap is long-standing, not a PERF15 regression. Not provable from code: how long the room stays above -55 dBFS, so the whole-meeting outcome is environment dependent; the guaranteed loss is from the start of the second recording until the first RMS close and reopen.

**Direction.** Engage MicGate for every recording (empty handles when source is nil) and reset MicGate.lastVerdict in stop(), or push micGate.current into the recorder at start. Traced through MeetingRecorder.swift:425, MicGate.swift:138-148 and 309-311, RMSGateProbe.swift:47, MicGateWriter.swift:42.

### F005. A workflow picked in the prompt and then not recorded leaks into the next meeting as the top-precedence override

- **Severity:** high (confirmed; reported as high). **Lens:** security. **Found by:** spine. **Established by:** read.
- **Location:** `daemon/Sources/MeetingPipe/MeetingSessionController.swift:515`
- **Backlog:** New. No task owns it. AI9's done spec states the override 'is only cleared by a start', so a skipped prompt leaves it armed, and routed its hint around that. The beginRecording comment saying neither can leak is wrong.

**Claim.** pendingWorkflowOverride, set by the prompt's workflow picker, is cleared only inside beginRecording, after its early returns. Skip, prompt timeout, meeting-ended-during-prompt and force-stop never clear it, so it becomes the top-precedence override of the next recording, in any app at any later time, beating that meeting's rule match and NDA flag.

**As corrected by verification.** Claim holds. Precision notes: the picker is the prompt's workflow chip menu and the AI9 caption (MeetingPromptWindow.swift:306-309, 830-900), not the chevron menu, which only carries BYO/Always/Skip. The stale value lives in memory, so it survives until the next committed start or a daemon restart, not indefinitely. It is also consumed by a manual hotkey start and shown as the pre-selected chip on the next prompt. Global regulated mode still clamps independently (line 533, sidecar regulated_mode), so the egress applies to meetings relying on a per-workflow NDA flag. The HUD shows the stale workflow name during the recording, so it is visible but not prevented.

**Failure scenario.** User picks a cloud workflow in the prompt chevron, then clicks Skip. Hours later an auto-consented meeting that matches an NDA workflow starts with no prompt: it resolves to the stale pick, records capture-first, and that workflow's routing is written to the meta sidecar the pipeline applies.

**Quoted code.**

```
var overrideID = pendingWorkflowOverride
        if overrideID == nil, let hint = preselectedRoutingHint, hint.source == source {
            overrideID = hint.workflowID
        }
```

**Verifier (both): confirmed.** Traced end to end by reading; could not refute. The override has three writers only: the picker delegate, the clear at line 524 (after three early returns), and the resume path. Skip, timeout-skip, ended-during-prompt and force-stop all leave it set. The auto-consent path calls beginRecording directly, WorkflowMatcher returns the override before any rule match, and capture mode plus the sidecar's nda/backend/sinks derive from it. The code's own comments admit the leak. No test pins a clear on skip. Trigger is uncommon, but the outcome is NDA-violating egress.

Evidence: daemon/Sources/MeetingPipe/MeetingSessionController.swift:42 (in-memory field, "Highest matcher precedence"); :46-48 comment "pendingWorkflowOverride is only cleared by a start"; :433-435 setter; :476-510 three early returns (start in flight, mic permission, dry run) before the clear; :515-525 snippet and the only clear; :532-536 capture mode from resolvedWorkflow.flags.ndaMode; :353-369 forceStop .prompting, no clear; :1046-1062 timeout default skip, no clear; :1116 only other writer (resume path); :1154-1161 auto-consent calls beginRecording with no prompt; :1169 next prompt chip also resolves through the stale override; :1173-1174 comment "the way a lingering explicit override could"; :1281-1291 handleMeetingEndedDuringPrompt, no clear; :986-989 sidecar built from activeWorkflow. daemon/Sources/MeetingPipe/Coordinator+Delegates.swift:14-36 didChooseSkip calls abandonPrompt only; :162-168 didChooseWorkflow is the sole caller of setPendingWorkflowOverride. daemon/Sources/MeetingPipe/MeetingPromptWindow.swift:306-309 chip click opens the workflow menu; :830-847 AI9 caption; :877-900 selectWorkflow fires the delegate; :137-213 present/dismiss never reset the override. daemon/Sources/MeetingPipe/Coordination/DetectionStateMachine.swift:270-275 abandonPrompt touches cooldown, latch and state only. daemon/Sources/MeetingPipe/WorkflowMatcher.swift:14-17 override returned before rule scoring. daemon/Sources/MeetingPipe/MeetingMetaSidecar.swift:48-67 workflow_backend, workflow_sinks, workflow_nda_mode come from the resolved workflow. pipeline/src/mp/workflow.py:170-188 apply_overrides reads workflow_nda_mode and workflow_backend from the sidecar. daemon/Tests/MeetingPipeTests/MeetingSessionControllerBranchTests.swift:191-207 pins clear-on-start only; :310-312 test comment restates that a skipped prompt leaves it set.

**Direction.** Clear the override on every prompt exit (abandonPrompt, ended-during-prompt, a new present) and key it to the prompt's source the way preselectedRoutingHint is keyed. Setter is Coordinator+Delegates.swift:162; precedence is WorkflowMatcher.swift:15.

### F009. Quick Find, notification and deeplink targets are dropped when the Library window is first created

- **Severity:** high (confirmed; reported as high). **Lens:** quality. **Found by:** ui-library. **Established by:** read.
- **Location:** `daemon/Sources/MeetingPipe/LibraryWindow.swift:662`
- **Backlog:** New. No task or audit names it. AUTO1 (deferred; URL scheme half shipped in 12724e3c) says deeplinks land at the right rail via pendingScope, and TECH-A3 added pendingSelection. Those are feature claims, not a fix claim for the first-open miss.

**Claim.** pendingSelection and pendingScope are consumed only by onChange, but their setters (Coordinator.openMeeting, openLibraryViaAutomation) run before show() builds the view, so the initial value never fires; onAppear handles only pendingTranscriptJump. Neither value is cleared after a miss, so sending the same stem or scope again is not a change either.

**Failure scenario.** After launch, press Cmd+K and pick a meeting, or click a failure notification: the Library opens with nothing selected. Cmd+Return Ask lands on All meetings, and the stored question runs by itself later when the Ask rail is first opened.

**Quoted code.**

```
.onChange(of: model.pendingSelection) { _, stem in
            guard let stem else { return }
            // Quick Find can fire while a workflow scope is active; switch to All Meetings so the row is always visible.
            scope = .allMeetings
            meetingSelection = [stem]
            model.pendingSelection = nil
```

**Verifier (both): confirmed.** Could not refute. Setters run before show() constructs LibraryRootView, the NSWindow is built lazily on first show(), and pendingSelection/pendingScope are read only by onChange, which does not fire for an initial value (the file's own AUTO2 comment says so; only the transcript jump got an onAppear fix). Both are cleared only inside those handlers, so repeats of the same value stay inert. AskView.onAppear later runs the stale question. No test pins otherwise. Impact is navigation only, once per daemon lifetime plus sticky repeats; no data loss.

Evidence: daemon/Sources/MeetingPipe/LibraryWindow.swift:14-23 (window and root view built lazily on first show()); :626-633 (onAppear resolves only pendingTranscriptJump, comment "onChange never fired for it"); :662-668 (pendingSelection consumed and cleared only in onChange); :669-674 (pendingScope same); :555 (scope defaults to .allMeetings). daemon/Sources/MeetingPipe/Coordinator+MenuActions.swift:118-121 (openMeeting sets pendingSelection, then show()). daemon/Sources/MeetingPipe/Automation/Coordinator+Automation.swift:26-28 and 63-68 (pendingScope set before show(); pendingAskQuestion set after). Callers: daemon/Sources/MeetingPipe/Coordinator.swift:849-857 (Quick Find onSelect and onAsk), daemon/Sources/MeetingPipe/Coordinator+Delegates.swift:54-57 (failure notification click), daemon/Sources/MeetingPipe/App.swift:71-80 (meetingpipe:// deeplinks), daemon/Sources/MeetingPipe/QuickFindWindow.swift:238-256 (Enter and Cmd+Return). Stale Ask run: daemon/Sources/MeetingPipe/AskView.swift:123-137 and 154-156, daemon/Sources/MeetingPipe/AskModel.swift:230-240. Coordinator.swift:171 creates only the LibraryWindow wrapper; no launch path calls libraryWindow.show() (grep: only Coordinator+MenuActions.swift:85,97,114,120 and Coordinator+Automation.swift:60,67). grep of daemon/Sources and daemon/Tests: no other reader of pendingSelection or LibraryWindowModel.pendingScope, and no test references either. Not run: no build or SwiftUI experiment (builds forbidden); onChange initial-value behaviour rests on documented SwiftUI semantics plus the in-file comment at LibraryWindow.swift:630-631.

**Direction.** Consume both pending values in onAppear the way resolveTranscriptJump already is (or onChange(initial: true)), and drop pendingAskQuestion when its scope switch did not happen.

### F011. Prompt hover pause is display-only: the default action still fires at the timeout

- **Severity:** high (confirmed; reported as high). **Lens:** quality. **Found by:** ui-chrome. **Established by:** read.
- **Location:** `daemon/Sources/MeetingPipe/MeetingPromptWindow.swift:481`
- **Backlog:** New. No task, audit or ADR names the hover-pause mismatch. CONC10 (owner-verify) moved both prompt timers to common mode with semantics unchanged; UX10 and AUD-12 cover the silent timeout skip. None adds a pause hook to startPromptTimeout.

**Claim.** setHovered freezes the progress hairline and cancels only the panel's own dismiss timer. The timer that executes default_prompt_action is DetectionStateMachine.startPromptTimeout, which has no pause hook (SessionPromptPresenting exposes present/dismiss only). It dismisses the panel and acts while the countdown looks paused; dismiss() also nils currentSource, so later menu picks are dropped.

**Failure scenario.** Default 30 s timeout. User rests the pointer on the prompt or opens the chevron menu; the bar freezes. At 30 s the panel vanishes and the meeting is skipped, or with default action 'record' it starts in auto mode and a later 'Skip' or 'Record (BYO)' pick does nothing.

**Quoted code.**

```
fileprivate func setHovered(_ hovered: Bool) {
        dismissProgress?.setPaused(hovered)
```

**Verifier (both): confirmed.** Could not refute. setHovered pauses only the hairline and the panel's private dismiss timer. The acting timer is the state machine's, armed for every prompt with the same timeout, guarded only by state == .prompting, with no pause API and no caller from the panel. At timeout it calls prompt.dismiss() and runs the default action. The design mockup states the pause exists so a reader does not lose the prompt, and no test pins hover. Trigger is ordinary use (reading the Last time card). Bounded by a start-late notification, so not critical.

Evidence: daemon/Sources/MeetingPipe/MeetingPromptWindow.swift:481-493 (setHovered: dismissProgress.setPaused + cancel/reschedule of cancelDismissTimer only); :473-479 (panel timer only calls self.dismiss()); :185-195 (dismiss() nils currentSource); :497-519 (handleRecord/Skip/Always/RecordBYO all guard on currentSource); :959-960 (tracking area is the only setHovered caller). daemon/Sources/MeetingPipe/Design/DismissProgressView.swift:84-104 (setPaused is a CALayer speed freeze plus dim, visual only). daemon/Sources/MeetingPipe/Coordination/DetectionStateMachine.swift:292-310 (startPromptTimeout: common-mode one-shot, sole guard is `case .prompting(let src) = current, src == source`; only cancelPromptTimeout exists, no pause). daemon/Sources/MeetingPipe/MeetingSessionController.swift:1190-1197 (present(autoDismissAfter: livePromptTimeoutSec) then startPromptTimeout with the same value); :1027-1064 (timeout action: prompt.dismiss(), then record / byo / abandonPrompt + notifySkippedMeeting); :252 and :1080 (live callers of handleMeetingStarted: lifecycle .starting verdict and mic-in-use dwell). daemon/Sources/MeetingPipe/SessionHost.swift:183-195 (SessionPromptPresenting exposes present and dismiss only). daemon/Sources/MeetingPipe/Coordinator+Delegates.swift:10, 15, 158 (delegate handlers also guard on .prompting, so a late pick is dropped a second time). daemon/Sources/MeetingPipe/ConfigDefaults.swift:33 (promptTimeoutSec = 30); daemon/Sources/MeetingPipe/ConfigStore.swift:315 (default_prompt_action defaults to "skip"). daemon/Sources/MeetingPipeCore/Infra/Schedulers.swift:19-27 (timer is live during alerts and menu tracking). design/ui_kits/macos_app/MeetingPrompt.jsx:16 ("Pauses on hover so a reader does not lose the prompt"), contradicted by the implementation. grep of daemon/Tests for hover/setPaused/isPaused: no test covers the prompt hover path; MeetingSessionControllerBranchTests.swift:751-762 pins the timeout firing unconditionally. Mitigation weighed: daemon/Sources/MeetingPipe/Notifier.swift:220-238 (sounded "Meeting prompt timed out. Start recording?" with start-late action) and statusUI.setSuppressed at MeetingSessionController.swift:1059; though :1166-1167 notes the panel is the primary surface because banners can be suppressed under Focus. Not verified at runtime: whether an open NSMenu survives the panel's orderOut. Either way the pick cannot take effect, so the dropped-pick sub-claim holds from the code guards alone.

**Direction.** Give the state machine one timer that the panel pauses and resumes (or drop the hover pause), and make a menu pick after dismissal either act or be impossible.

### F012. ConfigStore never re-reads a parsed config.toml, so any Preferences change writes the launch-time document over later edits

- **Severity:** high (confirmed; reported as high). **Lens:** data. **Found by:** ui-chrome. **Established by:** read.
- **Location:** `daemon/Sources/MeetingPipe/ConfigStore.swift:268`
- **Backlog:** New. ARCH9 (done, 19d19a12) documents the no-re-read as deliberate ('a parsed store is the file's author') but never costs lost hand edits; UX45 and UX89 still endorse hand edits. UX94 covers only the unparseable case. No task accepts the overwrite.

**Claim.** The file is parsed once into rawDocument at init; reloadIfUnparsed returns unless a parse error is set; there is no watcher. writeBack then persistToDisk serialise that in-memory document over the file. Yet the Advanced pane offers 'Open in editor' and calls hand edits safe, and the Obsidian footer says template_path and daily_note_backlink 'stay in config.toml'.

**Failure scenario.** With the menu-bar app running, the user adds obsidian.template_path (or flips modes.regulated_mode) in config.toml. The daemon keeps its old values, and the next toggle of any Preferences control rewrites the file from memory: the new key is gone and regulated_mode is back to false, silently.

**Quoted code.**

```
func reloadIfUnparsed() {
        guard parseError != nil else { return }
```

**Verifier (both): confirmed.** Traced by reading, not executed. rawDocument is assigned only in apply(), reached from init and the parse-error-guarded reload; the only file watcher in the daemon targets the recordings dir. Any ConfigStore-bound control change rewrites the whole file from the launch-time document, so an added unmodeled key vanishes and a hand-set modeled key reverts. A test pins the no-reload as deliberate, but UI copy and SETUP step 8 invite live hand edits without a relaunch, and a code comment records the owner hitting it. Nuance: UserDefaults, secrets and workflow controls do not trigger the save.

Evidence: daemon/Sources/MeetingPipe/ConfigStore.swift:235-240 (single parse at init), :268-274 (reloadIfUnparsed guarded on parseError), :278-281 (only assignment of rawDocument), :373-395 (scheduleSave: writeBack then persistToDisk on any didSet), :399-441 (writeBack sets modes.regulated_mode and only modeled keys), :444-473 (persistToDisk replaces config.toml with rawDocument), :111-115 (comment: changing summarization.model by hand "meant quitting the app first or having its next save write the old id back"), :140-142 (template_path and daily_note_backlink TOML-only on purpose). daemon/Sources/MeetingPipe/PreferencesWindow.swift:42-45 (show() calls only reloadIfUnparsed). daemon/Sources/MeetingPipe/App.swift:140-147 (one long-lived store for the app). daemon/Sources/MeetingPipe/MeetingStore.swift:387-397 (the only makeFileSystemObjectSource, on recordingsDir). grep of daemon/Sources: no other ConfigStore.read/apply caller, no FSEvents or NSFilePresenter. daemon/Sources/MeetingPipe/Preferences/PreferencesView+Advanced.swift:16-17 ("Open in editor"), :51 ("safe to edit by hand"). daemon/Sources/MeetingPipe/Preferences/PreferencesView+Integrations.swift:245 (Obsidian footer "stay in config.toml"). daemon/Tests/MeetingPipeTests/ConfigStoreTests.swift:658-667 (test_reload_is_a_no_op_on_a_store_that_parsed pins the behaviour). daemon/docs/gotchas.md:477 ("once the file parsed the store is its author"). docs/SETUP.md:162-169 (tells the user to hand-edit [output] sinks; "Most changes take effect on the next recording"). pipeline/src/mp/config.py:283-288 and pipeline/src/mp/publish_router.py:127 (pipeline reads template_path from the file at spawn, so the edit works until the next Preferences save silently removes it).

**Direction.** Re-read (or compare mtime/hash) before each save and merge only the modeled keys, or watch the file and reload when no save is pending.

### F014. Series continuity block sends a withheld prior meeting's content to the cloud

- **Severity:** high (confirmed; reported as high). **Lens:** data. **Found by:** py-summarize, contracts, x-security. **Established by:** read.
- **Location:** `pipeline/src/mp/summarize.py:310`
- **Backlog:** New. SEC29 (new) covers the same AI6 block but only its placement outside the untrusted fence; CAL3 covers the series key. Neither adds a withheld gate. AI6 (done, 86999550) asserted regulated/NDA behaviour unchanged without checking the prior meeting's flags.

**Claim.** The AI6 continuity block picks the newest earlier meeting by `workflow_id` alone and injects its title, decisions and open actions into the system prompt sent to whatever backend summarizes the current meeting. It never checks the prior's `regulated_mode` or `workflow_nda_mode`, the per-meeting gate (`visibility.withheld_reason`) every other cross-meeting surface applies.

**Failure scenario.** Meetings in a workflow are recorded under regulated mode, or with the workflow's NDA flag on. The owner later switches it off. The next meeting in that workflow sends the withheld meeting's decisions, action items with owner names, and title to Anthropic.

**Quoted code.**

```
for stem, summary_json in earlier
            if read_meta(summary_json).get("workflow_id") == workflow_id
```

**Verifier (both): confirmed.** Snippet exists at summarize.py:310-311. The prior is matched on workflow_id only; the only other gate is language. Its title, up to 12 decisions and 12 open actions (owner, task, due) join the system prompt every backend receives. The current meeting's clamp reads only its own sidecar, so a regulated or NDA prior does not force local. A scratch probe with a withheld prior and an unclamped current meeting put all three into the prompt with backend anthropic (the default). No test or doc pins an exemption. Not critical: bounded summary items, not the transcript, and it needs mixed posture inside one workflow.

Evidence: pipeline/src/mp/summarize.py:283-286 (series key is the current meeting's workflow_id), :297-314 (newest earlier stem with equal workflow_id, no regulated_mode / workflow_nda_mode / visibility check), :324-327 and :349-368 (title, decisions, open actions with owner and due go into the block), :337-347 (language mismatch is the only drop rule), :223-226 (block appended to the system prompt as trusted text), :565-583 (summarize() passes it to client.summarize), :456-462 (Anthropic client sends it as the system block), :818-823 (auto backend tries cloud first with the same prompt). pipeline/src/mp/provider_openai.py:56-63 and pipeline/src/mp/provider_claude_cli.py:78-85 (other cloud backends take the same system_prompt). pipeline/src/mp/workflow.py:158-182 and pipeline/src/mp/config.py:296-335 (zero_egress and effective_backend are decided from the current meeting's sidecar only, so a withheld prior does not clamp the run); pipeline/src/mp/config.py:122 (default backend is "anthropic"). Stated policy the path contradicts: pipeline/src/mp/visibility.py:26-30 and :80-95 (a meeting flagged regulated_mode or workflow_nda_mode is withheld, and a regulated one "stays clamped even after the global flag is turned off"); pipeline/src/mp/workflow.py:175-178 (same rule for a reprocess). summarize.py imports only read_meta (line 72), never visibility. Reachability: daemon/Sources/MeetingPipe/MeetingMetaSidecar.swift:37-39, :48-49, :67 (the daemon writes regulated_mode, workflow_id and workflow_nda_mode into the same sidecar, so a regulated or NDA meeting carries the series key); pipeline/src/mp/orchestrate.py:566-571 (run-all calls summarize() for every recording) and summarize.py:905 (standalone mp summarize, the Library regenerate path). A zero-egress meeting still gets a local <stem>.summary.json, so it is eligible as a prior. Tests: pipeline/tests/test_summarize.py:416-420 (the prior fixture writes only workflow_id and workflow_name) and :432-632 (no AI6 test covers a regulated or NDA prior). Experiment (scratch dir only, pipeline/.venv python, no network): prior sidecar with regulated_mode true, then with workflow_nda_mode true; current sidecar same workflow_id, unflagged. Result both times: visibility.withheld_reason(prior) = "regulated" / "nda", zero_egress(current cfg) = False, backend = anthropic, and the prior's title, decision and action all present in _load_system_prompt output. Preconditions that bound it: a cloud backend for the current meeting, the prior in the same language, and mixed posture within one workflow (global regulated mode switched off after some meetings, or the workflow's NDA flag turned off).

**Direction.** Skip any prior whose sidecar is withheld per `visibility.withheld_reason` unless the current run is itself zero-egress, and pin it with a test beside the existing AI6 tests.

Also reported as: contracts: Prior-meeting context (AI6) carries a regulated or NDA meeting's decisions into a later cloud summar...; x-security: AI6 prior-meeting context sends a zero-egress meeting's decisions and actions to a cloud backend

### F016. publish-from-paste overwrites the pasted summary.md with a lossy re-render before publishing

- **Severity:** high (confirmed; reported as high). **Lens:** data. **Found by:** py-publish. **Established by:** read.
- **Location:** `pipeline/src/mp/publish_from_paste.py:270`
- **Backlog:** New. The lossy parse-and-overwrite of the pasted summary is unfiled. PIPE30 (new) covers only the non-atomic write of those files; HYG18 only the placeholder wording; WF7 (done) preserved non-standard H2 bullets. No task or ADR accepts the content loss.

**Claim.** The parser keeps only what it recognises (bullets under known H2s, at most ten summary bullets, a 120-char title). The command then overwrites the user-supplied `<stem>.summary.md` and `.summary.json` in place with plain `write_text`, not `storage.atomic_write_text`, before any sink runs. Unparsed prose is silently replaced by a placeholder bullet.

**Failure scenario.** A pasted summary has prose under `## Summary`. `_extract_bullets` returns an empty list (confirmed by running the real helper source on a sample), the placeholder is substituted, and the file is rewritten: the prose is gone from that file and from every sink.

**Quoted code.**

```
summary_md_path.write_text(
        render_summary_md(summary, deeplink_stem(transcript_md)), encoding="utf-8"
    )
```

**Verifier (both): confirmed.** Snippet is exact. Running the real parse_summary_md plus render_summary_md on prose under "## Summary" yields only the placeholder bullet; unchecked action bullets, tables and H3 prose vanish too. Both files are rewritten with plain write_text before fanout, and every sink renders from the parsed model. No guard except regulated mode. Reachable by default: Save & publish in the paste box (BYO, or cloud transcripts over 80000 chars), and the bundle prompt gives no Markdown shape. Intentional and test-pinned, yet lossy. Not critical: audio and transcript untouched, paste source usually survives. Nit: unknown-H2 bullets are kept.

Evidence: pipeline/src/mp/publish_from_paste.py:59-60 (docstring: unparsed content dropped silently), :65 (title[:120]), :67-70 (empty bullets -> placeholder, cap 10), :41-44 + :159 (actions need a [ ] checkbox), :106-121 (unknown H2 bullets kept as extra sections, so claim slightly understates what survives), :246-255 (only guard: regulated mode), :259-262 (summary.json plain write_text), :263-265 (comment wrongly says "preserves user content"), :270-272 (snippet, plain write_text), :278 (fanout runs after both writes). pipeline/src/mp/storage.py:16-33 (atomic_write_text exists, unused here; summarize.py:617,621 use it for the same two files). pipeline/src/mp/publish_fs.py:64, publish_lan.py:70 (sinks render from the parsed MeetingSummary, not the raw paste). pipeline/tests/test_publish_from_paste.py:213-216 (re-render is pinned), :225-228 (regulated test docstring concedes the overwrite "would silently destroy editorial content"), :84-92 (placeholder pinned). Reachability: daemon/Sources/MeetingPipe/SummaryTab.swift:358-408 (Paste box, Save & publish), daemon/Sources/MeetingPipe/Library/MeetingLibraryService.swift:949-995 (writes pasted text only to <stem>.summary.md at :968, then runs mp), daemon/Sources/MeetingPipe/PipelineLauncher.swift:1192-1193, daemon/Sources/MeetingPipe/MeetingStore.swift:878-879 (manualPasteReady), pipeline/src/mp/orchestrate.py:374-385 and :402-423 (BYO and long-meeting guard write the bundle), pipeline/src/mp/config.py:99 (skip_above_chars=80000), :122 (backend default anthropic), pipeline/src/mp/prompts/meeting_summary.md:66-69 (bundled prompt asks for a tool call, specifies no Markdown shape), README.md:77 and docs/GUIDE.md:58 (documented flow, no format requirement stated). Experiment: scratch probe at the session scratchpad run with pipeline/.venv/bin/python and PYTHONPATH=src: 201-char input with prose under "## Summary" rendered to 130 chars containing only the placeholder bullet plus the one Decisions bullet; a 377-char input with nested bullets, H3 prose, unchecked action bullets, a prose "Next Steps" section and a table rendered to 84 chars (two summary bullets only); 12 summary bullets rendered as 10.

**Direction.** Publish from the parsed form but keep the pasted file (or save it as a sibling original), refuse when a section parses empty, and write through atomic_write_text.

### F017. Notion republish deletes every block on the page, then appends the new body without retry

- **Severity:** high (confirmed; reported as high). **Lens:** data. **Found by:** py-publish, x-concurrency. **Established by:** read.
- **Location:** `pipeline/src/mp/publish_notion.py:333`
- **Backlog:** New. PIPE23 (new) covers the same publisher but different defects: duplicate pages on create, deleted pages, Date and Status reset. Nothing names the delete-all-then-append body replacement, the unretried append, or the loss of owner-added blocks and to-do ticks.

**Claim.** `_update_page` fetches all top-level children and deletes them (eight parallel DELETEs), which includes anything the owner added to the page in Notion, then appends through `_request_once`, which never retries. A 429 or 5xx on the append, or a kill in between, leaves the live page with new properties and no body.

**As corrected by verification.** Claim holds as stated. Two refinements: (1) the empty-body state is not silent or permanent: the sink is recorded as failed (partial state, or exit 3 when Notion is the only sink), the old sidecar keeps page_id, and the next publish re-runs the update path and restores the body from the local summary; (2) the 429-after-burst trigger is inferred, not demonstrated against live Notion, so the deterministic leg is the unconditional deletion of owner-added top-level blocks (and in-Notion to-do ticks) on every republish, which the app's own docs say cannot happen.

**Failure scenario.** Owner adds notes to a meeting page in Notion, then republishes after editing the summary: their blocks are deleted. If the first append is rate-limited after the delete burst (Notion limits inferred, not tested), the sink fails and the page stays empty until a later publish succeeds.

**Quoted code.**

```
block_ids = _fetch_all_child_ids(client, page_id)
    if block_ids:
        with ThreadPoolExecutor(max_workers=8) as ex:
```

**Verifier (both): confirmed.** Could not refute. The update path deletes every top-level child with no authorship filter, then appends once with no retry. A MockTransport run reproduced it: properties patched, both blocks deleted (one standing in for an owner note), one append attempt on 429, exception raised. Path is live: Notion is the default sink and every republish, regenerate, merge and retry reaches it. Docs promise republish loses nothing hand-written. Limits: the empty body is visible and repaired by the next publish; 429 likelihood against live Notion is untested.

Evidence: pipeline/src/mp/publish_notion.py:333-340 (fetch all child ids, 8-worker DELETE of every one, no created_by or marker filter; grep for last_edited/created_by/archived in pipeline/src/mp finds no guard); :264-284 (_fetch_all_child_ids pages through all top-level children); :345-351 (append via _request_once); :243-261 (_request_once has no retry); :217-221 (429 and 5xx raise HTTPStatusError); :319-324 (properties PATCHed first, so new properties land before the wipe); :97-103 (update path taken whenever <stem>.notion.json has page_id); :116-127 (sidecar rewritten only on success, so the old page_id survives a failure and the next publish re-enters the update path and re-appends). Reachability: pipeline/src/mp/config.py:244 (default sinks = ["notion"]); pipeline/src/mp/publish_router.py:112-121, 210-229 (fanout builds NotionRestPublisher, catches the exception and records sink_failed); pipeline/src/mp/publish_cmd.py:37 and orchestrate.py:603 and merge_meetings.py:237 (all fan out); daemon/Sources/MeetingPipe/PipelineLauncher.swift:883 and :1301 (daemon spawns `mp publish`); docs/GUIDE.md:337 (user told to Republish after ticking an action). Contradicted safety claim: daemon/Sources/MeetingPipe/BatchActionConfirmation.swift:27-31 and BatchActionsPane.swift:79-81 and README.md:328 (Republish is ungated because "nothing the owner authored is lost"). Tests pin the wipe, none cover append failure after delete: pipeline/tests/test_publish_notion.py:92-132, 203-245, 436-472. Experiment (pipeline/.venv python, httpx.MockTransport, no network), script at the session scratchpad request order GET /databases, PATCH /pages/page-1, GET children, DELETE blk-app-1, DELETE blk-OWNER-note, PATCH children -> 429; "append attempts: 1"; HTTPStatusError raised; sidecar unchanged. Not verifiable from the repo: whether Notion actually returns 429 after an 8-thread burst, and that Notion's block DELETE is an archive to trash (restorable in Notion), which would soften the owner-note loss to recoverable.

**Direction.** Append the new body first and delete old blocks only after it lands (or replace only pipeline-owned blocks), and retry 429 on append since a rejected request was not applied.

Also reported as: x-concurrency: Notion republish wipes the page with an unpaced 8-thread DELETE burst before a non-retried append

### F018. doctor's cloud-sync check never inspects the folder NDA and regulated meetings publish to

- **Severity:** high (confirmed; reported as high). **Lens:** security. **Found by:** py-orchestrate. **Established by:** read.
- **Location:** `pipeline/src/mp/doctor.py:614`
- **Backlog:** Claimed fixed, not holding (SEC12, 81dc71fa). SEC12 (done, 81dc71fa) claimed doctor checks every synced root and FAILs under regulated or NDA; the _synced_roots docstring and SEC18 repeat it. Published folder is checked only when global sinks list filesystem. SEC18's publish gate does not touch doctor.

**Claim.** `_synced_roots` adds `filesystem.output_dir` only when the global `output.sinks` lists `filesystem`. But `workflow.apply_overrides` rewrites sinks to `["filesystem"]` for every NDA or regulated meeting, so those transcripts land in `~/Documents/Meetings/published` by default. Doctor then prints an all-clear without ever inspecting that folder. Workflow-level sinks are ignored the same way.

**Failure scenario.** Global sinks = [notion], one NDA workflow, library moved out of iCloud via the app (LibraryMover.execute moves only recordings and digests). An NDA meeting publishes summary plus full transcript into iCloud-synced ~/Documents/Meetings/published; `mp doctor` says no meeting data is inside a cloud-sync folder.

**Quoted code.**

```
if "filesystem" in cfg.output.sinks:
        # `filesystem.output_dir` is a raw string with a possible `~`;
        # `detect_sync_provider` expands it.
        roots.append(("published summaries", Path(cfg.filesystem.output_dir)))
```

**Verifier (both): confirmed.** Snippet is verbatim at doctor.py:614-617 (584 is line drift). `_synced_roots` gates the published root on global `output.sinks` only (default `["notion"]`); nothing reads workflow sinks. NDA and sidecar-stamped regulated meetings are clamped to `["filesystem"]` and copy summary plus full transcript into `filesystem.output_dir` (default under ~/Documents). The app's move repoints only the recordings dir, and the Storage pane checks only the library. A sandbox run reproduced the all-clear with an NDA workflow present. Doctor is the silent detector, not the cause: high, not critical.

Evidence: All paths under the repo root. The gate and the all-clear: - pipeline/src/mp/doctor.py:614-617: published root appended only when "filesystem" is in global cfg.output.sinks. - pipeline/src/mp/doctor.py:650-653: empty result prints "[ OK ] no meeting data is inside a cloud-sync folder" and returns before the NDA lookup at 655-656, which reads flags only, never sinks. - pipeline/src/mp/doctor.py:672: the fix hint itself recommends the library move that opens the gap. - pipeline/src/mp/workflows.py:42-69: the only workflow readers are nda_workflow_names and local_backend_workflow_names; no sink reader exists. Defaults: - pipeline/src/mp/config.py:244: output.sinks defaults to ["notion"]. - pipeline/src/mp/config.py:217 and daemon/Sources/MeetingPipe/ConfigStore.swift:357-358: filesystem.output_dir defaults to ~/Documents/Meetings/published. NDA and regulated meetings do publish there, end to end: - daemon/Sources/MeetingPipe/Workflow.swift:209-211: effectiveSinks is [.filesystem] under NDA. - daemon/Sources/MeetingPipe/MeetingMetaSidecar.swift:37-38, 63, 67: sidecar stamps regulated_mode, workflow_sinks, workflow_nda_mode. - pipeline/src/mp/entry.py:51 and pipeline/src/mp/orchestrate.py:284: run_all resolves cfg through apply_overrides. - pipeline/src/mp/workflow.py:235-241 (and 110-113 for an unreadable sidecar): zero egress forces sinks to ["filesystem"]. - pipeline/src/mp/orchestrate.py:603-607: fanout receives the overlaid cfg and transcript_md. - pipeline/src/mp/publish_router.py:136-138 and pipeline/src/mp/publish_fs.py:87-93: FilesystemPublisher writes <stem>.summary.md, .actions.json and .transcript.md into filesystem.output_dir. No guard elsewhere: - daemon/Sources/MeetingPipe/LibraryMover.swift:12-15, 138-152 and daemon/Sources/MeetingPipe/Preferences/StorageStatsStore.swift:150: the move takes recordings and digests and repoints only recording.output_dir. - daemon/Sources/MeetingPipe/Preferences/StorageStatsStore.swift:55 and LibraryMover.swift:97: CloudSyncDetector is used only for the library dir and the move destination. - cloudsync.detect_sync_provider has a single caller, doctor.py:622. Documented contract that fails: - README.md:423 and 428, CONVENTIONS.md:717: doctor is promised to keep reporting published/ after the move. Tests: - pipeline/tests/test_doctor.py:317-331: the only published-sink test puts "filesystem" in global sinks; no test covers NDA with default sinks. Experiment (pipeline/.venv python with -B, fake home in the scratchpad, repo left clean): local library, published under Library/CloudStorage/OneDrive-Contoso, default sinks, one NDA workflow. check_library_sync printed the [ OK ] all-clear, while apply_overrides plus build_publishers resolved that NDA meeting to a FilesystemPublisher on the synced folder. Control with "filesystem" in global sinks printed [FAIL]. One narrowing that does not change the verdict: a regulated run with no sidecar at all returns early at workflow.py:162-163 and publishes nowhere, so "every regulated meeting" means every daemon-recorded one.

**Direction.** Check the published dir whenever regulated_mode is on, any NDA workflow exists, or any workflow lists the filesystem sink, not only when the global sinks do.

### F019. merge-meetings concatenates per-meeting speaker labels verbatim and ignores the fragments' overlays and markers

- **Severity:** high (confirmed; reported as high). **Lens:** data. **Found by:** py-orchestrate, contracts. **Established by:** read.
- **Location:** `pipeline/src/mp/merge_meetings.py:78`
- **Backlog:** New. FEAT9 (done, 516cb3b8) shipped the merge with timestamp offsets and a gap marker only; its spec, README and END17's header Merge never mention per-fragment speaker labels, overlays, corrections or markers. No task or audit names the cross-fragment label collision.

**Claim.** Fragment segments are copied with their `speaker` untouched, but `THEM-A/B` labels are assigned per meeting by order of first speech (`diarize.resolve_speaker_labels`). Fragments are read from raw `<stem>.json`, so their speaker-name and text-correction overlays and flag markers are ignored; the primary's name overlay then applies to the fragment's same-named clusters.

**Failure scenario.** Dropped call with two unnamed remote speakers. Before the drop Ann speaks first (THEM-A); after rejoining Raj speaks first (THEM-A). The merged transcript and re-summary attribute Raj's words and actions to Ann, the owner's fragment edits are not carried, and the daemon moves the fragments to the Trash.

**Quoted code.**

```
for seg in frag.get("segments") or []:
            shifted = dict(seg)
            if isinstance(shifted.get("start"), (int, float)):
                shifted["start"] = float(shifted["start"]) + offset
```

**Verifier (both): confirmed.** Traced end to end and reproduced with the shipped pure functions: fragments whose unknown voices first speak in different order both yield THEM-A, merge_transcripts keeps them verbatim, and the primary's labels table then renames every THEM-A segment. Nothing in merge_meetings.py or the Swift merge path reads fragment speaker_labels, transcript_corrections, markers or embeddings sidecars. Reachable from batch Merge and the END17 resume Merge button. Gates: two or more unenrolled remote voices; roster-matched voices and 1:1 calls are immune. Fragments stay recoverable in the Trash, so not critical.

Evidence: All paths under the repo root. Snippet and merge transform: - pipeline/src/mp/merge_meetings.py:78-84 copies each fragment segment with `dict(seg)`, shifting only start/end; `speaker` untouched. - pipeline/src/mp/merge_meetings.py:154-164 `_read_transcript` reads raw `<stem>.json` only; :205 builds `structured` from those; :214 merge; :228-229 writes merged json/md under the primary stem. A grep of the file for speaker_labels / transcript_corrections / markers / embeddings / overlay returns nothing. Per-recording label assignment: - pipeline/src/mp/diarize.py:354-372 `resolve_speaker_labels`: `order` is first-appearance order of non-me speakers; an unmatched speaker with an embedding gets `them_label(unknown_idx)`; :367-368 roster-matched voices get their name instead (immune). - pipeline/src/mp/orchestrate.py:789-801 finalize writes those labels into `<stem>.json`. - daemon/Sources/MeetingPipe/Transcription/FluidAudioRunner.swift:223 `diarizer.speakerManager.reset()` per job (ids restart per meeting), :237-242 and :176 write per-speaker embeddings, so the THEM branch (diarize.py:369) is the normal path. - daemon/Sources/MeetingPipe/SpeakerLabelStore.swift:3-11 in-app naming uses `--no-relabel`, so `<stem>.json` keeps THEM-x and names live only in the overlay sidecar. Primary overlay applied to the merged transcript: - pipeline/src/mp/merge_meetings.py:236 `summarize(md_path, ...)` on the primary stem. - pipeline/src/mp/summarize.py:535 `transcript_corrections.overlaid_structured(transcript_md)`; pipeline/src/mp/transcript_corrections.py:95-108 reads the primary's `<stem>.speaker_labels.json` and corrections; pipeline/src/mp/speaker_overlay.py:99-105 `labels.get(base, base)` over every segment, fragment segments included. - pipeline/src/mp/summarize.py:561 and pipeline/src/mp/markers.py:42-47 read only `<primary>.markers.json`; fragment flags never reach the re-summary. Reachability and aftermath (Swift): - daemon/Sources/MeetingPipe/BatchActionsPane.swift:599-606 batch Merge; daemon/Sources/MeetingPipe/LibraryWindow.swift:321-337 END17 resume Merge (header button at MeetingDetailView+Header.swift:258). - daemon/Sources/MeetingPipe/MeetingMergeEligibility.swift:52-67 gates only on count, done status, audio, workflow, privacy posture; nothing about speakers or overlays. - daemon/Sources/MeetingPipe/PipelineLauncher.swift:910-911 spawns `mp merge-meetings`; no pre-merge overlay baking. - daemon/Sources/MeetingPipe/Library/MeetingLibraryService.swift:1286-1302 on success soft-deletes each fragment; :1096-1106 `softDeleteMeeting` uses `fm.trashItem` on every file of the stem (overlay, corrections, markers sidecars included), so they are recoverable until the Trash is emptied. - daemon/Sources/MeetingPipe/BatchActionConfirmation.swift:53-59 the confirm warns about the primary's summary edits only; it says nothing about fragment names, text corrections or flags. No test pins the opposite: pipeline/tests/test_merge_meetings.py uses only `Me` / `Alice` / `Speaker?` labels and never asserts on speakers, overlays or markers. Experiment (read-only, pipeline/.venv python, PYTHONDONTWRITEBYTECODE=1, run from the scratchpad): fragment 1 with Ann speaking first resolved to {s_ann: THEM-A, s_raj: THEM-B}; fragment 2 with Raj speaking first resolved to {s_raj: THEM-A, s_ann: THEM-B}. `merge_transcripts` output carried THEM-A for both Ann's and Raj's lines; applying a primary overlay {"THEM-A": "Ann"} via `speaker_overlay.apply_overlay` then `render_markdown` printed "**Ann**: Raj: I will own the migration." and a speaker count of Ann: 2. Severity notes: not critical because fragment originals (audio, raw json, overlays, markers) go to the macOS Trash rather than being destroyed, and the primary's own overlays and markers stay index- and time-aligned (primary is first, offset 0). High rather than medium because the mis-attribution is silent, lands in the republished summary, and occurs on the feature's core use case (dropped group call) whenever two or more remote voices are not roster-enrolled and their first-speech order or membership differs across fragments; the loss of fragment flags and edits from the merged meeting occurs on every merge where the fragment had them.

**Direction.** Reconcile fragment clusters to the primary's by embedding similarity (or suffix unmatched labels per fragment), merge from the overlaid view, and carry markers with the time offset.

Also reported as: contracts: merge-meetings conflates per-recording THEM-x clusters and drops the fragments' overlays and flags

### F088. Every Notion update rewrites Date to the publish day (UTC) and Status to the default

- **Severity:** high (confirmed; reported as medium). **Lens:** data. **Found by:** py-publish. **Established by:** read.
- **Location:** `pipeline/src/mp/publish_notion.py:380`
- **Backlog:** Known, open (PIPE23). PIPE23 (new, P2; go-live UX-12) names it: _properties writes the publish day's UTC Date and default_status on create and every update. Scope item 3: create uses the stem's date, update writes neither.

**Claim.** `_properties` serves both create and update. It always sets `Date` to the UTC date of the publish run, never the meeting date carried by the stem, and `Status` to `notion.default_status`. `_update_page` PATCHes both on each republish, overwriting a hand-set status and the date the page was first filed under.

**Failure scenario.** Meeting held 3 Nov; the owner sets Status to Reviewed in Notion. On 12 Nov they edit the summary and republish: Date becomes 2026-11-12 and Status returns to Captured. A publish retried the next day also files a new meeting under the wrong date.

**Quoted code.**

```
"Date": {"date": {"start": today}},
        "Status": {"select": {"name": cfg.notion.default_status}},
```

**Verifier (batch): confirmed.** _properties (375-382) computes today in UTC and always sets Date and Status; _update_page PATCHes them on every republish (319-324). No test pins Date and nothing reads the stem's date. It contradicts the module's own no-wipe intent for hand-set fields (423-425). Notion is the default sink, SETUP tells the user to add Status options, and GUIDE presents republish as the routine after editing or ticking an action, so a later-day republish reliably refiles the page and resets Status. Bounded to two remote properties, but likely to be hit.

Evidence: Paths relative to the repo root. pipeline/src/mp/publish_notion.py:97-103 (update branch when the sidecar has page_id), 296-299 (create uses the same _properties), 319-324 (PATCH /pages/{id} with _properties), 375-382 (today = datetime.now(timezone.utc).date(); Date and Status always set), 423-425 (docstring: a republish never wipes a hand-set field, applied to optional properties only); pipeline/src/mp/config.py:195 (default_status 'Captured'), 244 (default sinks ['notion']); pipeline/src/mp/publish_cmd.py:36-41 and daemon/Sources/MeetingPipe/Library/MeetingLibraryService.swift:1221 (Republish path); docs/GUIDE.md:337, 582 (republish is the documented routine after edits); docs/SETUP.md:124-128 (Date and Status columns required, Captured as one option); pipeline/tests/test_publish_notion.py:92-133, 524 (update test asserts routes only; Status asserted on create; Date never asserted).

**Direction.** Derive Date from the recording stem and send Status only on create.

### G003. Undo naming in one meeting deletes the person's whole roster voiceprint

- **Severity:** high (confirmed; reported as high). **Lens:** data. **Found by:** gap-2. **Established by:** read.
- **Location:** `daemon/Sources/MeetingPipe/Library/MeetingLibraryService.swift:820`
- **Backlog:** New. FEAT3-UNDO and UX40 (done) deliberately route Undo naming and Un-name to mp roster forget, but nothing weighs the loss of samples from other meetings or a confirm. SEC22 and STOR7 (new) cover forget cascade and sample provenance only.

**Claim.** `undoSpeakerNaming` (and `renameSpeaker`, line 882) run `mp roster forget --name`, and `RosterStore.forget` (roster.py:207) removes the whole person: every sample from every meeting, not this meeting's contribution. The chip's Un-name and the row's Undo naming fire it immediately, with no confirm and no caption.

**Failure scenario.** Rana has nine samples from earlier meetings. In one meeting the owner accepts the suggestion 'Name as Rana' on the wrong voice, then undoes it. Rana's entire roster entry is deleted: she is never auto-matched again and her People row disappears.

**Quoted code.**

```
launcher.rosterForget(name: name) { [weak self] result in
```

**Verifier (both): confirmed.** Traced end to end. Enroll appends a sample to an existing person, but undo and rename call `mp roster forget`, which drops the whole person, so undo is not the inverse of naming. A scratch run of RosterStore showed Rana 9 samples, 10 after accept, entry gone after forget. Both UI items fire immediately; only Preferences Remove has an alert. Tests pin the forget but never a pre-existing person. High, not critical: only the derived roster entry is lost, one person, no recording or transcript, rebuildable by re-naming.

Evidence: daemon/Sources/MeetingPipe/Library/MeetingLibraryService.swift:761 (nameSpeaker enrolls with noRelabel), :801-820 (undo drops overlay, then rosterForget(name:) when the label has a voiceprint), :882 (renameSpeaker forgets oldName, result discarded). daemon/Sources/MeetingPipe/PipelineLauncher.swift:1014-1016 (runs `roster forget --name`). pipeline/src/mp/roster_cmd.py:60-63; pipeline/src/mp/roster.py:185-202 (enroll appends to existing person), :204-211 (forget filters out the whole person, no per-sample removal exists). UI reachability: daemon/Sources/MeetingPipe/VoiceResolutionBar.swift:109-112 (Un-name button, no confirm), :227-236 (namedHere cluster offers .unname; unresolved offers .suggest), :270-278 (caption nil for .unname), :332 (help text says the name lives in this meeting's overlay); daemon/Sources/MeetingPipe/TranscriptTab.swift:355, :513-528, :604, :1237 (row "Undo naming" calls straight through); daemon/Sources/MeetingPipe/MeetingCast.swift:197-205; daemon/Sources/MeetingPipe/LibraryWindow.swift:490-492. Suggestion glue: pipeline/src/mp/diarize.py:376-377, pipeline/src/mp/orchestrate.py:749-750, daemon/Sources/MeetingPipe/MeetingStore.swift:655-656, daemon/Sources/MeetingPipe/TranscriptTab.swift:847-850, daemon/Sources/MeetingPipe/VoiceResolution.swift:196-198. Contrast: daemon/Sources/MeetingPipe/Preferences/PreferencesView+Pipeline.swift:331-342 (deliberate Remove has an NSAlert confirm). Tests: daemon/Tests/MeetingPipeTests/MeetingLibraryServiceTests.swift:962-972 pins that undo forgets the name, only for a person with no prior samples; pipeline/tests/test_roster.py:80-86 pins whole-person forget. No test covers undo on a pre-existing multi-sample person. Docs: docs/GUIDE.md:205, :209, :213 advertise Un-name / Undo naming as "fully reversible" and say accepting a suggestion adds a sample to that person. People row: daemon/Sources/MeetingPipe/RosterProfile.swift:25-31 reads roster.json people. Mitigation only: pipeline/src/mp/backup.py:8 includes the roster in backups; per-meeting <stem>.embeddings.json files are untouched. Experiment (scratchpad, stdlib only, temp roster path): before [('Rana', 9), ('Dana', 1)], after accept [('Rana', 10), ('Dana', 1)], after forget [('Dana', 1)].

**Direction.** Record per-sample provenance (stem, label) in roster.json and remove only that sample; forget the whole person only when it was their sole sample or behind an explicit confirm.

### G004. Renaming a workflow orphans its meetings, its NDA-only membership and its vocabulary

- **Severity:** high (confirmed; reported as high). **Lens:** architecture. **Found by:** gap-2. **Established by:** read.
- **Location:** `daemon/Sources/MeetingPipe/WorkflowsView.swift:770`
- **Backlog:** New. No task covers a rename cascade. Name-keyed resolution was kept deliberately (TECH-B4 portability; UX30, UX33 and WF9, all done, declined id-keyed scopes), but only delete and collision costs were documented; UX44 notes vocabulary tables key by name.

**Claim.** Save renames in place and migrates nothing. Meetings resolve their workflow by the sidecar's name only (LibraryScope.swift:158, LibraryWindow.swift:1166) although `workflow_id` is stored, and vocabulary tables are keyed by name (GlossaryStore.swift:215, glossary.py:194). The editor warns only on collisions, and LibraryScope's comment says a rename cannot orphan.

**Failure scenario.** NDA workflow 'Client A' with 40 meetings and 25 vocabulary terms is renamed 'Acme'. Its rail row and inspector show no meetings, the NDA only scope loses all 40, and new 'Acme' meetings are transcribed without the terms, which sit under an unreachable 'Client A' table.

**Quoted code.**

```
clone.name = trimmedName
```

**Verifier (both): confirmed.** Editor Save (Library sheet, reachable) calls store.update, which only rewrites the workflow TOML; no sidecar or glossary migration exists. List, rail counts, NDA-only scope and inspector all resolve by sidecar workflow_name; glossary tables are name-keyed on both sides and the picker lists current names only. Sidecar workflow_id is ignored there, though PrepCard already uses it. No test pins rename survival; README calls renaming free. Bounds: nothing on disk is lost, NDA egress clamp reads the sidecar snapshot, renaming back restores everything, list and badge stay stale until recompute.

Evidence: Rename in place, no migration: daemon/Sources/MeetingPipe/WorkflowsView.swift:763-800 (clone.name at 770, store.update at 791); daemon/Sources/MeetingPipe/WorkflowStore.swift:114-147 (upsert/update only persist workflow TOMLs). Reachable: daemon/Sources/MeetingPipe/LibraryWindow.swift:687-693, 1141, 1215 (Edit workflow sheet hosts WorkflowEditor). Only warning is the collision hint: WorkflowsView.swift:191-198, 227-235; WorkflowStore.swift:43-49. Name-only resolution in the Library: daemon/Sources/MeetingPipe/LibraryScope.swift:145-159 (workflowsByName lookup), :197 (ndaOnly via that lookup), :214 (workflow scope via that lookup); daemon/Sources/MeetingPipe/LibraryListView.swift:194-195; daemon/Sources/MeetingPipe/LibrarySidebar.swift:331-334 (ScopeCounts.build); daemon/Sources/MeetingPipe/LibraryWindow.swift:1165-1167 (inspector filter workflowName == workflow.name). workflow_id is stored and lifted but unused for membership: daemon/Sources/MeetingPipe/MeetingMetaSidecar.swift:49-50; daemon/Sources/MeetingPipe/MeetingStore.swift:42-46, 947-949 (only other reader is MeetingMergeEligibility.swift:59). Misleading comments: LibraryScope.swift:3 and :155. Vocabulary keyed by name: daemon/Sources/MeetingPipe/GlossaryStore.swift:178-186, 213-216, 275-281 (writeBack touches only the selected table, so the old table is preserved, not deleted); pipeline/src/mp/glossary.py:191-196; sole caller pipeline/src/mp/orchestrate.py:231. Old table unreachable from the UI: daemon/Sources/MeetingPipe/Preferences/VocabularyEditor.swift:41-45 (picker options are current workflow names), :325-329; daemon/Sources/MeetingPipe/Preferences/PreferencesView.swift:152. Stale-until-recompute nuance: LibraryListView.swift:71-73 and LibraryWindow.swift:651, 997-1009 (recount keyed on workflow ids and count, not names); inspector is computed at render so it empties at once. Contrast showing the id path was known: daemon/Sources/MeetingPipe/PrepCard.swift:159-204 (id first, name fallback), daemon/Tests/MeetingPipeTests/PrepCardTests.swift:126; pipeline/src/mp/summarize.py:284-311. Only Library test pins name resolution: daemon/Tests/MeetingPipeTests/LibraryScopeTests.swift:72. Docs treat rename as free and common: README.md:356; WorkflowsView.swift:192. Bounds on severity: NDA egress clamp reads the sidecar snapshot, not the name: MeetingMetaSidecar.swift:66, pipeline/src/mp/workflow.py:170-173; orphaned meetings remain in All meetings and filterable by old name: daemon/Sources/MeetingPipe/MeetingFilter.swift:98, 162; per-meeting reassign exists: daemon/Sources/MeetingPipe/Library/MeetingLibraryService.swift:549-594.

**Direction.** Resolve meeting-to-workflow by workflow_id with the name as fallback, and move (or id-key) the workflow's glossary table when its name changes.

### F001. Originals reaper permanently deletes the only copy of a held-back or quarantined recording

- **Severity:** high (partially confirmed; reported as critical). **Lens:** data. **Found by:** store. **Established by:** read.
- **Location:** `daemon/Sources/MeetingPipe/OriginalsReaper.swift:48`
- **Backlog:** Known, open (SEC26). SEC26 (new, P2) is this defect exactly: no reaper exemption for held or quarantined only copies, 30 day or 10 GB removeItem, surfaces say kept. Its scope is a held/ folder the reaper skips. No commits yet.

**Claim.** decideReap removes every file in originals/ older than 30 days by mtime, then oldest-first past 10 GB, on the stated premise that the redacted artifact stays in raw/. MuteRedactor.quarantine moves held-back and orphaned recordings there leaving nothing in raw/, the rename keeps mtime, removeItem is permanent, and the folder is backup-excluded.

**As corrected by verification.** OriginalsReaper has no exemption for a file that is the only copy. sweep() hands every entry of originals/ to decideReap and removeItem's anything older than 30 days by mtime (a rename keeps mtime), then oldest-first past 10 GB. Held-back recordings (any MuteRedactor .failed reason) and quarantined crash orphans land there under the same name as ordinary kept originals, with no marker. For ffmpeg_failed, timeline_unreadable, timeline_missing, move_aside_failed, promote_failed and the orphan quarantine, the file is the merged meeting and its only audio copy (intermediates are deleted after a verified merge), so the whole meeting is lost at 30 days. In the reported ffmpeg-missing-at-stop scenario the claim is overstated: the quarantined file is the mic-only final, <stem>.system.wav remains in raw/, and the orphan sweep can later rebuild a system-only <stem>.wav (the ffmpeg-absent single-source path copies it), which redactIfNeeded treats as already redacted because a differing originals/<stem>.wav exists, so it is transcribed. What is lost there is the user's entire mic channel, not the whole meeting. The failed row and the orphan notification say the recording "is kept" with no deadline; the 30-day reap is disclosed only generically (Preferences Storage row, mp doctor, GUIDE recovery-copy sentence), and the reap itself logs only a count and bytes with no notification.

**Failure scenario.** ffmpeg is missing when an off-the-record meeting stops. SinkDispatcher moves the WAV to originals/ and the row says the full recording is kept. Thirty days later a launch or after-job sweep deletes it. Nothing was transcribed, so the meeting is gone.

**Quoted code.**

```
if now.timeIntervalSince(candidate.modified) > maxAge {
                reap.append(candidate.url)
```

**Verifier (reach): partially confirmed.** Snippet exact at line 48. decideReap and sweep exempt nothing, and sweep runs at launch and after every job. quarantine is a moveItem into that same folder, used by both the held-back and orphan paths; the timeline is written only in stop(), so a quit mid-recording after an off-the-record toggle quarantines. Notices say kept, no deadline. Narrowed: redaction is off by default, and with ffmpeg missing only the mic file moves while system.wav stays in raw/. Thirty-day window after a notice, so high, not critical.

Evidence: daemon/Sources/MeetingPipe/OriginalsReaper.swift:5-6 (premise: redacted artifact stays in raw/), :22 and :26 (30 days, 10 GB), :47-53 and :57-61 (no exemption), :76-91 (candidates by contentModificationDate, every non-hidden file), :100 (removeItem, permanent). daemon/Sources/MeetingPipe/Coordinator.swift:315 (after every job), :633 (launch), :753-754 (OriginalsReaper.sweep() wired), :797-803 (orphan notice: "kept for review ... in the MeetingPipe originals folder", no deadline). daemon/Sources/MeetingPipe/MuteRedactor.swift:245-253 (quarantine = moveItem into originalsDirectory, then protectOriginalAtRest), :78-84 (0600 + isExcludedFromBackup), :191-193 (ffmpegMissing), :124, :131, :209 (other failure reasons). daemon/Sources/MeetingPipe/Coordination/SinkDispatcher.swift:448-463 (failed redaction holds the job back and quarantines), :1000 ("The full recording is kept in MeetingPipe's originals folder"), :1006-1014. daemon/Sources/MeetingPipe/OrphanRecordingRecovery.swift:199-207 and :307-316 (orphan quarantined when timeline missing and capture_first_redact or .offrecord marker), :320-331; :37-51 (a leftover .system.wav with no final is an orphan stem). daemon/Sources/MeetingPipe/MeetingRecorder.swift:1431 and :1441 (timeline written only in stop()), :1532-1597 (termination flush writes no timeline). daemon/Sources/MeetingPipe/MeetingSessionController.swift:409-421 (off-the-record writes the .offrecord marker). daemon/Sources/MeetingPipe/RecordingPostProcessor.swift:331-336 (no ffmpeg: mic renamed to final, system.wav kept in raw/), :188-212 and :371-380 (single-source recovery). daemon/Sources/MeetingPipe/Workflow.swift:97 and CaptureMode.swift:42-44 (redaction opt-in, off by default). daemon/Sources/MeetingPipe/Library/MeetingLibraryService.swift:1112-1128 (only other writer to originals/ is the delete cascade, and it uses the Trash); Preferences/StorageStatsStore.swift:57-69 (read-only stats). No restore path exists; daemon/docs/gotchas.md:255 says recovery is a manual copy-back and "a recovery UI is a separate ask". daemon/Tests/MeetingPipeTests/OriginalsReaperTests.swift:19-91 (tests pin age and size only, no sole-copy case). README.md:91 documents the 30 day / 10 GB reclaim only for the redaction recovery copy; docs/GUIDE.md never mentions originals. Scratch check (rename + chmod 600 + backup-exclude xattr keeps mtime, file older than 30 days qualifies): the session scratchpad

**Verifier (trace): partially confirmed.** Snippet exact at lines 48-49. sweep() feeds every entry of originals/ to decideReap with no marker or exemption; quarantine() is a rename writing no sidecar; no test pins an exemption; no in-app restore exists. Sole-copy recordings are therefore removed permanently. Narrowed: with ffmpeg missing at stop, only the mic-only final is quarantined; system.wav stays in raw/ and orphan recovery can rebuild a system-only meeting. Whole-meeting loss holds for ffmpeg_failed, timeline failures and crash-orphan quarantine. Requires a visible prior failure plus 30 days without manual rescue, hence high.

Evidence: daemon/Sources/MeetingPipe/OriginalsReaper.swift:5-6 (premise: redacted artifact stays in raw/), :22 and :26 (30 days, 10 GB), :47-52 (snippet), :76-92 (every non-hidden entry is a candidate, no exemption), :100 (removeItem, permanent), :107-112 (log only, no notification). daemon/Sources/MeetingPipe/MuteRedactor.swift:35-46 (failure reasons), :78-84 (backup-excluded, 0600), :146-151 (differing kept copy means "already redacted"), :191-193 (ffmpegMissing), :245-253 (quarantine: moveItem, no marker). daemon/Sources/MeetingPipe/Coordination/SinkDispatcher.swift:448-463 (failed redaction leads to quarantineHeldBack), :999-1001 (row copy: "The full recording is kept in MeetingPipe's originals folder", no deadline), :1006-1023. daemon/Sources/MeetingPipe/OrphanRecordingRecovery.swift:37-51 (lone .system.wav without a final is an orphan), :198-207, :307-316 (existing timeline means no quarantine), :320-331 (orphan quarantine). daemon/Sources/MeetingPipe/RecordingPostProcessor.swift:331-346 (ffmpeg absent: mic renamed to final, system.wav kept, returns true), :353-356 (intermediates deleted after verified merge), :372-380 and :513-517 (single-source path copies as-is without ffmpeg). daemon/Sources/MeetingPipe/Coordinator.swift:315 and :633 (after-job and launch callers), :753-754 (OriginalsReaper.sweep() on default dir), :801-803 (orphan notification, no deadline). daemon/Sources/MeetingPipe/Coordination/PipelineJobDispatcher.swift:171-184 (onDone on success only). daemon/Tests/MeetingPipeTests/OriginalsReaperTests.swift:19-97 (no test exempts a quarantined or held-back file); daemon/Tests/MeetingPipeTests/MuteRedactorTests.swift:380-402 (recovery is a by-hand copy). Disclosure: daemon/Sources/MeetingPipe/Preferences/PreferencesView+Storage.swift:207-208 ("Reaped after 30 days"), pipeline/src/mp/doctor.py:549, docs/GUIDE.md:76 and :78, ARCHITECTURE.md:585 (both kinds land in originals/), pipeline/src/mp/backup.py:114 (originals/ excluded from backup).

**Direction.** Never age- or size-reap a file that has no counterpart in raw/; mark quarantined recordings (subfolder or sidecar), exempt them, and surface them in the app with an explicit expiry if one is wanted.

### F020. Default uninstall deletes the only copies of held-back recordings and the corrections corpus, against what SETUP.md promises

- **Severity:** high (partially confirmed; reported as high). **Lens:** data. **Found by:** install-ci. **Established by:** read.
- **Location:** `scripts/uninstall.sh:93`
- **Backlog:** New. DIST5 (new) covers the opposite direction (agents and models left behind) and states the SETUP sentence is true. SEC26 (new) covers the reaper deleting held-back originals, not uninstall. Nothing names the default removal of Application Support originals and corrections.

**Claim.** Plain uninstall.sh, with no flag and no prompt, removes ~/Library/Application Support/MeetingPipe. That holds originals/ (MuteRedactor.quarantine moves held-back and orphan recordings there; storage.py:58 says never in a backup; 30-day retention) and the hand-made corrections corpus. docs/SETUP.md:217 says the uninstaller leaves recordings alone, and config, the recreatable part, is what gets kept.

**As corrected by verification.** Default uninstall.sh (no flag, no prompt) removes ~/Library/Application Support/MeetingPipe. That deletes originals/, which is the only copy of held-back and orphan-quarantined recordings (moved there, intermediates already deleted, excluded from mp backup and Time Machine) plus every kept pre-redaction original, and it deletes the summary-grading corrections corpus (grades, CorrectionWindow edits that exist nowhere else, the Revert source) and auto_consent.json. The corrections corpus is recoverable only if an mp backup archive exists. Per-line transcript corrections are NOT affected: they are <stem>.transcript_corrections.json sidecars in the library. SETUP.md:217's "leaves your recordings ... alone" is false for held-back recordings; its narrower sentence about ~/Documents/Meetings is literally true. The script header and its closing echo do disclose "Application Support data"; SETUP.md and README do not. The same rm lines run under `uninstall.sh --reset-tcc`, which README recommends as a permissions fix.

**Failure scenario.** A meeting is held back after a failed redaction, so its only audio sits in originals/. The owner runs uninstall.sh to reinstall cleanly, as SETUP.md suggests is safe. That recording, every kept full original and all transcript corrections are deleted with no confirmation.

**Quoted code.**

```
rm -rf "$DATA_DIR"
rm -rf "$LOG_DIR"
rm -rf "$APP_SUPPORT"
```

**Verifier (both): partially confirmed.** The rm lines run unconditionally, and App Support is the parent of originals/ and corrections/. A held-back recording is moved (not copied) there after its capture intermediates were deleted, and backup excludes originals, so that copy is the only one. No guard, prompt or test exists. Two overstatements: transcript corrections are library sidecars and survive (the summary-grading corpus is what dies), and that corpus is in every mp backup archive. Severity stays high: corpus loss on every default uninstall, reachable via README's --reset-tcc advice; recording loss needs a failed redaction within the 30-day reap window.

Evidence: scripts/uninstall.sh:24-45 (only --purge/--reset-tcc/--all parsed, no prompt), :52 (APP_SUPPORT), :91-95 (unconditional rm -rf; reported line 93 exact), :4-5 and :96 (header and echo disclose "Application Support data"), :5-6 (anticipates reinstall). docs/SETUP.md:211-217 ("That leaves your recordings, your settings ... alone"; "recordings in ~/Documents/Meetings/ are never touched"). README.md:745 ("keeps config + leaves TCC alone", no mention of App Support); README.md:182 and :737 (recommend uninstall.sh --reset-tcc as a permissions fix); README.md:486 and :529 (corrections corpus location, included in backup). daemon/Sources/MeetingPipe/MuteRedactor.swift:60-64 (originalsDirectory under Application Support/MeetingPipe/originals), :78-84 (0600 + excluded from backup), :245-253 (quarantine uses moveItem). daemon/Sources/MeetingPipe/Coordination/SinkDispatcher.swift:448-463 and :1006-1009 (failed redaction moves job.file to originals), :1000 (user told the recording is kept in the originals folder). daemon/Sources/MeetingPipe/OrphanRecordingRecovery.swift:320-325 (orphan quarantine, same move). daemon/Sources/MeetingPipe/RecordingPostProcessor.swift:354-355, :378-379 (mic/system intermediates deleted after a verified merge, so no second copy remains). daemon/Sources/MeetingPipe/OriginalsReaper.swift:22 (30-day retention bounds the window). pipeline/src/mp/storage.py:47-60 (app_support_dir holds corrections and originals; originals "never included in a backup"); pipeline/src/mp/backup.py:1-17, :112-116 (originals excluded), :140 (corrections root is archived, so recoverable only with a backup). daemon/Sources/MeetingPipe/Endpoints.swift:44 and CorrectionStore.swift:19-31 (corrections under App Support); daemon/Sources/MeetingPipe/SummaryStaleness.swift:35-38 (CorrectionWindow writes only corrections/<stem>.json, never summary.json); CorrectionWindow.swift:172-183. daemon/Sources/MeetingPipe/TranscriptCorrectionStore.swift:31-33 and Library/MeetingLibraryService.swift:409 (transcript corrections live in the meeting's library directory, so they survive). daemon/Sources/MeetingPipe/ConsentStore.swift:17-20 (auto_consent.json also under App Support). docs/GUIDE.md:78 (held-back recording "moved into the private recovery folder"). No test references uninstall.sh (grep of scripts/, daemon/Tests, pipeline/tests).

**Direction.** Keep originals/ and corrections/ unless --purge, print what will be deleted and confirm, and correct SETUP.md:217.

### F046. Resume-after-end records the next same-app call with no prompt and pins the previous workflow over its rule match

- **Severity:** high (partially confirmed; reported as medium). **Lens:** data. **Found by:** spine. **Established by:** read.
- **Location:** `daemon/Sources/MeetingPipe/MeetingSessionController.swift:1112`
- **Backlog:** New. ADR 0017 and END17 (partial) accept the promptless resume inside 120 s, and ResumeAfterEnd says 'same workflow', but nothing weighs the pin outranking the new meeting's rule match or an NDA downgrade guard. SEC21 (new) is a different fail-open path.

**Claim.** Within 120 s of a lifecycle end, the next .starting from the same app records with no prompt, clearing skip latch and cooldown even when the app is not auto-consented, and pins the previous recording's workflow as an explicit override that outranks the new meeting's own rule match. ResumeAfterEnd documents the recording, not the routing.

**As corrected by verification.** Recording the next same-app call without a prompt inside 120 s is documented, accepted design (ADR 0017 line 68, README line 90, ResumeAfterEnd doc). The unweighed defect is that the resume pins the previous recording's workflow as an explicit override, which outranks the new meeting's own rule match, with no guard against an NDA downgrade. A meeting whose title rule maps to an NDA or local-only workflow is then captured and routed under the previous cloud or publishing workflow; the HUD workflow chip is the only cue.

**Failure scenario.** A client call recorded under a Notion-publishing workflow ends at 10:30. At 10:31 a private 1:1 starts in the same app: it is recorded without a prompt and routed through the client workflow, even if a title rule maps it to an NDA workflow.

**Quoted code.**

```
if let candidate = resumeCandidate, candidate.applies(to: source.bundleID, at: Date()) {
            resumeCandidate = nil
            micTierPromptBundle = nil
            coordinator.stateMachine.clearSuppression(bundleID: source.bundleID)
            pendingWorkflowOverride = candidate.workflowID
            pendingResumedFrom = candidate.stem
```

**Verifier (batch): partially confirmed.** Mechanism holds, and every sourced lifecycle end arms it, definitive ends included. Not as stated: the no-prompt recording of a genuine back-to-back call is an accepted negative in ADR 0017 and README, and ResumeAfterEnd does document same workflow and summary mode. What nobody weighed is the pin as an explicit override, which outranks the new meeting's rule match with no NDA floor; the AI9 hint refuses exactly that downgrade. I judge the NDA-rule bypass to be egress-class, conditional on a title-bearing NDA rule, hence high rather than critical. Back-to-back same-app calls are ordinary.

Evidence: daemon/Sources/MeetingPipe/MeetingSessionController.swift:515-536,1109-1126,1244-1252,1528-1531; daemon/Sources/MeetingPipe/ResumeAfterEnd.swift:12-17,29,34-37; daemon/Sources/MeetingPipe/WorkflowMatcher.swift:3,14-17; daemon/Sources/MeetingPipe/WorkflowRoutingHint.swift:145-151; daemon/Sources/MeetingPipe/MeetingMetaSidecar.swift:67; docs/decisions/0017-hold-long-trim-later-end-detection.md:60,68; README.md:90; daemon/Tests/MeetingPipeTests/HeldEndSessionTests.swift:120-147

**Direction.** On resume, re-run the matcher and fall back to the previous workflow only when no rule matches; never resume into a weaker privacy posture than the rules give, and consider a visible resume notice with undo.

## Medium findings

Grouped by backlog status, then by lens. Each was verified in a batch by one independent agent; the verdict and reasoning are kept in the run journal and summarised here by outcome.

### Claimed fixed, not holding (17)

**F083. train-adapter trains on a request shape the server never sends, and its default budget drops every pair**

`pipeline/src/mp/train_adapter.py:214`. Lens: antipattern. Outcome: confirmed. Backlog: Claimed fixed, not holding (LOCAL9, LOCAL17). LOCAL9 (done, 39d0357c) claimed the train/inference prompt mismatch fixed by building pairs from the shipping helpers, 'exactly as served'. Pairs still differ and the 4096 default drops every pair. LOCAL17 (deferred) retrains at 8192 without owning this.

Training pairs differ from the served request despite the docstrings: the transcript is the stored `<stem>.md` without `[mm:ss]` markers, the system turn lacks the language reinforcement, and the completion is the stored shape, not the `{text, evidence}` objects the prompt's schema demands. Executed: the system turn alone (15,857 chars) exceeds the default 10,240-char budget.

*Scenario:* `mp train-adapter` with defaults drops every pair and exits 2. With a larger `--max-seq-length` it trains an adapter to emit plain-string sections and timestamps it cannot see, and writes full transcripts to `<adapter>/data/*.jsonl` with default (world-readable) permissions.

*Direction:* Build pairs through the same transcript render and message builder `summarize` uses, emit completions in the model-facing shape, size the default budget from the real prompt, and write the dataset 0600 via the storage helper.

**G026. Regulated-gate held-tail cut is skipped for single-source recordings while the event says truncated**

`daemon/Sources/MeetingPipe/RecordingPostProcessor.swift:371`. Lens: data. Outcome: confirmed. Backlog: Claimed fixed, not holding (END9, END17). END9 (86269d3a) shipped trim-on-confirm so a held tail is discarded; END17 (01e904a5) and ADR 0017 say regulated and NDA cut the tail at stop. Both tasks are partial for unrelated remainders; neither mentions the single-source convert path.

Absent test, real gap. produceFinal uses limitSeconds only inside `if hasMic && hasSystem`. With one capture side (Screen Recording denied, or a system file under 4 KB) this convert has no duration cap, so the held tail stays at rest while MeetingSessionController logs held_end_trimmed with mode truncated. CallTeardownHoldTests covers applyTrim arithmetic only.

*Scenario:* NDA workflow, Screen Recording not granted. The user leaves a browser call and keeps talking in the room; the weak end holds 12 minutes until the lone dwell. The final WAV keeps all 12 minutes of post-call room audio the regulated posture says must not exist.

*Direction:* Pass the limit into convertToTempViaFFmpeg as a duration cap and assert the produced file's length for both merge paths.

**G027. AX mute producers dedupe before the fusion accepts; the fusion test re-injects by hand**

`daemon/Tests/MeetingPipeCoreTests/MuteSourceFusionTests.swift:109`. Lens: data. Outcome: confirmed. Backlog: Claimed fixed, not holding (MIC8). MIC8 (done, db9725db) claims the AX read carries whenever the log has been quiet for 5 s. A reading refused while the log is fresh is never re-sent; the pinning test injects it by hand.

Fake fidelity. AXMuteButtonProbe sets lastEvent (line 358) and MeetingAXWindowWatcher sets lastEmitted (line 342) before calling the sink, so a reading MuteSourceFusion refuses while the log is fresh is never re-sent. This test shows AX carrying only because it injects a second event by hand. No test wires a real producer into MicGate.

*Scenario:* The log says unmute. Three seconds later the user re-mutes and the log misses the line (the measured gap fusion exists for). The AX muted reading is refused, both producers remember it as delivered, and the gate stays confidently unmuted for the whole muted stretch.

*Direction:* Record a reading as delivered only when MicGate accepts it, or have MicGate keep the last refused AX reading and apply it when the log window lapses.

**F099. merge-meetings records the merge before the audio swap, so a failure in between is resumed as if complete**

`pipeline/src/mp/merge_meetings.py:228`. Lens: data. Outcome: partially confirmed. Backlog: Claimed fixed, not holding (PIPE8, dcbf94cd). PIPE8 (done, dcbf94cd) moved the merged_from commit before the audio swap and called the residual safe: retry republishes the correct transcript, fragments stay recoverable. Resume branch never finishes the swap, exits 0, and the daemon trashes fragments.

If the run fails after the merged JSON carrying merged_from is committed (line 228) but before the markdown write (229) or the audio swap (230) completes, the retry takes the resume branch, never finishes the swap or re-renders the markdown, exits 0, and the daemon then trashes the fragments, leaving part-one audio (and possibly a part-one .md) under a merged JSON plus an orphaned .merging.tmp. A plain disk-full usually fails the JSON write first, which is harmless, so the window is two statements wide rather than a generic out-of-space condition. No free-space preflight exists on either side.

*Scenario:* Disk fills just after the multi-GB temp is written, so the markdown write raises. The retry takes the resume branch and exits 0; the daemon trashes the fragments. The meeting now has a merged JSON but part-one audio and a part-one markdown transcript published to the sinks.

*Direction:* On the resume branch finish the swap when `.merging.tmp` exists and re-render the markdown; unlink the temp on any failure and preflight free space.

**F107. All four publishers send the raw `<stem>.md`, ignoring the Library's speaker and text-correction overlays**

`pipeline/src/mp/publish_notion.py:545`. Lens: data. Outcome: confirmed. Backlog: Claimed fixed, not holding (FEAT3-SEGMENT, PIPE9). FEAT3-SEGMENT (d9983d9c) closed its 'a subsequent republish reflects it' acceptance and PIPE9 (712b63af) claimed corrections reach the pipeline, but both wired overlaid_markdown into summarize and embed_index only. No open task covers the four publishers.

Speaker names and transcript edits made in the app live only in Swift-written overlays (`speaker_labels.json`, `transcript_corrections.json`; enroll runs with `--no-relabel`, and no Swift code rewrites `<stem>.md`). `summarize`, `embed_index` and MCP apply them through `overlaid_markdown`, but Notion, Obsidian, filesystem and LAN read `transcript_md.read_text()` directly.

*Scenario:* User corrects a mis-transcribed sentence and names THEM-A 'Anna' in the Transcript tab, then Republish. The Notion transcript toggle and the filesystem copy still show the original wording and 'THEM-A', while the regenerated summary says Anna.

*Direction:* Have `fanout` pass publishers `transcript_corrections.overlaid_markdown(transcript_md)` when it returns text, and pin it in the overlay golden fixtures.

**F045. The in-flight start is a private Bool, not a state: ends and stops during bring-up are dropped for idle-origin starts**

`daemon/Sources/MeetingPipe/MeetingSessionController.swift:1269`. Lens: quality. Outcome: confirmed. Backlog: Claimed fixed, not holding (REC7, 3aacb666). REC7 (done, 3aacb666) claimed any confirmed end during the async start is latched and stops the fresh recording. The latch sits only under .prompting/.suppressed, so idle-origin starts still drop it. The forceStop half was never claimed and has no task.

An in-flight start is a private Bool, not a state. Starts from idle (auto-consent, resume, start-late, hotkey) leave current == .idle for the whole bring-up (engine budget 8 s). There a lifecycle .ended falls to `default: break` and forceStop is a no-op; from .prompting, forceStop abandons the prompt but the Task still commits .recording.

*Scenario:* Auto-consented Teams call on a slow Bluetooth input: during the engine start the user presses force-stop, or the call ends. Nothing is latched. Seconds later the HUD appears and the recording runs against the user's stop, or against a dead meeting until the idle backstop.

*Direction:* Add a .starting AppState, or check one cancel/end latch for every origin right before setRecording (line 591), and have forceStop and toggleManual set it. forceStop's no-op is line 367; auto-consent starts from idle at line 1160.

**G015. Rename everywhere leaves the person's open actions behind**

`daemon/Sources/MeetingPipe/PeopleRail.swift:110`. Lens: quality. Outcome: confirmed. Backlog: Claimed fixed, not holding (DV3). DV3 (done, a106f41f) claimed a roster rename reflects everywhere and added RosterRename.carry so a rename would not empty the person's rail history. The carry never reaches summary.json owners. UX41 accepted stale names only inside summaries, with a re-summarize cue.

Ownership compares the roster name with the raw `owner` string from each summary.json (Facts.swift:204, passed through LibraryProjections unchanged). `RosterRename.carry` rewrites only speaker-label overlays, which owners never pass through, so after a rename nothing matches. PeopleView's header says the rename makes this rail read the same name.

*Scenario:* Rana owns six open actions. The owner renames her to 'Rana Kapoor' from the People rail. Her row keeps its attended meetings but shows no open actions, and meetings she appears in only as an action owner drop out, until each summary is regenerated.

*Direction:* Resolve action owners through the same overlay or an alias list kept on the roster entry, so a renamed person still matches the names old summaries carry.

**F062. Index-keyed transcript overlays are applied with no drift check and are not carried when a re-transcribe fails**

`daemon/Sources/MeetingPipe/TranscriptCorrectionStore.swift:115`. Lens: quality. Outcome: confirmed. Backlog: Claimed fixed, not holding (ASR3, 1c26afe2). ASR3 (done) claimed TranscriptOverlayCarry stops index-keyed overlays landing on the wrong sentence after a re-transcribe. UX52 knew a failed finalize leaves the transcript rewritten yet no carry runs. The apply-time original_text check is unfiled.

apply (and Python's apply_corrections) replace text purely by segment index and never compare original_text. The overlay carry runs only on a successful re-transcribe; the failure branch, where invokeFinalize states the runner already replaced the transcript, does none, and the carry uses overlays read at request time, not at completion.

*Scenario:* The owner corrected lines 12 and 30, then re-transcribes. The runner rewrites the transcript and mp finalize fails. Lines 12 and 30 of the new segmentation now display the old corrections, and a later regenerate summarizes and publishes them.

*Direction:* Skip and report a correction whose original_text no longer matches its segment, run the carry on every path that rewrites <stem>.json, and re-read the overlays when the job completes.

**F069. A meeting without audio inherits the previous meeting's loaded recording**

`daemon/Sources/MeetingPipe/TranscriptTab.swift:376`. Lens: quality. Outcome: confirmed. Backlog: Claimed fixed, not holding (UX78, 7a063e01). UX78 (partial, only the owner walkthrough left) claimed in 7a063e01 that the loaded-URL check means the transport can never drive the wrong meeting. Only the header transport checks it; nothing unloads for a meeting with no audio.

Both audio tabs call playback.load only when meeting.audioURL is non-nil (AudioTab.swift:60 too), and AudioPlaybackController has no unload. On a switch MeetingDetailView only pauses. For a meeting whose recording retention dropped, the transport bar, row click-to-seek and AudioTab's footer still drive the previous meeting's file; only the header transport compares loadedURL.

*Scenario:* Play meeting A on the Transcript tab, then select meeting B whose audio was dropped. B's bar shows A's duration; clicking a line in B plays A's recording from that offset and the highlight follows A's clock over B's rows.

*Direction:* Add an unload to AudioPlaybackController, call it when audioURL is nil, and disable transport and click-to-seek unless loadedURL equals this meeting's audio.

**G035. Tutorial step 3 points at a control that is not rendered on an empty Library or on four rails**

`daemon/Sources/MeetingPipe/Tutorial/TutorialAnchor.swift:65`. Lens: quality. Outcome: confirmed. Backlog: Claimed fixed, not holding (FEAT15). FEAT15 (owner-verify, b122e001) states anchors point only at unconditionally rendered controls and that seven steps each ring a real control; .search breaks that rule. The step 6 below-the-fold part is FEAT15's accepted scroll-position fragility.

Step 3 (.search) is unrendered on an empty or still-loading Library and on five rails (Facts, People, Meeting time, Ask, Digests), so the tour shows the 'Not on screen right now' card there. Step 6 (Speaker labels, after six groups in a 660 pt pane, no scroll-to) being below the fold is plausible but not verifiable without rendering.

*Scenario:* A new user with no meetings yet, or one who last left the Library on Ask, picks Tutorial…: step 3 dims the window and says 'Not on screen right now, so there is nothing to point at.' No source fence can see it.

*Direction:* Have presentTutorialSurface select the All meetings scope and scroll the step's anchor into view, and give the empty Library a fallback for the search step.

**F031. Pair dwell accepts an ended stamp of any age and ignores a live sibling in the same class**

`daemon/Sources/MeetingPipeCore/Lifecycle/PromotionEngine.swift:285`. Lens: quality. Outcome: confirmed. Backlog: Claimed fixed, not holding (END17, 01e904a5). END17 (partial, verification only; commit 01e904a5) and ADR 0017 claim a hold confirms only when two evidence classes both stayed ended 60 s, so no weak signal ends a call alone. The stale-stamp and live-sibling gaps are unfiled.

A class counts as ended if any member is ended, even while its sibling reads `.live`, and the stamp may be arbitrarily old: a window-gone absorbed by the veto an hour earlier, or a process-audio `false` that was the signal's first reading. 'Two classes held 60 s' then reduces to one fresh signal held 60 s.

*Scenario:* Teams call whose window title never matched (remembered ended since minute 1, absorbed by the veto). At minute 40 the headset drops and Teams releases the mic for 61 seconds. Process audio leads a hold, the stale stamp pairs, the recording ends with Leave healthy.

*Direction:* Count a class only if its ended edge falls inside the current hold window and no member of that class reads `.live`.

**F002. END8 rescue is a no-op when the Leave button is already armed and healthy, so a window-gone hold runs to the lone dwell**

`daemon/Sources/MeetingPipeCore/Lifecycle/Signals/AXLeaveButtonSignal.swift:232`. Lens: quality. Outcome: partially confirmed. Backlog: Claimed fixed, not holding (END8, 11bac7b4). END8 (done) claimed an off-screen call window no longer chops because the rescue's healthy Leave button reverts the hold. END14 (partial) recorded that the re-arm emits nothing and only added a process-audio veto; ADR 0017 still lists the revert.

When a window-gone hold opens while the Leave button is already armed and probes healthy, rescueProvisionalEnd's armLeaveButton is a silent no-op (no .live reaches the engine), so the END8 same-class revert that PromotionEngine.swift:463-464 and MeetingSessionController.swift:1794 still promise never fires. On an adapter with no live process-audio reading (Webex and Slack by config; Teams or Zoom only while the signal is unresolved, since an unresolved read emits nothing) the hold then confirms on the 720 s lone dwell unless a matching window comes back on-screen or the Leave element flickers. The trigger is narrower than stated: every window of the bundle whose title matches must be off-screen for 12 continuous minutes (title tokens are brand-wide for Teams, Zoom and Webex, call-specific only for Slack), and the premise that minimising or another Space trips the signal is asserted by the repo (PromotionEngineTests.swift:435, NativeLifecycleAdapter.swift:171-173 for Teams) but unmeasured for Webex and Slack. The consequence is also narrower: the recording is stopped, but under any non-regulated capture mode the held 12 minutes stay in the WAV and are only left out of the transcript (restorable); the audio is cut at stop only under regulatedGate. Whether the rest of the live call is then recorded is not established: discovery re-sights through AX and a 120 s resume window exists, but a re-engage with the window still off-screen can end directly in .starting.

*Scenario:* Webex or Slack call (no process-audio signal), or Teams/Zoom with it unresolved. The user minimizes the call window or works in another Space for 12 minutes. Window-gone opens a hold, the rescue finds Leave and changes nothing, and the live recording is stopped and its last 12 minutes trimmed.

*Direction:* On a rescue that finds a healthy armed button, re-emit the healthy baseline, or make `tick` refuse the lone dwell while a same-class signal reads `.live`. PromotionEngineTests:434 injects the `.live` by hand and AXLeaveButtonSignalTests:164 pins the no-op; nothing tests the two together.

**F036. A suppressed AX mute reading is lost for good; the documented 5 s correction bound does not exist**

`daemon/Sources/MeetingPipeCore/MicGate/MicGate.swift:200`. Lens: quality. Outcome: partially confirmed. Backlog: Claimed fixed, not holding (MIC8, db9725db). MIC8 (done, commit db9725db) claimed the 5 s log freshness window bounds an uncorrectable log miss to five seconds, with AX carrying afterwards. No task, audit or ADR records that a suppressed AX reading is never re-delivered.

A suppressed AX reading is not re-delivered when the 5 s freshness window expires, because both AX producers record it as delivered before calling the sink and dedupe on that. The 5 s correction bound documented in MuteSourceFusion is therefore not implemented. It is not lost for good: besides the next real toggle, the window watcher clears lastEmitted after a 4 s muted-plus-voice contradiction and after three blind polls, and then re-emits the current state. Recovery is incidental and unbounded in time, and the fault needs a missing SlimCore line (Teams only).

*Scenario:* Teams: user unmutes, answers, re-mutes 3 s later, and the SlimCore line for the re-mute is missing (the gap fusion exists to cover). AX 'muted' lands inside the 5 s window, is suppressed and never repeated. The gate stays confidently unmuted while the user is muted.

*Direction:* Keep the last suppressed AX reading inside MicGate and apply it when the log freshness window lapses without a newer log reading, or return the accept result so producers do not record it as delivered.

**G006. END8 rescue is tested with a Leave-button event production does not emit**

`daemon/Tests/MeetingPipeCoreTests/PromotionEngineTests.swift:441`. Lens: quality. Outcome: confirmed. Backlog: Claimed fixed, not holding (END8). END8 (done, 11bac7b4) claims the AX rescue's healthy Leave reverts a window-gone provisional. END14 (partial) already records that no event is emitted and vetoes via process audio instead; END8's test and apps without process audio stay unaddressed.

Fake fidelity. With the Leave signal already armed and healthy, the host rescue's armLeaveButton is a no-op (AXLeaveButtonSignal._armIfNeeded returns early; AXLeaveButtonSignalTests:182 pins no re-emit), so this `.live` never arrives, and tick ignores a live same-class reading already in `states`. No test drives rescueProvisionalEnd or composes signal, adapter and engine.

*Scenario:* Webex or Slack call (no process-audio veto), Leave button healthy. The user minimises the call window or works on another Space for 12 minutes. Window-gone leads, nothing reverts, the lone dwell ends the recording and those 12 minutes are cut as post-call tail.

*Direction:* Make tick treat a live same-class sibling as contradicting the lead (or re-emit the healthy baseline on rescue) and add an adapter-level test that composes the real signal with the engine.

**G024. Pair corroboration counts a class as ended while its sibling reads live; the test pins a remembered window-gone as the second class**

`daemon/Tests/MeetingPipeCoreTests/PromotionEngineTests.swift:581`. Lens: quality. Outcome: confirmed. Backlog: Claimed fixed, not holding (END14). END14 (8d4a9449, gotchas.md) says a vetoed window-gone older than the debounce deliberately does not corroborate a mic release. END17's tick (01e904a5) pairs it after 60 s, and this test pins that. The live-sibling check is unfiled.

Pins a vetoed window-gone from 599 s earlier as the independent second class: the assertion at 600 + dwell only holds because of that stamp. tick takes the oldest ended stamp per class and never checks a live sibling. The live-sibling case is absent, and line 509 pins two reads of one window title as separate classes.

*Scenario:* Teams window minimised at minute 2 (vetoed, remembered). At minute 22 process audio reads false for 60 s (stale object ID, slow device switch). The Leave button is healthy throughout. tick confirms a pair and the recording ends, confirmed_by shareable_content_window_gone.

*Direction:* Count an evidence class as ended only when none of its kinds reads live, and add that case plus the PWA title pair to the engine tests.

**G025. Native app quit is asserted on a signal native sessions never receive; the live-mic veto has no freshness**

`daemon/Tests/MeetingPipeCoreTests/PromotionEngineTests.swift:672`. Lens: quality. Outcome: partially confirmed. Backlog: Claimed fixed, not holding (END17, END14). END17 (01e904a5) and ADR 0017 say an app quit ends at once, yet only the browser adapter builds a WorkspaceSignal. END14 (8d4a9449) called a stale live reading bounded, citing a ceiling END17 retired and a backstop that stands down.

The structural claims hold: no native adapter constructs a WorkspaceSignal, so a workspaceAppTerminated event alongside a live process-audio reading cannot occur in production (browsers never emit process audio), and the live-mic veto in tick has no freshness bound. The force-quit outcome is consistent with the code but rests on unmeasured HAL teardown ordering (a readable false before the objects vanish lifts the veto) and on Zoom's process audio resolving at all, which is unmeasured. Where the stuck reading does occur and no hold opens, SilenceAutoStopPolicy also stands the idle backstop down for a native meeting still reading in_meeting, so the idle-backstop bound the finding cites is not guaranteed.

*Scenario:* Zoom is force-quit mid-call while its mic object read true. The objects vanish, the probe returns nil, the engine keeps `.live`: window-gone is absorbed and no dwell confirms. Recording runs until manual Stop or the idle backstop. The dead-object read is inferred, not run.

*Direction:* Give NativeLifecycleAdapter a WorkspaceSignal and let the veto lapse when the process-audio reading becomes unreadable.

**F109. Backup and restore print their failure reason to stdout; the daemon reads only stderr**

`pipeline/src/mp/backup.py:503`. Lens: quality. Outcome: confirmed. Backlog: Claimed fixed, not holding (STOR3). STOR3 (done) claimed any Back up now failure shows inline via runMP's stderr tail, but mp prints the reason to stdout, so the notice has no cause. STOR10 (new) covers scheduled runs only; restore shares the gap.

`mp backup` and `mp restore` report `BackupError` / `RestoreError` with a bare `print` (stdout), exit 1 and write no failure metadata. `runMP` keeps only the stderr tail, so `PipelineLauncher.diagnostics(for:)` is an empty string and the Storage pane shows a generic title with no cause.

*Scenario:* The backup drive is unplugged. Python raises '... is not mounted ... Plug the drive in' and prints it to stdout. Preferences shows 'Couldn't finish the file operation' with nothing else; the actionable text exists only in pipeline.log.

*Direction:* Print `[FAIL]` lines to `sys.stderr` (or call `emit_failure(..., operation="storage")`) in `backup.main` and `restore.main`.

### New (62)

**F023. Regenerate and Retry always fail for Apple Intelligence meetings: Swift routes them to the Python summarizer, which refuses that backend**

`daemon/Sources/MeetingPipe/PipelineLauncher.swift:1173`. Lens: architecture. Outcome: confirmed. Backlog: New. Same defect as F022, unfiled. UX80 (done) added the summary-scope Retry that reaches regenerateMeeting; PIPE6 (done) only kept Apple out of the Re-summarize menu because Python cannot run it. Neither claims the nil-backend path works.

For a non-NDA, non-regulated meeting whose resolved backend is apple_intelligence (global or workflow pin, both non-default), every nil-backend re-summarize (row "Regenerate summary", Retry/Reprocess on a failed row with a reusable transcript, batch "Re-summarize all", the reassign follow-up, restoreHeldTail) spawns `mp summarize`, which exits 1 with the "runs in the daemon (Swift)" ValueError. The failed attempt also writes a pipeline failure sidecar, so a previously healthy meeting shows as failed and its Retry loops into the same error. Not strictly "never": explicit "Re-summarize with" local/Anthropic works, and the Summary tab's candidate preview plus Keep does run Apple Intelligence when the global backend is apple_intelligence and a summary already exists (no path exists for a failed meeting with no summary, or for a workflow-only Apple pin).

*Scenario:* Global or workflow backend apple_intelligence, non-NDA meeting. User clicks Regenerate, or Retry after a failed Apple summary: `mp summarize <md>` exits 1 with 'runs in the daemon (Swift)'. The meeting can never be re-summarized on its own backend.

*Direction:* Resolve the effective backend once in Swift for nil-backend regenerates and dispatch Apple meetings to AppleIntelligenceSummarizer, or make `mp summarize` write the apple_pending handoff the way run-all does.

**F151. coverage.sh daemon leg reports one arbitrary test bundle: printed 90.0%, real figure 51.0%**

`scripts/coverage.sh:63`. Lens: build. Outcome: confirmed. Backlog: New. No task, audit or ADR mentions the bundle selection. T3 (f78ca057) built the harness and CI6 (94899fc0) fixed only its exit-1 headline bug, recording a whole-daemon 37.3% figure; neither covers picking the first xctest binary.

The daemon leg hands llvm-cov the first xctest binary find returns. This toolchain builds two bundles (MeetingPipeTests, MeetingPipeCoreTests) and a stale October binary also matches. The run printed LINE COVERAGE 4349/4834 = 90.0% with a 40-file Core-only table, exactly what MeetingPipeCoreTests alone yields; MeetingPipeTests yields 34024/66762 = 51.0% over 318 files.

*Scenario:* Owner runs scripts/coverage.sh swift and reads 90.0% as daemon coverage while the 277-file executable target is at 47.9% (MeetingRecorder.swift 17.3%, Coordinator.swift 0.3%). A later identical find returned the stale binary first, for which llvm-cov reports no coverage data.

*Direction:* Pass every fresh .xctest binary under the active products dir (first as positional, rest via -object) and ignore the old arm64-apple-macosx tree.

**F041. README says muted spans are redacted by default; the default capture mode never redacts**

`README.md:91`. Lens: data. Outcome: confirmed. Backlog: New. No task covers README:91. The behaviour is deliberate: ADR 0016's 2026-06-08 amendment (TECH-MIC9, dcdaf3da) made redaction opt-in, but that commit never touched README and the DOC7/DOC9 sweeps did not list it. Doc fix only.

README states muted spans are redacted by default. The code default is CaptureMode.captureFirst, which writes no mute timeline and never redacts; redaction needs the per-workflow redact_muted_spans flag, default false (CaptureMode.swift:44, WorkflowStore.swift:313). In the default mode MicGate's mute verdict changes nothing in the consumed artifact.

*Scenario:* A user trusts the README, mutes in Zoom for a private aside and assumes it is cut. Under the default workflow the aside is transcribed, summarized by the configured backend and published to the configured sink.

*Direction:* Correct README line 91 to say redaction is opt-in per workflow, matching the Workflows pane copy and ARCHITECTURE.md.

**F060. Retention sweep treats any summarized meeting as done, ignoring the failure sidecar the Library honours**

`daemon/Sources/MeetingPipe/AudioRetentionSweep.swift:133`. Lens: data. Outcome: confirmed. Backlog: New. No task names AudioRetentionSweep.candidates hardcoding .done. ARCH20 and UX90 (both new) cover the duplicated status ladder in the badge and LibraryMover but omit this third copy; PIPE34 changes isSettled for a different cause.

Candidate.status is documented as derived exactly as the Library derives it, but candidates() hardcodes .done whenever summary.json exists. buildMeeting lets error.json win for a publish-stage failure or a newer structured one (a failed regenerate always writes metadata), so a row the Library lists as failed is still settled here and its audio is removed.

*Scenario:* Workflow drops audio after 30 days. On day 20 a re-summarize fails, so the fully published meeting sits in Needs you as failed. On day 31 the sweep deletes its audio, although the documented rule exempts every Needs you row; re-transcribing it is no longer possible.

*Direction:* Derive the candidate status through the same decision buildMeeting uses, or at minimum skip any stem that has an error sidecar.

**F008. Move to Trash has no guard for the meeting being recorded**

`daemon/Sources/MeetingPipe/BatchActionsPane.swift:624`. Lens: data. Outcome: confirmed. Backlog: New. No task covers it. STOR7 (new) is about the delete footprint, honest counts and off-main batching; REC23 (done) excludes recorder-owned stems from the reaper, orphan scan and retention sweep only. Neither guards a user trash of the live stem.

No trash path checks the live recording. softDeleteMeeting trashes every file whose first-dot stem matches, including the open <stem>.mic.wav and <stem>.system.wav. The row menu gates only on pipeline-busy (MeetingRow.swift:475); header Delete (MeetingDetailView+Header.swift:895) and the batch pane gate on nothing. At stop, mergeIntermediates tests the original paths and produces no final.

*Scenario:* While recording, multi-select today's rows (the live row is listed) and confirm 'Move N meetings to Trash?'. The HUD keeps recording into files now in the Trash; at stop neither intermediate is found and the meeting never reaches the pipeline.

*Direction:* Refuse or exclude stems in MeetingRecorder.ownedStems (and stems with an active or queued job) inside softDeleteMeeting, and name the skipped rows in the confirmation.

**G009. A redaction that lands after the PIPE36 deadline makes the Retry hold the meeting back and overwrite the kept original**

`daemon/Sources/MeetingPipe/Coordination/SinkDispatcher.swift:488`. Lens: data. Outcome: confirmed. Backlog: New. Introduced by PIPE36 (done, 4949c9c0), whose comment asserts the retry's redactor is idempotent; its spec and tests cover a redactor that never returns, not one landing late. SEC26 (new) covers held-back copies in originals, not this overwrite.

The comment is false. `redactIfNeeded` checks the timeline before its idempotency check, and a redaction that lands after the deadline reaps the timeline while `.offrecord` stays. Retry therefore returns `.failed(.timelineMissing)`, and `quarantineHeldBack` deletes the kept original at the same originals path and moves the redacted WAV over it.

*Scenario:* A meeting with a manual off-the-record span, library on a slow volume: the unbounded redaction ffmpeg outlasts the job deadline, then finishes. The owner presses Retry as the row suggests. The meeting is held back for good and the only full recording is replaced by the redacted copy.

*Direction:* Stop the redaction on a redact-phase expiry, or run the kept-original idempotency check before the missing-timeline check and never quarantine over an existing kept original.

**F135. In-app restore leaves app-lifetime stores stale; the next workflow save reverts the restored files**

`daemon/Sources/MeetingPipe/Coordinator.swift:599`. Lens: data. Outcome: confirmed. Backlog: New. No task, audit or ADR covers stale app-lifetime stores after an in-app restore. STOR5 (owner-verify) shipped the restore and never claimed to reload WorkflowStore, SavedSearchStore or WorkflowCorrectionStore; its walkthrough only warns that a restore replaces workflows.

After an in-app `mp restore --force` the only follow-up is a failed-count refresh. `WorkflowStore` (loaded once at launch) keeps pre-restore workflows, and `persistAll()` rewrites every in-memory workflow file on the next upsert or reorder. `SavedSearchStore` and `WorkflowCorrectionStore` persist whole snapshots the same way.

*Scenario:* Owner restores a backup; the confirm says workflows are replaced by the backup's copies. Before relaunching they edit or reorder any workflow: every restored `<id>.toml` is overwritten with the stale in-memory version, with no message.

*Direction:* Reload WorkflowStore, saved searches and workflow corrections in onLibraryRestored, or force a relaunch after a restore lands.

**G011. Re-transcribe snapshots the overlays at request time and writes them back minutes later**

`daemon/Sources/MeetingPipe/Library/MeetingLibraryService.swift:407`. Lens: data. Outcome: confirmed. Backlog: New. ASR3 (done, 1c26afe2) shipped re-transcribe with TranscriptOverlayCarry and covers time re-anchoring only. No task, audit or ADR mentions the request-time overlay snapshot or edits made while the job is queued. STOR9 covers unreadable overlays, a different defect.

These snapshots are carried and written back with `replace` (lines 495-499) when the queued job ends, with no re-read. The transcript tab is not gated meanwhile, and Clarify's rule path starts the job and closes its sheet. Edits made in between are overwritten, or, when nothing is replaced, stay keyed to the old indices.

*Scenario:* Owner adds a term with 'Re-transcribe this meeting afterwards', then keeps fixing lines while it runs. On completion an older fix is retired, so the corrections file is replaced from the snapshot. The fixes typed during the run are gone and the alert does not mention them.

*Direction:* Re-read both sidecars at completion and carry those (or block overlay edits for a stem while its re-transcribe is queued), and keep the pre-carry sidecars as a backup.

**F057. Library move in-flight guard can miss live work and is never re-checked at execute**

`daemon/Sources/MeetingPipe/LibraryMover.swift:58`. Lens: data. Outcome: confirmed. Backlog: New. No task describes the first-.mic.wav masking, the missing re-check in execute, or the start-anchored two-hour window. ARCH20 item 4 only swaps inFlightReason's suffix chain for MeetingStatus.decide; PERF13 item 8 only moved plan off main.

inFlightReason hands the whole listing to freshCaptureIntermediate, which tests only the first .mic.wav found, so a stale orphan can mask a live capture (ordering inferred). The guard runs in plan() only; execute() runs after the confirm dialog unchecked. The processing test counts two hours from recording start, not from stop.

*Scenario:* A detected meeting starts while the Move confirmation is open, or a 2.5 hour meeting has just stopped and is mid-pipeline. Confirm renames or copies raw/ under the recorder or the mp child; the stop-time merge and sidecar writes then target paths that no longer exist.

*Direction:* Ask MeetingRecorder.ownedStems and the job queue instead of the filesystem (the REC23 rule), filter fresh intermediates per stem, and re-run the guard inside execute().

**G008. Workflow and NDA rail scopes resolve by current workflow name, so a rename empties them**

`daemon/Sources/MeetingPipe/LibraryScope.swift:156`. Lens: data. Outcome: confirmed. Backlog: New. Same root as G004. UX30, UX33 and WF9 (done) keep name-based scope resolution on purpose and document the delete and duplicate-name effects, never a rename; LibraryScope's comment claims the opposite. The NDA scope and cache keys are unmentioned anywhere.

Both .workflow(id) and .ndaOnly resolve a meeting through this lookup of its sidecar workflow_name in the live workflow table, although Meeting carries workflowID and the persisted workflowNDAMode. MeetingMetaSidecar.build and .reassigned are the only writers of workflow_name, so a rename is never cascaded. CountsKey and DerivedKey ignore names and NDA flags.

*Scenario:* Rename workflow 'Client A' to 'Acme'. Existing sidecars still say 'Client A', so the Acme rail scope and count fall to zero, those meetings are not Untagged either, and its NDA meetings leave 'NDA only' while their rows still show the lock and 'Kept local'.

*Direction:* Match on meeting.workflowID with a name fallback (as PrepCardStore.matches does), read NDA membership from meeting.isZeroEgress, and key counts and the derived list on workflow names and flags.

**F067. Single-meeting Reprocess and Re-summarize rewrite the summary and republish straight off the click**

`daemon/Sources/MeetingPipe/MeetingDetailView+Header.swift:417`. Lens: data. Outcome: confirmed. Backlog: New. UX61 (done, 7f582033) gated only batch Merge and Re-summarize all, on the rule that hand edits and done ticks are destroyed. Its spec is silent on detail-menu Reprocess, Re-summarize with and row Regenerate; no task covers the single-meeting form.

The header's Reprocess item (labelled with an ellipsis, opens no dialog), the 'Re-summarize with' items and the row's 'Regenerate summary' start a regenerate immediately; Reprocess also discards the Result. retryMeeting on a healthy meeting chains summarize into performRepublish. BatchActionConfirmation gates the batch form because, in its own words, hand edits and done ticks are lost.

*Scenario:* On a meeting with a hand-edited summary and ticked actions, one click on Reprocess in the More actions menu regenerates the summary, replaces the edited file and republishes the page. No dialog, no undo; a refused retry (no audio) says nothing.

*Direction:* Reuse BatchActionConfirmation.resummarize with count 1 for every single-meeting regenerate entry point and surface the retryMeeting failure.

**F025. Mute timeline is persisted only after a successful stop-time merge**

`daemon/Sources/MeetingPipe/MeetingRecorder.swift:1430`. Lens: data. Outcome: confirmed. Backlog: New. No task persists the mute timeline before stop. REC26 (done) fixed this exact shape for flag markers only; REC21 (new) excludes the timeline write. Quarantine of a timeline-less orphan is designed fail-closed (SEC16, 53d18a47), with SEC26 the downstream cost.

The mute timeline exists only in memory and is written only when stop() produced a final. flushIntermediatesForTermination (menu Quit, SIGTERM) and a failed or wedged stop-time merge never write it, so orphan recovery finds redaction intent without a timeline and quarantines a recording whose spans the recorder was holding.

*Scenario:* Recording under a redact workflow, or after one off-the-record press. The user picks Quit. Next launch merges the orphan, shouldQuarantine is true, and the meeting is moved to the originals folder with a 'timeline was lost' notice instead of being redacted and processed.

*Direction:* Write the timeline keyed by stem regardless of hasFinal and in the termination flush after the bounded teardown, or persist spans incrementally as they close.

**F028. Mic gap pad is one unclamped buffer charged in full to the backlog cap**

`daemon/Sources/MeetingPipe/MeetingRecorder.swift:1749`. Lens: data. Outcome: partially confirmed. Backlog: New. No task clamps or chunks the mic gap pad. The 900 s maxPadSeconds clamp (REC16, partial) and the charged-once pad buffer (REC25, done) are system-channel only; REC25's 512 MiB backlog cap is what a sleep-sized mic pad would trip.

The mic gap pad is unclamped and allocated as one buffer on main, charged in full to the backlog cap, unlike the system side. A sleep-sized pad requires a device-change recovery already pending at sleep onset (scheduled retry or in-flight bounded engine call) that is not superseded on wake; the wake re-check and any fresh configuration change stamp a new gapStart. The writer_stalled force-stop then depends on a 1 Hz tick landing before the single write completes. Above about 46.6 minutes at 48 kHz mono Float32 the pad exceeds the 512 MiB cap. Not executed.

*Scenario:* A device-change recovery straddles a 50 minute sleep. On wake about 576 MB is allocated on main and enqueued; a 1 Hz tick sees more than hardCapBytes pending and force-stops the recording as writer_stalled. An overnight gap asks for gigabytes.

*Direction:* Clamp the mic pad like SystemCaptureRetryPlanner.maxPadSeconds and enqueue a shared 1 s chunk through enqueue(_:bytes:) so only one chunk counts.

**G036. Move to Trash is enabled on the live-recording row and the delete service has no owned-stem guard**

`daemon/Sources/MeetingPipe/MeetingRow.swift:470`. Lens: data. Outcome: confirmed. Backlog: New. REC23 (done) added MeetingRecorder.ownedStems for the orphan, reap and retention sweeps only. STOR7 (new) rewrites softDeleteMeeting for footprint and off-main work. Neither guards delete against the live stem or gates the row on recording.

The row's destructive item is gated only on processing.isBusy, which tracks pipeline-lane jobs and is .idle during capture. softDeleteMeeting trashes every file with the stem and never consults MeetingRecorder.ownedStems or liveRecordingStem; the detail header and batch pane call the same service. What the recorder's stop path does afterwards was not traced.

*Scenario:* During a recording, right-click the pinned In progress row (or include it in a batch selection), choose Move to Trash and confirm. The capture files under the running recorder are moved to the Trash while the HUD keeps showing Recording.

*Direction:* Refuse in MeetingLibraryService.softDeleteMeeting when the stem is in MeetingRecorder.ownedStems, and disable the row, header and batch delete for the live stem.

**G031. A Stop during 'Confirming end' skips the trim, so post-call audio is kept and transcribed, even under NDA**

`daemon/Sources/MeetingPipe/MeetingSessionController.swift:783`. Lens: data. Outcome: confirmed. Backlog: New. No task covers a stop during an open hold. END9's spec deliberately lets a force-stop end with trimAt = now; END17 (partial) and ADR 0017 promise the cut only for confirmed holds. Backstop and low-space routes unaddressed.

pendingEndTrimAt is set only when the engine or the teardown oracle concludes a hold. A user Stop, the low-space stop or the idle backstop during an open Confirming end hold reaches stopRecording with it nil, so nothing is trimmed or cut. ADR 0017 L58 and GUIDE L92 promise those minutes are excluded, and deleted under NDA or regulated mode.

*Scenario:* NDA Zoom call ends; the panel reads Confirming end. Three minutes later the user presses Stop. limitSeconds is nil and no held_end_trim_sec is written, so three minutes of post-call room talk stay in the WAV, the transcript and the summary.

*Direction:* Decide what a stop inside an open hold means (conclude the hold so its start is the trim point, at least under regulatedGate), pin it in HeldEndSessionTests, and align ADR 0017 and GUIDE.

**G030. Quitting mid-recording quarantines any recording that used off the record, contrary to GUIDE**

`daemon/Sources/MeetingPipe/OrphanRecordingRecovery.swift:315`. Lens: data. Outcome: confirmed. Backlog: New. Lost-timeline quarantine is deliberate fail-closed (MIC14, SEC16). REC26 (done) fixed the same quit-path loss for flag markers only; REC13 wrote the GUIDE promise; REC21 and SEC26 are adjacent. Nothing covers persisting the mute timeline at quit.

GUIDE.md L98 promises a mid-recording quit is 'picked up and finished the next time the app starts'. The quit path (MeetingRecorder.flushIntermediatesForTermination, L1532) never writes the in-memory mute timeline, so any recording with an off-the-record press or a redact-muted workflow is quarantined on relaunch instead, with only a notification and no failure sidecar.

*Scenario:* Press ⌃⌥O once during a call, later choose Quit MeetingPipe while still recording. On relaunch the merged WAV is moved to Application Support/MeetingPipe/originals, never transcribed, and OriginalsReaper deletes it after 30 days.

*Direction:* Write the timeline (or append spans as they close) in the termination flush so orphan recovery can redact instead of quarantine, and narrow GUIDE L98 until then.

**F010. 'Always for <app>' consent is persisted with no in-app revoke, and Preferences shows the opposite**

`daemon/Sources/MeetingPipe/Preferences/PreferencesView+Recording.swift:50`. Lens: data. Outcome: confirmed. Backlog: New. No task describes the missing revoke or the Preferences mismatch. SEC24 (new, P3) notes Always silences the prompt for good but keeps it and scopes only a disclosure; UX88 edits the config list; STOR9 covers an unreadable consent file.

Holds as stated, with two corrections. The either-list check is at MeetingSessionController.swift:1154-1155, not 1147-1148. The manual workaround is weaker than reported: ConsentStore reads auto_consent.json once at init and save() rewrites it from memory, so deleting the file does nothing until the daemon is restarted, and a later Always pick in the same run writes the old entries back.

*Scenario:* User clicks chevron, 'Always for Zoom' once (or for a browser on a mic-in-use prompt). Every later call in that app records with no prompt. Preferences, Recording still reads 'No apps yet - every meeting will prompt.' Only deleting auto_consent.json by hand undoes it.

*Direction:* Render and edit the ConsentStore set in the same allowlist (or fold it into auto_consent_apps) so there is one list with a remove control.

**F073. 'Evict unused' deletes every model in the shared HuggingFace cache except the summary model, including the app's own search embedder**

`daemon/Sources/MeetingPipe/Preferences/StorageStatsStore.swift:100`. Lens: data. Outcome: partially confirmed. Backlog: New. No task covers the embedder being evictable or the regulated-mode Ask break. STOR1's README and dialog document the scope; the 2026-08-03 band triaged 'other tools' models' to low with no spec; STOR7 only fixes bytes_freed.

'Evict unused' deletes every models--* directory in the shared ~/.cache/huggingface/hub except summarization.local_model, so it removes other HuggingFace tools' cached models and mp's own embedding model (mlx-community/multilingual-e5-small-mlx). All of it is re-downloadable and the deletion scope is documented in the dialog and README. The functional break is limited to global regulated mode, where the next Ask (or MCP serve, or actions --cluster) fails closed with 'Embedding model ... is not in the local HuggingFace cache' until a manual mp prefetch-model; a per-workflow NDA flag does not arm the guard for Ask, and outside regulated mode the embedder re-downloads on demand.

*Scenario:* User confirms 'Delete unused models?' (copy: 'They re-download on demand'). Unrelated models other tools cached there are deleted, plus multilingual-e5-small; the next Ask in a regulated or NDA run fails with 'Embedding model ... is not in the local HuggingFace cache' until a manual mp prefetch-model.

*Direction:* Evict only repos the app itself downloaded (track them, or allowlist the local_model presets plus the embedder) and name the repos in the dialog.

**F141. Library move checks for in-flight work only at plan time and only from file heuristics**

`daemon/Sources/MeetingPipe/Preferences/StorageStatsStore.swift:145`. Lens: data. Outcome: confirmed. Backlog: New. No task covers the busy check being plan-time only and file-inferred, never asking the recorder or pipeline lane. OBS3 fixes its unreadable-folder nil, ARCH20 its duplicated suffix chain. Same defect as F074.

The busy refusal runs only in `LibraryMover.plan` and is inferred from files (a `.mic.wav` written in the last 60 s, or a final recording with no terminal sidecar). `executeMove` runs after the confirm dialog with no re-check and never asks the recorder or the pipeline lane; re-runs of summarized meetings are invisible to it.

*Scenario:* The plan is built, the confirm sits open, a detected meeting starts recording, then the owner clicks Move to a folder on another volume. `moveItem` copies a partial `.mic.wav` and removes the source; the rest of the meeting is written to an unlinked file.

*Direction:* Re-run the busy check inside executeMove against MeetingRecorder.ownedStems and the job dispatcher, and block recording start while the move runs.

**F074. Library move is checked for a live recording only when planned, then executed unguarded and ungated**

`daemon/Sources/MeetingPipe/Preferences/StorageStatsStore.swift:148`. Lens: data. Outcome: confirmed. Backlog: New. No task covers executeMove skipping the in-flight re-check after the confirm, or Move library bypassing StorageBusyGate. UX89, OBS3 and ARCH20 touch LibraryMover.inFlightReason for other defects. Same defect as F141.

LibraryMover.plan runs inFlightReason, but executeMove calls LibraryMover.execute after an open-ended confirmation dialog with no re-check, and the 'Move library…' button is not disabled by StorageBusyGate. LibraryMover's header calls a move under a live recording 'a lost meeting'. The config repoint then goes through the 500 ms debounced save.

*Scenario:* User picks a destination; while the 'Move the library?' dialog is up an allowlisted app starts a call and recording begins, or a backup or restore is running. Confirming renames or copies the directory out from under the recorder or the mp job.

*Direction:* Re-run inFlightReason, and consult the recorder state and the busy gate, inside executeMove immediately before execute; hold new recordings for the duration.

**G002. Low-space watch reads zero free bytes on any volume except the boot Data volume, so it stops every recording at the first tick**

`daemon/Sources/MeetingPipe/RecordingWriteFailure.swift:81`. Lens: data. Outcome: partially confirmed. Backlog: New. No task covers a zero important-usage reading. REC19 (done) chose the smaller of two capacity keys by owner decision; REC20 (partial) reuses it for the low-space preflight and watch. Neither considers ExFAT, FAT32 or nobrowse volumes.

`effectiveFreeBytes` takes `min` of the two capacity keys, so a volume whose `volumeAvailableCapacityForImportantUsage` reads 0 (not nil) while space is free is treated as having zero free bytes. That is NOT every non-boot volume. Measured on this Mac with scratch disk images: a normally mounted APFS or HFS+ volume reads important == available (non-zero), so an ordinary Mac-formatted external or secondary disk is unaffected. The key reads 0 with space free on ExFAT and FAT32 volumes (writable, browsable) and on any volume mounted `nobrowse` regardless of filesystem. Network volumes were not measured. If the recordings folder is on such a volume, every recording there opens on a `Disk: 0m left` HUD label and a low-space notification, and the first 60 s tick returns `.stop` and force-stops it with a false "disk was almost full (Zero KB free)" notice; the first minute is kept and merged. The same 0 also makes `RecordingWriteFailure.decide` blame `disk_full` for any real write-failure stop on those volumes. The default folder (`~/Documents/Meetings/raw`, boot volume) is unaffected.

*Scenario:* Recordings folder moved to an external or secondary volume. The HUD opens on `Disk: 0m left`; at the first 60 s tick `Policy.evaluate` gets 0 bytes, returns `.stop`, and `handleLowSpace` calls `forceStop`. Every meeting is cut to its first minute with a false disk-full notice.

*Direction:* Treat a zero or missing important-usage value as unreadable and fall back to `volumeAvailableCapacity`; pin `effectiveFreeBytes(importantUsage: 0, available: n) == n` in a test.

**F059. In-app restore overwrites workflow and saved-search files but the running stores never reload**

`daemon/Sources/MeetingPipe/RestoreFlow.swift:277`. Lens: data. Outcome: confirmed. Backlog: New. No task covers running stores not reloading after a restore. STOR5 (owner-verify) shipped the feature without a reload; UX53 row 26 scored restore as refreshing for meeting files only and excluded non-meeting surfaces.

A finished restore only calls onRestored, wired in Coordinator to a failed-count refresh. WorkflowStore, SavedSearchStore and WorkflowCorrectionStore load once at init (the only three load() calls) and rewrite their whole in-memory set on any mutation, while mp restore --force overwrites those files and the confirm promises workflows are replaced.

*Scenario:* Restore a backup whose client workflow has NDA mode on. The daemon keeps routing with the pre-restore workflows. The next workflow save or reorder runs persistAll and writes the old versions over the restored TOML files; the next smart-folder edit does the same to saved_searches.json.

*Direction:* Reload every store backed by the config root in onRestored (or relaunch) before any further write is possible.

**F066. Inline summary save overwrites summary.json without the staleness check and reports Saved when the write fails**

`daemon/Sources/MeetingPipe/SummaryTab.swift:609`. Lens: data. Outcome: confirmed. Backlog: New. The missing staleness check is unfiled: UX65 (done) fixed CorrectionWindow only and scoped SummaryTab out as a new row. ARCH10 item 3 (new) already owns the swallowed write that still returns true, despite UX13 (done).

beginEditing snapshots the summary and builds the model without loadedIdentity; persistEdit never re-reads. The SummaryStaleness.hasMoved check that CorrectionWindow.performSave makes is absent here, so a save writes snapshot plus edits over whatever is on disk and records a stale original_summary. The summary write is try? and the function still returns true.

*Scenario:* Start Re-summarize, open Edit summary while it runs, save after it lands: the regenerated summary and any ticks made since are replaced by the old text. If the write fails, the footer still shows Saved and the edit disappears from the reader.

*Direction:* Route the inline save through the same identity check as CorrectionWindow.performSave and return false, keeping the editor open, when the summary write fails.

**G005. Re-transcribe carry lays a short line's edit over a whole merged turn, erasing the rest of it**

`daemon/Sources/MeetingPipe/TranscriptOverlayCarry.swift:273`. Lens: data. Outcome: confirmed. Backlog: New. ASR3 (done, 1c26afe2) shipped the cover-half-of-the-old-span gate and its headline test pins the lossy case. Its notes say an edit must not land on a different sentence; the merged-turn text loss is documented nowhere. UX66 only added glossary contradictions.

The gate only requires the new segment to cover half of the OLD one. When the new turn is longer, the old fragment's whole `editedText` replaces the whole new text (Swift `apply` and Python `apply_corrections` are whole-text). The suite's headline test (lines 31-52) pins it: 'hi we shipped perfecta' becomes 'we shipped Perfeqta'.

*Scenario:* Segmentation differs between runs (speaker-separation setting changed, or a newer build). A four-word fix made on a fragment lands on a sixty-word coalesced turn. The Library, the next summary and the ask index see only four words, and the alert says the edit carried over.

*Direction:* Require coverage in both directions (old must also cover most of new) for corrections and per-segment reassignments; otherwise re-apply the edit as a diff against the new text or drop and report it.

**G010. Cluster-name carry lets a small named cluster rename a large merged one**

`daemon/Sources/MeetingPipe/TranscriptOverlayCarry.swift:312`. Lens: data. Outcome: confirmed. Backlog: New. ASR3 (done, 1c26afe2) documents the rule as designed: a new cluster inherits a name on a strict majority of the old cluster's time. It reasons about the split case only. No task, audit or ADR covers a merged cluster.

Dominance is the share of the OLD cluster's time only, and only named old clusters compete. A named cluster absorbed into a larger new one passes at ratio 1.0, so the whole new cluster takes its name, even a roster-matched label (the test at lines 167-175 lands a name on one). `apply_overlay` feeds that to summaries.

*Scenario:* Old THEM-A, named Alice, spoke 40 seconds; unnamed THEM-B spoke 30 minutes. The new diarization merges both into one cluster. The carry names that cluster Alice: every line shows Alice, a re-summary credits her with 30 minutes of speech, and the alert reports one edit carried.

*Direction:* Also require the old cluster to own a majority of the new cluster's speaking time; otherwise leave it unnamed and count it as dropped.

**F051. Held-end privacy trim fails open when meta.json cannot be read**

`daemon/Sources/MeetingPipe/Transcription/HeldEndTrim.swift:20`. Lens: data. Outcome: confirmed. Backlog: New. SEC25 (done) routed its enumerated NDA-routing readers through MeetingMetaRead. HeldEndTrim.trimSeconds, added by END17 two days before SEC25 shipped, was not among them, and no task, audit or ADR covers its try? read.

The held-end trim reads <stem>.meta.json with try? and treats unreadable or unparseable as no trim; SinkDispatcher.swift:527 then writes the untrimmed transcript. MeetingMetaRead (SEC25) exists because iCloud made this sidecar unreadable on 2026-10-16, and the repo rule demands fail-closed reads for privacy decisions. This reader bypasses it.

*Scenario:* Re-transcribe or Retry a held-end meeting while its meta.json is dataless: trimSeconds returns nil and the audio after the call ended is transcribed into <stem>.json. That run is clamped local by load_meta, but a later re-summarize or publish, once the sidecar reads again, carries the tail.

*Direction:* Read through MeetingMetaRead and fail the job, writing no transcript, on .unreadable.

**G014. Retention's manual-recordings warning reads the saved default flag, and a destructive policy saves with no confirm**

`daemon/Sources/MeetingPipe/WorkflowsView.swift:676`. Lens: data. Outcome: partially confirmed. Backlog: New. No task covers the warning reading the saved isDefault flag or the missing confirm. REC20 (partial) added the line; the owner accepted its retroactive reach on 2026-11-12, on the premise that manual recordings carry no workflow.

Ticking Use as default on a workflow with a compress or delete policy hides the 'also applies to manual recordings' line and saves with no confirm. Retroactively the sweep reaches only settled meetings whose meta lacks workflow_id (pre-workflow or sidecar-less stems), via removeItem for a drop policy; app-made manual recordings carry the default-at-record-time id and are not affected. The REC20 comment 'manual recordings carry no workflow' is itself inaccurate for the shipped record path.

*Scenario:* 'Standups' deletes audio after 7 days. The owner ticks Use as default and presses Return. After the next pipeline job every settled manual or pre-workflow recording older than 7 days loses its audio for good, with no count and no warning shown.

*Direction:* Key the line on the live toggle, and confirm any save that newly brings existing audio under compress or drop, stating how many meetings the next sweep will touch.

**F114. The WAV-deleting compress path has no test for its verification or ffmpeg failure branches**

`daemon/Tests/MeetingPipeTests/AudioTranscoderTests.swift:92`. Lens: data. Outcome: confirmed. Backlog: New. No task asks for verificationFailed, ffmpegFailed or outputMissing tests. CONC5 (new) adds only a timeout case to AudioTranscoderTests; DEP2 (new) replaces the ffmpeg encode but keeps the duration verify. STOR1 (done) claimed no such coverage.

compressToFLAC deletes the source WAV once a duration check passes. The suite covers the happy path and a missing source only; verificationFailed, ffmpegFailed and outputMissing appear in no test, although MEETINGPIPE_FFMPEG already lets RecordingPostProcessorTests inject a truncating ffmpeg for the merge.

*Scenario:* The duration guard is dropped or its tolerance widened in a refactor. All four tests pass. A retention sweep with policy compress replaces an hour-long WAV with a truncated FLAC and removes the original.

*Direction:* Reuse the fake-ffmpeg helper to emit a short or undecodable output and a non-zero exit, and assert the WAV survives and no FLAC or .flac.writing file remains.

**G032. SETUP says only the summarizer sees the transcript; the default Notion sink uploads the full transcript**

`docs/SETUP.md:146`. Lens: data. Outcome: confirmed. Backlog: New. No task covers SETUP Step 7's claim that nothing but the summarizer call leaves the Mac. STOR6 (new) fixes the same class of copy on the Welcome screen and README only; UX45 documents include_full_transcript defaulting true.

With the documented default (Anthropic plus Notion) the Notion sink also uploads the summary and, because notion.include_full_transcript defaults to True (config.py L196, publish_notion.py L545), the whole transcript. L148 'Fully on-device, no network' and L152 'whether a summary left your Mac' ignore the sink the same way. README L643 says the opposite of L146.

*Scenario:* A user picks Local MLX to keep client calls on the Mac and keeps the Notion destination from step 6. Every word of each transcript is posted to Notion while the meeting's engine line reads (on-device).

*Direction:* Say in steps 6 and 7 that Notion receives the summary and, by default, the full transcript, and name the Include the full transcript toggle.

**F092. Backup of a missing or unreadable library succeeds, stamps the marker and lets retention prune good archives**

`pipeline/src/mp/backup.py:155`. Lens: data. Outcome: confirmed. Backlog: New. No task guards a missing or unreadable library root. STOR4 (done) refused only the unmounted destination; STOR12 (done) added the prune that makes an empty run destructive; UX89 (new) covers only the mistyped output_dir trigger.

A library root that is missing (unmounted volume, wrong or defaulted `output_dir`) contributes zero files, and `rglob` silently skips unreadable directories (CPython 3.11 pathlib swallows PermissionError; skip reproduced in scratch). `run_backup` still renames the archive into place, stamps the last-backup marker and prunes older archives. Nothing compares the result with the previous archive.

*Scenario:* Library lives on an external drive that is unplugged while the daily launch agent backs up to a NAS. Each run writes a config-only archive and reports success; doctor says the last backup was today. After roughly five weeks retention has pruned every archive that held recordings.

*Direction:* Raise BackupError when the library root is absent or the file count collapses against the last manifest, and report unreadable paths instead of skipping them.

**F139. Absolute paths baked into run and correction sidecars break after a library move or cross-path restore**

`pipeline/src/mp/corrections.py:81`. Lens: data. Outcome: partially confirmed. Backlog: New. No task covers stale absolute paths in run.json or correction records after a library move or restore. SEC12 (done) shipped LibraryMover without mentioning sidecar paths; PIPE33 (new) only changes stem derivation from transcript_path.

After a library move or a restore onto a different root, pre-move meetings drop out of `mp train-adapter` (corrections and runs sources) and contribute 0 transcript chars to `mp corrections-stats`, because `<stem>.run.json` and correction records keep absolute paths that nothing rewrites, and new corrections for old meetings inherit the stale path. The readiness gate is depressed rather than permanently blocked: new and re-summarized meetings carry fresh paths and `--force` bypasses it. Impact is limited to the opt-in, hand-run LoRA training commands.

*Scenario:* Owner moves the library out of iCloud with the Storage pane. Every earlier meeting silently drops out of `mp train-adapter` (transcript unreadable), and `corrections-stats` counts 0 transcript chars, so the readiness gate never passes.

*Direction:* Resolve transcripts and summaries by stem against the current output_dir in both readers; treat stored absolute paths as hints only.

**F140. Merging meetings drops the fragments' speaker-name and text-correction overlays**

`pipeline/src/mp/merge_meetings.py:205`. Lens: data. Outcome: confirmed. Backlog: New. No task, audit or ADR mentions fragment speaker_labels, transcript_corrections or embeddings sidecars in a merge. FEAT9's done entry and PIPE8 cover audio, transcript, gap marker and retry order only; STOR7 and STOR9 concern delete and overlay reads.

Merge reads each fragment's raw `<stem>.json` and never applies or carries its `.speaker_labels.json` / `.transcript_corrections.json` overlays or its embeddings sidecar. On success `MeetingLibraryService.mergeMeetings` soft-deletes every fragment file, so the user's names and text fixes on fragments are absent from the merged transcript and summary.

*Scenario:* User names speakers and fixes misheard lines in the second half of a dropped call, then merges the two recordings. The merged meeting shows the fragment's uncorrected text and THEM-x labels; the edits now sit in the Trash.

*Direction:* Apply each fragment's overlays before concatenating, or re-key the overlay sidecars onto the primary using the segment offset.

**F015. Obsidian note filename is publish date plus title slug, so same-titled meetings overwrite each other**

`pipeline/src/mp/publish_obsidian.py:177`. Lens: data. Outcome: confirmed. Backlog: New. Same-title same-day overwrite is unfiled. PIPE31 (new) covers the adjacent legs (later-day republish orphan, stale docstring, date from stem), but its fix still maps two same-titled stems to one path. Best handled as a PIPE31 amendment.

The note path is `<today UTC> <title slug>.md`; the recording stem is used only when the slug is empty, contradicting the module docstring's `<vault>/<folder>/<stem>.md`. Two meetings with the same title published on one UTC day share a path and `write_text` replaces the first. A changed republish on a later day leaves the old note orphaned.

*Scenario:* Two meetings carry the same `meeting_title` (a recurring series: last week's regenerated on the day this week's is published, or two same-named calls in one day). Both resolve to one file; the second replaces the first, whose sidecar hash still matches, so republishing it is skipped as unchanged.

*Direction:* Build the filename from the recording stem (title as a suffix) and reuse the sidecar's recorded note_path on republish.

**F106. Swift writes summary.json shapes the Python reader rejects; the failure exits 1, so Retry re-summarizes over the user's edit**

`pipeline/src/mp/publish_router.py:197`. Lens: data. Outcome: confirmed. Backlog: New. No task covers Swift writing summary.json past pydantic limits or the exit-1 misclassification. ARCH10 unifies Swift summary writers and ARCH11 moves Apple summarize behind Python, but neither adds limits; ADR 0014 names the Python schema as source of truth.

The Summary editor (`CorrectionEditor` appends bullets freely, free-text title) and the Apple summarizer write `<stem>.summary.json` through `jsonObject()` with no limits. `fanout` re-validates with pydantic (title max 120, summary max 10 items, `confidence` a Literal) before any sink runs. That error exits 1, not 3, so Swift records stage `pipeline`, not `publish`.

*Scenario:* User adds an 11th summary bullet, saves, clicks Republish. `mp publish` raises ValidationError and exits 1. The row shows failed; Retry skips the publish-only path, runs regenerateMeeting, and `mp summarize` overwrites the hand-edited summary. (The Apple `confidence` variant is inferred, not traced.)

*Direction:* Clamp or reject over-limit fields in `MeetingSummary.jsonObject()` and the editor, and have `mp publish` report a pre-sink failure as a publish-stage outcome.

**F094. Restore overwrites live files in place with no space check, no per-file atomicity and no verification**

`pipeline/src/mp/restore.py:276`. Lens: data. Outcome: confirmed. Backlog: New. No task covers restore's missing free-space check, per-file atomicity or post-restore verification. STOR12 (done) only scaled the timeout around the half-restored hazard; STOR5 documents always --force and that workflows, roster and vocabulary are replaced, shown in the confirm.

Extraction writes each member straight over the live file (CPython 3.11 `TarFile.makefile` opens the target `wb`), with no free-space check, no temp-and-rename, and no comparison against the manifest's counts. Only `FilterError` is handled. The app always passes `--force`, and the config root (workflows with NDA flags, roster, voiceprint) is overwritten with the backup's older copies.

*Scenario:* In-app restore of an older archive onto a nearly full disk. Added recordings consume the space; the next replaced WAV or transcript is truncated and the write fails with ENOSPC. Restore exits with a traceback, leaving a previously intact file truncated and the library half restored.

*Direction:* Preflight free space, extract to a temp name and os.replace per file, map OSError to RestoreError, and verify written counts against the manifest.

**F105. rebuild.sh overwrites the running daemon's executable in place, long before it stops the daemon**

`scripts/rebuild.sh:60`. Lens: data. Outcome: partially confirmed. Backlog: New. No task or commit covers copying over the live binary before the daemon stops, or the missing live-recording check. DIST6 notes the in-place overwrite only as no rollback; REC26 (done) only keeps flags through a rebuild relaunch.

rebuild.sh:60 overwrites the installed binary in place (same inode, measured) long before the daemon is stopped at :122. Two consequences are verified: until codesign at :83 replaces the inode, any fresh launch of that path (a KeepAlive respawn, a user open) is killed at exec (measured exit 137), and the relaunch ends a recording in progress with no check or warning, since neither script looks for a live recording (the SIGTERM path flushes what was captured; the rest of the meeting is not recorded by that instance). The claimed kill of the already-running daemon by changed code pages was not reproduced in three scratch trials, where every page was resident at overwrite time, and is not disproved. A respawn inside the window would be killed at exec, not run half-refreshed.

*Scenario:* The owner rebuilds during a call. macOS can kill a process whose mapped code pages changed, with no SIGTERM flush, and KeepAlive respawns a half-refreshed binary that is not yet re-signed. At best bootout ends the recording mid-meeting without a warning.

*Direction:* Stop the daemon first, refusing or asking when a recording is live, then replace the binary through a temp file and rename.

**G021. Corpus redaction check is closed-vocabulary only for lifecycle traces; promotion traces (33 of 41 committed) pass with arbitrary free text**

`scripts/redact_detection_trace.py:87`. Lens: data. Outcome: confirmed. Backlog: New. T8 (owner-verify) and the corpus README scope closed keys to lifecycle traces only; C6-FINISH's gate was always signal kind plus email, URL, @-mention. Nothing covers the open promotion schema or the unenforced no-free-text rule.

For `engine: promotion`, validate() checks only `events[].kind`. Unknown top-level keys, unknown context or event keys, free-text `description` and `expected_verdicts[].leading` are accepted, and scan_pii matches only emails, URLs and @-mentions. So test_every_committed_corpus_trace_passes_the_strict_check (test_detection_trace_scripts.py:266) gates names and meeting subjects on nothing for that engine.

*Scenario:* A curated trace gets description "Quarterly sync with Jane Doe about the Acme merger", a `notes` key and an event `label`. Executed: validate=[], scan_pii=[], needs_redaction=False, and `--check` prints OK with exit 0. The file can be committed to the corpus.

*Direction:* Give promotion traces the same closed key set lifecycle traces have, and constrain description and scenario to a generated template or a token charset.

**G016. 'Always fix this' accepts common words and case-only pairs, and stores a key the user did not type**

`daemon/Sources/MeetingPipe/Clarify.swift:108`. Lens: quality. Outcome: confirmed. Backlog: New. No task guards rule keys. FEAT13 (done) pins the c++ no-match limitation on purpose and FEAT12 (done) the outer-punctuation trim and whole-edit capitalization pairs, but accepting common words or case-only pairs as global rules is discussed nowhere.

The rule path rejects only empty or identical sides. Keys are folded at match time, so a case-only fix such as 'it' to 'IT' becomes a rule on every occurrence. Outer punctuation is stripped from the key without showing it (pinned at ClarifyTests.swift:234-245), and a key like 'c++' that can never match is written silently.

*Scenario:* The owner types 'it' and 'IT' on a line about the IT team and picks 'Always fix this'. Replaying glossary.py's regex on 'I think it works. It ships Friday.' gives 'IT' for every pronoun, in every future transcript of that scope.

*Direction:* Show the normalised key and a match preview against this transcript before confirm, and warn or refuse on very short keys, stop-words, case-only pairs and keys with no word-character edge.

**F044. Unguarded 'Always' plus a catch that forces .idle can desynchronise the state machine from a live recorder**

`daemon/Sources/MeetingPipe/Coordinator+Delegates.swift:38`. Lens: quality. Outcome: confirmed. Backlog: New. No task, audit or ADR mentions didChooseAlways lacking the .prompting guard or beginRecording's catch forcing .idle. REC12 only remarks that prompts are suppressed while recording; REC27 (done) covers failed-start leftovers, a different defect.

didChooseAlways is the only prompt outcome with no .prompting(source) guard. If it fires while a recording is live, recorder.start throws alreadyRecording and beginRecording's catch unconditionally sets the state machine and status bar to idle while the recorder keeps running. Every stop path keys on .recording, so none works afterwards.

*Scenario:* Hotkey start from idle; state stays .idle during bring-up, so a queued lifecycle .starting raises a prompt that survives the commit. User clicks Always: error banner, menu reads Idle, HUD Stop and force-stop hotkey both fail, and the recording runs until Quit.

*Direction:* Guard didChooseAlways like its siblings, and in beginRecording's catch (MeetingSessionController.swift:670) do not go idle on alreadyRecording; dismiss any prompt when a start commits.

**G039. Filters and Needs you read a scan status that is never .recording and turns .failed after two hours live**

`daemon/Sources/MeetingPipe/FilterBarView.swift:158`. Lens: quality. Outcome: confirmed. Backlog: New. No task names it. ARCH20 (new) and PERF22 (done) describe buildMeeting's age branch (.failed past staleProcessingThresholdSec) but neither treats the live recording row or the never-assigned Status.recording filter as a defect.

No code assigns Meeting.Status.recording except MeetingRow's display overlay; the scan reports a live row as .processing and, once its stem is two hours old, .failed. MeetingFilterEngine, saved folders and LibraryScope.needsYou read the raw status, so this chip can never match and a long live meeting counts as failed.

*Scenario:* Two hours ten minutes into a workshop the rail shows an amber '1 meeting needs you', Status: Failed lists the meeting still being recorded, its context menu offers Reprocess, and Status: Recording returns an empty list.

*Direction:* Apply the live-stem overlay once where rows are derived (or pass owned stems into the filter and scope contexts) and exempt an owned stem from the age-inferred failure rule.

**F027. micCaptureAbandoned stays latched after a recovery that reports resumed**

`daemon/Sources/MeetingPipe/InputDeviceRecovery.swift:491`. Lens: quality. Outcome: confirmed. Backlog: New. No task tracks it. REC15 (partial, 2446f13d) introduced the flag and lets a device change still reach recovery; its 'cleared by a successful recovery' reads as the failure budget, and the flag's doc comment says cleared by start() only.

A successful recovery resets the failure run but not micCaptureAbandoned; only resetForRecording() clears it. A configuration-change recovery is still allowed after abandonment and reports .resumed, yet the guards at checkTapLiveness (line 584) and recheckAfterWake (line 623) stay shut for the rest of the recording.

*Scenario:* Headset drops, five recoveries fail, the mic is abandoned. The headset reconnects and the change notification recovers capture; the HUD clears. Later the tap stalls silently or the Mac wakes with a stopped engine: nothing re-arms, and the mic channel is empty until stop.

*Direction:* Clear micCaptureAbandoned when recoverCapture succeeds, and pin it with a test that abandons, recovers by notification, then expects the watchdog to re-arm.

**F022. Regenerate and Retry always spawn `mp summarize`, which rejects the apple_intelligence backend**

`daemon/Sources/MeetingPipe/Library/MeetingLibraryService.swift:295`. Lens: quality. Outcome: confirmed. Backlog: New. No task describes nil-backend Regenerate or Retry spawning mp summarize for an apple_intelligence meeting. PIPE25 covers only the language refusal; ARCH11's provider leg would remove the path without naming it. Duplicate of F023.

`regenerateMeeting` spawns `mp summarize` whatever the resolved backend; Regenerate, batch regenerate, restore-tail and `retryMeeting` (any failure with a reusable transcript) pass `backend: nil`. For `apple_intelligence` Python's builder raises ValueError (`providers._apple_summary`), so only run-all's sentinel hand-off reaches the Swift summarizer. `merge_meetings` hits the same raise after committing the merged audio.

*Scenario:* Global backend apple_intelligence. One run fails after finalize because the system model is not ready. Retry finds a reusable transcript, calls regenerateMeeting, and `mp summarize` exits 1 with 'runs in the daemon (Swift)'. Every later Retry or Regenerate fails identically.

*Direction:* In `regenerateMeeting`, resolve the effective backend first and route apple_intelligence through `AppleIntelligenceSummarizer` then `mp publish`, as `completeViaAppleIntelligence` does.

**F048. PermissionsCenter mutates @Published state off the main thread, contrary to its own header**

`daemon/Sources/MeetingPipe/PermissionsCenter.swift:89`. Lens: quality. Outcome: confirmed. Backlog: New. No task covers PermissionsCenter's nonisolated async refresh writing @Published state off main. CONC6 names SystemAudioCapture statics and the session controller's invariant; OBS5 edits commit() only for unchanged-status publishes.

PermissionsCenter is a non-isolated ObservableObject whose header says mutations run on main. Its async refresh and request methods are nonisolated, so with tools 5.9 and no upcoming features (SE-0338) `Task { @MainActor in await self.refreshAll() }` leaves main, and commit() writes @Published state and the deferredToSettings Set from pool threads.

*Scenario:* At launch requestPermissionsAtStartup awaits requestNotifications and requestMic from a MainActor Task; both hop off main and call commit(). With Preferences open the 2 s poll does the same while the status menu's refreshMenuRelevantSync() runs commit() on main.

*Direction:* Mark the class @MainActor (or make commit hop to main) so the documented invariant is compiler-checked; Package.swift sets only -strict-concurrency=targeted, which does not catch this.

**G033. Finish setup and doctor are two reachability models that disagree in both directions**

`daemon/Sources/MeetingPipe/SetupChecklist.swift:160`. Lens: quality. Outcome: confirmed. Backlog: New. No task covers the disagreement. UX22 (done) shipped the checklist as mirroring doctor; ARCH14 (new) records the missing OpenAI-key row as observed, not filed. Doctor failing ANTHROPIC_API_KEY and NOTION_TOKEN unconditionally appears in no task or audit.

The checklist says it mirrors doctor; GUIDE L461 says 'When it is gone, you are set up'. It has no item for an OpenAI key or claude binary and tests only the global Notion database id. Doctor fails ANTHROPIC_API_KEY and NOTION_TOKEN unconditionally (doctor.py L74), so SETUP L169's 'come up clean' is unreachable on Local MLX with a folder sink.

*Scenario:* Global backend OpenAI with no key: decide() returns no items, the Finish setup row disappears and every summary fails. Conversely, Local MLX with a Filesystem sink shows nothing left to do while Run doctor prints four [FAIL] lines.

*Direction:* Drive both from one reachability table: add openai and claude_cli items, honour per-workflow Notion database ids, and make doctor's required secrets depend on the backends and sinks in use.

**F065. Summary tab state survives a meeting switch: a finished preview or pasted text lands on the wrong meeting**

`daemon/Sources/MeetingPipe/SummaryTab.swift:199`. Lens: quality. Outcome: confirmed. Backlog: New. No task covers SummaryTab state leaking across selections. A16 (done) discards only a finished candidate on navigation, not an in-flight preview; paste state is never reset. UX78 (partial) fixed the audio symptom of the same view reuse.

MeetingDetailView is reused across selections (no .id, see its own comment at MeetingDetailView.swift:101), so SummaryTab's @State is shared between meetings. The stem-change reset (lines 72-86) omits previewing, pasteText, pasteSaving and pasteError, and runPreview assigns candidate after its await without checking which meeting is on screen. No rescan repairs this state.

*Scenario:* Click Reprocess, Generate candidate on meeting A, then select meeting B. When A's run ends, B's Summary tab shows A's candidate beside B's summary, with Keep and Discard aimed at B's stem and A's candidate sidecar orphaned. Text pasted for one paste-pending meeting pre-fills the next.

*Direction:* Give MeetingDetailView .id(meeting.stem), or hold per-meeting run state in a stem-keyed model and reset every per-meeting field on change.

**F070. Stale-stem guards in the detail tabs compare a value with itself**

`daemon/Sources/MeetingPipe/TranscriptTab.swift:841`. Lens: quality. Outcome: partially confirmed. Backlog: New. No task, audit or ADR mentions the self-comparing stem guards or a late reload writing another meeting's state. UX53 (done) accepted the Audio tab's stem-only key only for a stale waveform; PERF8 is adjacent, not this defect.

The stale-stem guards are tautological and a late or cancelled reload does write another meeting's data into the shared @State. For Name a speaker the stale pane self-heals at the next debounced rescan (roughly 0.5 s plus scan time), so an edit landing in that window is very unlikely. The stale state persists for Undo naming on a voiceprinted label (overlay removed before the roster subprocess, reload runs after it with no further directory event), for a slow load that finishes after a faster one, and on the Audio tab, whose task is keyed on the stem only and whose cancelled run also calls playback.load for the meeting just left. A correction saved while the pane is stale is written to the selected meeting's sidecar with the other meeting's index and original text, and apply() resolves by index alone.

*Scenario:* Name a speaker in meeting A (a subprocess, seconds) and select B on the Transcript tab. A's continuation reloads and B's pane shows A's lines until the next rescan. A line edit or reassignment made meanwhile is saved to B's sidecars under A's indices.

*Direction:* Compare against live state (a stem token held in @State) and check Task.isCancelled after each await, or reset the subtree with .id(meeting.stem).

**F033. Native adapter has no app-termination signal, and a vanished process-audio object freezes the veto at live**

`daemon/Sources/MeetingPipeCore/Lifecycle/Adapters/NativeLifecycleAdapter.swift:105`. Lens: quality. Outcome: partially confirmed. Backlog: New. No task covers it. ADR 0017 and END17 list workspace_app_terminated as definitive for the meeting app or browser, but only the browser adapter emits it. The frozen veto after a vanished process-audio object is also unfiled.

Native adapters (Teams, Zoom, Webex, Slack) have no app-termination signal, so the tier table's definitive app-quit route does not exist for them: confirmed by read. The frozen live veto after a crash or force-quit is conditional on CoreAudio removing the process object before a false IsRunningInput read lands, which is unmeasured. If that happens, a Teams or Zoom recording runs on until the 15 minute silence backstop or a manual stop, unless the app is relaunched and re-resolved. A normal quit usually releases the mic first and ends on the 60 s pair dwell rather than at once. Webex and Slack never emit process audio, so they end on the 12 minute lone dwell. A live HAL probe of a killed Zoom or Teams process would settle the conditional part.

*Scenario:* Zoom crashes or is force-quit mid-call while the mic read true. Its HAL objects disappear, the probe returns nil, nothing is emitted. Window-gone is absorbed by the stale veto and the recorder keeps capturing the room until the idle backstop or a manual stop.

*Direction:* Start a `WorkspaceSignal` in `NativeLifecycleAdapter`, and have ProcessAudioSignal report unknown (clearing the engine's reading) when a previously resolved set goes empty. The code path is read; that the HAL drops the object without a final false read on a crash is assumed.

**F030. A signal's first reading is forwarded as an end edge; the engine drops it, direct-ends on it or holds on it depending on a three-queue start-up race**

`daemon/Sources/MeetingPipeCore/Lifecycle/Signals/ShareableContentSignal.swift:173`. Lens: quality. Outcome: confirmed. Backlog: New. No task covers a nil-lastValue first probe emitting an end edge. END14 (partial) documents .starting ending directly on window-gone without a process-audio reading; PERF15 and CONC9 (done) made the three initial evaluates asynchronous.

The first probe, with `lastValue` nil, emits `false` as `shareable_content_window_gone` for a window never seen (ProcessAudioSignal does the same). PromotionEngine ignores it in `.idle`, ends directly in `.starting` (`handleStarting`, lines 376-384), or opens a hold in `.inMeeting`. Which applies depends on the arrival order of three independently queued initial evaluates.

*Scenario:* Hotkey start on a Webex call with its window minimized. AX healthy arrives first (`.starting`), the ScreenCaptureKit read lands before the host's late `confirmRecording` round trip, the engine emits `.ended` with no hold, and `handleMeetingEnded` stops the seconds-old recording.

*Direction:* In the engine, ignore `.ended` from a signal that has not read `.live` this session (the browser adapter's `hasMatchedMeetingTitle` gate, generalized to every signal).

**F096. Mic-channel 'me' identification has no runner-up check, so a second person on the owner's mic can take the owner's name and voiceprint**

`pipeline/src/mp/diarize.py:291`. Lens: quality. Outcome: confirmed. Backlog: New. DIAR6 and UX83 (both new) put the owner cluster rule (0.6 mic fraction, _resolve_me_id precedence) out of scope. Commit fd001ef2 gave two gates to the voiceprint only. No task adds a margin to the mic pick.

The mic-channel 'me' pick takes the speaker with the highest mic fraction and checks only that it clears 0.6. There is no runner-up margin and ties go to the first speaker heard, unlike the two-gate rules used for voiceprint and roster. The result outranks the voiceprint, names the owner, and is auto-enrolled by `_me_signals`.

*Scenario:* Hybrid call: the owner and a colleague share one laptop mic, a third person is remote. Both local voices are near 100% mic-side; the colleague spoke first, so they get the owner's name in transcript and summary and their embedding is folded into voiceprint.json.

*Direction:* Return None when a second speaker also clears the mic threshold or the margin to the runner-up is small.

**F089. MCP list_actions truncates oldest-first before sorting and returns task text unfenced**

`pipeline/src/mp/mcp_tools.py:304`. Lens: quality. Outcome: confirmed. Backlog: New (AUTO8). Truncate-before-sort (oldest N open actions, no truncation marker) appears in no task, audit or ADR. Only the unfenced task, title and owner half is covered, by AUTO8 (new, P2); AUTO8's cap is task length, not row limit.

`actions.discover` yields actions in ascending stem order; the loop breaks at `limit` and only afterwards sorts by due date, so a large library returns the oldest N open actions with no truncation marker. Row fields `task`, `title` and `owner` are raw strings, although the tool description says returned meeting text is fenced as untrusted.

*Scenario:* digest.py's docstring cites 970 open actions on the owner's library (comment, unverified). A client asking what is owed gets 200 from the earliest meetings, sorted to look complete, and none from recent weeks; a task line carrying injected instructions arrives outside any fence.

*Direction:* Rank before applying the limit, return a total or truncated flag, and fence or drop free-text fields in rows.

**F126. Library and pipeline resolve a meeting's title with opposite precedence, so an in-app rename never reaches a sink**

`pipeline/src/mp/publish_notion.py:140`. Lens: quality. Outcome: confirmed. Backlog: New. No task covers Swift preferring summary.title while apply_meeting_title prefers meta meeting_title, or the 120-character cap failing a longer rename. ARCH10 (writeTitle parse safety) and SEC28 (title scrubbing) touch the same code but describe different defects.

Swift shows summary.title over meta meeting_title (MeetingStore.displayTitle) and a rename writes only summary.json["title"] when a summary exists, with no length cap. Python's apply_meeting_title, used by every fanout, prefers meta meeting_title; and MeetingSummary.title has max_length=120, so a longer rename fails validation before any sink runs.

*Scenario:* Zoom meeting whose window topic was captured into meta.json. User renames it in the Library and clicks Republish: Notion and Obsidian keep the old topic. A 130-character rename makes every later `mp publish` exit 1 on a pydantic error.

*Direction:* Give the user-facing title one owner (an override key both trees read first) and clamp to the schema limit at the Swift write.

**G019. report_timings pairs run_completed with the oldest unclosed run_started, so one skipped or failed run corrupts every later run total**

`scripts/valid1_check.py:143`. Lens: quality. Outcome: confirmed. Backlog: New. VALID1 (done, db9fb3e9) only fixed --timings missing the Swift transcription.* events, never run pairing. OBS4 (no run id across daemon and mp) is adjacent, not this FIFO. No task, audit or ADR mentions report_timings or skipped/failed runs.

`open_runs` is a FIFO popped only on run_completed. orchestrate.py emits run_started for every run (line 295) and ends five skip paths and three failure paths with run_skipped or run_failed, which never pop. Each leaves a stale start at the queue head for the next completion to consume. test_valid1_check.py does not cover report_timings.

*Scenario:* Log: 09:00 run_started then run_skipped(no_speech); 15:00 a 40 s run; next day a 30 s run. Executed against the script: it prints `21640.00 s total` and `68430.00 s total`. The A15/A16 run table is wrong on any real log with a skip.

*Direction:* Pair on the `wav` attribute and close a run on run_skipped and run_failed as well as run_completed.

**G022. valid1 --coldstart watchdog SIGKILLs the client's process group, which does not contain the model server**

`scripts/valid1_check.py:735`. Lens: quality. Outcome: confirmed. Backlog: New. PIPE22 (done) covers SIGTERM unwind and daemon Cancel reaping; LOCAL21 (new) names the general abnormal-exit leak of the setsid server. Neither mentions valid1's watchdog SIGKILLing a group that excludes the server. LOCAL10's reaper is only a later backstop.

`_run_timed` kills the caffeinate group. `mp summarize --backend local` starts mlx_lm.server with `preexec_fn=os.setsid` (summarize_local.py:1058), so the server sits in another group, and SIGKILL skips the in-process `_terminate_proc` teardown that would stop it. Both the low-memory path and the 900 s timeout path leave the model resident.

*Scenario:* Free memory drops under 10% during the cold run. The watchdog prints ABORT and kills caffeinate and mp; mlx_lm.server keeps the weights loaded on :8765 with a marker naming a dead owner. The machine keeps swapping, which is the case the guard exists for.

*Direction:* Send SIGTERM and wait first (mp unwinds and stops its server on SIGTERM), then kill the pid named in the mlx-server.json marker before escalating to SIGKILL.

**G037. Ask suggestions and empty state ignore the visibility gate that mp ask enforces**

`daemon/Sources/MeetingPipe/AskView.swift:65`. Lens: security. Outcome: confirmed. Backlog: New. No task covers it. UX38 (done) built the suggestion chips from the newest meetings and never applied visibility.visible_stems, which mp ask and the MCP server enforce (AUTO3). AUTO6 and PIPE29 (new) touch that gate for other callers only.

mp ask removes NDA, regulated and sidecar-less stems from its corpus (visibility.visible_stems). The pane builds its chips from the first, newest row with no such filter, so a withheld meeting's summary-derived title or workflow name is written into a question that goes to the configured backend, and an all-withheld library reads 'No meetings to search yet.'

*Scenario:* Backend anthropic, regulated mode off, newest meeting recorded under an NDA workflow and titled 'Acme acquisition terms'. Ask offers 'What came out of Acme acquisition terms?'; one click sends that title to Anthropic, and the answer can only cite other meetings.

*Direction:* Derive suggestions only from rows where isZeroEgress is false and a sidecar exists, and show the withheld count and reason in the pane instead of the empty-library copy.

**F123. 'Re-run locally (preview)' is gated and dispatched on the global backend while the pipeline resolves the meeting's workflow backend**

`daemon/Sources/MeetingPipe/Library/MeetingLibraryService.swift:1028`. Lens: security. Outcome: confirmed. Backlog: New. No task covers the global-versus-workflow backend mismatch for the preview. ARCH14 (new) lists canPreviewLocally and the preview dispatch only to type the string predicates, explicitly changing no decision.

The preview is offered (LibraryWindow.canPreviewLocally) and dispatched on the raw global summarization.backend. `mp summarize --candidate` then applies the meeting's workflow overlay, and --candidate does not force local. The button says on-device; the run uses whatever workflow_backend the sidecar pins, or raises if that is apple_intelligence.

*Scenario:* Global backend local; meeting recorded under a non-NDA workflow pinned to anthropic. User clicks 'Re-run locally (preview)' and sees 'Re-running on-device': the transcript goes to Anthropic. With a workflow pinned to apple_intelligence the same click fails with a ValueError.

*Direction:* Resolve the effective backend per meeting (sidecar plus clamp) for both the gate and the dispatch, and pass `--backend local` explicitly for the MLX preview.

**F026. Orphan recovery clears privacy markers before the quarantine move succeeds**

`daemon/Sources/MeetingPipe/OrphanRecordingRecovery.swift:203`. Lens: security. Outcome: confirmed. Backlog: New. No task covers cleanupStartMarkers running before the quarantine move, or a failed move leaving an unmarked final in raw/. REC21 (marker write failures) and SEC26 (reaper after quarantine) are adjacent, not this ordering defect.

recover() deletes the .capturemode and .offrecord markers before attempting the quarantine move. If MuteRedactor.quarantine throws, the merged un-redacted final stays in raw/ with no marker and no timeline, the user is not notified, and redactIfNeeded will answer .notNeeded for it.

*Scenario:* A redaction-intent orphan merges, then the move into Application Support/MeetingPipe/originals fails (permissions, or a full or different volume). The WAV is left as an ordinary Library file, and any later processing finds nothing saying audio was owed a cut.

*Direction:* Quarantine first and clear the start markers only after the move succeeded; on failure keep them so the redactor fails closed.

**F124. In-daemon FluidAudio model download has no zero-egress gate, unlike the pipeline's model fetch**

`daemon/Sources/MeetingPipe/Transcription/FluidAudioRunner.swift:185`. Lens: security. Outcome: partially confirmed. Backlog: New. SEC13 (done) gated only the pipeline's model fetch. HYG10 (new) notes FluidAudio downloads from the daemon as rule drift and proposes sanctioning it, with no regulated or NDA gate. DIST7 covers the unhashed fetch only.

The in-daemon ASR and diarizer model load is not gated under regulated or NDA mode, so a missing or invalidated FluidAudio cache makes the daemon request model files from huggingface.co in the middle of a transcription job. Only model-file requests leave the machine, no audio or transcript. Reachable routes are a failed install-time prefetch, a cleared cache, or FluidAudio's own wipe-and-redownload on a first-load error. A drag-install route does not exist yet. The lazy download is intended behaviour in normal mode, and no document carves out or forbids it for regulated mode specifically, while README:728 treats a huggingface.co request from a zero-egress meeting as a broken promise for the pipeline's model.

*Scenario:* Drag-installed app, or a cleared `~/Library/Application Support/FluidAudio`, on a Mac in regulated mode. The first recording's transcription makes the daemon request huggingface.co mid-job, an outbound connection both the regulated promise and the daemon-offline rule exclude.

*Direction:* Preflight the FluidAudio cache; under regulated or NDA fail the job with a 'download speech models first' notice instead of fetching.

**G013. Inspector says a blank rule matches 'Any meeting'; the matcher says it matches nothing**

`daemon/Sources/MeetingPipe/WorkflowInspectorPresentation.swift:152`. Lens: security. Outcome: partially confirmed. Backlog: New. No task covers the blank-rule mismatch. UX33 (done) introduced the 'Any meeting' copy with a comment that a blank rule matches everything. The regex half (no validation, silent never-match) is already open as UX88.

A workflow whose rules are all blank reads 'Any meeting' in the inspector but scores 0 in WorkflowMatcher, so its calls fall to the default workflow (an auto-consented app skips the prompt chip). The regex half is a separate gap: the editor never validates title_regex and an uncompilable one silently never matches, but the pane then shows the regex text, not 'Any meeting'.

*Scenario:* An NDA workflow has one blank or mistyped-regex rule. Its pane reads 'Any meeting' and 'NDA mode, so nothing leaves this Mac'. An auto-consented call scores 0, falls to the default workflow, and is summarized and published by whatever cloud route that default uses.

*Direction:* Derive the Trigger row from WorkflowMatcher's own scoring, drop blank rules at save, and reject or flag a title regex that does not compile.

**G007. Blind-clear of a latched mute is pinned with no regulated-gate variant and contradicts the probe's privacy latch**

`daemon/Tests/MeetingPipeTests/MeetingAXWindowWatcherTests.swift:407`. Lens: security. Outcome: partially confirmed. Backlog: New. MIC6 (done) made the blind clear mode-agnostic as the regulated gate's rescue (ADR 0016) and accepted only a call-setup leak; MIC10 gated its sibling closures on capturesLosslessly. This mid-call leak and the missing host-level test are documented nowhere.

The fail-open is real, but it lives in the host wiring rather than in the test. MeetingSessionController.swift:1465-1467 calls micGate.clearAxMute() on a 3-poll blind streak without the capturesLosslessly gate that its two sibling closures use (:1471-1481, :1486-1488). Under the regulated/NDA gate a genuine app-mute whose log reading is older than 5 s (or any non-Teams mute, where no log exists) is therefore dropped, MicGate.decide falls through to VAD/RMS, and speech is written to the mic file until the watcher's next confident read re-latches `.muted` (lastEmitted is reset to nil at the clear, so the next confident read re-emits). The primary probe does not re-assert it, because its lastEvent still equals the muted event. The pinned test (MeetingAXWindowWatcherTests:389-414) covers a mode-agnostic watcher callback and would survive a host-side gate unchanged; what is missing is any host-level test of engageMicGate wiring (none exists in daemon/Tests). The behaviour is not an accidental regression: ADR 0016 names the MIC6 rescue as the regulated gate's only reliability lever against the incident-proven opposite failure (owner's voice zeroed for a whole call), so this is an undocumented privacy cost and an inconsistency with MIC10's "privacy still wins under the regulated gate" scope guards, needing an owner decision. Bounds: audio stays on the machine (no egress), and the leak lasts roughly the blind streak minus 3 s plus up to the cache's 10 s backstop. The "Teams goes compact" branch is weaker than stated, since scopeToLiveControl now anchors on the call panel; the AX blackout branch is solid and field-observed (mute_state_cleared_blind with blind_polls 3 during a blackout). It also reopens the exact "Mic is not available" leak the probe latch was built to close, since the watcher's cache reads the same button as unknown.

*Scenario:* Regulated mode, user muted in Teams over 5 s ago for an aside. The AX tree blanks for 3 s (END9 measured 1 to 65 s) or Teams goes compact: the cached button reads unknown, the latch clears, VAD hears speech, the aside is written to disk.

*Direction:* Gate the blind clear on capturesLosslessly like the other two discredits and add a watcher-to-MicGate test under the regulated gate.

**F095. Unknown or misplaced config keys are silently dropped, including the regulated-mode switch**

`pipeline/src/mp/config.py:247`. Lens: security. Outcome: confirmed. Backlog: New. ADR 0007 and ARCH9 accept silent extra=ignore for legacy keys in the sections that declare it; nothing covers Modes, Summarization, OutputCfg or Config, doctor validation or sink names. SEC21 is workflow files only, UX94 parse failures.

`Modes`, `Summarization`, `OutputCfg` and the top-level `Config` declare no `model_config`, so pydantic's default `extra='ignore'` applies: an unknown or misplaced key is dropped without a word and the default wins. `output.sinks` is a free `list[str]`; a misspelt sink only raises `PublisherBuildError` after the summary has been paid for. Doctor validates neither.

*Scenario:* Owner appends `modes.regulated_mode = true` (the README's spelling) to the end of config.toml. TOML nests it under the last table (`mcp.modes...`, checked with tomllib); the model ignores it, regulated mode stays off, and the next meeting is summarized by the cloud backend.

*Direction:* Reject or loudly warn on unknown keys for modes, summarization, output and the top level, and type sink names as a Literal validated at load.

**F078. Map-reduce reduce step drops the system prompt: no injection fence, no workflow directives**

`pipeline/src/mp/summarize_local.py:755`. Lens: security. Outcome: partially confirmed. Backlog: New. Fence half was verified and dropped by the 2026-11-12 security review (inputs are schema-validated outputs of fenced map calls). No task covers the lost workflow directives; gotchas.md only records that the reduce never sees the caller's system prompt.

The reduce call's system prompt is `_reduce_instructions()` plus the schema block (plus only LANG1's suffix on a repair), so UNTRUSTED_GUIDANCE, team context, the extra-section directive, and the prior-meeting and flagged-moment instructions never reach the merge, and partial summaries enter the user turn unfenced. Whether extra sections are actually dropped is model-dependent and unmeasured: partials and SUMMARY_TOOL both carry `extra_sections`, though the schema text tells the model to leave them empty unless the system prompt requests them. The injection is second-order and limited to schema-validated summary text; the model has no tools.

*Scenario:* Any long meeting on the local backend, which includes every long regulated or NDA meeting: an instruction spoken in the meeting survives into a map partial and reaches the reduce call as bare text, and the workflow's requested extra sections are omitted from the merged summary.

*Direction:* Fence the partials with `wrap_untrusted`, append UNTRUSTED_GUIDANCE, and carry the caller's extra-section, context and flagged-moment directives into the reduce system prompt.

**F129. 'Every Swift-Python surface is pinned by a shared fixture' covers 10 of roughly 30 cross-tree contracts**

`CONVENTIONS.md:563`. Lens: tests. Outcome: partially confirmed. Backlog: New. No task flags the CONVENTIONS.md:563 overclaim. STOR5 deliberately kept RestorePlan out of the CI4 fixtures (accepted there); the backend-clamp mirror is adjacent to ARCH11 and ARCH14. Scope a filing to the wording, not new fixtures.

CONVENTIONS.md:563 overclaims. At least the RestorePlan JSON (Python writes, Swift strict-decodes) and the effective-backend clamp mirror (RegulatedMode.effectiveBackend vs mp.config.effective_backend) have neither a shared fixture nor a source-reading fence. The gap is smaller than '10 of roughly 30' because several other cross-tree surfaces are pinned by Swift tests that read Python source (for example ConfigStoreTests) and by scripts/truth_fences.py. A RestorePlan key rename fails closed: restorePreview returns 'produced no readable plan', so the in-app restore cannot proceed, and nothing is corrupted.

*Scenario:* Python renames `keeps_config_toml` in mp.restore's plan and updates test_backup_restore.py. Both suites pass; Swift's RestorePlan decode then fails at runtime, so Preferences cannot preview the app's most destructive action.

*Direction:* Generate fixtures for every Python-written payload Swift decodes (restore plan, ask, clusters, MCP status) in gen_contract_fixtures.py and add a contract inventory that the truth fences check.

### Known, open (46)

**F071. Batch run state lives in a view the detail pane rebuilds, and the trash loop can never show progress or honour Stop**

`daemon/Sources/MeetingPipe/BatchActionsPane.swift:16`. Lens: antipattern. Outcome: confirmed. Backlog: Known, open (STOR7). STOR7's 2026-10-25 amendment (new) covers the @MainActor trash loop whose progress and Stop never render. The @State lifetime half (pane rebuilt, orphaned Tasks, unreachable Stop) is in no task; amend STOR7 rather than refile.

state and cancelRequested are @State on a pane that detailPane removes when the selection drops to one row, while the unstructured Tasks keep looping. A re-created pane starts idle and its Stop cannot reach the old loop. runSoftDelete is @MainActor with no await, so its progress strip and Stop never render.

*Scenario:* Confirm 'Re-summarize 20 meetings', then click one row to read it. The pane is gone, the engine calls continue and no Stop exists; cancelling a row only advances to the next stem. Trashing 50 meetings blocks main, listing the whole directory per stem.

*Direction:* Move batch runs into a root-owned model like AskModel (one run, cancellable from anywhere) and run the trash and export file work off main with real suspension points.

**F063. Vocabulary editor overwrites a malformed or unreadable glossary.toml with an empty document on close**

`daemon/Sources/MeetingPipe/GlossaryStore.swift:93`. Lens: antipattern. Outcome: confirmed. Backlog: Known, open (STOR9). STOR9 (new, P2) describes exactly this: GlossaryStore loads an unparseable file as empty and VocabularyEditor's flush overwrites it; SavedSearchStore, WorkflowCorrectionStore and ConsentStore likewise. Scope item 4 makes glossary follow ARCH9's refuse-to-save rule.

GlossaryStore loads an unreadable or unparseable file as an empty document and VocabularyEditor calls flush() on disappear, which saves unconditionally: the opposite of ConfigStore's refuse-to-save rule. SavedSearchStore, WorkflowCorrectionStore and ConsentStore likewise decode a bad file to empty and rewrite the whole file on the next mutation.

*Scenario:* The owner hand-edits glossary.toml to set fuzzy max_distance, a file-only knob, and leaves a syntax error. Opening Preferences Pipeline and leaving it writes back an empty [terms] table: every global and per-workflow term is gone with no warning or backup.

*Direction:* Carry a parse-error state like ConfigStore: show it, refuse to save, and keep the original (or write a .bak) before any replacement; apply the same rule to the single-file JSON stores.

**F053. Keychain access is a synchronous, unbounded subprocess on the main thread, with secrets on argv**

`daemon/Sources/MeetingPipe/KeychainSecrets.swift:80`. Lens: antipattern. Outcome: partially confirmed. Backlog: Known, open (CONC5, CONC8, SEC23). CONC5 (new) bounds KeychainBackend.run and the launch-time reads; CONC8 (new) moves SecretsStore's three writes per save off main; SEC23 (new) writes only changed accounts and moves the token from argv to security -i stdin.

Every daemon Keychain access is a synchronous /usr/bin/security spawn with no timeout on the main thread: 4 reads in App.main, 3 in SecretsStore.init before the status item exists, and 3 writes or deletes per debounced save that re-send unchanged tokens on argv. This contradicts the repo's own no-Process-on-main rule and the Python twin's 10 s bound. The locked-keychain hang is a plausible but unverified OS behaviour, and if it occurs a system dialog would be on screen, so 'no sign why' is overstated. Argv visibility of a changed token is an acknowledged trade-off in the source.

*Scenario:* If the login keychain is locked or wants its password (auto-lock, changed login password), `security find-generic-password -w` would wait on a system dialog, so the daemon blocks in main() before the status item exists: no icon, no detection, no log line saying why.

*Direction:* Move Keychain reads and writes off main under a watchdog, write only changed accounts, and feed the secret through `security -i` on stdin.

**F049. MeetingSessionController is a god object: 1,980 lines, 29 mutable stored properties, about 14 responsibilities**

`daemon/Sources/MeetingPipe/MeetingSessionController.swift:22`. Lens: antipattern. Outcome: confirmed. Backlog: Known, open (ARCH7). ARCH7 (new, architecture review A1) covers the session spine as a god object, but it scopes the 26-member seam and moves more subsystems into the controller rather than splitting it. The file grew from 1,622 to 1,980 lines since filing.

MeetingSessionController: 1,980 lines, 56 methods, 31 stored properties (29 mutable), 26 distinct host members reached, about 14 responsibilities (verdict consumers, start, stop and its warnings, sidecars, prompt timeout, DET1, resume, idle backstop, MicGate, lifecycle builds, teardown hold, markers, off-record). Coordinator: 40 stored properties, 10 mutable, mostly composition.

*Scenario:* Each feature adds a cross-meeting flag with its own reset site. pendingWorkflowOverride is never reset on skip, endObservedDuringStart is only latched from .prompting, and the MicGate engage is skipped for source-less starts. Three findings in this audit are that one pattern.

*Direction:* Group per-meeting state into one value created at start and dropped at idle (plus one per-prompt value), so a reset cannot be forgotten; split the teardown hold and the PERF15 build orchestration into their own types.

**F075. Backup and digest schedule toggles shell out to launchctl on the main thread, drop the result, and never read launchd back**

`daemon/Sources/MeetingPipe/Preferences/PreferencesView+Storage.swift:416`. Lens: antipattern. Outcome: confirmed. Backlog: Known, open (CONC5, STOR10, HYG10). CONC5's amendment item 5 covers the binding setters running findMP, a plist write and unbounded launchctl on main; STOR10 covers the discarded bootstrap status and plist-only isInstalled; HYG10 lists the false UX67 rule.

Each Binding setter here (and the digest ones in the Pipeline pane) calls LaunchAgentScheduler.install or remove synchronously: findMP, a plist write, then bootout and bootstrap via Process.waitUntilExit with no watchdog, against daemon/CLAUDE.md's UX67 rule. bootstrap's exit status is discarded, install returns true, and isInstalled is never read, so the toggles render UserDefaults only.

*Scenario:* mp cannot be resolved, or bootstrap fails right after bootout: 'Automatic backup' stays on with no error while no agent is loaded. Each DatePicker step spawns two launchctl children on main; a slow launchctl freezes every window, including the HUD Stop button.

*Direction:* Run the scheduler off main through the watchdogged ProcessLaunchctl helper, check bootstrap's status, and render the toggle from plist/launchd state as LaunchAtLoginModel does.

**F108. Apple Intelligence summarizer is a second, narrower implementation of `mp.summarize`**

`daemon/Sources/MeetingPipe/Summarization/AppleIntelligenceSummarizer.swift:133`. Lens: antipattern. Outcome: confirmed. Backlog: Known, open (ARCH11, PIPE30, AUTO8). ARCH11 (new) calls it a second summarizer missing extra sections and prior context; PIPE30 owns the plain write; AUTO8 notes the unscrubbed owner field. Flagged moments and overlays are unnamed in ARCH11.

The Swift summarizer is fed only the raw `<stem>.md`, team context and language (`instructions(teamContext:summaryLanguage:)`). Unlike `mp.summarize` it never receives workflow extra sections, flagged moments, prior-meeting context or, on a candidate re-run, the two overlays, and its `summary.json` is written with a plain `data.write`, bypassing pydantic's scrub and limits.

*Scenario:* A workflow defines an extra section 'Risks' and the user flags two moments. On apple_intelligence the summary has no Risks section and ignores the flags, with no warning; the same meeting on local or anthropic honours both.

*Direction:* Have Python emit the composed model input (overlaid transcript, flagged block, extra-section spec) for the daemon to consume, or surface per-backend unsupported features in the workflow editor.

**F091. Notion upsert identity lives only in the local sidecar, with no lookup or recovery**

`pipeline/src/mp/publish_notion.py:97`. Lens: antipattern. Outcome: partially confirmed. Backlog: Known, open (PIPE23). PIPE23 (new, P2) covers sidecar-only identity, duplicate on a post-commit create failure, the deleted-page dead end and the non-atomic sidecar. Not owned by PIPE23 or HYG10: the false deterministic-slug line in ARCHITECTURE.md and pipeline/CLAUDE.md.

Notion create-versus-update identity lives only in <stem>.notion.json; no stem key, lookup or slug exists, so the 'deterministic slug' statement in pipeline/CLAUDE.md and ARCHITECTURE.md is false. The app's own library move and backup/restore preserve the sidecar, so a duplicate page needs a hand-removed or partially copied sidecar, or a failure between the POST and the non-atomic sidecar write. Any 4xx on the update (for example a page deleted in Notion; API behaviour inferred, not verifiable from the repo) fails every later publish of that meeting, with no fallback to create and no in-app way to clear the sidecar.

*Scenario:* The sidecar is lost or corrupted (library moved, partial restore): the next publish creates a second page. If the owner trashes the page in Notion and the PATCH is rejected (API behaviour inferred), every later publish of that meeting fails until the sidecar is deleted by hand.

*Direction:* Write the stem into a page property and query the database for it when the sidecar is absent; on a not-found or archived response fall back to create.

**F125. The Swift Apple summarizer is a second summarize stage that skips most of the pipeline contract**

`daemon/Sources/MeetingPipe/Summarization/AppleIntelligenceSummarizer.swift:133`. Lens: architecture. Outcome: confirmed. Backlog: Known, open (ARCH11, PIPE30). ARCH11 (new) lists missing extra sections, prior context, evidence and language repair. PIPE30 (new) owns the non-atomic, default-permission write, although SEC14 (done) claimed Swift summary writes land 0600. Overlays and flagged moments are unnamed.

The in-daemon summarizer reads raw `<stem>.md` with its own prompt and schema. It never applies the speaker-label or transcript-correction overlays, the flagged-moments block, workflow extra sections, prior-meeting context, language repair or evidence checks that summarize.py applies, and writes summary.json non-atomically with default permissions (line 468) against PIPE8 and SEC14.

*Scenario:* Workflow with 'Extra summary sections' on the Apple backend; user flags moments with the hotkey and later renames speakers. The first summary has no extra sections and ignores the flags; the Apple preview re-run still shows the old speaker labels.

*Direction:* Have Python prepare one composed input (overlaid transcript, flags, sections) for Swift to summarize, and validate and write the Apple result through an `mp` verb so one contract owns summary.json.

**G034. Regulated mode replaces every sink with Filesystem while its own copy and a sibling rule say only Notion is dropped**

`pipeline/src/mp/workflow.py:239`. Lens: architecture. Outcome: confirmed. Backlog: Known, open (SEC18). SEC18 (new) names the two-path disagreement and scopes one sink rule on both, asking the owner about LAN. UX45 (owner-verify) pinned the divergence and corrected four strings, but not RegulatedMode.swift's copy or the config.py comment.

Every recording made under regulated mode carries a sidecar, so this overlay replaces its sinks with Filesystem alone. RegulatedMode.swift L98 tells the owner 'Two things happen while it is on' (no Notion upload, on-device summary); config.py L309 says LAN is deliberately not clamped; test_publish_router.py L208 pins Obsidian surviving. One switch, two sink rules.

*Scenario:* An Obsidian-only workflow with regulated mode on: summaries stop reaching the vault, and summary, transcript and actions files appear in ~/Documents/Meetings/published (the filesystem default, config.py L217), a folder the user never ticked and iCloud Documents can sync.

*Direction:* Choose one rule, apply it in effective_sinks only, mirror it in Swift beside effectiveBackend, and build the Preferences and tutorial copy from that mirror.

**F021. The app actually running on this Mac is a 2026-09-11 binary driving HEAD Python, and nothing in the product can tell**

`scripts/install.sh:220`. Lens: architecture. Outcome: partially confirmed. Backlog: Known, open (DIST6). DIST6 (new) covers the missing build identity: fixed 0.1.0/1, stale plist after rebuild.sh, cdhash-only marker, unrecorded mp tier. DIST4 (done) removed the editable venv in code; this Mac was never reinstalled. Editable-venv detection is not in DIST6.

The install on this Mac is still pre-DIST4: an 11 Sep 2026 daemon binary (running since 30 Oct) whose mp launcher is an editable install importing the main checkout's pipeline/src, so every committed or uncommitted Python change in that checkout runs against real meetings under a two-month-old daemon (94 commits behind, 48 touching daemon/Sources, 19 touching pipeline/src). No runtime check catches it: both doctors and PipelineLauncher.findMP accept an editable or stale venv, versions are fixed at 0.1.0 / 1 on both sides, rebuild.sh never rewrites Info.plist, and the one build marker (RebuildTagger's cdhash event) is never compared with the pipeline or surfaced. The skew is transitional, not permanent: install.sh and rebuild.sh now sync the venv and the binary together, so a single run clears it. No concrete contract break was found in the drift examined: no CLI flag was removed, egress_guard.py and entry.py are unchanged and the sidecar change (SEC25) only fails closed, and the new publish_state "local" falls into benign default branches in the September daemon. The residual harm is a recoverable pipeline failure or misbehaviour from a work-in-progress Python edit, plus the owner having no in-product signal that two months of daemon fixes are not running.

*Scenario:* Cross-tree commits since September (WF10, SEC25, PIPE22, the last landing during this audit) are live on the Python side only. The old daemon runs today's mp against contracts it predates, and any uncommitted pipeline edit in the main checkout processes real meetings.

*Direction:* Stamp the git SHA into the app and the wheel, compare them when the daemon spawns mp, and add a doctor probe that fails on an editable or mismatched venv.

**F136. Deleting a meeting leaves its summary in the corrections corpus and its transcript in the ask index**

`daemon/Sources/MeetingPipe/Library/MeetingLibraryService.swift:1129`. Lens: data. Outcome: confirmed. Backlog: Known, open (STOR7). STOR7 (new, P2) names both residues: corrections/<stem>.json is never deleted and ai2-index keeps a deleted stem's chunks until the next refresh. Scope item 2 trashes the corrections file and prunes the index.

`softDeleteMeeting` trashes stem-prefixed files in `raw/`, the kept original and the peaks cache, nothing else. `corrections/<stem>.json` (full original and corrected summary, also a backup root) is only ever removed by Corrections revert, and the Python `ai2-index` keeps the transcript chunks until a later `mp ask` or `mcp-serve` refresh.

*Scenario:* User deletes a sensitive meeting and empties the Trash. Its graded summary still sits in Application Support and enters the next backup; its transcript chunks stay in `~/Library/Caches/meeting-pipe/ai2-index` for as long as Ask is not run again.

*Direction:* Cascade the delete into the correction record and drop the stem from the embedding index (or invalidate the index) inside softDeleteMeeting.

**F052. No-ffmpeg fallback promotes a mic-only final as success; the system channel is never merged**

`daemon/Sources/MeetingPipe/RecordingPostProcessor.swift:331`. Lens: data. Outcome: confirmed. Backlog: Known, open (DEP2). DEP2 (new, P2) names the mic-only final without ffmpeg and removes the fallback via a native merge. The silent success and the unreachable later merge are unnamed. REC1 (done) only kept system.wav, which holds.

With both channels captured and no ffmpeg, produceFinal renames mic.wav to the final and returns true (line 346) with no recordfail breadcrumb. The promised later merge cannot happen: recoverOrphan returns nil whenever <stem>.wav exists (line 195), and the orphan scan only lists stems without a final.

*Scenario:* No ffmpeg at MEETINGPIPE_FFMPEG, on PATH, in the bundle, or at the three fallback paths (Homebrew ffmpeg removed on a build without the bundled binary). Each later meeting is finalized mic-only and published as a success with the far side missing; system.wav stays unmerged.

*Direction:* Return false with a recordfail breadcrumb and keep both intermediates so the sweep retries once ffmpeg exists, or merge natively.

**G040. One undecodable saved folder empties the whole set, and the next edit persists the loss**

`daemon/Sources/MeetingPipe/SavedSearchStore.swift:44`. Lens: data. Outcome: partially confirmed. Backlog: Known, open (STOR9). STOR9 (new, P2) names SavedSearchStore.load setting searches = [] on a decode failure and the next persist writing the reduced list. Its fix quarantines the file to .corrupt-<ts>; it does not propose per-entry lenient decoding.

One undecodable entry (unknown base or status token, or a missing non-optional key) makes load() leave the set empty, and the next upsert of a new folder rewrites the file with only that folder. Rename, delete and updateCriteria cannot persist the loss: each guards on finding the id in the now-empty set and returns before persist(). The trigger needs a hand edit or build skew; no on-disk token has changed since UX24 (11399676).

*Scenario:* saved_searches.json holds eight folders and one carries status 'queued' from a hand edit or another build. On launch the rail shows no smart folders; saving one new folder rewrites the file with that single entry and the other seven are gone.

*Direction:* Decode element by element, skipping and logging bad entries, and refuse to persist (or keep a .bak) while the last load failed.

**F061. Speaker-label and correction sidecars: an unreadable file reads as empty and the read-modify-write replaces or deletes it**

`daemon/Sources/MeetingPipe/SpeakerLabelStore.swift:81`. Lens: data. Outcome: confirmed. Backlog: Known, open (STOR9). STOR9 (new, P2) names the same speaker-label and transcript-correction stores and the roster rename carry reading an unreadable file as empty and writing over it; it specs a typed load with quarantine or refusal.

read() returns .empty for a missing, unreadable or malformed sidecar, and every setter writes back read() plus one change. A failed read therefore replaces all prior names and reassignments with the one new entry, and removeLabel deletes the file. TranscriptCorrectionStore.upsert/remove and RosterRename.carry share the shape. Write-after-failed-read is inferred.

*Scenario:* A meeting carries 40 per-line speaker reassignments. Its speaker_labels.json is briefly unreadable or was hand-edited into invalid JSON. Naming one more speaker writes a sidecar holding only that name; the other entries are gone and no error is shown.

*Direction:* Give both stores a three-state read (absent, loaded, unreadable) and throw from every mutator when the file exists but did not parse.

**F121. Notion republish rewrites Date and Status on every update and no test pins either value**

`pipeline/tests/test_publish_notion.py:557`. Lens: data. Outcome: confirmed. Backlog: Known, open (PIPE23). PIPE23 (new, P2) names it: _properties writes Date as today's UTC date and Status as default_status on every update. Its scope drops both from updates and its acceptance adds the missing update-body test.

The update-path test checks optional properties only. _update_page (publish_notion.py:323) PATCHes _properties(), which always writes Date = today in UTC and Status = notion.default_status (lines 375-381), so each republish re-dates the page and resets a Status edited in Notion. Other tests assert key names only; upsert identity is the local sidecar alone.

*Scenario:* The user marks a page Reviewed in Notion, then clicks Regenerate or Republish a week later: Date becomes today and Status returns to the default. A meeting first published after UTC midnight is dated the following day.

*Direction:* Derive Date from the meeting stem, leave Status and Date out of the update PATCH, and assert both values in the create and update tests.

**F047. Scheduled-agent launchctl calls are unbounded, run on the main thread, and report success whatever bootstrap returned**

`daemon/Sources/MeetingPipe/LaunchAgentScheduler.swift:125`. Lens: performance. Outcome: confirmed. Backlog: Known, open (CONC5, STOR10). CONC5 (new) bounds LaunchAgentScheduler.launchctl, and its amendment item 5 takes the binding-setter applies off main; STOR10 (new) covers the discarded bootstrap result still logging backup_schedule_installed. HYG10 records the false off-main rule text.

launchctl() blocks on an unbounded waitUntilExit, and install() runs bootout then bootstrap through it, discards the bootstrap result and returns true (lines 102-104). Its callers are SwiftUI Binding setters in Preferences, on main. LaunchAtLoginService documents and bounds this freeze class; here a failed bootstrap is still logged as backup_schedule_installed.

*Scenario:* User toggles scheduled backup while launchd is busy (the rebuild case LaunchAtLoginService describes): main blocks inside launchctl and the hotkeys go dead. If bootstrap fails instead, the toggle shows on and no backup runs until a later login loads the plist.

*Direction:* Route these through the watchdogged ProcessLaunchctl runner on a background queue and return the bootstrap status so the Preferences row and the event log can report a refusal. Callers: PreferencesView+Storage.swift:408, PreferencesView+Pipeline.swift:375.

**F038. Idle discovery walk gate is effectively always open: three uncached full-tree AX walks per scan**

`daemon/Sources/MeetingPipe/MeetingSourceScanner.swift:407`. Lens: performance. Outcome: confirmed. Backlog: Known, open (PERF6). PERF6, shipped 2026-07-11 (980661b7), was reopened 2026-10-26 (status new, e8bbe87f) for exactly this: DET5's lone-native admission and the permissive Teams title reopen the gate, and three separate uncached walks run per scan.

The PERF6 walk gate is open whenever one native meeting app runs, and Teams' permissive title recognizer matches ordinary chat windows anyway. Every idle scan then runs three uncached full-tree walks (toolbar, Leave, mute; up to 4000 nodes per window, 2 to 5 AX IPCs per node) on each 3 to 12 s poll and each browser or meeting-app activation.

*Scenario:* Teams idles in the background all day. Each poll and each Cmd+Tab to Chrome walks every Teams window three times. The code's own figure for a comparable handle-build walk is about half a second on a healthy Teams (not re-measured here), served on Teams' main thread.

*Direction:* Cache per-window walk results keyed on the window set and subroles, as MuteControlCache already does for the in-call poll, and stop treating isLoneNative as a walk admission for an idle app.

**F058. After an in-app library move the Library keeps scanning the old folder until relaunch**

`daemon/Sources/MeetingPipe/Coordinator.swift:150`. Lens: quality. Outcome: confirmed. Backlog: Known, open (UX89). UX89 (new, P2) names it: executeMove sets outputDirPath but MeetingStore keeps the init-time directory until restart; scope item 2 re-roots or relaunches. The FTS wipe and duration-cache prune on reopen are not in its text.

The Library's MeetingStore directory is fixed at Coordinator init, while executeMove only assigns configStore.outputDirPath. The Library keeps listing the pre-move path; on reopen attachWatcher recreates that folder, the empty listing succeeds, the reconciler deletes every FTS row and the duration cache is pruned and persisted empty. No relaunch is requested.

*Scenario:* The owner follows the cloud-sync warning and moves the library. The Library window now shows no meetings and an empty raw/ reappears inside the synced folder. New recordings land in the new path but stay invisible in the Library until the app is relaunched.

*Direction:* Make MeetingStore, PrepCardStore and the indexer follow ConfigStore's output_dir (rebuild on change), or make a relaunch the last step of the move.

**F039. Mic-in-use tier samples the input device that was default at daemon launch, forever**

`daemon/Sources/MeetingPipe/MeetingDiscoveryWatcher.swift:164`. Lens: quality. Outcome: partially confirmed. Backlog: Known, open (DET10). DET10 (partial) names the bind-once mic device as a third candidate cause ('Bound once, never rebound') and scopes a re-resolve on default-input change via CoreAudioHALBus; both the fix and the owner-run probe are still owed.

Mic-busy sampling is pinned to the AVCaptureDevice that was default at daemon start for the whole process lifetime, with no re-resolve on default-input change. Whether that pin is what suppresses the DET1 catch-all prompt is unestablished, because the input has reportedly never read true at all (two other candidate causes are recorded and unresolved). The pin is a third candidate cause, not a proven one.

*Scenario:* Daemon launches at login with the built-in mic as default. User later connects AirPods and takes a FaceTime or unlisted-domain browser call. The pinned device stays idle, no mic_busy span opens, and the catch-all prompt README line 665 promises never appears.

*Direction:* Re-resolve the device on default-input changes, or sample kAudioDevicePropertyDeviceIsRunningSomewhere on the current default each tick; then prove the tier fires once in a live call.

**F146. Menu-bar failed count ignores publish failures that the Library marks failed**

`daemon/Sources/MeetingPipe/MeetingStore.swift:1169`. Lens: quality. Outcome: confirmed. Backlog: Known, open (UX90). UX90 (new) is this defect verbatim: unrecoveredFailureStems skips any stem with a summary, the doc comment claims agreement, and MeetingStoreTests pins the skip. ARCH20 (new) later routes the badge through the same decide.

unrecoveredFailureStems, the only source of the status-bar failed count (via MeetingLibraryService.failedMeetingCount), skips every stem that has a summary. buildMeeting (lines 850-853) marks such a stem .failed when its error sidecar is publish-stage or carries newer structured metadata. The doc comment at line 1129 claims the two agree; MeetingStoreTests line 570 pins the divergence.

*Scenario:* Notion token expires, mp run-all exits 3, and SinkDispatcher writes a publish-stage error.json beside the summary. The Library row reads Failed, but the menu-bar count stays at zero, so with the Library closed nothing durable says the meeting landed nowhere.

*Direction:* Derive the badge from the same precedence as buildMeeting (read the sidecar stage, or share one pure decide function between the two).

**F040. Meeting-title extraction has drifted from the recognizer, so title-keyed workflow routing silently fails**

`daemon/Sources/MeetingPipe/MeetingTitleResolver.swift:81`. Lens: quality. Outcome: confirmed. Backlog: Known, open (CAL3, SEC21, VALOWN1). CAL3 (deferred) names extractTeamsNativeTitle's single pattern and 3% title coverage, with the fix gated on VALOWN1; SEC21 (new) covers title rules scoring 0 on a nil title. The browser first-match branch is not filed anywhere.

The Teams extractor accepts only 'Meeting in/with X | Microsoft Teams', while the scanner (line 615) says Teams titles are now just the topic. Topic-only and 'Call with' titles resolve nil, so WorkflowMatcher title-regex rules score 0. The browser branch (line 40) takes the first brand-matching title across all windows, not the meeting tab's.

*Scenario:* A workflow with NDA mode is selected by title regex 'Client X'. A scheduled Teams meeting titled 'Client X sync | Microsoft Teams' resolves no title, the rule cannot match, and the meeting is processed under the default workflow's backend and publish sink.

*Direction:* Derive the title from the same recognizer the scanner uses (strip the brand suffix and chrome names), take it from the window that matched, and replace the 21 hand-seeded fixture titles with captured ones.

**F006. notifyError drops its message: every recorder failure is announced as 'Processing could not finish'**

`daemon/Sources/MeetingPipe/Notifier.swift:191`. Lens: quality. Outcome: confirmed. Backlog: Known, open (UX93). UX93 (new, P2) is this defect: notifyError takes no operation, so all 20 callers get the 'Processing could not finish' title. Scope: a required operation per call site and the message as the body.

notifyError(message) wraps the text in FailurePresentation(diagnostics:) and notifyFailure posts only failure.title with a fixed body. An unclassified message gets the .processing default title, so a failed recording start, missing mic permission, write-failure stop, low-space stop and failed finalize all read 'Processing could not finish / Review failure details.' The real text needs a click.

*Scenario:* The engine start fails on a wedged Bluetooth input as a meeting begins. No HUD appears and the banner says processing could not finish. The user takes it for a post-processing hiccup and the meeting goes unrecorded. After a relaunch the click opens an empty details dialog.

*Direction:* Put the message in the banner body and give recorder errors their own operation and title; keep a durable menu row for a failed start or forced stop, as pipeline failures already have. See Notifier.swift:201-202 and FailurePresentation.swift:24, 90, 142.

**F143. runMP shares the stderr tail across queues with no lock and never drains the pipes at exit**

`daemon/Sources/MeetingPipe/PipelineLauncher.swift:1464`. Lens: quality. Outcome: confirmed. Backlog: Known, open (CONC7). CONC7 (new, P2) describes exactly this: runMP's unlocked stderrTail shared across two queues and handlers cleared in terminationHandler with no final drain. Same defect as F055.

`stderrTail` is a captured `var Data` appended on the pipe's readability queue and read by `terminationHandler` on another queue (line 1514), right after the handlers are set to nil. There is no lock and no final `readDataToEndOfFile`, so bytes still in the pipe are dropped and an in-flight append races the read.

*Scenario:* `mp` writes its ERROR line and exits. The termination handler runs before the last chunk is delivered, or while it is being appended: the failure sidecar and `pipeline.log` lose the reason, or the concurrent `Data` mutation corrupts memory in the daemon.

*Direction:* After nil-ing the handlers, read both pipes to EOF in the termination handler and guard the tail with a lock (or confine all three closures to one serial queue).

**F055. Termination handler drops undrained pipe output and reads stderrTail without synchronization**

`daemon/Sources/MeetingPipe/PipelineLauncher.swift:1490`. Lens: quality. Outcome: confirmed. Backlog: Known, open (CONC7). CONC7 (new, P2) covers runMP and DoctorRunner clearing readabilityHandlers with no final drain, plus the unlocked stderrTail, citing ModelDownloadSupervisor as the correct shape. Same defect as F143.

The termination handler detaches both readability handlers without reading what is still buffered, then reads stderrTail, a captured var the stderr handler mutates on another queue with no lock. ModelDownloadSupervisor.handleTermination flushes availableData before detaching; this path and DoctorRunner.swift:129 do not.

*Scenario:* mp logs its fatal error and exits; the exit notification beats the stderr read source. The last lines reach neither pipeline.log nor the 4 KB tail, so the failure sidecar's reason omits the real error. In the Preferences doctor the closing verdict lines vanish.

*Direction:* After exit, drain both handles to EOF (bounded) before detaching, and guard stderrTail with a lock.

**F037. HAL voice-activity probe never rebinds after a default-input change, latching a stale VAD value**

`daemon/Sources/MeetingPipeCore/MicGate/Probes/HALVoiceActivityProbe.swift:69`. Lens: quality. Outcome: partially confirmed. Backlog: Known, open (DET10). DET10's 2026-10-25 amendment names this exact gap (VAD probe binds once while HALSystemMuteProbe rebinds) and adds rebind acceptance independent of its probe verdict. CONC9 (done) only confined the probe's threading, no rebind claim.

HALVoiceActivityProbe binds to the default input once per MicGate.start (call site MeetingSessionController.swift:1444, not 1418) and never rebinds or re-samples enablement. A stale true latch needs (a) VAD .supported at start, which requires another process to have enabled the bit since the probe never writes it, and (b) removal of that device while VAD reads true with no final HAL delivery. A switch that leaves the old device attached keeps tracking the old device, whose state reads 0 once its input stops. When latched, IdleStopBackstop never counts silence while unmuted; mute discrediting applies in capture-first mode only, after a 4 s dwell, and for Teams the clear is refused while a log reading is fresh.

*Scenario:* User pulls a USB headset mid-sentence with VAD active. halVad stays true: decide() returns hot(vad_active) whenever not muted, so IdleStopBackstop never counts silence and a forgotten recording never auto-stops, and the VAD-contradiction path keeps discrediting real mutes.

*Direction:* Subscribe to kAudioHardwarePropertyDefaultInputDevice as HALSystemMuteProbe does; on change rebind, re-read the enable bit and reset halVad to nil.

**F090. Local sinks skip on a content hash without checking where, or whether, the note exists**

`pipeline/src/mp/publish_obsidian.py:124`. Lens: quality. Outcome: confirmed. Backlog: Known, open (PIPE31). PIPE31 covers Obsidian only: reuse the recorded note_path and rewrite when the recorded note is gone. Filesystem and LAN sinks, and an unchanged hash after the vault or output dir moved, are unowned; PIPE23 calls them idempotent by path.

The Obsidian, filesystem and LAN sinks return `idempotent: True` whenever the sidecar hash matches. The hash covers rendered content only: the configured vault, folder or output directory and the existence of the target file are never compared, although the sidecar records the path. The skip reports the old path as the landing URL.

*Scenario:* Owner moves the vault, changes `filesystem.output_dir`, or deletes the published note, then republishes. Nothing is written (the filesystem sink even creates the new empty directory first), the run reports success, and the Open link points at the old or missing file.

*Direction:* Skip only when the recorded target equals the freshly computed target and that file still exists.

**F080. A client's close() kills the model server another mp process is using**

`pipeline/src/mp/summarize_local.py:877`. Lens: quality. Outcome: confirmed. Backlog: Known, open (LOCAL21). LOCAL21 (new) owns the two-owner class. PIPE22 (done) added the owner_pid re-stamp for the reaper and its amendment states outright that the spawner's close() still kills a server another mp is using, deferring that to LOCAL21.

`close()` always kills the server this client spawned. PIPE22 lets a second `mp` re-stamp the marker when it adopts a shared server, but only the reaper reads that; the spawner's close ignores it. The daemon runs `mp ask` in a separate slot that 'overlaps freely' with the pipeline lane (PipelineLauncher.swift:1231), so sharing is routine.

*Scenario:* Local backend, no warm preloader. An ask spawns the server; a meeting ends and run-all reuses it for a multi-minute summarize. The ask finishes first and SIGTERMs the server; run-all's in-flight request raises 'local backend HTTP error' and the meeting is marked failed.

*Direction:* Before killing, re-read the marker and leave the server up (transferring ownership) when another live mp has re-stamped it; additionally retry once through `_ensure_running` on a transport error.

**F102. install.sh reports the new build running without checking, and on the login-off path leaves the old one alive**

`scripts/install.sh:582`. Lens: quality. Outcome: confirmed. Backlog: Known, open (DIST5). DIST5 (new, P2) item 1 covers the unchecked bootstrap and kickstart and the false running line, via a shared relaunch helper. It leaves the UX42 login-off branch unchanged, so the surviving hand-started instance is outside its scope.

bootstrap and kickstart -k are both `|| true` and nothing checks for a process, yet the script prints that MeetingPipe is running; rebuild.sh:97-102 says kickstart after a cdhash change fails silently with status 0. On the launch-at-login-off branch (569-573) install.sh never stops a hand-started instance, which rebuild.sh:118 does.

*Scenario:* Login start is off and the app was opened from Finder. install.sh replaces the bundle and reports success, the old process keeps running, and opening the app as advised makes SingleInstanceGuard stand the newcomer down. The fix just installed never executes.

*Direction:* Move rebuild.sh's stop, bootstrap-retry and pgrep verification into one lib function that both scripts call.

**F104. FluidAudio is pinned exactly, but the model weights it downloads float on `main` with no hash**

`daemon/Package.swift:24`. Lens: security. Outcome: confirmed. Backlog: Known, open (DIST7, SEC27). DIST7 (new, P3) item 2 names the resolve/main fetch with no hash for FluidAudio models and the embedder; SEC27 (new, P1) owns the local LLM's floating main. The REGISTRY_URL override is in neither.

At the pinned revision the SDK builds model URLs as <base>/<repo>/resolve/main/<file>, its library sources use no SHA256 or CryptoKit, and base is taken from REGISTRY_URL or MODEL_REGISTRY_URL when set. The ASR, diarizer and embedding weights this pin exists to freeze are therefore neither pinned nor verified. No model revision is recorded for the MLX models either.

*Scenario:* Upstream republishes a model repository. The next fresh install, or a reinstall after uninstall.sh removed the FluidAudio cache, gets different weights: transcripts shift and stored voiceprints stop matching. A REGISTRY_URL already exported in the installing shell redirects install.sh's prefetch.

*Direction:* Record the expected revision and per-file sha256 for each model in the repo, verify after download, and unset registry override variables in install.sh.

**F056. Unparseable config.toml silently reverts the recordings folder to the default path while recording continues**

`daemon/Sources/MeetingPipe/ConfigStore.swift:294`. Lens: security. Outcome: confirmed. Backlog: Known, open (UX94). UX94 (new) covers the silent revert to defaults on a parse error, visible only in Preferences and os.Logger. ARCH9 (done) chose defaults plus regulated-on. Neither names output_dir, so the recordings-folder split is an unlisted consequence.

On a parse error apply() runs over an empty document: only regulatedMode fails closed, every other value takes its default, including output_dir. App.swift only logs it and nothing else consumes parseError except the Preferences pane, so recording continues into ~/Documents/Meetings/raw and the Library is built on that folder.

*Scenario:* The library was moved out of a synced Documents folder. A hand edit leaves a TOML syntax error. After the next launch meetings record into the default Documents path (uploaded if Desktop and Documents sync is on) and the Library shows that folder, not the real library.

*Direction:* Treat output_dir like regulated mode: while parseError is set refuse to start a recording (or keep a last-known-good path) and raise the error in the menu bar, not only in Preferences.

**F007. Title edit rewrites an unreadable summary.json or meta.json as a one-key file**

`daemon/Sources/MeetingPipe/MeetingDetailView+Header.swift:927`. Lens: security. Outcome: confirmed. Backlog: Known, open (ARCH10). ARCH10 (new) covers both branches: its body names writeTitle replacing an unparseable summary.json with one key, and the 2026-10-25 amendment adds the meta.json branch dropping workflow and regulated keys. SEC25 (done) does not list this writer.

writeTitle treats a target that exists but cannot be read or parsed as an empty dict and atomically writes it back with one key. Over summary.json that erases the summary; over meta.json it drops workflow_nda_mode and regulated_mode, so later reads see a valid sidecar with no privacy flag. Outside my file list; write-after-failed-read is inferred.

*Scenario:* An NDA meeting has no summary yet and its meta.json read fails transiently (the dataless iCloud file case SEC25 documents). Renaming the meeting writes only meeting_title. Retry then reads a loaded sidecar without NDA and uses the global backend and sinks.

*Direction:* Use the three-state MeetingMetaRead (and an equivalent for summary.json) and refuse to write when the target exists but did not load, as reassignWorkflow already does.

**F148. Recovery manifest reader treats unreadable as absent and defaults to the egressing mode**

`daemon/Sources/MeetingPipe/RecordingManifest.swift:70`. Lens: security. Outcome: confirmed. Backlog: Known, open (REC21). REC21 (new, P2) covers an unreadable manifest recovering as auto and specs a three-outcome read with quarantine. The mislabelled fail-closed token mapping that sends unknown tokens to auto is not named there.

The manifest exists so a crash-interrupted BYO or NDA meeting stays on-device, yet read() returns nil for an unreadable or malformed file exactly as for a missing one, and recovery then enqueues .auto with no sidecar. summaryMode(fromToken:) (line 89) is labelled 'Fail-closed mapping' while sending every unknown token to .auto, the cloud path.

*Scenario:* A BYO recording crashes and its <stem>.recovery.json cannot be read at relaunch (IO error on a synced folder, damaged content). Orphan recovery merges the audio and enqueues it as auto, so it is cloud-summarized and published.

*Direction:* Give the manifest the three-outcome reader MeetingMetaRead has: an unreadable manifest holds the recording instead of falling back to auto.

**F076. Secret fields: every debounced save rewrites all three Keychain items via synchronous /usr/bin/security on main, and a failed read becomes a delete**

`daemon/Sources/MeetingPipe/SecretsStore.swift:60`. Lens: security. Outcome: confirmed. Backlog: Known, open (SEC23, CONC8, CONC5). SEC23 owns rewriting all three items and, by its 2026-10-25 amendment, a failed read becoming a delete. CONC8 owns the main-thread save, CONC5 the missing timeout. All three are status new.

SettingsSecretField binds to SecretsStore, whose 0.5 s main-thread timer calls persist(): three sequential security subprocesses with waitUntilExit and no timeout. KeychainBackend.value returns nil for any non-zero exit, init maps nil to an empty string, and write() treats empty as remove, so editing one field deletes any token that merely failed to load.

*Scenario:* The daemon launches while the login keychain is locked or security errors, so all three fields load empty. The user retypes the Anthropic key; the save runs delete-generic-password for NOTION_TOKEN and OPENAI_API_KEY. Separately, a keychain prompt during any save blocks the main thread until answered.

*Direction:* Write only the account whose value changed, treat only 'item not found' as absent and never delete after an unknown read failure, and move the spawns off main with a watchdog.

**F068. Model-written summary and Ask text renders clickable links to any URL scheme, including the app's own action verbs**

`daemon/Sources/MeetingPipe/SummaryRenderedView.swift:353`. Lens: security. Outcome: confirmed. Backlog: Known, open (SEC30, AUTO7). SEC30 (new, P2) describes this exactly: summary, action task and Ask text link any scheme with no open-URL handler, including the second parser copy. AUTO7 (new) owns the unconfirmed app verbs.

Summary bullets, action tasks and Ask answers are parsed as inline markdown, which keeps [text] (url) links, and no openURL handler or scheme allowlist exists in the daemon. The registered meetingpipe:// scheme (AutomationCommand.parse) executes stop, record and ask?q= without confirmation. ActionItemRow.taskAttributed (line 509) is a second copy of the 'one' parser.

*Scenario:* Spoken or pasted content steers the model to emit [Open notes] (meetingpipe://stop), or an https link with summary text in its query. The reader sees only 'Open notes'; one click stops the live recording or sends the text to that host.

*Direction:* Install an OpenURLAction on the reading surfaces that allows only https (destination shown) and meetingpipe://open, and strip link attributes for every other scheme after parsing.

**F137. Backup destination is never checked for cloud sync, so zero-egress libraries can upload wholesale**

`pipeline/src/mp/backup.py:226`. Lens: security. Outcome: confirmed. Backlog: Known, open (SEC18, STOR8). SEC18 item 5 is the synced destination refusal for mp backup; STOR8 item 1 is the 0600 archive. STOR12 landed only STOR8 item 2. Neither scope adds the picker or doctor check the finding names.

The only destination guard is the unmounted `/Volumes` check. Neither `mp backup`, the Storage pane picker, nor doctor's `_synced_roots` runs cloud-sync detection on the backup destination, though a synced library is a FAIL under regulated/NDA. The archive (all audio, transcripts, voiceprint, roster) is also created at umask-default mode (`open(partial, "xb")`).

*Scenario:* Regulated-mode owner picks `~/Documents/Backups` (inside iCloud Desktop and Documents) and enables the daily schedule. Every NDA recording and transcript uploads inside the tarball; doctor and the Storage pane report nothing.

*Direction:* Run detect_sync_provider on the destination in run_backup and in the picker (FAIL under zero_egress, WARN otherwise) and create the archive 0600.

**F087. Egress guard authorizes on the URL host, so a configured HTTP proxy still receives 'loopback' requests**

`pipeline/src/mp/egress_guard.py:144`. Lens: security. Outcome: confirmed. Backlog: Known, open (SEC19). SEC19's 2026-11-12 amendment (security review finding 8) describes exactly this: the loopback client honours HTTP_PROXY and macOS proxies, the guard checks only request.url.host. Scope adds trust_env=False and refusing proxied transports. Status new, P2.

The patch tests `request.url.host` only. httpx 0.28.1 with `trust_env` on (how `summarize_local` builds its client) mounts HTTP_PROXY/ALL_PROXY, or the macOS system proxy via `urllib.request.getproxies()`, as `HTTPTransport(proxy=...)` with no loopback exemption unless NO_PROXY says so. The armed guard therefore passes requests for `http://127.0.0.1:<port>` to that proxy transport.

*Scenario:* Regulated Mac with a manual HTTP proxy. The local-model health probe goes to the proxy; if it answers 200 the transcript prompt is POSTed to it in cleartext (leg read, not run), otherwise the server never looks healthy and local summaries fail. This Mac has no system proxy today.

*Direction:* Add NO_PROXY=* to the arm-time environment and build loopback clients with trust_env=False; optionally reject proxy transports inside the wrapper.

**F084. MCP search_meetings keeps the first call's allowlist and corpus for the whole server session**

`pipeline/src/mp/mcp_serve.py:217`. Lens: security. Outcome: confirmed. Backlog: Known, open (AUTO6). AUTO6's 2026-10-25 amendment (performance review PYTHON-6) covers it: Library.index caches the first call's allowlist and search_meetings never re-checks. Added scope items 4 to 6 refresh on a fingerprint change under a lock. Status new, P2.

`Library.index` builds the index once with the first call's allowlist and afterwards returns the cached object, ignoring `allow`; `mcp_tools.search_meetings` never re-checks a hit's stem. The class docstring says the gate is resolved per call so a long-lived server cannot hold a stale allowlist. That is true of the other four tools only.

*Scenario:* An MCP client keeps `mp mcp-serve` running. After one search the owner reassigns a meeting to an NDA workflow (WF8 rewrites its sidecar). `get_meeting` now returns not_found, but `search_meetings` still returns its 900-char excerpts, and meetings recorded since never appear.

*Direction:* Call load_or_build on every search (an unchanged library is a stat pass) and drop hits whose stem is not in the current allowlist.

**F085. mp mcp-serve is not clamped by global regulated_mode**

`pipeline/src/mp/mcp_serve.py:427`. Lens: security. Outcome: confirmed. Backlog: Known, open (AUTO6). AUTO6 (status new, P2) is this defect: withheld_reason reads only per-meeting flags and main never checks zero_egress. Scope: allow_stems re-reads config per call, main refuses to start under regulated mode, status reports regulated_global.

The only start gate is `mcp.enabled`. `main` arms the guard but never consults `zero_egress(cfg)`, and `visibility.withheld_reason` reads per-meeting sidecar flags only; grep finds no Swift coupling either. With `modes.regulated_mode = true`, meetings recorded before the flag was set stay readable by the client's cloud model, though README says the mode promises nothing leaves the Mac.

*Scenario:* Owner enables MCP, later turns regulated mode on. Summaries pin on-device and Notion is dropped, but a connected assistant can still search every earlier unflagged meeting and pull 20,000-character transcript windows from it.

*Direction:* Refuse to serve, and say so in --status, when zero_egress(cfg) is true; or have visibility return nothing under global regulated mode.

**F132. MCP list_actions rows and meeting titles are returned outside the untrusted fence**

`pipeline/src/mp/mcp_tools.py:294`. Lens: security. Outcome: confirmed. Backlog: Known, open (AUTO8). AUTO8 (status new, P2; security review finding 6) covers list_actions returning task, owner and title raw, plus unfenced titles in the shared row builder and search hits, against the UNTRUSTED_NOTE description.

The module docstring says returned meeting text is fenced in every function, and `list_actions`' description in `mcp_serve.py` says it arrives "fenced in untrusted-content markers". The rows carry `task`, `owner` and `title` raw, and `_row` (line 100) and search hits (line 131) return the `summary.json` title raw as well.

*Scenario:* A participant gets an instruction-shaped sentence recorded as an action item. An agent calling `list_actions` receives it as a bare JSON string with no markers, although the tool description told it meeting text is fenced, so it reads as ordinary tool output.

*Direction:* Wrap task, owner and title values (or the whole rows payload) with `wrap_untrusted`, and add the untrusted note to `list_meetings`.

**F013. claude CLI provider leaves tools enabled and persists the transcript**

`pipeline/src/mp/provider_claude_cli.py:133`. Lens: security. Outcome: partially confirmed. Backlog: Known, open (SEC20). SEC20 (new, P2) describes exactly this: the empty allowed-tools flag only pre-approves, MCP servers, hooks and memory load, cwd unset, sessions persisted; its scope adds the tools, strict MCP config and no-persistence flags. HYG10 owns the false comment.

The flag misuse and the missing --no-session-persistence are real: the argv at provider_claude_cli.py:133 pre-approves nothing and removes nothing, so claude_cli summaries, speaker cleanup, mp ask and mp digest each run a default Claude Code print-mode session (built-in tools, user settings, hooks, MCP servers, global CLAUDE.md) with no cwd set, and the session, including the transcript, is persisted under ~/.claude/projects. The exploit itself was not demonstrated. It needs the opt-in claude_cli backend (default is anthropic), a hostile speaker whose instruction survives ASR, and the model obeying it despite the UNTRUSTED fence. In print mode anything that would prompt is denied, so reach is limited to read-only file tools and whatever the user's own allow rules pre-approve. The persisted copy stays on the machine. Note a full fix needs more than --tools "": that covers built-in tools only, MCP needs --strict-mcp-config.

*Scenario:* A participant says: read a named file and put it in the summary. With claude_cli selected, any tool the user's Claude Code permissions allow without a prompt (file reads in the working directory, allow-listed Bash or MCP tools) runs, and the output lands in the published summary.

*Direction:* Pass `--tools ""`, `--no-session-persistence`, `--strict-mcp-config` and a restricted settings source, run in an empty temp cwd, and move the instructions to `--system-prompt` so only the fenced transcript rides on stdin.

**F082. Loopback client honours HTTP proxies and trusts any listener; egress guard checks only the URL host**

`pipeline/src/mp/summarize_local.py:468`. Lens: security. Outcome: confirmed. Backlog: Known, open (SEC19, SEC27). Both halves are filed: SEC19's 2026-11-12 amendment covers the proxy-honouring loopback client and the URL-host-only guard (trust_env=False, refuse proxied transports); SEC27 item 7 covers reuse of a non-mlx listener. Both status new.

The loopback client is a default `httpx.Client` (trust_env on). httpx 0.28.1 mounts an HTTP proxy from the environment or macOS system settings for `http://` with no loopback bypass unless NO_PROXY lists it, and `egress_guard` checks only `request.url.host`, which stays 127.0.0.1. Separately, a non-mlx listener on the port reads as identity None, which `_reuse_is_safe` accepts.

*Scenario:* A Mac with a manual web proxy runs a regulated meeting: health checks go to the proxy, so the local backend fails as 'did not become healthy'. If the proxy, or any process squatting on 8765, answers 200, the full transcript is POSTed to it.

*Direction:* Construct the client with `trust_env=False` (or an explicit direct transport), and treat a listener that is not an mlx_lm.server as unsafe to reuse instead of unknown.

**F122. Egress guard allow rule is untested against proxies: loopback URLs can ride a proxy transport**

`pipeline/tests/test_egress_guard.py:55`. Lens: security. Outcome: confirmed. Backlog: Known, open (SEC19). SEC19 (new, P2) was amended 2026-11-12 from security review finding 8 with this exact defect: trust_env=False on loopback clients, the armed guard refuses proxied transports, and an HTTP_PROXY test is in its acceptance.

The only loopback test uses a direct transport with the downstream stubbed. The guard permits by request.url.host alone (egress_guard.py:144), httpx 0.28.1 mounts environment or macOS system proxies for http:// with no loopback bypass (_utils.py:30-70), and LocalSummaryClient builds httpx.Client with trust_env on (summarize_local.py:468). No test sets a proxy.

*Scenario:* Mac with a system HTTP proxy or HTTP_PROXY set, regulated run: the armed guard passes the GET to http://127.0.0.1:8765/v1/models, which httpx hands to the proxy host. If that proxy answers 200, the transcript POST follows the same route.

*Direction:* Build loopback clients with trust_env=False, make the guard refuse a permitted request whose transport carries a proxy, and add a test with HTTP_PROXY set.

**F153. uv.lock carries 13 packages with published advisories, including the TLS trust store used for cloud calls**

`pipeline/uv.lock:115`. Lens: security. Outcome: confirmed. Backlog: Known, open (SEC31). SEC31 (new, P1) covers the certifi advisory and the 12 other flagged packages through a constrained lock refresh. The missing recurring audit step in ci-local.sh is in neither SEC31 nor CI12, so that part is uncovered.

OSV lists advisories against 13 of 102 locked packages. The reachable one: certifi 2026.4.22 (GHSA-6q48-6c7w-9gw2, compromised emSign intermediates, fixed in 2026.10.18) is httpx's default trust store for the Anthropic and Notion clients, which pass no verify. ci-local.sh has no audit step; dependabot.yml is the only mechanism. Uncapped mlx-embeddings alone pulls 23 packages including pillow 12.2.0 (54 advisories).

*Scenario:* A network attacker holding a certificate chained to the compromised intermediate intercepts a summarize or publish call and reads the API key and transcript text. The mcp and pyjwt advisories are not reachable over stdio, nor anyio's TLS advisory with the sync clients used.

*Direction:* Re-lock with upgrades inside the existing caps (certifi, idna, urllib3, mcp 1.30), add an OSV or uv audit step to ci-local.sh, and cap mlx-embeddings.

**F130. Signing key imported with an allow-all ACL is the identity the app's TCC grants are bound to**

`scripts/lib/dev-cert.sh:98`. Lens: security. Outcome: partially confirmed. Backlog: Known, open (SEC17). SEC17 (new, P2) covers the -A import and the leaf-only designated requirement. Its planned fix, -T /usr/bin/codesign, is the prompt-free ACL this finding says leaves the exposure intact. Same root cause as F101; count once.

Verified: the self-signed key is imported with -A, the app is signed with it without a hardened-runtime option, and the installed app's designated requirement is identifier plus that certificate leaf, so anything able to sign with the key can produce code satisfying the requirement the TCC grants are bound to. Inferred, not executed: TCC treating such code as the app. -A is only the widest form of the exposure: any prompt-free ACL (for example codesign-only) leaves it intact because a same-user process can invoke /usr/bin/codesign, and the rebuild loop depends on prompt-free signing. The code comment says the key has no value off this machine, not that it is valueless. This is one root cause with F101 (its signing-key leg) and should be counted once.

*Scenario:* A process running as the owner signs its own binary with "MeetingPipe Dev" and identifier `com.meetingpipe.daemon`, or replaces the binary in ~/Applications, and is treated as the app that holds Microphone, Screen Recording and Accessibility. Not executed.

*Direction:* Import with `-T /usr/bin/codesign` instead of `-A`, sign with `--options runtime`, and state the residual risk in the script header.

**F101. The app's TCC grants can be inherited by any same-user process: no hardened runtime, and a signing key any tool may use**

`scripts/lib/sign-app.sh:38`. Lens: security. Outcome: partially confirmed. Backlog: Known, open (SEC17). SEC17 (new, P2) covers no hardened runtime, DYLD injection, the -A key and the user-writable plist (judged closed by hardened runtime). The uninstall leg, identity left behind and TCC reset only under a flag, is in no task.

Verified configuration: the app is signed with no hardened runtime and no entitlements (installed copy reads flags=0x0(none)), its designated requirement is only the identifier plus the self-signed leaf certificate, the signing key is imported for use by any application (-A), the LaunchAgent plist is a user-writable file that already carries an EnvironmentVariables block, and uninstall.sh never removes the signing identity and resets TCC only under --reset-tcc. Inferred from documented macOS behaviour, not executed: that a same-user process can therefore run code under the app's Microphone, Screen Recording and Accessibility grants, either through DYLD_INSERT_LIBRARIES or by signing with the key. It requires code already running as the owner. F130 is the signing-key leg of this same issue.

*Scenario:* A malicious package postinstall running as the user adds DYLD_INSERT_LIBRARIES to the user-writable LaunchAgent plist, or signs its own binary as com.meetingpipe.daemon with the key. It then captures microphone and system audio and drives Accessibility with no prompt.

*Direction:* Sign with --options runtime plus an audio-input entitlement, import the key with -T /usr/bin/codesign instead of -A, and delete the identity on uninstall.

**F150. Swift test suite strands temp directories: 365 mp-wf dirs, 16.4 GB in the real temp dir**

`daemon/Tests/MeetingPipeTests/WaveformPeaksTests.swift:10`. Lens: tests. Outcome: confirmed. Backlog: Known, open (T11). T11 covers it exactly: the 230 MB WAV with no teardown, a shared ScratchDir helper and a fence. The leak has grown since filing, from 135 mp-wf dirs at 5.37 GiB to 365 at 16.4 GB.

WaveformPeaksTests creates mp-wf-<UUID> directories under the real temp dir and the file contains no tearDown, removeItem or addTeardownBlock. One test writes a 60-minute stereo WAV (about 225 MB). On this host $TMPDIR holds 365 mp-wf directories totalling 16.4 GB (16,142 entries overall, mostly mp-* test leftovers); my two suite runs added two 225 MB directories.

*Scenario:* Every swift test run (CI gate, coverage script, each agent session) strands about 225 MB plus roughly 160 small directories. Repeated runs consume tens of GB on the volume the recorder writes to, the low-disk condition its own free-space watch exists for.

*Direction:* Remove each test's temp dir in tearDown or addTeardownBlock (shared helper for all mp-* test dirs), and shrink the synthetic WAV.

### Known, accepted trade-off (11)

**F029. Mic stall recovery pads from detection, not from when audio stopped**

`daemon/Sources/MeetingPipe/InputDeviceRecovery.swift:653`. Lens: data. Outcome: confirmed. Backlog: Known, accepted trade-off (REC16). REC16's 'Explicitly not in scope' section names the mic gap's 2.5 s detection latency as real, bounded and deliberately left, to be fixed only if the same code moves. Nothing tracks it since.

On the watchdog and wake paths the pad starts when recovery starts, not when buffers stopped. MicTapLivenessMonitor reports a stall only after 2.5 s without a buffer, so each such recovery leaves the mic file at least 2.5 s short. The system channel backdates its loss by stalledForSeconds; the mic does not.

*Scenario:* The mic tap stalls silently twice during a call and the watchdog re-arms it both times. Everything the user says afterwards sits five or more seconds early against the far side in the merged file, so cross-channel turn order and timestamps are wrong.

*Direction:* Pass the monitor's stall window into recoverAfterStall and subtract it from gapStart, as handleSystemAudioLost already does for the system channel.

**F035. VAD-contradiction heuristic un-mutes the exact case redaction exists for: speaking while muted**

`daemon/Sources/MeetingPipe/MeetingAXWindowWatcher.swift:305`. Lens: data. Outcome: partially confirmed. Backlog: Known, accepted trade-off (MIC10). MIC10 part 2 (done, 4ad585dc) deliberately clears a VAD-contradicted mute under capture-first only, naming the genuine muted side-conversation cost and exempting the regulated gate. ARCHITECTURE.md lists it as a backstop. Its 'only briefly affected' comment understates the leak.

The mechanism holds and is intended (test-pinned): in both capture-first modes, 4 s of app-muted plus HAL VAD voice clears axMute, the verdict turns hot, and the mute-timeline span closes until VAD drops. Preconditions the finding understates: the probe never enables HAL VAD, so another process must already have enabled it on the input device; a native app with an AX mute read and app-mute tracking on; the workflow's redact flag on. For the scenario as worded (mute, then talk for 30 s) the outcome is the same without the heuristic, because MuteRedactor withholds any auto span whose mean mic level is above -50 dBFS. The heuristic changes the result only when the aside sits inside a long, quiet muted span that would otherwise be redacted whole; there roughly 25 s of a 30 s aside escapes redaction. Regulated and NDA modes are unaffected (host mode gate).

*Scenario:* Workflow has 'Redact muted spans' on and HAL VAD is enabled on the input device. User mutes and talks to someone in the room for 30 s. After about 4 s the span is no longer marked muted; roughly 25 s of the aside is transcribed, summarized and published.

*Direction:* Do not treat VAD-while-muted as staleness by itself; require a second oracle (panel gone, element unreadable, log disagreement), or keep the span marked for redaction when the workflow opted in.

**F003. Blind-clear drops a latched app-mute in every capture mode, including the regulated/NDA gate**

`daemon/Sources/MeetingPipe/MeetingAXWindowWatcher.swift:361`. Lens: data. Outcome: confirmed. Backlog: Known, accepted trade-off (MIC6, ADR-0016). MIC6's done entry (q4-final) says the regulated gate still leaks when the control is unreadable, 'the accepted ADR-0016 trade'. ARCHITECTURE lists the blind streak as ungated. Mid-call loss of a confirmed mute is not weighed against MIC10's guard.

The claim holds, with three bounds. (1) For Teams the blind-clear is refused if a SlimCore log mute line landed in the previous 5 s, and because the clear fires once per blind streak, a streak that begins within about 2 s of the toggle never clears; any streak whose third blind poll lands more than 5 s after the last log line does clear, including a log-sourced .muted. Zoom, Slack and Webex have no such guard. (2) The leak lasts only until the next confident poll re-latches .muted. (3) The audio is written and transcribed on-device only (NDA and regulated force the local backend and filesystem sink), so this violates the no-muted-audio-at-rest promise, not an egress policy. The ungated clear is the TECH-MIC6 rescue that ADR 0016 retains for the regulated gate, so it is a deliberate capture-over-privacy trade whose leak side is undocumented and contradicts the MIC10 scope guard applied to the two sibling paths.

*Scenario:* NDA workflow; user mutes in Teams to speak to a colleague. Teams' AX tree is unreadable for 3+ s (app busy, or controls in a view the matchers miss). axMute clears, speech opens the RMS gate, verdict turns hot, and the muted speech is written to disk and transcribed.

*Direction:* Gate onMuteCleared on activeCaptureMode.capturesLosslessly like the other two discredits; under the regulated gate keep the latch (or zero) while the control is unreadable.

**G012. A term confirmed in Clarify is silently erased by an open Preferences window**

`daemon/Sources/MeetingPipe/TranscriptTab.swift:768`. Lens: data. Outcome: partially confirmed. Backlog: Known, accepted trade-off (FEAT12). FEAT12 (done) named this race and declined shared store ownership, calling it a narrow mid-keystroke 500 ms window. Verified trigger needs no keystroke: any open Pipeline pane erases the term on exit, so the acceptance understates it.

The Pipeline pane's GlossaryStore reads glossary.toml once at init and never reloads, and every later persist serializes that stale document over the file. With Preferences open on the Pipeline pane, a term confirmed in Clarify is silently erased by a pane switch (VocabularySection.onDisappear calls flush with no dirty gate), by the near-miss toggle, by any row edit, or by a scope change. Re-following the Vocabulary link for the workflow already selected is a no-op (selectWorkflow guard), so that trigger writes only when it changes scope.

*Scenario:* Preferences stays open after the workflow editor's Vocabulary link. The owner confirms 'Always fix this' on three transcript lines. Following the link again, switching pane or toggling near-miss matching then writes the stale document: the three terms are gone and nothing reports it.

*Direction:* Share one GlossaryStore between both surfaces, or reload and merge from disk before every writeBack, and make flush a no-op when nothing changed.

**F032. Hold-start trim treats a lone-dwell end as evidence of when the call ended**

`daemon/Sources/MeetingPipeCore/Lifecycle/TeardownHoldPolicy.swift:68`. Lens: data. Outcome: confirmed. Backlog: Known, accepted trade-off (ADR-0017, END17). ADR 0017 makes the hold's start the trim point for every confirmed hold, cut at stop under regulated or NDA; END17 owner decisions 1 and 3 accepted it. Irreversible loss on a wrong lone dwell is not weighed there.

`trimPoint` cuts at hold start for every confirmed end, on the premise that the held span is 'post-call audio by construction'. A lone-dwell confirm carries no evidence the call ended then, or at all. The host truncates the file there under `regulatedGate` (`recorder.stop(limitSeconds:)`) and otherwise records a suggested trim the transcript path applies (`HeldEndTrim.apply`).

*Scenario:* Google Meet in a Chrome tab; the user works in another tab of the same window for 12 minutes. The lone dwell ends the recording and the preceding 12 minutes of live meeting are trimmed, irreversibly in regulated mode.

*Direction:* Pass the confirming route into the policy and trim only for evidence-backed ends (teardown, pair); leave the tail untrimmed when `confirmedBy` is `lone_dwell`.

**F116. Merge retry test pins a path that leaves the primary audio unmerged while reporting success**

`pipeline/tests/test_merge_meetings.py:253`. Lens: data. Outcome: confirmed. Backlog: Known, accepted trade-off (PIPE8). PIPE8 (done, dcbf94cd, archived in q6-final.md) added this test and documents the unswapped-audio retry as an accepted residual, premised on fragments staying recoverable. It never mentions the daemon moving fragments to Trash on exit 0 or the orphaned .merging.tmp.

The test pins a retry after a failed audio swap as republish-only with a clean result. merge_meetings.py:196-203 never swaps the audio on that branch (its comment admits it), the .merging.tmp stays orphaned, and the test never checks the primary .wav. A clean result is exit 0, on which the daemon soft-deletes the fragments (MeetingLibraryService.swift:1300-1301).

*Scenario:* mp merge-meetings is killed, or os.replace fails, after the transcript commit (merge_meetings.py:228-230). The user retries: exit 0, fragments go to the trash, and the primary audio still holds only the first part while its transcript and summary cover the whole meeting.

*Direction:* On the resumed branch, swap in a verified .merging.tmp (or fail with a distinct error) before reporting success, and assert the primary audio bytes in this test.

**F079. Per-Mac context ceiling is unreachable for the tiers it targets; watchdog cannot see inside a request**

`pipeline/src/mp/summarize_local.py:185`. Lens: performance. Outcome: confirmed. Backlog: Known, accepted trade-off (LOCAL23, LOCAL18). LOCAL23 (done) documents it: on the 4,000-token tiers the ceiling stays unmet, the native budget stands and one warning is logged, with LOCAL14 named as the lever. The pre-request watchdog check is LOCAL16's design; LOCAL18 (new) questions whether it fires.

Executed against the real prompt: the fixed request estimates at 4,004 to 4,101 tokens, so the 4,000-token tiers are unreachable and `request_budget` returns the native 28,768 for 7B on 16 GB and 14B on 24 GB. The ceiling binds in one of 15 preset/RAM pairs. The stated backstop, the watchdog, samples only before a request (line 1210).

*Scenario:* 24 GB Mac, Large (14B) preset, 60-minute English meeting of about 60K chars: one request of about 19K tokens goes out, above the 16K at which resource_guard's own notes record an OOM on a 32 GB Mac, and nothing can abort it mid-request.

*Direction:* When the ceiling is unreachable, fall back to the smallest feasible window budget (or a shorter fixed prompt) instead of the native budget, and sample memory from a timer thread while a request is in flight.

**F081. Language check false positives trigger full re-summaries that are thrown away**

`pipeline/src/mp/summary_language.py:205`. Lens: performance. Outcome: confirmed. Backlog: Known, accepted trade-off (LANG2, LANG1, PIPE20). LANG2 (done) reviewed language_signature and kept the majority split on purpose, accepting a wrong flag as one discarded call; it recorded a real title at 49% Latin. The doubled local replay is PIPE20 item 4 (new); OBS2 adds the event.

`divergent_sections` flags any section, including the one-line title, whose letters are majority Latin. Executed: 'Міграція Jenkins pipeline на GitHub Actions' reads as 'en'. Each flag triggers a full second summarize (`summarize._verify_and_repair_language`) that is discarded if it still diverges, and the local client runs its own replay inside each call first.

*Scenario:* A Ukrainian engineering meeting gets a title or action list dominated by product names. Cloud: the whole transcript is sent and billed twice for no change. Local: up to four generations (summary, replay, repair, replay), each a minute or more.

*Direction:* Exclude the title and proper-noun-heavy text from the trigger (or require a Cyrillic-versus-Cyrillic or clear-majority divergence), and skip the outer repair when the local client already replayed.

**G028. Test requires a lone process-audio drop to end the meeting, opposite to the signal's stated safety rail**

`daemon/Tests/MeetingPipeCoreTests/PromotionEngineTests.swift:488`. Lens: quality. Outcome: partially confirmed. Backlog: Known, accepted trade-off (END17). ADR 0017 and END17 (owner decision 2026-10-24) make a lone weak end, process audio included, confirm after the 12 min lone dwell. Not filed: the two stale 'cannot solo-confirm' comments and the stale cached-ID false reading.

ProcessAudioSignal.swift:32-34 and NativeLifecycleAdapter.swift:19-21 still promise that a lone process-audio drop cannot end a recording, but since END17 it ends one after the 720 s lone dwell, by design and pinned by this test. Residual risk: a stale cached mic-owner ID beside readable idle helpers reads false rather than unknown, the poll never re-enumerates on a false, and only a process-object-list notification re-resolves it; the Teams re-registration trigger is unobserved and inferred.

*Scenario:* Teams' mic-owning helper re-registers under a new object ID and the list notification is dropped. The cached ID reads nil, the other helpers read false, the signal emits ended and never re-resolves. Twelve minutes later the live call ends on lone_dwell. Trigger inferred from DET8's notes.

*Direction:* Treat a read where a previously live object is unreadable as unknown and re-resolve, then make the comments and the test agree on whether the rail still exists.

**F024. Muted-span redaction keeps every span that carries speech, silently**

`daemon/Sources/MeetingPipe/MuteRedactor.swift:299`. Lens: security. Outcome: confirmed. Backlog: Known, accepted trade-off (MIC12, ADR-0016). MIC12 (done) and ADR 0016's MIC9 amendment make the per-span speech withhold deliberate; MIC12's close note keeps it event-only with a user-facing banner explicitly out of scope. The 'redacted' UI copy mismatch is not filed.

With Redact muted spans on, an auto-muted span is zeroed only if its mean mic level over the whole span is at or below -50 dBFS; a span carrying speech is kept whole. The withhold is deliberate (MIC12) but only logged, while WorkflowsView.swift:633 and WorkflowInspectorPresentation.swift:186 tell the user muted spans are redacted.

*Scenario:* Workflow has redact_muted_spans on. The user mutes in Teams for five minutes and talks to someone in the room. If that span's mean exceeds -50 dBFS it is withheld, and the aside is transcribed, summarized and published with no notice to the user.

*Direction:* Surface withheld spans as a review or held-back state instead of consuming them silently, and make the control's copy say what the guard actually does.

**F110. No test ever starts, writes or stops a real recording; the capture lifecycle is pinned by source-text order**

`daemon/Tests/MeetingPipeTests/MeetingRecorderPinsARCH8Tests.swift:11`. Lens: tests. Outcome: partially confirmed. Backlog: Known, accepted trade-off (T7, ARCH8). T7 (done) labelled this file a source fence pinning implementation, named the missing seam (injectable engine and capture) and deferred conversion until touched. ARCH8 (done) records that tests refuse the HAL. No open task builds it.

MeetingRecorder (1,786 lines, not 1,726) has no behavioural test of its own orchestration: start() past the engine, the tap-to-write path, a live stop(), and flushIntermediatesForTermination. The steps it delegates to are behaviourally tested in isolation (RecordingPostProcessor.produceFinal with real ffmpeg, SerialBufferWriter.drain/finish, EngineTeardown, InputDeviceRecovery against a fake host), but the sequence and the private wrappers (drainWriters, finalizeFiles, mergeIntermediates, the termination flush closing the mic file) are pinned only by source-text order or not at all.

*Scenario:* A refactor makes drainWriters return before the last buffers reach disk, or the termination flush stops closing the mic file. Every test stays green; the next real meeting loses its tail or is recovered short after a quit.

*Direction:* Put the engine and system capture behind an injectable protocol so one test can start, feed buffers, stop, and assert the final WAV's duration and the intermediates' fate.

## Low findings, verified

These were reported at a higher severity and demoted by verification, so each has been independently re-read.

| ID | Lens | Outcome | Reported as | Finding | Location |
|---|---|---|---|---|---|
| F042 | antipattern | partially confirmed | medium | Mute control is identified by first-hit substring heuristics with no structural anchor | `daemon/Sources/MeetingPipe/MeetingAXHandleBuilder.swift:604` |
| F100 | antipattern | partially confirmed | medium | run-all repeats the LLM cleanup pass on every re-run; the diarize_cleaned marker is never read and the audit is overwritten | `pipeline/src/mp/orchestrate.py:529` |
| F112 | antipattern | confirmed | medium | REC23 wiring fence passes on token presence and cannot tell a working ownership guard from an inert one | `daemon/Tests/MeetingPipeTests/RecordingStemOwnershipREC23Tests.swift:131` |
| G017 | antipattern | partially confirmed | medium | Summary editor's list rows bind by array position, the crash shape the workflow editor already removed | `daemon/Sources/MeetingPipe/CorrectionEditor.swift:78` |
| F127 | architecture | confirmed | medium | Meeting-app identity is hard-coded in about nine tables and one has already drifted: com.cisco.spark has no title extractor | `daemon/Sources/MeetingPipe/MeetingTitleResolver.swift:34` |
| F128 | architecture | partially confirmed | medium | One 71k-line executable target: layering rules are enforced by substring fences, not by the compiler | `daemon/Package.swift:58` |
| F103 | build | partially confirmed | medium | bundle-runtime.sh targets the live app with a dead pin, then an ad-hoc hardened-runtime re-sign with no entitlements | `scripts/bundle-runtime.sh:112` |
| F064 | data | confirmed | medium | Delete unused models removes every Hugging Face hub model except the summarizer, including the pipeline's own embedder | `daemon/Sources/MeetingPipe/StorageStats.swift:208` |
| F093 | data | confirmed | medium | Roster and voiceprint stores treat an unreadable file as empty inside an unlocked read-modify-write | `pipeline/src/mp/roster.py:116` |
| F098 | data | confirmed | medium | Voice embeddings are kept for every speaker with no retention, written 0644, and not removed by roster forget | `pipeline/src/mp/orchestrate.py:751` |
| F120 | data | confirmed | medium | Forced restore, the only path the app uses, is asserted by member count only | `pipeline/tests/test_backup_restore.py:348` |
| F134 | data | confirmed | medium | Delete unused models wipes the shared HuggingFace cache, including the mp ask embedder | `daemon/Sources/MeetingPipe/StorageStats.swift:216` |
| F138 | data | confirmed | medium | Participants' voice embeddings are stored per meeting with no opt-in, and roster forget does not purge them | `pipeline/src/mp/orchestrate.py:751` |
| F144 | data | confirmed | medium | MicGate can publish verdicts out of order and latch a stale one | `daemon/Sources/MeetingPipeCore/MicGate/MicGate.swift:299` |
| F147 | data | confirmed | medium | Verbose logging toggle promises effects that do not exist and has an undisclosed one | `daemon/Sources/MeetingPipe/Preferences/PreferencesView+Advanced.swift:36` |
| F072 | performance | partially confirmed | medium | Every 15 Hz playback tick re-evaluates the whole detail pane and the full transcript list body | `daemon/Sources/MeetingPipe/TranscriptTab.swift:916` |
| F142 | performance | confirmed | medium | Call-teardown watcher polls the Teams log directory at 1 Hz for the whole process lifetime | `daemon/Sources/MeetingPipeCore/Lifecycle/CallTeardownWatcher.swift:56` |
| F043 | quality | partially confirmed | medium | User overlay meeting_apps.toml fails silently and most of its tables cannot take effect | `daemon/Sources/MeetingPipe/MeetingAppRegistry.swift:47` |
| F054 | quality | partially confirmed | medium | Stale apple_pending sentinel hijacks a later successful run-all | `daemon/Sources/MeetingPipe/PipelineLauncher.swift:857` |
| F077 | quality | partially confirmed | medium | Onboarding window is closed without isReleasedWhenClosed = false (likely over-release when the first-run flow finishes) | `daemon/Sources/MeetingPipe/Onboarding/OnboardingWindow.swift:74` |
| F097 | quality | partially confirmed | medium | Diarize cleanup applies model-supplied segment indices that were never in the window the model saw | `pipeline/src/mp/diarize_cleanup.py:299` |
| F113 | quality | confirmed | medium | REC16 wall-clock fence skips the assignments it claims to pin | `daemon/Tests/MeetingPipeTests/CaptureHealthREC16Tests.swift:203` |
| F145 | quality | partially confirmed | medium | Merge and redaction ffmpeg runners wait for exit without draining stderr, and a timed-out ffmpeg is never killed | `daemon/Sources/MeetingPipe/RecordingPostProcessor.swift:550` |
| G038 | quality | partially confirmed | medium | Row status pill lets zero-egress outrank Failed, No speech and Recording | `daemon/Sources/MeetingPipe/MeetingRow.swift:575` |
| G041 | quality | confirmed | medium | The two pulses PRODUCT.md names for Reduce Motion have no reduced-motion branch | `daemon/Sources/MeetingPipe/LibraryToolbar.swift:224` |
| G042 | quality | confirmed | medium | Prompt workflow chip has no accessible name and its only call site supplies none | `daemon/Sources/MeetingPipe/Design/WorkflowChipView.swift:27` |
| F050 | security | partially confirmed | medium | meetingpipe:// URL scheme starts, stops and queries with no confirmation or sender check | `daemon/Sources/MeetingPipe/Automation/Coordinator+Automation.swift:18` |
| F086 | security | partially confirmed | medium | NDA and regulated runs still copy raw audio and the full transcript into the Obsidian vault, and no sync check covers the vault | `pipeline/src/mp/publish_obsidian.py:140` |
| F111 | security | partially confirmed | medium | The only test that spawns through PipelineLauncher.runMP is skipped in CI; watchdog and token-strip wiring are never executed | `daemon/Tests/MeetingPipeTests/FailureProcessTests.swift:8` |
| F117 | security | confirmed | medium | Suite reads the real login Keychain: the stub is per test, not in conftest | `pipeline/tests/test_orchestrate.py:1132` |
| F118 | security | confirmed | medium | Entry-contract fence misses the real client construction seams and non-main prepare calls | `pipeline/tests/test_entry_contract.py:151` |
| F131 | security | partially confirmed | medium | Local backend posts the transcript to whatever listens on the port, even a known non-mlx process | `pipeline/src/mp/summarize_local.py:938` |
| F133 | security | confirmed | medium | Only owner and attendees are scrubbed; other model-authored text reaches Markdown sinks verbatim | `pipeline/src/mp/publish_obsidian.py:238` |
| F115 | tests | confirmed | medium | Test named for the already-engaged guard never engages an adapter | `daemon/Tests/MeetingPipeTests/ExplicitStartLifecycleTests.swift:137` |
| F119 | tests | partially confirmed | medium | Module-level importorskip skips every MCP test when the optional extra is absent | `pipeline/tests/test_mcp_serve.py:523` |
| F149 | tests | partially confirmed | medium | A large share of the Swift suite asserts on source text, including exact line equality | `daemon/Tests/MeetingPipeTests/EngineCallBoundsREC27Tests.swift:125` |
| F152 | tests | confirmed | medium | A pytest test opens a live connection to huggingface.co and rewrites the real HF cache | `pipeline/tests/test_action_clusters.py:213` |
| G018 | tests | partially confirmed | medium | Prefetch golden is synthesized by the generator; `_emit` is never executed by the generator or any pipeline test | `scripts/gen_contract_fixtures.py:253` |
| G020 | tests | confirmed | medium | Meta-contract fixtures pin about half the sidecar keys Python consumes; workflow_name, workflow_id, meeting_title and extra sections can drift with both suites green | `daemon/Tests/MeetingPipeTests/MetaContractFixtureTests.swift:9` |
| G023 | tests | confirmed | medium | Distilled 'real dogfood' traces are rebuilt from the engine's own verdicts: 20 traces collapse to 4 structures, and the tick family asserts values the description says came from the log | `scripts/extract_detection_trace.py:289` |
| G029 | tests | partially confirmed | medium | 16 of 41 corpus traces end through an unconditional pseudo-event carrying the retired empty-rewalk evidence | `daemon/Tests/MeetingPipeCoreTests/Fixtures/detection-corpus/teams_native_rewalk_end_01.json:21` |

## Low findings, not verified

Reported as low by a finder and never re-checked. Treat as leads, not as facts.

| ID | Lens | Finding | Location |
|---|---|---|---|
| F154 | antipattern | Redaction ffmpeg is unbounded and reads stderr only after exit | `daemon/Sources/MeetingPipe/MuteRedactor.swift:376` |
| F161 | antipattern | Signal callbacks are plain vars written on main and read on signal queues; targeted strict concurrency does not see it | `daemon/Sources/MeetingPipeCore/Lifecycle/Signals/AXLeaveButtonSignal.swift:31` |
| F162 | antipattern | AX handler box is released off-main while callbacks dereference it on main | `daemon/Sources/MeetingPipeCore/Infra/RealAXBackend.swift:98` |
| F196 | antipattern | serve-local tests redirect the pytest process's stdout and stderr and never restore them | `pipeline/tests/test_serve_local.py:67` |
| F211 | antipattern | SystemAudioCapture's static cache and permission state are unsynchronized across the pool and main | `daemon/Sources/MeetingPipe/SystemAudioCapture.swift:80` |
| F214 | antipattern | Staged local summarizer (about 1,000 lines) is reachable only through an env var nothing sets | `pipeline/src/mp/summarize_staged.py:77` |
| F215 | antipattern | Comments are as large as the code and are mostly history, including the owner's usage statistics | `daemon/Sources/MeetingPipe/MeetingStore.swift:1006` |
| F200 | architecture | Accepted ADRs and scope docs state invariants the code has left behind | `docs/decisions/0003-filesystem-library-source-of-truth.md:84` |
| F205 | architecture | Schema versions are written on durable artifacts but never checked, including the backup manifest | `pipeline/src/mp/restore.py:103` |
| F219 | architecture | CI never exercises the configuration the app actually runs in | `.github/workflows/ci.yml:73` |
| G045 | architecture | Quit signals supervised runs once with no backstop, leaves other spawns unbounded, and the relaunch labels interrupted without checking the old mp is gone | `daemon/Sources/MeetingPipe/PipelineLauncher.swift:745` |
| G058 | architecture | Three accepted ADRs describe superseded behaviour with no amendment | `docs/decisions/0004-menu-bar-over-dock-app.md:61` |
| F183 | build | ci-local.sh is not the same run as CI, and CONTRIBUTING.md describes gates that no longer exist | `.github/workflows/ci.yml:59` |
| F201 | build | bundle-runtime.sh embeds a downloaded interpreter and ffmpeg without verifying a digest | `scripts/bundle-runtime.sh:59` |
| F216 | build | No warning gate behind the documented strict-concurrency rule; 11 warnings stand, 4 concurrency class | `scripts/ci-local.sh:187` |
| F218 | build | Package.resolved is gitignored, so the Swift dependency graph has no committed lock | `.gitignore:9` |
| F155 | data | Writer backlog warning is log-only until 512 MiB of audio is held in RAM | `daemon/Sources/MeetingPipe/MeetingRecorder.swift:1584` |
| F160 | data | One failed resolve resets the teardown tail, and the next tick skips to end of file | `daemon/Sources/MeetingPipeCore/Lifecycle/CallTeardownWatcher.swift:233` |
| F163 | data | Titles of browser tabs judged not to be meetings are persisted verbatim to the event log | `daemon/Sources/MeetingPipe/MeetingDiscoveryWatcher.swift:425` |
| F164 | data | StrandedJobRecovery counts the ffmpeg merge temp as a finished recording | `daemon/Sources/MeetingPipe/StrandedJobRecovery.swift:45` |
| F169 | data | Apple Intelligence path rewrites the live summary non-atomically with default permissions | `daemon/Sources/MeetingPipe/Summarization/AppleIntelligenceSummarizer.swift:468` |
| F170 | data | Drag-out leaves a plaintext summary and transcript copy in the temp directory | `daemon/Sources/MeetingPipe/MeetingDragItem.swift:30` |
| F171 | data | Batch selection is resolved against the whole library, not the list on screen | `daemon/Sources/MeetingPipe/LibraryWindow.swift:1107` |
| F175 | data | First-run wizard (run from the launch path) promises notes 'never leave your Mac' while the default backend is Anthropic | `daemon/Sources/MeetingPipe/Onboarding/OnboardingStepWelcome.swift:11` |
| F179 | data | Deleted or re-filed meetings keep their full text in the embedding cache until the next ask | `pipeline/src/mp/embed_index.py:79` |
| F185 | data | The microphone prompt promises audio never leaves the Mac while the shipped defaults record into ~/Documents | `scripts/install.sh:229` |
| F186 | data | Per-workflow glossary is keyed by workflow name on both sides, so a rename silently detaches it | `pipeline/src/mp/glossary.py:194` |
| F192 | data | Soft-delete tests use the real user Trash and assert only that the WAV is gone | `daemon/Tests/MeetingPipeTests/MeetingLibraryServiceTests.swift:491` |
| F202 | data | Audio restored from a backup is deleted again by the next retention sweep | `daemon/Sources/MeetingPipe/AudioRetention.swift:97` |
| F209 | data | A quit while stop() is in flight skips the termination flush | `daemon/Sources/MeetingPipe/Coordinator.swift:699` |
| G050 | data | engine_compare_report.py overwrites hand-entered dogfood scores and notes in place on every run | `scripts/engine_compare_report.py:94` |
| G051 | data | Interrupting valid1 --coldstart leaves the model run alive in its own session, and each run writes candidate summaries into the live library | `scripts/valid1_check.py:722` |
| G052 | data | A committed test names the people in a meeting it describes as real | `pipeline/tests/test_valid1_check.py:179` |
| F157 | performance | Synchronous log file write inside the tap and SCStream callbacks on first buffer | `daemon/Sources/MeetingPipe/MeetingRecorder.swift:916` |
| F159 | performance | Process-object-list listener re-resolves and re-subscribes on every system-wide audio client change, uncoalesced, with 3N+1 log appends each time | `daemon/Sources/MeetingPipeCore/Lifecycle/Signals/ProcessAudioSignal.swift:306` |
| F172 | performance | Diagnostics window parses every event-log generation on the main thread on each open and filter change | `daemon/Sources/MeetingPipe/DiagnosticsView.swift:128` |
| F194 | performance | One unit test builds and writes 1.85 GB of zeros to exercise an 8 KB header read | `daemon/Tests/MeetingPipeTests/MergeLengthFallbackTests.swift:173` |
| F206 | performance | Seven serial Keychain subprocesses on the main thread at every launch, three more per secrets save | `daemon/Sources/MeetingPipe/SecretsStore.swift:31` |
| F207 | performance | Recent meetings submenu lists and mtime-sorts the whole recordings directory on the main thread | `daemon/Sources/MeetingPipe/Library/MeetingLibraryService.swift:1325` |
| F208 | performance | mp re-probes the Keychain for every absent managed key on each entry.prepare call | `pipeline/src/mp/config.py:535` |
| G044 | performance | A transcription pass the deadline abandons keeps its runner, models and audio resident beside the replacement | `daemon/Sources/MeetingPipe/Coordination/SinkDispatcher.swift:900` |
| F156 | quality | Recovery path bypasses the loudest-channel mono collapse | `daemon/Sources/MeetingPipe/InputDeviceRecovery.swift:357` |
| F158 | quality | Two title-derived signals sit in different evidence classes, so one PWA title change satisfies the pair | `daemon/Sources/MeetingPipeCore/Lifecycle/PromotionEngine.swift:72` |
| F165 | quality | SIGTERM is ignored outright when the main thread is already wedged; the termination ceiling is armed from main | `daemon/Sources/MeetingPipe/App.swift:222` |
| F166 | quality | Level-callback closures are swapped on main while the audio threads read them | `daemon/Sources/MeetingPipe/MeetingSessionController.swift:1344` |
| F168 | quality | Warm model server has no reap path after an abnormal daemon exit, and its liveness is never tracked | `daemon/Sources/MeetingPipe/LocalModelPreloader.swift:117` |
| F173 | quality | Reduce Motion is not honoured by the HUD pulse or the panel fades, contrary to PRODUCT.md's accessibility floor | `daemon/Sources/MeetingPipe/RecordingHUDWindow.swift:840` |
| F174 | quality | HUD meter zeroing for 'Mic lost' and off-the-record is overwritten by the 10 Hz ticker; elapsed clock stays muted after a confirming-end hold | `daemon/Sources/MeetingPipe/RecordingHUDWindow.swift:227` |
| F176 | quality | Summary schema accepts empty and blank output as a valid summary | `pipeline/src/mp/schemas.py:236` |
| F180 | quality | doctor confirms a pinned probe model, demands cloud keys unconditionally and validates no sink | `pipeline/src/mp/doctor.py:146` |
| F182 | quality | The worktree janitor's live-session veto never fires when the repo path contains a space | `scripts/prune-worktrees.sh:56` |
| F187 | quality | `MP_VERBOSE` is exported by the daemon and read by nothing in the pipeline | `daemon/Sources/MeetingPipe/App.swift:134` |
| F189 | quality | pipeline.log is written through positional, non-append handles by spawns that are allowed to overlap | `daemon/Sources/MeetingPipe/PipelineLauncher.swift:1285` |
| F195 | quality | CLI tests parse the developer's real config.toml | `pipeline/tests/test_actions.py:55` |
| F199 | quality | A Preferences view file carries its own unbounded `mp` spawn; the 'single spawn primitive' has six siblings | `daemon/Sources/MeetingPipe/Preferences/PreferencesView+Pipeline.swift:652` |
| F203 | quality | Two writers still rewrite the only transcript or summary copy non-atomically | `pipeline/src/mp/roster_cmd.py:119` |
| F210 | quality | LocalServerReaper decides, waits up to 10 s, then deletes whatever marker is there | `daemon/Sources/MeetingPipe/LocalServerReaper.swift:77` |
| F212 | quality | Pipeline log rotation is an unlocked check-then-rename shared by threads and processes | `pipeline/src/mp/events.py:57` |
| G043 | quality | Storage pane and mp doctor read different free-space figures, so the two growth projections REC20 says agree do not | `daemon/Sources/MeetingPipe/StorageStats.swift:196` |
| G047 | quality | CONFIG_NOT_FROM_TOML exempts its keys from the dead-knob check and, unlike the three allowlists, has no staleness ratchet | `scripts/truth_fences.py:439` |
| G048 | quality | UX4 and DIAR1 acceptance checks can pass without the behaviour they grade | `scripts/valid1_check.py:113` |
| G053 | quality | Teams' teardown line can confirm a Zoom, Webex or Slack hold; only the browser exclusion is tested | `daemon/Tests/MeetingPipeCoreTests/TeardownHoldPolicyTests.swift:41` |
| G055 | quality | A second tour run does not raise its window because `presented` is never reset | `daemon/Sources/MeetingPipe/Tutorial/TutorialSession.swift:82` |
| G057 | quality | GUIDE and SETUP describe three controls differently from the code | `docs/GUIDE.md:116` |
| G059 | quality | Two-channel waveform declares no accessibility role and seeks by pointer only | `daemon/Sources/MeetingPipe/AudioTab.swift:357` |
| G060 | quality | Talk share matches the owner on the renamed display label and discards the mic-channel raw id | `daemon/Sources/MeetingPipe/MeetingStats.swift:154` |
| G061 | quality | Quick Find treats a multi-word query as one phrase, unlike the filter bar, and its doc claims otherwise | `daemon/Sources/MeetingPipe/QuickFindRanker.swift:34` |
| G062 | quality | Facts mark-done passes a trimmed task to an exact-match writer and its result is discarded | `daemon/Sources/MeetingPipe/Facts.swift:371` |
| F167 | security | SEC5 token strip covers two of the four managed tokens; spawn sites are inconsistent | `daemon/Sources/MeetingPipe/PipelineLauncher.swift:1542` |
| F177 | security | Local model server runs unauthenticated with CORS open to every origin | `pipeline/src/mp/summarize_local.py:378` |
| F178 | security | Model downloads have no durable revision pin or checksum | `pipeline/src/mp/prefetch_model.py:199` |
| F181 | security | secrets.env migration deletes the file even when a token was skipped or failed to store | `scripts/install.sh:491` |
| F184 | security | Uninstall leaves the scheduled digest and backup agents, the OpenAI key under --purge, and the signing identity | `scripts/uninstall.sh:148` |
| F204 | security | secrets.env migration deletes the plaintext file even when the Keychain write failed | `daemon/Sources/MeetingPipe/SecretsStore.swift:88` |
| F213 | security | Wrong-typed regulated_mode silently reads false and is then overwritten on save | `daemon/Sources/MeetingPipe/ConfigStore.swift:322` |
| F188 | tests | Restore plan and Swift-written summary.json have no shared fixture | `daemon/Tests/MeetingPipeTests/RestoreFlowTests.swift:65` |
| F190 | tests | The 'load-bearing' atomic-write test cannot fail against the remove-then-move defect it describes | `daemon/Tests/MeetingPipeTests/AtomicSidecarWriteTests.swift:48` |
| F191 | tests | Window-title recognizer is verified only against 21 author-seeded rows; the honesty gate skips permanently | `daemon/Tests/MeetingPipeTests/WindowRecognizerFixtureTests.swift:157` |
| F193 | tests | Restore plan contract is a JSON string pasted into the Swift test, not a shared generated fixture | `daemon/Tests/MeetingPipeTests/RestoreFlowTests.swift:117` |
| F197 | tests | Idle-timer and heartbeat tests depend on real sleeps with sub-second margins | `pipeline/tests/test_summarize_local.py:1140` |
| F198 | tests | Production-log isolation test asserts the path helper, not where emit wrote | `pipeline/tests/test_events.py:139` |
| F217 | tests | Waveform performance budget is asserted only in a branch no gate compiles | `daemon/Tests/MeetingPipeTests/WaveformPeaksTests.swift:136` |
| G046 | tests | The suites' safety tests never drive the handlers that write; editor save and people actions have no test | `daemon/Tests/MeetingPipeTests/ClarifyTests.swift:291` |
| G049 | tests | Publish golden never carries the failed-sink shape fanout writes, and Swift asserts neither `error` nor `failure` from it | `scripts/gen_contract_fixtures.py:98` |
| G054 | tests | Registry fence is one-directional and a malformed or mistyped entry shrinks detection silently | `daemon/Tests/MeetingPipeTests/MeetingAppRegistryFenceTests.swift:20` |
| G056 | tests | The launch-path fence pins one literal, so an indirect start from a launch path stays green | `daemon/Tests/MeetingPipeTests/TutorialFenceTests.swift:212` |

## Refuted

Kept so the kill rate is visible: 1 of the findings sent to verification was refuted outright, and 53 were narrowed (partially confirmed).

- **F034. Core emits events from six-plus queues into an unsynchronized seek-then-write appender** (`daemon/Sources/MeetingPipe/Logger.swift:92`, reported as medium). Refuted because: The reported appender no longer exists. Log.event calls Log.append, which takes one process-wide OSAllocatedUnfairLock, rotates under it, then opens per write with O_WRONLY | O_APPEND | O_CREAT and loops write(2). rotateIfNeeded takes the same lock. LogEventAdapter forwards every Core emit to Log.event. No appendData, ...

## Build and test results

Run by a single agent at HEAD `4949c9c0`. It built and tested in the repo's own build directories only; it did not run `install.sh`, `rebuild.sh` or `uninstall.sh`, and did not relaunch or re-sign the installed app. The text below is that agent's report, unedited apart from formatting.

**swift build.** EXIT 0, 9.7 s (incremental build on Swift 6.4.2 / macOS 27.2; the build backend replays diagnostics, but this was not a clean build). 0 errors. 21 warning lines = 11 distinct warnings (each file warning prints twice). Concurrency class, 4: RecordingPostProcessor.swift:351 reference to captured var 'lengths' in concurrently-executing code (Swift 6 error); Preferences/MCPStatusStore.swift:68 main actor-isolated static 'ceilingSeconds' read off the actor (Swift 6 error); MeetingRecorder.swift:750 and :1705 conformance of AVAudioFormat to Sendable only available in macOS 26+. Other, 7: 'weak' self capture differs from outer strong capture at DoctorRunner.swift:70,74 and StatusBarController.swift:488,506; Combine not imported at Onboarding/OnboardingStepTest.swift:11 (2 warnings); package warning for unhandled Sources/MeetingPipeCore/CLAUDE.md. Test targets add 8 more when built: ModalSafeTimerTests.swift:74,90 non-Sendable capture in a @Sendable closure, DoctorCommandTests.swift:82 mutation of captured var in concurrent code, plus 5 hygiene warnings.

**swift test.** EXIT 0, wall 85 s. XCTest: MeetingPipeTests.xctest 3106 tests, 1 skipped, 0 failures, 68.2 s; MeetingPipeCoreTests.xctest 425 tests, 0 failures, 3.1 s. Total 3531 cases, 3530 passed, 1 skipped, 0 failed. Swift Testing: 0 tests in 0 suites (reported twice). The one skip is WindowRecognizerFixtureTests.test_fixture_is_backed_by_real_captures (window_titles.json holds 21 seeded guesses and 0 captured rows), which is on the ci-local.sh allowlist. Slowest: WaveformPeaksTests.test_compute_renders_60_minute_synth_in_under_two_seconds 19.0 s, FailureLayoutTests 5.0 s, PipelineLauncherTests 4.0 s. A second full run under --enable-code-coverage gave the same totals. No failures to quote.

**pytest.** EXIT 0. 1559 passed, 0 failed, 0 skipped, 0 xfailed, 0 xpassed in 73.8 s (wall 75 s), Python 3.11.15. Run three times in total (plain, with a passive socket-recording plugin, with coverage); identical totals each time. Slowest: three test_link_fence tests at 3.3-3.4 s, test_summarize_local idle-timeout test 3.3 s, test_action_clusters::test_cli_out_writes_cluster_ids 2.6 s.

**ruff.** EXIT 0, 'All checks passed!' (ruff 0.15.12 from the lock; rule set E4, E7, E9, F).

**pyright.** EXIT 0, '0 errors, 0 warnings, 0 informations' with --extra dev --extra mcp (pyright 1.1.411; it notes 1.1.414 is available).

**Coverage.** Pipeline (pytest-cov over src/mp): 9339 statements, 980 missed, 90% line coverage. Least covered: prefetch_model.py 38%, doctor.py 58%, __main__.py 59% (the router with the exit-code and signal handling), dogfood.py 66%, logs_cmd.py 70%, train_adapter.py 72%, provider_claude_cli.py 75%, merge_meetings.py 79%. Daemon: scripts/coverage.sh swift exited 0 in 97 s and printed 'LINE COVERAGE: 4349/4834 = 90.0%', but that table holds only the 40 MeetingPipeCore files. Recomputed from the fresh MeetingPipeTests bundle (same result with both bundles merged): 34024/66762 lines = 51.0% over 318 files; MeetingPipe executable target 29667/61919 = 47.9% over 277 files; MeetingPipeCore 4349/4834 = 90.0%; MeetingPipeObjC 8/9. Least covered important daemon files: Coordinator.swift 0.3% of 1035 lines, Coordinator+Delegates.swift 0% of 168, App.swift 1.7% of 238, Notifier.swift 0% of 394, MeetingDiscoveryWatcher.swift 8.5% of 375, SystemAudioCapture.swift 17.0% of 289, MeetingRecorder.swift 17.3% of 1210, FluidAudioRunner.swift 44.7% of 421, PipelineLauncher.swift 63.4% of 1228. Well covered: SinkDispatcher.swift 95.7%, MuteRedactor.swift 91.9%, ConfigStore.swift 90.5%, RecordingPostProcessor.swift 86.0%, MeetingSessionController.swift 84.6%. Most SwiftUI panes are between 0% and 35%.

**Dependencies and advisories.** Swift: FluidAudio exact 0.14.8 (rev 56607d9, tagged 2026-05-31; upstream latest v0.18.3 dated 7 Nov; tag still points at the pinned revision); TOMLKit from 0.6.0, resolved 0.6.0, which is also the latest tag. No transitive Swift packages. daemon/Package.resolved exists locally but is gitignored and untracked. Python: uv.lock has 102 registry packages and uv lock --check passes. Direct pins: anthropic 0.97.0 (2026-04-23; capped <1; newest 0.x is 0.125.0, newest overall 2.8.0 requires httpx2, which confirms the pyproject comment), httpx 0.28.1 (latest), pydantic 2.13.3 (latest 2.14.3), mlx-lm 0.31.3 (capped <0.32; latest 0.32.2), mlx-embeddings 0.1.0 (latest; no upper cap), mcp 1.29.0 (latest 2.3.0), tenacity 9.1.4 (latest 9.2.1), numpy 2.4.4, soundfile 0.13.1. OSV version-exact query on 2026-11-12 flags 13 packages: certifi 2026.4.22 (critical-rated, fixed 2026.10.18), anyio 4.13.0 (critical-rated TLSStream issue, fixed 4.14.2, not reachable with the sync clients used), mcp 1.29.0 (4 moderate, fixed 1.30.0, HTTP transport and bearer-auth paths that stdio does not use), pyjwt 2.13.0 (15), urllib3 2.7.0 (3), aiohttp 3.14.1 (11), pillow 12.2.0 (54), transformers 5.8.0 (2 high), idna 3.13, filelock 3.29.0 (9), fsspec, datasets, multidict. uv.lock was last committed 2026-10-24. No audit step in ci-local.sh or ci.yml; .github/dependabot.yml covers uv, swift and actions weekly. FluidAudio releases 0.15 through 0.17.0 were not reviewed; 0.17.1 to 0.18.3 notes include long-form ASR fixes (dropped opening speech, seam repair), offline diarizer changes, and macOS 27 CoreML fixes for CTC and Kokoro models.

**FluidAudio 0.14.8 on this macOS 27.2 host.** Host is macOS 27.2 (build 26B123), Darwin 27.2.0, arm64. Requested path, from the code (read): FluidAudioRunner calls AsrModels.downloadAndLoad(version:) and DiarizerModels.downloadIfNeeded() with no configuration, so 0.14.8 defaults apply: Parakeet v3 preprocessor on cpuOnly; encoder, decoder and joint on cpuAndNeuralEngine (AsrModels.swift:135-137, 450-453); pyannote segmentation and wespeaker embedding on .all (DiarizerModels.swift:104-107). There is no OS-version gate and no CPU fallback in the daemon or in 0.14.8. Planned dispatch, measured with MLComputePlan in a foreground CLI on this host: encoder 1381 ops on ANE and 4 on CPU (15.7 s plan load); decoder and joint entirely CPU (24 ops each); pyannote segmentation 17 GPU, 9 ANE, 5 CPU; wespeaker 1149 ops on GPU. So ANE and GPU are available to these models on 27.2 in the foreground. What the menu-bar agent gets is unmeasured, and that is exactly the open question: upstream issue 738 (opened 2026-06-25, closed 2026-08-19 via PR 858, which repaired Kokoro TTS only) quotes Apple's note that OS 27 restricts background access to the Neural Engine, similar to GPU restrictions. Risk of the pin: 0.14.8 predates every upstream macOS 27 fix (0.18.0, 0.18.1 and 0.18.3 each carry one, for CTC and Kokoro models rather than the TDT path used here) and the long-form ASR fixes in 0.18.2; and on any model load error it deletes the model cache and re-downloads from huggingface.co. I found no evidence that transcription is failing on this host, and did not read the app's logs to check.

**Side effects of the run.** git status --porcelain is empty and HEAD is unchanged at 4949c9c0; the set of ignored paths is identical before and after (no .coverage or .coverage-html created, since I ran the Python coverage leg by hand with the data file in the scratchpad). Build output went only to daemon/.build. Outside the repo: (1) each of my three pytest runs contacted huggingface.co and rewrote ~/.cache/huggingface/hub/models--mlx-community--multilingual-e5-small-mlx/refs/main; (2) each swift test run rewrote ~/Library/Preferences/com.apple.dt.xctest.tool.plist (keys MeetingDetailSelectedTab and mp.onboarding.completed) and left about 160 mp-* directories in $TMPDIR, including one 225 MB mp-wf directory per run (two runs, about 450 MB); pytest left its usual pytest-of-<user> tree (145 MB). The installed app was running throughout (pid 4180); its Logs, Application Support, Caches and the Documents/Meetings tree were unchanged by file count and newest mtime, and I read none of their contents. My compute-plan probe read the cached CoreML models under ~/Library/Application Support/FluidAudio without modifying them.

**Not run.** scripts/ci-local.sh itself (so the one-thread cooperative-pool engine suites, the DIST4 relocation smoke test, the design-token greps and truth fences are unverified); swift build -c release and any release-mode test; a clean (non-incremental) debug build, to avoid deleting daemon/.build under a running install; the Python leg of scripts/coverage.sh through the script (run by hand with the same pytest-cov flags minus the HTML report, to avoid writing into the repo); install.sh, rebuild.sh, uninstall.sh, test-app-relocation.sh, test-login-agent-guard.sh, test-prune-worktrees.sh. Actual CoreML dispatch inside the daemon process was not measured: the probe ran as a foreground CLI, which is not the menu-bar agent's situation. CI's real toolchain version and whether Dependabot PRs are open were not checked. Weekly usage stood at 82% when I finished, below the 90% pause threshold.

## Coverage of the audit itself

"Read in full" is each finder's own report of what it read, not a measurement.

| Slice | Read in full | Skimmed | Listed but not reached |
|---|---|---|---|
| capture | 37 | 14 | [] |
| core-lifecycle | 26 | 10 | [] |
| micgate-ax | 35 | 18 | [] |
| spine | 30 | 26 | [] |
| boundary | 40 | 28 | [] |
| store | 48 | 20 | [] |
| ui-library | 20 | 39 | [] |
| ui-chrome | 47 | 25 | ['daemon/Sources/MeetingPipe/Resources/meeting_apps.toml'] |
| py-summarize | 29 | 11 | [] |
| py-publish | 23 | 25 | [] |
| py-orchestrate | 28 | 18 | [] |
| install-ci | 30 | 17 | ['scripts/backlog.py', 'scripts/dogfood_report.py', 'scripts/dump_window_titles.swift', 'scripts/engine_compare_report.py', 'scripts/extract_detection_trace.py', 'scripts/gen-icon.swift', 'scripts/gen-readme-hero.swift', 'scripts/gen_contract_fixtures.py', 'scripts/valid1_check.py', 'bench/parakeet-vs-whisperx/REPORT.md', 'daemon/scripts/auto1-app-intents-probe.sh'] |
| contracts | 19 | 59 | ['pipeline/src/mp/entry.py', 'pipeline/src/mp/embed_index.py', 'pipeline/src/mp/digest.py', 'pipeline/src/mp/publish_from_paste.py', 'pipeline/src/mp/prefetch_model.py', 'pipeline/src/mp/doctor.py', 'pipeline/src/mp/logs_cmd.py', 'pipeline/src/mp/diarize_cleanup.py', 'pipeline/src/mp/backend_fallback.py', 'pipeline/src/mp/train_adapter.py', 'pipeline/src/mp/finalize.py', 'pipeline/tests/test_ci4_contracts.py', 'pipeline/tests/test_ci3_parity.py', 'pipeline/tests/test_workflow_overlay.py', 'daemon/Sources/MeetingPipe/Logger.swift', 'daemon/Sources/MeetingPipe/PrepCard.swift', 'daemon/Sources/MeetingPipe/CorrectionStore.swift', 'daemon/Sources/MeetingPipe/ModelDownloadSupervisor.swift', 'daemon/Sources/MeetingPipe/DoctorRunner.swift', 'daemon/Sources/MeetingPipe/LocalModelPreloader.swift', 'daemon/Sources/MeetingPipe/OrphanRecordingRecovery.swift', 'daemon/Sources/MeetingPipe/RecordingManifest.swift', 'daemon/Tests/MeetingPipeTests/CI4ContractFixtureTests.swift', 'daemon/Tests/MeetingPipeTests/MetaContractFixtureTests.swift', 'daemon/Tests/MeetingPipeTests/Fixtures/*.json (fixture bodies not opened; cross-tree use established only by filename grep in both trees)'] |
| tests-swift | 29 | 38 | ['daemon/Tests/MeetingPipeCoreTests/AXLeaveButtonSignalTests.swift', 'daemon/Tests/MeetingPipeCoreTests/AXMuteButtonProbeTests.swift', 'daemon/Tests/MeetingPipeCoreTests/AXObserverBusTests.swift', 'daemon/Tests/MeetingPipeCoreTests/AdaptivePollCadenceTests.swift', 'daemon/Tests/MeetingPipeCoreTests/CallTeardownOracleTests.swift', 'daemon/Tests/MeetingPipeCoreTests/CallTeardownWatcherTests.swift', 'daemon/Tests/MeetingPipeCoreTests/ConcurrentHALTestSupport.swift', 'daemon/Tests/MeetingPipeCoreTests/CoreAudioHALBusTests.swift', 'daemon/Tests/MeetingPipeCoreTests/HALSystemMuteProbeTests.swift', 'daemon/Tests/MeetingPipeCoreTests/HALVoiceActivityProbeTests.swift', 'daemon/Tests/MeetingPipeCoreTests/IdleStopBackstopTests.swift', 'daemon/Tests/MeetingPipeCoreTests/InputDeviceIdentityTests.swift', 'daemon/Tests/MeetingPipeCoreTests/LifecycleTraceReplay.swift', 'daemon/Tests/MeetingPipeCoreTests/LogMuteAdapterTests.swift', 'daemon/Tests/MeetingPipeCoreTests/MeetingLifecycleVerdictTests.swift', 'daemon/Tests/MeetingPipeCoreTests/MicGateAdaptersStep6Tests.swift', 'daemon/Tests/MeetingPipeCoreTests/MicGateVerdictTests.swift', 'daemon/Tests/MeetingPipeCoreTests/MicGateWriterTests.swift', 'daemon/Tests/MeetingPipeCoreTests/MuteLabelsLoaderTests.swift', 'daemon/Tests/MeetingPipeCoreTests/MuteLabelsValidator.swift', 'daemon/Tests/MeetingPipeCoreTests/MuteLabelsValidatorTests.swift', 'daemon/Tests/MeetingPipeCoreTests/MuteSourceFusionTests.swift', 'daemon/Tests/MeetingPipeCoreTests/ProcessAudioScanProbeTests.swift', 'daemon/Tests/MeetingPipeCoreTests/ProcessAudioSignalTests.swift', 'daemon/Tests/MeetingPipeCoreTests/PromotionEngineTests.swift', 'daemon/Tests/MeetingPipeCoreTests/RMSGateProbeTests.swift', 'daemon/Tests/MeetingPipeCoreTests/RealAXBackendTests.swift', 'daemon/Tests/MeetingPipeCoreTests/ResourceBundleLocatorTests.swift', 'daemon/Tests/MeetingPipeCoreTests/ShareableContentSignalTests.swift', 'daemon/Tests/MeetingPipeCoreTests/TeardownHoldPolicyTests.swift'] |
| tests-python | 31 | 15 | ['pipeline/tests/__init__.py', 'pipeline/tests/test_action_clusters.py', 'pipeline/tests/test_analyze_detection.py', 'pipeline/tests/test_auto2_deeplinks.py', 'pipeline/tests/test_backlog_index.py', 'pipeline/tests/test_chunking.py', 'pipeline/tests/test_corrections.py', 'pipeline/tests/test_detection_trace_scripts.py', 'pipeline/tests/test_diarize.py', 'pipeline/tests/test_dogfood_report.py', 'pipeline/tests/test_embed_index.py', 'pipeline/tests/test_evidence.py', 'pipeline/tests/test_glossary.py', 'pipeline/tests/test_json_extract.py', 'pipeline/tests/test_local_server.py', 'pipeline/tests/test_markdown.py', 'pipeline/tests/test_markers.py', 'pipeline/tests/test_prefetch_model.py', 'pipeline/tests/test_prep.py', 'pipeline/tests/test_provider_claude_cli.py', 'pipeline/tests/test_provider_openai.py', 'pipeline/tests/test_publish_lan.py', 'pipeline/tests/test_publish_notion_blocks.py', 'pipeline/tests/test_publish_obsidian.py', 'pipeline/tests/test_rag.py', 'pipeline/tests/test_resource_guard.py', 'pipeline/tests/test_roster.py', 'pipeline/tests/test_schemas.py', 'pipeline/tests/test_speaker_overlay.py', 'pipeline/tests/test_summarize_staged.py'] |
| x-architecture | 21 | 51 | ['daemon/Sources/MeetingPipe/MeetingSessionController.swift', 'daemon/Sources/MeetingPipe/MeetingRecorder.swift', 'daemon/Sources/MeetingPipe/Coordinator.swift', 'daemon/Sources/MeetingPipe/Coordination/SinkDispatcher.swift', 'daemon/Sources/MeetingPipe/Coordination/DetectionStateMachine.swift', 'daemon/Sources/MeetingPipe/SearchIndex.swift (grep only)', 'daemon/Sources/MeetingPipe/ModelDownloadSupervisor.swift', 'daemon/Sources/MeetingPipe/LocalModelPreloader.swift', 'daemon/Sources/MeetingPipe/DoctorRunner.swift', 'daemon/Sources/MeetingPipe (about 240 other Swift files not opened)', 'daemon/Sources/MeetingPipeCore (bodies of the 40 files not read)', 'daemon/Sources/MeetingPipeObjC', 'daemon/Tests (all but two test files)', 'pipeline/src/mp/summarize_local.py', 'pipeline/src/mp/summarize_staged.py', 'pipeline/src/mp/embed_index.py', 'pipeline/src/mp/doctor.py', 'pipeline/src/mp/egress_guard.py (grep only)', 'pipeline/src/mp (about 55 other modules not opened)', 'pipeline/tests', 'scripts/truth_fences.py', 'scripts/gen_contract_fixtures.py', 'scripts/ci-local.sh', 'docs/decisions/0004-menu-bar-over-dock-app.md', 'docs/decisions/0005-no-em-dash-lint.md', 'docs/decisions/0009-stereo-on-disk-mono-on-playback.md', 'docs/decisions/0015-corrections-tab-wired.md', 'docs/decisions/0016-capture-first-mute-redaction.md', 'docs/decisions/0017-hold-long-trim-later-end-detection.md', 'docs/GUIDE.md'] |
| x-security | 28 | 27 | ['daemon/Sources/MeetingPipeCore/ (all files)', 'daemon/Sources/MeetingPipeObjC/ (all files)', 'daemon/Sources/MeetingPipe/ (about 260 remaining files, including Logger.swift, Config.swift, ConfigStore.swift, the secrets store, MuteRedactor.swift, AudioTranscoder.swift, RecordingPostProcessor.swift, LocalServerReaper.swift, ModelDownloadSupervisor.swift, DoctorRunner.swift, CLI/, Preferences/, Automation/MeetingPipeAppIntents.swift)', 'daemon/Tests/ (all files)', 'pipeline/src/mp/ remaining modules (orchestrate.py, summarize_staged.py, diarize_cleanup.py, provider_openai.py, providers.py, engine.py, rag.py, prefetch_model.py, train_adapter.py, corrections.py, events.py, failure_details.py, cloudsync.py, publish_from_paste.py, publish_cmd.py, roster.py, voiceprint.py, glossary.py, dogfood.py, finalize.py, logs_cmd.py and others)', 'pipeline/tests/ (all files)', 'scripts/ remaining (uninstall.sh, rebuild.sh, ci-local.sh, prune-worktrees.sh, truth_fences.py, lib/login-agent.sh, lib/resource-bundles.sh, test and report scripts)', 'daemon/scripts/, design/, docs/ (not opened)'] |
| x-data | 31 | 24 | ['daemon/Sources/MeetingPipe/MeetingRecorder.swift', 'daemon/Sources/MeetingPipe/Coordination/SinkDispatcher.swift', 'daemon/Sources/MeetingPipe/Coordination/PipelineJobDispatcher.swift', 'daemon/Sources/MeetingPipe/TranscriptCorrectionStore.swift', 'daemon/Sources/MeetingPipe/SpeakerLabelStore.swift', 'daemon/Sources/MeetingPipe/WorkflowCorrectionStore.swift', 'daemon/Sources/MeetingPipe/ConsentStore.swift', 'daemon/Sources/MeetingPipe/ConfigStore.swift', 'daemon/Sources/MeetingPipe/MeetingMetaSidecar.swift', 'daemon/Sources/MeetingPipe/MeetingMetaRead.swift', 'daemon/Sources/MeetingPipe/PipelineFailureSidecar.swift', 'daemon/Sources/MeetingPipe/WaveformPeaks.swift', 'daemon/Sources/MeetingPipe/MeetingDurationCache.swift', 'daemon/Sources/MeetingPipe/CloudSyncDetector.swift', 'daemon/Sources/MeetingPipe/PrivacyReach.swift', 'daemon/Sources/MeetingPipe/BackupSchedulerService.swift', 'daemon/Sources/MeetingPipe/LaunchAgentScheduler.swift', 'daemon/Sources/MeetingPipe/LastBackup.swift', 'daemon/Sources/MeetingPipe/DigestsView.swift', 'daemon/Sources/MeetingPipe/ModelDownloadSupervisor.swift', 'daemon/Sources/MeetingPipe/UncaughtExceptionLogger.swift', 'daemon/Sources/MeetingPipeCore/ (whole target)', 'pipeline/src/mp/publish_router.py', 'pipeline/src/mp/publish_notion.py', 'pipeline/src/mp/publish_obsidian.py', 'pipeline/src/mp/publish_fs.py', 'pipeline/src/mp/publish_lan.py', 'pipeline/src/mp/summarize.py', 'pipeline/src/mp/summarize_local.py', 'pipeline/src/mp/summarize_staged.py'] |
| x-performance | 16 | 42 | ['daemon/Sources/MeetingPipe/SystemAudioCapture.swift', 'daemon/Sources/MeetingPipe/SystemAudioChannel.swift', 'daemon/Sources/MeetingPipe/MeetingSessionController.swift', 'daemon/Sources/MeetingPipe/InputDeviceRecovery.swift', 'daemon/Sources/MeetingPipe/MeetingRecorder.swift outside lines 905-1054', 'daemon/Sources/MeetingPipeCore/Lifecycle/Signals/{ProcessAudioSignal,AXLeaveButtonSignal,WorkspaceSignal}.swift', 'daemon/Sources/MeetingPipeCore/MicGate/** except SlimCoreMuteLog.swift', 'daemon/Sources/MeetingPipeCore/Lifecycle/{PromotionEngine,MeetingLifecycleCoordinator,Adapters/*}.swift (grep only)', 'daemon/Sources/MeetingPipe/{TranscriptTab,MeetingStats,QuickFindWindow,LibraryWindow,LibrarySidebar,StatusBarModel,MeetingRow,SummaryTab,AudioTab,WaveformPeaks,StorageStats,OrphanRecordingRecovery,OriginalsReaper,LocalModelPreloader,LocalServerReaper,ModelDownloadSupervisor}.swift', 'daemon/Sources/MeetingPipe/Summarization/**', 'daemon/Sources/MeetingPipe/Preferences/** except the two excerpts listed', 'daemon/Sources/MeetingPipe/{Onboarding,Tutorial,Automation,Design,CLI,Util}/**', 'daemon/Sources/MeetingPipeObjC/**', 'daemon/Tests/**', 'pipeline/src/mp/{summarize,summarize_local,summarize_staged,local_server,publish_router,publish_notion,publish_obsidian,mcp_serve,mcp_tools,digest,actions,backup,restore,doctor,corrections,roster,voiceprint,workflow,egress_guard,engine,rag,providers}.py', 'pipeline/tests/**', 'scripts/**', 'ARCHITECTURE.md, CONVENTIONS.md, README.md (not opened)'] |
| x-concurrency | 19 | 33 | ['daemon/Sources/MeetingPipeCore/Lifecycle/Signals/ProcessAudioSignal.swift', 'daemon/Sources/MeetingPipeCore/MicGate/Probes/AXMuteButtonProbe.swift', 'daemon/Sources/MeetingPipeCore/MicGate/Probes/HALVoiceActivityProbe.swift', 'daemon/Sources/MeetingPipeCore/MicGate/Probes/HALSystemMuteProbe.swift', 'daemon/Sources/MeetingPipeCore/Infra/CoreAudioHALBus.swift', 'daemon/Sources/MeetingPipeCore/Infra/Schedulers.swift', 'daemon/Sources/MeetingPipe/Design/MicLevelMonitor.swift', 'daemon/Sources/MeetingPipe/BoundedEngineStart.swift', 'daemon/Sources/MeetingPipe/EngineTeardown.swift', 'daemon/Sources/MeetingPipe/GuardedTapInstall.swift', 'daemon/Sources/MeetingPipe/AbandonedEngineCalls.swift', 'daemon/Sources/MeetingPipe/StopStallWatchdog.swift', 'daemon/Sources/MeetingPipe/CLI/PrefetchModelsCommand.swift', 'daemon/Sources/MeetingPipe/SearchIndex.swift', 'daemon/Sources/MeetingPipe/SearchIndexer.swift', 'daemon/Sources/MeetingPipe/MeetingAXWindowWatcher.swift', 'daemon/Sources/MeetingPipe/Preferences/StorageStatsStore.swift', 'daemon/Sources/MeetingPipe/Preferences/MCPStatusStore.swift', 'daemon/Sources/MeetingPipe/SummaryTab.swift', 'daemon/Sources/MeetingPipe/ProjectionPass.swift', 'pipeline/src/mp/prefetch_model.py', 'pipeline/src/mp/resource_guard.py', 'pipeline/src/mp/provider_claude_cli.py', 'pipeline/src/mp/train_adapter.py', 'pipeline/src/mp/corrections.py', 'pipeline/src/mp/merge_meetings.py', 'pipeline/src/mp/backup.py', 'pipeline/src/mp/publish_lan.py', 'pipeline/src/mp/diarize_cleanup.py', 'scripts/valid1_check.py'] |
| x-antipatterns | 20 | 30 | ['daemon/Sources/MeetingPipe: about 248 of 280 Swift files not opened (all UI views, recorder and capture graph, detection, hotkeys, HUD, Preferences panes other than Advanced, tutorial, search indexer, workflow stores)', 'daemon/Sources/MeetingPipeCore: all 40 files (grep only)', 'daemon/Sources/MeetingPipeObjC: 2 files', 'daemon/Tests/MeetingPipeTests: about 241 of 244 files (grep only)', 'daemon/Tests/MeetingPipeCoreTests: all 38 files', 'pipeline/src/mp: about 60 of 70 modules not opened (summarize.py, publish_notion.py, publish_obsidian.py, publish_fs.py, publish_lan.py, embed_index.py, doctor.py, backup.py, restore.py, digest.py, diarize.py, diarize_cleanup.py, mcp_serve.py, egress_guard.py, entry.py, resource_guard.py, local_server.py, train_adapter.py, dogfood.py, analyze_detection.py and the rest)', 'pipeline/tests: all 82 files (grep only)', 'scripts: 25 of 27 files (install.sh grepped for one check)', 'bench/, design/, ds-bundle/, docs/ (outside the source-and-tests scope or excluded by the brief)'] |
| build | 11 | 15 | ['scripts/install.sh', 'scripts/rebuild.sh', 'scripts/uninstall.sh', 'scripts/test-app-relocation.sh', 'scripts/test-login-agent-guard.sh', 'scripts/test-prune-worktrees.sh', 'scripts/truth_fences.py', 'scripts/gen_contract_fixtures.py', 'scripts/bundle-runtime.sh', 'scripts/pre-commit', 'scripts/lib/pipeline-venv.sh', 'scripts/lib/sign-app.sh', 'scripts/lib/login-agent.sh', 'the bodies of the 3531 Swift and 1559 Python tests beyond the ones named above', 'README.md / ARCHITECTURE.md / CONVENTIONS.md (one grep for coverage figures only)'] |
| gap-1 (Late-landing commits: REC20 low-space stop, PIPE36 in-daemon deadlines, PIPE37 supervision, PERF13 logger, PIPE22) | 16 |  | [] |
| gap-2 (Workflow editor, Clarify and vocabulary, and people-naming write paths (never read in full)) | 38 |  | [] |
| gap-3 (Gate integrity: truth fences, contract-fixture generator, fixture bodies, and owner-run measurement scripts) | 37 |  | [] |
| gap-4 (Detection and mute decision tests versus the semantic defects found in the core) | 43 |  | [] |
| gap-5 (What the product says about itself: GUIDE.md, SETUP.md, the tutorial, the setup checklist and ADRs 0016/0017 against the code) | 25 |  | ['scripts/lib/dev-cert.sh', 'scripts/lib/login-agent.sh', 'scripts/lib/resource-bundles.sh', 'scripts/lib/sign-app.sh', 'daemon/Sources/MeetingPipe/PermissionsCenter.swift', 'pipeline/src/mp/egress_guard.py', 'pipeline/src/mp/provider_claude_cli.py', 'daemon/Sources/MeetingPipe/Onboarding/ (permission order in the Welcome flow not traced)'] |
| gap-6 (Accessibility floor and read-side correctness over the unread Library views and Design primitives) | 37 |  | [] |

### The completeness critic's notes

All paths in gaps and still_uncovered are relative to it, matching the lists I was given. HEAD is 4949c9c0, tree clean.

Method. git ls-files over daemon/Sources, pipeline/src, scripts, .github plus daemon/scripts gives 448 files and 112,893 lines. 358 are on the read-in-full list; 90 are not, totalling 20,978 lines: daemon/Sources 63 files and 12,433 lines, scripts 10 files and 4,274 lines, daemon/scripts 15 files and 4,268 lines, pipeline/src 2 trivial __init__ files. pipeline/src and .github are fully read. Nothing on the read list is missing from the tree.

Most important finding: the audit read a moving target. Five commits landed after base 330d20fe (PIPE22 17:22, PERF13 17:30, REC20 18:10, PIPE37 18:14, PIPE36 22:56, committer time on 2026-11-12), changing 46 source files by +2,831/-459 and adding 3,362 test lines. File lengths at each revision show auditors read different states: one recorded __main__.py at 330d20fe (264 lines, now 372); spine quotes MeetingSessionController at 1,980 lines, which is post-REC20; excerpt ranges up to SinkDispatcher 960, PipelineLauncher 1690 and FluidAudioRunner 480 are post-PIPE36. So "read in full" does not mean "read at HEAD" for the files in slice 1, and the two new REC20 files are on no list. I read those two files (341 lines) and the PIPE37 hunk of __main__.py to write a precise focus; I did not audit them.

Shape of what was unread. The unread daemon source is almost entirely Library and workflow UI plus pure presentation types; my grep for deletes, spawns, network and file IO over those 63 files found almost none directly, so the risk is in what they tell the stores to write (slice 2) and in what they show (slice 6). The unread scripts are CI gates and owner-run tools (slice 3).

Lens gaps judged from the assessments. Accessibility (PRODUCT.md lines 52 to 62) and documentation truth (GUIDE.md, SETUP.md, tutorial, ADR guarantees) were not applied by anyone; slices 6 and 5 cover them. Test quality was applied to 71 of 281 Swift test files and 46 of 82 Python ones, and skipped MeetingPipeCoreTests almost entirely, which is where the core auditors found semantic defects; slice 4 covers that. Gate integrity was shown weak by build and tests-swift but the main gate script was never read; slice 3. Priority order is the order given: 1 and 2 are the ones I would not skip.

Caveats. Slice sizes are about 5,700 to 6,100 lines each; slice 1 mixes full reads with diff hunks to stay in budget, and slice 5 is small in lines but heavy in cross-referencing. The leads inside each focus (for example WorkflowChipView having no accessibility modifiers, or NDA plus Notion being saveable) are places to look, not verified findings. I could not get a second opinion on this selection in this run; the advisor tool was rate-limited.

### Still not covered

- daemon/scripts/ owner-run spike probes: 15 files, about 4,270 lines, none read (det6-browser-url-probe.swift 805, cal3-teams-title-probe.swift 721, diar4-offline-diarizer-probe 460, det10-mic-busy-probe.swift 355, dep1-native-audio-spike.swift 290, det2, end6, ai-summarize.swift, cal1, det8, ax-dump-meeting.swift, mic7 js, mic8 sh, auto1-app-intents-probe.sh). Not shipped and not run by CI; install.sh points at auto1-app-intents-probe.sh as a regression guard and engine_compare_report.py consumes ai-summarize.swift output. They read browser URLs, calendar events, AX trees and Teams logs and write dumps, so the residual risk is hygiene and what a dump contains.
- scripts/gen-icon.swift (162) and scripts/gen-readme-hero.swift (184): asset generators, unread; gen-icon removes files and spawns a process.
- Swift tests: 210 of 281 test files (about 40,000 of 65,650 lines) were never opened; the gap slices above pick up about 20 of them, leaving roughly 190 files and 34,000 lines. Largest untouched: ConfigStoreTests 668, VoiceResolutionTests 650, MeetingSourceScorerTests 538, MeetingSourceScannerTests 529, PrepCardTests 525, MeetingCastTests 515, WorkflowStoreTests 500, AudioPlaybackControllerTests 488, ActionResolveTests 485, plus the remaining 14 MeetingPipeCoreTests files (ShareableContentSignalTests, MuteLabels*, RealAXBackendTests, CoreAudioHALBusTests, HAL probe tests and small ones).
- Python tests: 36 of 82 files (about 7,980 lines) not reached; slice 3 takes three, leaving 33 files and about 7,300 lines. Largest: test_embed_index 829, test_analyze_detection 591, test_summarize_staged 581, test_local_server 478 (extended by PIPE22), test_evidence 436, test_corrections 434, test_resource_guard 342, test_diarize 318, test_roster 262, and the sink tests test_publish_obsidian 207 and test_publish_notion_blocks 164 that sit under py-publish's data-loss findings.
- Test fixtures beyond slice 3: the 43 detection-corpus JSON traces were only scanned by script for free-text fields; pipeline test data files were not opened.
- Vendored third-party code that runs on user data, read only in targeted ranges: FluidAudio (DownloadUtils.swift 797 lines, ModelRegistry.swift 166, model loading for ASR and diarization), TOMLKit's decoder, mlx_lm/server.py (1,904 lines, the loopback model server), httpx and the Hugging Face download path behind prefetch_model. Model download integrity and the server's request handling have not been read end to end; x-security says the same.
- Long-form docs read by grep or skim only, by design or by omission: README.md, ARCHITECTURE.md, CONVENTIONS.md, daemon/docs/gotchas.md (263 KB), pipeline/docs/gotchas.md (37 KB), DESIGN.md, ADR 0005, docs/validation/valid1-acceptance-runbook.md, docs/engine-comparison.md, docs/local-llm-quality.md, bench/parakeet-vs-whisperx/REPORT.md.
- docs/spikes (29 files including 5 Python scripts and JSON result files) and docs/research (2 files): not opened; the result files may carry measurements taken from real meetings.
- Design assets: design/ (tokens CSS, ui_kits JSX, previews, 37 files), .design-sync/ (71 files), .impeccable/design.json, and the five AppGlyph SVGs (checked here: 349 to 474 bytes each, no script, image or external reference).
- Small tracked metadata never listed: .gitattributes, glossary.example.toml, LICENSE, AGENTS.md symlink, pipeline/src/mp/__init__.py (3 lines) and prompts/__init__.py (empty).
- Excluded by the brief and therefore unaudited: .claude/ (4 command files, hooks and settings), docs/audits (11 files), docs/backlog (241 files).
- Lenses still thin after these slices: the anti-pattern lens by its own account opened about 6 percent of files (its mechanical patterns, try? turning unreadable into absent and copied helpers, could be swept by grep across the whole tree); the security and concurrency lenses did not open any test file; the daemon/CLAUDE.md rule list (about 60 stated invariants) was read for claims only and never checked rule by rule against the code.

### Slice assessments

**capture.** The capture core is unusually defensive: bounded engine calls, generation gating, temp-and-promote merges. I found no path that silently discards captured audio on crash, kill or disk-full. The weak spots sit at the seams the hardening created. Mic and system channels follow different padding rules (anchor, clamp, backlog accounting); mic recovery has two triggers that do not coordinate; and the redaction lifecycle keeps its only copy of the timeline in memory, so privacy intent usually ends in quarantine or a silent withhold. Comments are long and confident, and several are stale or wrong against the code. Not established: frame-level boundary precision of the ffmpeg redaction, and the HAL behaviour behind the two inferred findings.

**core-lifecycle.** The pure decision types are genuinely pure, and the generation and queue discipline is consistent; mechanically this is careful code. The weakness is semantic: the engine reasons over edges while signals deliver levels, so first readings, steady `.live` readings and old `.ended` stamps are each mishandled, and three stated guarantees (END8 rescue, two independent classes, held tail is post-call) do not hold as coded. Teams is shielded by the process-audio veto, which hides these on the owner's main path and concentrates trust in one signal with no unknown state. Dwells use wall-clock `Date` (low risk); `WindowTitleSignal` still does AX IPC on main. Comments cite measurements heavily and several describe behaviour the code lacks. Nothing was executed: every finding is from reading, and the two marked inferred rest on OS or app behaviour I could not observe.

**micgate-ax.** Threading in this slice is careful: every cross-process AX call is off main with generation guards, decisions are pure and tested, and comments carry measurements. The weakness is epistemic. Three mute oracles (AX probe, 1 Hz watcher, SlimCore log) write one field with dedupe-before-accept, and several "discredit the mute" escape hatches added after capture-loss incidents fail open on privacy in exactly the muted-aside case, one of them even under the regulated gate. Per-app recognition is string heuristics checked only against hand-written titles (all 21 fixture rows are seeded), the title extractor and recognizer already disagree, the mic-in-use tier watches a launch-time device, and README privacy and extensibility claims have drifted from the code. The advisor tool was rate-limited, so findings were self-verified only.

**spine.** Mixed. Logging, the stop funnel and main-queue discipline for callbacks are solid, and much logic is extracted into testable pure functions. The core is not: MeetingSessionController is a 1,980-line object whose correctness rests on 29 mutable flags reset at scattered sites, and the in-flight start is a Bool rather than a state. Privacy routing (workflow override, resume) and the regulated mic gate for source-less recordings are the weakest areas. Comments are long, incident-driven, and several are false against the code. The single-instance guard is an unlocked Launch Services check-then-act; a simultaneous-launch race is plausible but only inferred, so it is not listed. Nothing was built or run; counts came from grep, everything else from reading.

**boundary.** The process boundary is mostly sound: argv-only spawns, env-borne secrets, continuous pipe drains, per-run cancel flags, a SIGTERM then SIGKILL ladder, stdin-EOF supervision, a verified promote for recordings. The defects sit at edges no fence covers: an unauthenticated URL scheme, one privacy read that bypasses the fail-closed sidecar reader, a no-ffmpeg fallback that reports half a recording as success, synchronous unbounded Keychain calls on main. Comments overstate repeatedly. Executable resolution: findMP walks 10 parents for pipeline/pyproject.toml and has a bare PATH tier, findFFmpeg prefers PATH over the bundled binary; low risk under launchd's PATH. Keychain ACL behaviour rests on a code comment only, unverified.

**store.** Mixed. The scan, cache and index plumbing is careful: atomic writes, bound SQL, off-main work, a real failed-listing guard, fail-closed meta and config reads. The weak part is everything around it. Destructive sweeps reason from premises the rest of the code no longer satisfies (originals are only recovery copies; a summary means done), fail-open reads feed read-modify-write stores, and long-lived in-memory state (library path, workflows, config snapshot) is never reconciled with a move, a restore or a hand edit. Seen but not filed: a damaged index.sqlite is never rebuilt (schema statements emulated with python sqlite3 all fail, file stays), WorkflowStore silently skips an undecodable workflow, ConfigStore rewrites its launch-time snapshot over later hand edits. Comments are often more confident than the code.

**ui-library.** Careful at the micro level (memoized derivations, off-main reads, bounded audio engine calls, pure decision types) but structurally fragile in the detail pane: one reused view tree holds per-meeting state, long-running continuations write into it, and the guards meant to stop that are no-ops. Destructive actions are gated inconsistently: batch forms confirm, single-meeting forms and the live-recording case do not. Comments are often more confident than the code (stale-stem guards, the 'one' markdown rule, Stop buttons that cannot fire). Coverage: 20 files read in full (about 10k of 17k lines), 7 partially, 22 only pattern-grepped for disk, process, timer and observer use, so the rails (People, Stats, Facts, sidebar, filters, cast strip) are effectively unexamined. Nothing was executed.

**ui-chrome.** Timers, window lifecycles and fail-closed config handling are careful, but comments describe intent the wiring does not always deliver. The consent surface is the weak point: the hover pause is cosmetic and 'Always' cannot be undone in-app. Preferences binds controls straight to stores that shell out or rewrite whole documents, so stale snapshots, main-thread subprocesses and unreconciled launchd state recur. Onboarding is the least maintained corner: it bypasses the design primitives, re-implements PermissionsCenter's deep links (its Notifications URL has already drifted) and contradicts CLAUDE.md's 'wizards deferred'. Not filed: neither panel sets sharingType, so the HUD (workflow name, NDA tag) and the prompt's 'Last time' notes appear in full-screen shares.

**py-summarize.** Mechanism by mechanism this slice is careful and often measured, but its comments claim more than the code delivers. Zero-egress backend routing holds. The weak points are the seams around it: the claude CLI provider is an unsandboxed agent session, the series-continuity block ignores the per-meeting privacy gate, the reduce step rebuilds its prompt without the fence, and the memory ceiling binds in one of fifteen preset/RAM pairs. Model-server sharing across processes is still racy after PIPE22, which landed mid-audit (changed regions re-read). Not listed: free-form `engine` calls default to the MeetingSummary `response_format`, masked only because mlx-lm 0.31.3 ignores it; validator errors are replayed outside the fence; the OpenAI provider has no transient retry.

**py-publish.** The policy core is sound: one zero-egress predicate, a fail-closed per-meeting visibility gate and a stdio-only MCP surface. The sinks are weaker. Idempotency and pathing in Obsidian, Notion and the paste path destroy or misplace content, and docstrings promise more than the code does (stem-based paths, deterministic Notion slug, config-time sink validation, per-call MCP gate). Smaller unlisted items: an unknown sink name or invalid summary raises before `<stem>.publish.json` is rewritten; `publish_lan` accepts an existing unmounted mount point; `_yaml_str` leaves `[`, `{`, `,` unquoted (executed); `_create_page` is not chunked at 100 blocks; `doctor.py` never arms the guard (observed, not traced). Performance is acceptable: exact search, but each refresh rewrites the whole index. Line numbers at HEAD fcae9623.

**py-orchestrate.** Mixed. The privacy core is careful: one entry contract, a fail-closed sidecar read, atomic 0600 transcript writes, a sound restore traversal defence. The edges are weaker. People data (roster, voiceprint, per-meeting embeddings) gets none of that discipline: no lock, unreadable treated as empty, 0644, no deletion path. Merge and cleanup trust per-meeting labels and model-supplied indices. Backup and restore succeed too easily (hollow archives, in-place overwrite). Doctor reads only global config, so its sync and readiness verdicts miss workflow-level routing. No lock guards two runs on one meeting; the daemon's lane is the only protection. `run-all --backend` is lost inside cleanup (re-overlay). Comments are dense and mostly accurate, yet several load-bearing ones did not hold. No critical finding.

**install-ci.** The shell layer is carefully written and better than most personal installers: strict mode, consistent quoting, bounded deletes, hash-locked Python dependencies. Its weakness is that it states beliefs about macOS (TCC, launchd, codesign) as confident comments that nothing tests, and install.sh and rebuild.sh contradict each other on the same launchd mechanism. The uninstaller's inventory has drifted from what the app writes, in both directions. bundle-runtime.sh has never run as committed. The most important fact is outside the repo: the app running on this Mac is a September binary on a pre-DIST4 editable venv, so recent fixes are not executing while HEAD Python is. About 3,500 lines of helper Python and Swift scripts were not reached. The second advisor review was unavailable (rate limited).

**contracts.** The explicitly modelled contracts are healthy: meta sidecar, publish.json with exit 3, restore plan keys, failure vocabulary and the summary field set agree on both sides, with tolerant readers and fail-closed privacy reads. The defects sit where a behaviour exists in one tree only, or twice: the Apple summarizer versus mp.summarize, overlays the publishers never apply, merge treating per-recording labels as global, a name-keyed glossary beside UUID-keyed workflows, and Swift as an unvalidated second writer of summary.json. One real privacy gap: AI6 prior-meeting context crosses the zero-egress boundary. Exit code 3 is the only stage signal, so every pre-sink publish failure is misfiled. Nothing was executed; findings come from reading, in a repo that changed during the audit.

**tests-swift.** Better than an AI-written suite usually is, and weakest exactly where the product can lose a meeting. Of 3,241 tests (8,435 assertions) I estimate 75 to 80 percent of test code buys real regression protection: pure decision logic, file-level stores, real-ffmpeg merge and redaction. About 90 tests in 43 files are source-text fences, concentrated on the recorder, Coordinator wiring and system capture, which have no headless seam; several of those fences are vacuous on inspection. The one subprocess test of the launcher does not run in CI. The estimate rests on 29 files read in full and 38 partly read of 273; 208 were not opened, so the UI and Core shares are extrapolated.

**tests-python.** Better than most AI-written suites: the bulk is real-behaviour tests over tmp files with in-memory fakes, and several AST fences guard themselves. The weak spot is isolation. conftest.py isolates the event log and server marker but not HOME, config.toml, the Keychain or the network, so behaviour on the owner's Mac differs from CI and rests on per-test stubs. Some tests pin the wrong thing: a merge retry that loses audio, a forced restore checked by count, a Notion republish checked by key names. Inventory: no xfail; three skip sites (module-level importorskip mcp, in-test importorskip soundfile/numpy, skipif xattr). Performance: several seconds of real sleeps, plus up to four security spawns per entry-point test.

**x-architecture.** The shape is sound in two places (the MeetingPipeCore island, and Python's single egress chokepoint plus provider table) and weak at the seam between the trees. The split costs about 7k lines of Swift glue and mirrors, 16 daemon-invoked subcommands, roughly 26 shared file kinds and about 18 mirrored rules, of which 10 are fixture-pinned. Its stated benefit, an offline daemon, is already untrue. Every concrete defect found sits where one rule exists twice: summarize, effective backend, title, app identity. The 71k-line single target has no internal access control, so layering is policed by text greps and a view can overwrite a sidecar. Docs are accurate on file locations but stale on invariants. The advisor tool was rate-limited, so this result had no second review.

**x-security.** The policy core is better than most: one zero-egress predicate, an ordered entry contract, fail-closed sidecar reads, argv-only spawns, a stdio-only MCP server. The gaps sit at edges that grew later: a cross-meeting context feature that bypasses the per-meeting gate, a CLI provider whose safety comment is wrong, an unauthenticated URL scheme and loopback port, and MCP fencing the docstrings overstate. Comments repeatedly assert properties the code does not have. Not examined: FluidAudio and `mp prefetch-model` downloads show no regulated gate by grep (model fetch only, not traced), ffmpeg argument strings, Swift log contents, file modes beyond the Python sinks and backup archive. The performance lens produced nothing in this sweep.

**x-data.** The storage core is careful wherever one writer owns one file: atomic renames, verified transcodes, fail-closed retention, a checkpointed index, private logs. The holes sit at the seams between owners. Delete, move, merge and restore each update the artifacts their author knew about and leave the rest: correction records, the Python embedding index, per-meeting voice embeddings, absolute paths inside sidecars, in-memory stores, the shared model cache. Cloud-sync detection covers the library but not the backup that copies it. Version fields are written almost everywhere and read almost nowhere. There is no single inventory of per-meeting and per-user artifacts, so every lifecycle operation re-derives the list and misses some. I did not reach the recorder, the publishers or the tests, and the advisor tool was unavailable.

**x-performance.** Nothing critical or high found. The daemon has clearly been through repeated performance passes: the recording, transcription, in-call polling and Library scan paths I read are bounded, off main and single-flight. What remains is at the edges. Two idle costs survive (three full AX walks per discovery poll for a lone meeting app, and an always-on 1 Hz log-directory poll whose own comment understates it). Several main-thread subprocess or directory round-trips sit outside the files earlier rules were written about (batch trash, launchctl schedule toggles, Keychain at launch, a submenu). Per-scan AX cost is inferred, not measured. Coverage is partial: the system-audio capture path, MeetingSessionController and InputDeviceRecovery were not opened, so audio-thread claims are limited to the mic tap.

**x-concurrency.** The recording spine is the best-defended code here: bounded engine and SCStream calls, generation gates, a main-confined dispatcher, once-only continuations. I found nothing there that silently loses a recording. The weak points sit at seams the incident-driven hardening has not reached: two mp processes sharing one model server, the launcher's pipe handling, Notion's wipe-then-append, MicGate's unlock-then-enqueue, and static state that targeted mode cannot see. Much safety rests on unenforced "main only" conventions (`@unchecked Sendable`, plain cross-thread counters and references in MeetingRecorder and SystemAudioChannel) rather than isolation; complete mode would flag dozens of sites. Coverage was partial: ProcessAudioSignal, AXMuteButtonProbe, the HAL probes, MicLevelMonitor and most UI Task.detached sites were not read. The advisor tool was rate-limited, so no second review ran.

**x-antipatterns.** Coverage is thin: about 20 files read in full and 28 in part out of roughly 780, chosen for data-lifecycle and cross-tree seams, so absence of a finding elsewhere means little. Performance was not examined in depth. The recurring defects are structural: try? collapsing unreadable into absent (37 inline JSON reads plus four copied helpers), one rule implemented at several sites where only one was hardened (SEC25 covers the Library retry but not orphan recovery), cross-tree state carried as string literals, and comments that assert properties the code no longer has. Ten Swift source files and one Python module exceed 1,000 lines, with comments near half their length. The code is careful where an incident already happened and optimistic everywhere it has not.

**build.** The suites are healthy where they are measured: everything passes, fast, with real isolation from the live app. The weaknesses sit around the tests, not in them. Test tooling misleads (the coverage script reports 90.0% for a daemon that is at 51.0%, with the recorder at 17% and the app spine near 0%), the Swift suite leaks hundreds of MB of temp data per run (16.4 GB accumulated here), one pytest test makes a live network call, and the Python lock has drifted behind 13 packages' advisories with no audit gate. The FluidAudio pin is five months and four minor versions behind upstream on an OS upstream is still fixing for, and it pins code but not model weights.

**gap-1.** Each commit is careful about the failure it targets: late transcription returns are fenced on main, the logger is one locked O_APPEND writer, and the supervision pipe is not inheritable through any spawn I found. The defects sit at seams with older code. REC20 decides a stop with a free-space reader built to label a failure, and that reader returns zero off the boot volume. PIPE36 fences the transcript but not the redactor's file moves. REC20's retention fallback keys on a parse result. The watch's real timer and the Coordinator wiring are pinned only by source-text fences; every behavioural test passes startsTimer false. A writable external disk was not exercised.

**gap-2.** The pure decision types are careful and well tested, and the privacy clamp itself held under every state I tried. The write paths around them are weaker. Identity rides on mutable names (workflow name for scopes and vocabulary, person name for the roster), so a rename or an undo reaches far further than its copy says. The re-transcribe carry measures overlap in one direction and its host does a minutes-long read-modify-write; two glossary writers coexist. Several comments assert safety the code does not have. Tests cover derivations, never the save or confirm handlers. Not listed: roster rename logs people's names verbatim to the event log, and a failed rename carry has no retry path.

**gap-3.** Healthier at the core than the brief feared: the config and event fences failed correctly on constructed dead inputs, and every CI3/CI4/meta golden is value-asserted by both trees. The weak spots are gates that assert their own model of a writer: the prefetch golden never runs `_emit`, meta-contract pins half the keys Python reads, the promotion-trace redaction check accepts free text, and 20 'real' corpus traces are 4 templates. valid1_check.py is the least trustworthy file (mispaired timings, vacuous UX4/DIAR passes, kill paths that miss the model server). Smaller gaps: the CLAUDE.md entry budget ignores paragraphs (root has a 1,599-byte one), the link fence skips 4 tracked .claude/commands files, dump_window_titles.swift cannot emit `unknown`. No critical or high findings.

**gap-4.** Thorough on mechanics (threading, dedupe, boundaries), thin on meaning. Against the core defects: held tail, blind-clear and dedupe-before-accept are pinned as intended; the lone process-audio end asserts the opposite of the stated rail; END8 and native app quit are tested through events the session's adapter never emits; first-reading-as-edge, live-sibling contradiction, stale veto and start-in-flight are absent. Fakes deliver one clean edge per signal, live first, never ended-then-unreadable. The corpus is 28 of 41 Teams promotion traces, 16 self-confirming, one raw. CallTeardownWatcher also loses its read position on a single failed listing, which no test checks. Green here means the engine still does what it does, not that a meeting survives. All traces were hand-read; a Python port of the engine re-checked them, the shipped code was not run.

**gap-5.** User-facing labels are unusually accurate: a mechanical sweep of about a hundred named controls found none missing, and the REC20, backup and end-detection numbers match the code. The defects sit where the documents make unconditional promises over conditional paths: quitting mid-recording, the Confirming end tail, recordings described as kept that sit on a 30-day reaper, what leaves the Mac when Notion is a sink, and an uninstaller that removes more than SETUP says. The setup checklist and doctor are two reachability models that disagree in both directions. ADRs 0004, 0015 and 0016 describe superseded behaviour. Not verified: tutorial layout on a real screen, SETUP's Gatekeeper right-click claim, permission order in PermissionsCenter, egress_guard and the Claude CLI provider.

**gap-6.** Pure derivations (stats arithmetic, facts aging, date bucketing, digest and Ask-width copy) are careful and came back clean, as did the date formatter and token names (only dark pulse-600 drifts from the CSS). The weak seam is state derived twice: workflow and NDA membership by name versus sidecar, lifecycle by scan versus live overlay, Ask's pane versus the pipeline's visibility gate. Delete paths trust UI gating that ignores a live recording, and the saved-folder Delete (LibraryWindow.swift:824) is unconfirmed. PRODUCT.md's floor is partly aspirational: named pulses ignore Reduce Motion, the chip and waveform declare nothing, RecordKey is pointer-only, nothing implements text scaling. Not traced: merged-meeting double counting, tab order, the recorder's stop path after a trash.

## Method

1. **Find.** 21 finders, each given one slice and told to apply every lens to it: 14 subsystem slices (capture, core lifecycle, MicGate and AX, spine, process boundary, store, Library UI, chrome UI, pipeline summarize, pipeline publish, pipeline orchestration, install and CI, cross-tree contracts, and two test-quality slices) and 7 cross-cutting sweeps (architecture, security, data, performance, concurrency, antipatterns). One more agent was the only one allowed to build and run tests.
2. **Dedup.** In code, no agent: findings on the same file within 8 lines were merged, and independent rediscovery was recorded.
3. **Verify.** Fresh agents briefed to refute. Critical findings got two skeptics with different lenses (trace the path; reach the state), highs got one, mediums were verified in batches of six. Every verification ran at HEAD `4949c9c0`.
4. **Gap round.** A completeness critic compared what was read against `git ls-files` and sent six more finders at what was missed, including five commits that landed on `main` while the first round was running. Their findings were verified the same way.
5. **Reconcile.** Only then were confirmed critical, high and medium findings compared with `docs/backlog/tasks/` and `docs/audits/`.

Agents: 106 in total (22 finders, 6 gap finders, 1 critic, 61 verifiers, 16 reconcilers), no failures. The run was paused once and resumed from its journal.

**Limits.** The first round read a moving target (see the critic's notes), though verification did not. The live library was out of scope, so nothing here says whether any defect has already cost a real meeting. Accessibility and documentation truth were applied only in the gap round. About 190 Swift test files and 33 Python test files were never opened. Vendored code that runs on user data (FluidAudio model loading, `mlx_lm` server, the Hugging Face download path) was read only in targeted ranges.
