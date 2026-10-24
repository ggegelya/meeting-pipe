# DET15: end-of-call signals are calibrated to English-UI Teams: the Leave and toolbar matchers are English-only, Teams title stems miss accented spellings, and every native app's hold reads Teams' log

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) PD-2). Filed P3: nothing has failed in the field yet, because the owner records English-UI Teams. Promote on the first recorded meeting in a non-English client UI, or the first false or missed end on Zoom, Webex or Slack. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified in code on 2026-10-24. The go-live review could not see a live non-English client, so the locale gaps below are read from the matchers, not observed.

1. **Leave buttons are English-only.** `MeetingAXHandleBuilder.matchesLeave` matches lowered substrings per bundle: Zoom `"leave"` or `"end meeting"`; Webex `"leave meeting"`, `"end meeting"`, `"end"` or `"leave"`; Slack `"leave huddle"`, `"leave call"`, `"end huddle"`. Teams goes through `isTeamsCallLeaveLabel`, an exact match against `"leave"`, `"leave call"`, `"leave meeting"`, `"leave the call"`, `"leave the meeting"`, or a `"hang up"` substring. Its doc comment says the set matches "what the daemon already shipped against". The mute side, by contrast, has a locale catalogue (`MeetingPipeCore/MicGate/Resources/MuteLabels.toml`, en, de, es, fr, ja, pt, ru, uk) with a validator. A Ukrainian-UI Teams call would never arm a Leave button, so `AXLeaveButtonSignal` would never lead or corroborate an end.
2. **Toolbar needles are English-only.** `callingControlsToolbarNeedles(bundleID:)` returns `["calling controls"]` for Teams and `"meeting controls"`, `"call controls"`, `"huddle controls"` for the others.
3. **Title stems are accent-sensitive.** `MeetingTitlePatterns.teams` lowercases the title and looks for any of `teamsTokens`: `"meeting"`, `"besprechung"`, `"reunion"`, `"reuniao"`, `"encuentro"`, `"встреча"`, `"kokous"`, `"spotkanie"`, `"moot"`, `"microsoft teams"`. `lowercased()` keeps diacritics, so French "réunion" and Portuguese "reunião" do not contain `"reunion"` or `"reuniao"`, and Spanish "reunión" does not either. There is a Russian stem and no Ukrainian one. Since 2026-10-08 Teams no longer appends ` | Microsoft Teams` ([END14](./END14.md)), so the localized stem is the only thing a call window can match on.
4. **The teardown oracle is Teams-only, but every native app consults it.** `Coordinator` holds one `CallTeardownWatcher.teams()`, which tails Teams' `MSTeamsNM_SlimCore_` log. `MeetingSessionController.rescueProvisionalEnd` is gated only on `context.kind == .native`, and when its walk finds no Leave button it calls `beginTeardownHold`, whose `consultTeardownOracle` reads `coordinator.callTeardown.snapshot()` with no bundle check. A Zoom, Webex or Slack hold therefore waits on Teams' log: with Teams not installed it confirms at once (`oracleUnavailable`); with Teams installed it holds until the 150 s cap, a live-signal veto, or a Teams teardown line from an unrelated Teams call after this recording started. Process audio is wired for Teams and Zoom only (`NativeLifecycleConfig.usesProcessAudio`), and DET8 measured the input release on Teams only.
5. **Calibration data.** The detection corpus holds 22 Teams traces against 1 Zoom, 1 Webex and 2 Google Meet, and no Slack.

## Scope

1. **A leave-label catalogue.** Move the Leave labels and toolbar needles into a localized catalogue beside `MuteLabels.toml`, loaded and validated the same way, seeded with today's English sets so English behaviour is unchanged. Add locales only from a live AX scrape of a real client (`scripts/dump_window_titles.swift` or an AX dump), never from translation guesses. Ukrainian labels are verified with the owner, as the backlog's locale rule requires.
2. **Diacritic-insensitive title matching.** Compare titles and tokens folded with `.diacriticInsensitive` and `.caseInsensitive`, and store tokens unaccented. Add a Ukrainian meeting stem confirmed by the owner from a real Teams window title.
3. **A per-app oracle.** Make the oracle a per-bundle lookup: Teams bundles get the SlimCore watcher, and any other bundle gets an explicit "no oracle for this app" answer, logged once per hold with the bundle, instead of Teams' snapshot. What a hold does with no oracle follows END17's evidence tiers; until END17 lands it keeps today's `oracleUnavailable` behaviour, now visible in the log.

## Explicitly not / out of scope

- Detecting browser meetings other than Meet: [DET6](./DET6.md).
- The end-of-call policy itself: END17. This task only stops the signals and the oracle from being silently English-Teams-shaped.
- Mute-label coverage, which already has its catalogue.
- Measuring whether Zoom releases process audio at leave; worth a probe the first time a Zoom meeting is recorded, listed so it is not lost.

## Acceptance

- Tests: every pre-existing English Leave label and toolbar needle still matches (a table over the old sets); the catalogue validator rejects a malformed entry; `MeetingTitlePatterns.teams` matches "Réunion d'équipe", "Reunião semanal" and "Reunión diaria" and still rejects a chat window title of the `Chat | <name>` shape END14 recorded; a non-Teams native hold logs the no-oracle event and does not read the Teams watcher (a fake watcher records zero snapshot calls).
- Any new locale entry names its scrape source in the catalogue comment.
- `cd daemon && swift build` and `swift test` green, with the new test count in the commit body; `python3 scripts/truth_fences.py` clean if a new event action is added (`CONVENTIONS.md` table in the same commit).

## Owner walkthrough

1. [owner] When promoting: join one Teams call with the Teams UI language set to Ukrainian, and send the session the Leave button's AX label and the call window's title (the session supplies the one-line dump command). Pass: the labels are added and a test pins them. Cost: one short test call.
