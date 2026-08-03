# HYG6: spec-truth sweep, stale citations and two walkthroughs that cannot pass

Filed 2026-08-03 by the audit band. Medium. This is the task-spec half of the doc-truth work, split from DOC12 because the audience is different: DOC12's readers are humans reading the product's documentation, and this one's readers are sessions executing a spec and the owner following a walkthrough.

## Why this matters more than a citation sweep sounds

The 2026-07-31 owner-owed pass closed 13 tasks and found that its dominant defect was **four task specs describing behaviour the code did not have**, each of which would have produced a false pass had the owner not been walked through it carefully. This row carries the instances that survived that pass, found by an angle whose whole job was to re-test every spec claim against code.

Note what was **re-validated and dropped** on 2026-08-03 rather than filed, because the owner correctly questioned whether specs curated during that pass deserved re-opening: AI11's step 5 wording is loose but the owner already executed that leg successfully on 2026-07-31 (interrupted at 112 stems, resumed at 112), so it is not worth an edit; HYG5's own counts have drifted but a session executing HYG5 greps for the real set anyway. Both were dropped. The three below survived re-validation.

## 1. DIAR2 and DIAR3 tell the owner to watch for a `THEM-*` chip on the surface that renders `Unknown A`

**Fixed in place on 2026-08-03 rather than left for this task, because DIAR2 is P1 and the owner is running its sweep now.** Recorded here as the trail.

`docs/backlog/tasks/DIAR3.md:74` step 6 says "read the cast strip above the transcript ... an over-split shows an extra unnamed `THEM-*` chip". `docs/backlog/tasks/DIAR2.md:37` uses the same wording, and `:30` step 4's over-split trigger depends on it.

The cast strip does not render `THEM-*`. `daemon/Sources/MeetingPipe/VoiceResolutionBar.swift:120` is `Text(voice.displayName)`, and `daemon/Sources/MeetingPipe/VoiceResolution.swift:112-113` states `displayName` "is what the transcript shows", mapped through `TranscriptDisplay.displayName`, which at `daemon/Sources/MeetingPipe/TranscriptTab.swift:157-159` turns `THEM-A` into `Unknown A`.

This is the FEAT11 defect shape exactly (FEAT11 step 3 told the owner to click a `THEM-*` chip when the UI renders `Unknown A/B/C`), recurring in two more specs. The audit's own skeptic initially refuted this finding by proving `THEM-*` **does** render in the summary, which is true and is why the summary is a valid place to see cluster labels. The owner corrected it on 2026-08-03: `THEM-*` appears only in the summary view, never in the transcript view or the cast strip, and DIAR3 step 6 names the cast strip. Recorded because the near-miss is instructive: a refutation that proves a string exists **somewhere** does not answer whether it exists on the surface the step points at.

## 2. UX48's step 7 and its acceptance pre-register an observation the scoped fix cannot produce

`docs/backlog/tasks/UX48.md:66` step 7: "with another app frontmost and **no menu open**, press **Cmd+K**. Pass: Quick Find appears with keyboard focus". `:33` asserts the same as acceptance, so it is not a walkthrough slip.

It cannot pass, for two independent reasons:

- With another app frontmost, macOS delivers the command-key equivalent to that app. UX48's scope (`:23`) installs a main menu only while MeetingPipe is `.regular`, and with the Library closed it is `.accessory` with no main menu at all.
- The scope's enumerated menu contents (`:25`) are the App menu (Preferences), an Edit menu, and a Window menu (Minimize, Close). **No Quick Find item.** So even frontmost-and-`.regular`, nothing in the main menu matches Cmd+K.

The risk is concrete and named in the spec's own "not in scope": a session chasing the stated acceptance adds a Carbon global hotkey via `HotkeyManager`, which `:35` explicitly forbids ("Do not add per-shortcut view-hierarchy handlers. That is the approach `292dfe49` took and it is the thing this task exists to stop repeating"). It is also a near-verbatim re-run of UX39's step 5, whose premise was refuted in writing on 2026-07-31.

Fix: correct step 7 and the `:33` clause to what a main menu can deliver, Cmd+K with MeetingPipe frontmost and the status-bar dropdown closed. Add a Quick Find item to the enumerated menu contents, or drop Cmd+K from the acceptance. If a genuinely global Cmd+K is wanted, say so as separate scope and name the mechanism, because it is a different feature with different consequences.

## 3. VALOWN1 tells the owner to paste probe output into a suite that hard-asserts the value the probe hardcodes

`daemon/scripts/cal3-teams-title-probe.swift:494` emits `"expected": "recognize"` as a string literal for every capture, without ever calling `MeetingSourceScanner.isActiveMeetingWindow` to check whether that is true.

`daemon/Tests/MeetingPipeTests/WindowRecognizerFixtureTests.swift:54-56` is `let expected = (entry.expected == "recognize")` then `XCTAssertEqual(recognized, expected, ...)`, a hard assertion rather than a report.

`docs/backlog/tasks/VALOWN1.md:46` instructs, "**whatever the verdict says**", that "the emitted fixture block replaces the seeded Teams entries ... with `seeded: false`".

So if any real captured Teams title is one the recognizer rejects, which is plausible **precisely because CAL3 exists on the finding that real Teams titles do not match this repo's guessed formats**, the paste turns weeks of owner capture into a red suite on an unrelated commit. VALOWN1's own acceptance ("the fixture test reports a non-zero captured count") would be satisfied while the suite is failing.

Secondary: `cal3-teams-title-probe.swift:472-474` emits states `in_meeting_named_series` and `in_meeting_ad_hoc`, neither of which exists in the fixture's 21 entries, so "REPLACING the seeded rows" has nothing to replace for those and the paste grows the fixture rather than converting it.

Fix: make the probe compute `expected` by calling the recognizer on each captured title, or emit it as unknown and have the paste step decide. Add the two missing state names to the fixture vocabulary or map onto existing ones. Amend VALOWN1 step 1 to say a real title recording `reject` is itself a DET-band finding rather than a paste error.

## 4. Four active specs anchor on `file:line` ranges that now land on unrelated code

UX43, UX45, UX46 and AUTO3 each cite the exact line of the code they exist to change, and in every case the cited line now holds something else, in three of the four by 40 to 200 lines, after LOCAL16, UX35 and AI11 shifted those files. Example: `docs/backlog/tasks/UX43.md:13` cites the Custom-picker setter at `:353-358`, and the real setter has moved.

Fix: re-resolve all four by symbol rather than by line, and prefer citing a symbol name plus a short quoted snippet over a bare line number, so the citation survives the next band. Record that preference in `.claude/commands/file-task.md` beside HYG5's absolute-total rule, since it is the same failure with a different unit.

## Scope

Items 2, 3 and 4. Item 1 is already fixed and is recorded here for the trail.

## Acceptance

UX48's step 7 and acceptance clause describe something the scope can deliver. The CAL3 probe cannot emit an `expected` it did not compute, and VALOWN1's paste step says what to do with a `reject`. The four stale citations resolve. `.claude/commands/file-task.md` records the cite-by-symbol rule. No code behaviour change beyond the probe, so both suites stay green.
