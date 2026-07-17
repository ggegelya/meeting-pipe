# ADR 0011: CalendarContextSignal disposition (delete)

| Property            | Value                  |
| ------------------- | ---------------------- |
| **Status**          | Accepted               |
| **Date**            | 2026-05-28             |
| **Decision Makers** | Project owner          |
| **Technical Area**  | Detection / lifecycle  |
| **Related Tasks**   | TECH-C16, TECH-C13, CAL1 |

## Context

`CalendarContextSignal` was built in the TECH-C13 step-3 signal set as a corroborating hint for the scheduled-end hysteresis check. Given an active `MeetingLifecycleContext`, it would compare the wall clock against the covering calendar event's scheduled end (plus a hysteresis buffer) and emit `withinSchedule` / `pastScheduledEnd` / `unknown`, so dogfood analysis could flag an `.ended` that fired suspiciously far past or before the calendar boundary.

It was never wired, and it was never finished. The EventKit access is an injectable probe, and the only probe that exists is the default, which returns `nil` unconditionally. The source comment is explicit: "the executable wires an EventStore-backed implementation in a follow-up." That follow-up never happened, so even if the signal were subscribed today it would emit nothing but `unknown`. A repo-wide search finds no reference to `CalendarContextSignal` outside its own source file and its unit test. Per the TECH-C16 framing, a built-but-unwired signal is the failure mode and must be wired or deleted.

## Decision Drivers

- **Wiring it for real requires a new TCC permission the product is trying to avoid.** A working signal needs an `EKEventStore`-backed probe, which means a Calendar (EventKit) access prompt at first run. The onboarding work (TECH-UX1) is actively trying to reduce the first-run TCC burst, and the existing permission set (mic, screen recording, accessibility) deliberately excludes calendar. Adding a calendar prompt for a corroboration hint cuts against that direction.
- **It never promotes a verdict.** Like the other corroborating signals its contract is telemetry only; it folds into post-hoc analysis, not into the `.ended` decision. The verdict path is driven by the wired PRIMARY signals (AX Leave button, process-audio, shareable-content, window-title, workspace).
- **No analysis consumer and no demand.** No dogfood report reads calendar-context state today, and for a single user whose meetings are not reliably calendar-bound, scheduled-end correlation is low value.
- **An unbuilt probe is worse than no signal.** Shipping a signal whose only implementation returns `nil` is dead weight that looks like a feature.

## Options Considered

### Option A: Finish and wire it (build the EventKit probe)

Implement an `EKEventStore`-backed probe, request Calendar TCC, subscribe the lifecycle coordinator, and emit `signal.calendar_context` events. Pros: closes the unwired state with a genuinely functional signal. Cons: introduces a new permission prompt at odds with the onboarding goals; adds EventKit query work on a 60 s poll per meeting; the result still cannot move a verdict; no consumer exists for the telemetry. Substantial new surface for negligible single-user value.

### Option B: Delete the signal and its test

Remove `CalendarContextSignal.swift` and `CalendarContextSignalTests.swift`. Pros: removes a half-built, unwired type and avoids a calendar TCC prompt entirely; the verdict path is unaffected (it never used this signal). Cons: if calendar-bounded end-detection becomes desirable later, the hysteresis logic must be rebuilt; it is recoverable from git history and is a small amount of code.

## Decision

**Option B.** Delete `CalendarContextSignal` and its test. It was never wired, its only probe returns `nil`, and making it real would cost a new Calendar TCC prompt the product is steering away from, in exchange for telemetry that cannot affect a verdict and that nothing consumes.

## Consequences

- `daemon/Sources/MeetingPipeCore/Lifecycle/Signals/CalendarContextSignal.swift` and `daemon/Tests/MeetingPipeCoreTests/CalendarContextSignalTests.swift` are removed. `swift build` and `swift test` stay green; no production path referenced the type.
- No Calendar (EventKit) TCC prompt is added. The first-run permission set stays mic, screen recording, accessibility, plus notifications.
- No `signal.calendar_context` events will appear in `events.jsonl`. Nothing read them.
- The scheduled-end hysteresis idea is not foreclosed: if calendar-bounded end-detection is wanted later, rebuild from git history (`docs/decisions/0011` and the deleted file), implement the EventStore probe, and decide the Calendar-permission trade-off as a deliberate onboarding choice at that time.
- **Revisited and measured by CAL1 (2026-07-17).** CAL1 re-evaluated this decision under a narrower scope (calendar as hints only, never a trigger: pre-title, expected-end horizon, preflight) and shipped an owner-run probe to test the assumption above. The probe found 0 of 55 recorded meetings covered by a calendar event, but with macOS Calendar (EventKit) effectively empty: the owner's Outlook / Teams calendar is not connected to macOS, so EventKit is structurally blind to their meetings. The owner chose to keep the calendar out of macOS, so this disposition holds, now on a measurement rather than an assumption. The operative reason for this user is refined: not that the meetings are unscheduled, but that their scheduling does not flow through EventKit. Revisit if that changes (see `docs/spikes/cal1-eventkit-calendar-context.md`).
