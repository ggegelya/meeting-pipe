# CAL1 spike: EventKit calendar context (re-evaluating ADR 0011)

Spike, 2026-07-12. Probe: [`daemon/scripts/cal1-calendar-probe.swift`](../../daemon/scripts/cal1-calendar-probe.swift) (owner-run, read-only, not in the SPM target). Run with `swift daemon/scripts/cal1-calendar-probe.swift`. This spike ships the analysis + the measuring instrument; the empirical verdict is owner-owed because it needs the owner's real calendar.

## Question

Every mature competitor uses calendar metadata as a hint (Granola: a pre-created note + a 1-minute-before nudge + an end-hint; Otter: tightens the silence threshold past the scheduled end; Notion: process + calendar match; Hyprnote: a mic-busy nudge listing nearby events). meeting-pipe deliberately does not: ADR 0011 deleted the one calendar signal it had.

CAL1 asks whether that was the right call under a **different, narrower scope** than ADR 0011 rejected, and whether the assumption ADR 0011 leaned on is actually true:

1. **Scope.** ADR 0011 evaluated calendar as an *end-detection corroborator* (telemetry that could not move a verdict, with no consumer). CAL1 evaluates calendar as **hints only, never a trigger**: pre-title the prompt panel + the meta sidecar; feed the covering event's scheduled end into `IdleStopBackstop`'s auto-stop horizon; warn before a scheduled meeting when a capture precondition is broken (TCC revoked, model missing, disk low). None of these move the detection verdict; they improve UX and reduce the forgotten-recording tail.
2. **Assumption.** ADR 0011's decision rested on "for a single user whose meetings are not reliably calendar-bound, scheduled-end correlation is low value." That was asserted, never measured. If the owner's meetings *are* calendar-bound, the hints pay off; if they are not, the hints rarely fire and ADR 0011 stands.

The headline is empirical: **does the owner's calendar actually carry their meetings?** Everything downstream (design or close) hangs on the number the probe returns.

## The unavoidable cost (why this needs a real answer, not a hunch)

A working EventKit read needs the **Calendar TCC permission**, a new first-run prompt. The current permission set (mic, screen recording, accessibility, notifications) deliberately excludes it, and the onboarding direction is to *reduce* the first-run prompt burst, not grow it. So CAL1 is a genuine trade: a new permission prompt versus a hint that only helps if meetings are calendar-bound. A GO is only justified if the coverage is high enough to be worth the prompt. That is exactly what the probe measures, so the decision is grounded rather than guessed.

## Method (the probe)

`cal1-calendar-probe.swift` is a read-only diagnostic the owner runs on their Mac:

- Requests Calendar access (`EKEventStore.requestFullAccessToEvents`), so the run itself is the "would the prompt land?" check.
- Enumerates recorded meetings from `~/Documents/Meetings/raw` (stems are `yyyyMMdd-HHmmss`, so each carries its own start time) and reads each `meeting_title` from the meta sidecar.
- Fetches non-all-day calendar events over the look-back window (default 30 days, `--days N`).
- For each recorded meeting, looks for a **covering event** (the recorded start falls within `[event.start - tol, event.end + tol]`, default `tol` 10 min, `--tolerance N`), and separately checks whether the recorded title and the event title share any content token.
- Prints a per-meeting table and a summary: `matched / total (%)`, how many also had a resembling title, and a READ line that maps the percentage to a recommendation.

Coverage percentage is the load-bearing number. Title resemblance is secondary evidence for the pre-title hint specifically (a covering event with an unrelated title still bounds the meeting in time, but only a resembling title is safe to prefill as the meeting name).

## Design, IF the probe says GO (hints only, never a trigger)

All three ride the AI/DV standing rule trivially: EventKit is fully on-device, so there is no new egress class, only a new TCC read.

- **Pre-title.** At prompt time, if a covering event exists, seed the prompt panel's title and `meeting_title` in the sidecar from `event.title` (only when the titles are safe to trust, i.e. no source title already, or the source title is a generic app name). This is the highest-value, lowest-risk hint: it makes the prompt read like the meeting.
- **Expected-end horizon.** Feed the covering event's scheduled end into `IdleStopBackstop` so the forgotten-recording auto-stop can tighten near the scheduled end instead of waiting out the fixed idle window. Strictly a horizon input to the existing idle logic; the fused `MicGate` verdict still decides silence (a meeting that runs long is not force-stopped at the calendar boundary; the event end only shortens the idle grace once the meeting is already quiet).
- **Preflight warning.** A cheap pre-meeting check (a covering event starts within N minutes) that surfaces a broken capture precondition (Screen Recording TCC revoked after a rebuild, local model missing, disk low) before the meeting starts, when it can still be fixed.

This would supersede ADR 0011 with a new ADR that accepts the Calendar TCC prompt as a deliberate onboarding cost for the hints, scoped explicitly to hints-never-triggers so the reasons ADR 0011 gave (no verdict impact) remain satisfied.

## Synergy

`CAL1`'s covering event carries an **attendee list**. That is the clean-attendee seed `DV2` (the People pivot) was blocked on, and a candidate seed for `FEAT3-ROSTER` names. If CAL1 goes GO, the attendee read is a natural follow-on (it does re-open the DV2 NO-GO's data-quality question, so treat it as a separate spike, not a freebie).

## Verdict: owner-owed measurement, provisional lean

The engineering is understood and the instrument is built; the decision is one number away and that number is on the owner's Mac.

- **If coverage >= ~60%:** GO. Write the superseding ADR, build pre-title first (highest value), then the expected-end horizon, then preflight. Accept the Calendar TCC prompt.
- **If ~30-60%:** marginal. Pre-title alone (the cheapest hint) might still be worth it; the horizon + preflight probably are not. Decide against the prompt cost.
- **If < ~30%:** close CAL1, confirming ADR 0011 empirically rather than by assumption. Keep this doc + the probe so the decision is revisitable if the owner's meeting habits change.

Provisional lean, pending the number: **pre-title is the one hint worth the permission even at moderate coverage**; the horizon and preflight need high coverage to justify themselves. But this is a lean, not the decision. Run the probe.

## Follow-on

- Owner: run `swift daemon/scripts/cal1-calendar-probe.swift` (optionally `--days 60`) and read the summary percentage.
- On GO: a new ADR superseding 0011; CAL2 (the pre-meeting prep card) then gets calendar-aware timing + title/attendee seeding, which its spec already sequences behind this spike.
- On NO-GO: close CAL1; ADR 0011 stands, now measured.
