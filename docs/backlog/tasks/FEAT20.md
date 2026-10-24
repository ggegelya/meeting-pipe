# FEAT20: spike, can the meeting app's own participant list supply name candidates locally, since every speaker name today has to come from the user

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) FQ-14, UX-16, and its "Improving transcription and people identification" item 3). `/spike` shaped: an owner-run read-only probe plus a decision rule committed before any number exists. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## The one question

**During the owner's real calls, how often can the names of the people in the call be read on this Mac, without the owner doing anything, and how often do they include the people the owner later names by hand?**

Not whether to auto-label voices from a list (a list of names says nothing about which voice is whose), and not how the names would be shown. Only whether the source exists and is good enough to be worth a surface.

## Context, verified 2026-10-24

- **Every name comes from the user today.** `resolve_speaker_labels` produces the owner's `user_label`, a roster name, or a `THEM-x`; the summary's `attendees` are "Inferred from speaker labels and content" (`pipeline/src/mp/schemas.py`, quoted in DV2's spike). Nothing in `daemon/Sources` reads a participant list or imports `EventKit`: the only two hits for "participant" are doc comments in `WindowActivationManager.swift` and `SilenceAutoStopPolicy.swift` that use the word in passing.
- **The calendar is closed for this owner.** CAL1 went NO-GO on 2026-07-17 as a false zero: the owner's Outlook and Teams calendar does not reach macOS EventKit, and the owner declined to connect it ([cal1-eventkit-calendar-context.md](../../spikes/cal1-eventkit-calendar-context.md), ADR 0011's revisit note). That doc already named the attendee list as a follow-on spike if the calendar ever opens. The go-live point that the NO-GO "only holds for the owner's own setup" is true but, in a single-user product, does not reopen it.
- **The window title carries little.** CAL3's probe work found `meeting_title` at 3 percent coverage and the Teams native-title regex matching one format; its measurement run is VALOWN1 ([cal3-teams-window-title-series.md](../../spikes/cal3-teams-window-title-series.md)).
- **Teams' AX tree has no values or identifiers.** `MeetingAXHandleBuilder.findMeetingWindowMuteButtons`'s comment records that "Teams exposes no AXValue and no AXIdentifier anywhere in its tree". Titles and descriptions are what the daemon reads today. A participant panel, if it is in the tree at all, would be read the same way: localized text, which this repo treats with care (DET15's class).

## What closes a priori, before any capture

1. **Is the panel in the tree when closed?** If Teams only builds the People panel's elements while it is open, the passive answer is near zero by construction and the probe must report "panel closed" captures as their own bin, not as misses.
2. **Which surfaces carry names without the panel?** Video tiles and the active-speaker caption often carry a display name. Use `daemon/scripts/ax-dump-meeting.swift` on one live call to list where names appear, by role and attribute, before writing a probe.
3. **Privacy.** Participant names are other people's personal data read off the screen. The probe keeps them in memory, compares them, and prints counts only; nothing is written unless the owner passes an explicit flag. Any later surface stores them like any other per-meeting data and honours NDA withholding.

## Pre-registered verdict thresholds

Written 2026-10-24, before any capture. Denominator: the owner's Teams calls during the probe window, at least five, recorded normally.

| Verdict | Measured | Next |
|---|---|---|
| **GO** | A non-empty name list read passively on 80 percent or more of calls, and on calls the owner later names, at least 60 percent of hand-named people appear in that call's list (casefolded) | File the build task with the owner: offer the list as candidates in the naming picker ([FEAT19](./FEAT19.md) leg 2) and as a hint to summarize's attendees |
| **MARGINAL** | A list on 30 to 80 percent of calls, or the 60 percent overlap missed | Record the bins; consider candidates-only in the picker, no summary use |
| **NO-GO** | Anything else, including "panel closed" dominating | Close; names stay user-supplied, which FEAT19 makes cheaper |

## Explicitly not

- Mapping a name to a voice from the list. Diarization and the roster own voice identity; the list is candidates.
- Reopening CAL1 or EventKit for this owner. If the owner ever connects a calendar, CAL1's probe is the instrument.
- Browser-meeting participant lists (Meet in a tab); DET6 owns browser meetings and their DOM is a different reader.
- Any production code. The deliverable is a doc and a probe; the build is a separate filing on GO.

## Deliverables and acceptance

- `docs/spikes/feat20-participant-names.md` with the question, the three a priori items answered with citations (item 2 from one AX dump), the thresholds table copied verbatim, and the owner's exact command.
- An owner-run probe under `daemon/scripts/`, read-only, that refuses to run or emit a verdict without an Accessibility grant (the CAL3 probe's rule: a disclaimed parent reads zero windows, and that false zero must never read as NO-GO), prints a READ line naming GO, MARGINAL or NO-GO, the bins (list read, panel closed, nothing found) and the overlap figure, with no names in the output by default.
- No production module changes. `python3 scripts/truth_fences.py both` green.
- The verdict read off the table without adjusting it, recorded in the spike doc.
