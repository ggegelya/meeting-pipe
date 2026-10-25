# PERF26: The Library's status spinners and pulses and the recording HUD's pulse redraw at the display's full refresh rate while visible, and a Paste pending row spins until someone pastes

Band origin: filed 2026-10-25 from the performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Review findings UI-6 (verified medium) and UI-10 (verified low), re-checked against the tree on 2026-10-25.

**SwiftUI indicators with no frame cap.** Three views draw their motion from `TimelineView(.animation)` with no `minimumInterval`, so SwiftUI re-evaluates the closure and commits a frame on every display refresh for as long as the view is on screen:

- `MPRingSpinner` in `LibraryChrome.swift` (`TimelineView(.animation) { ctx in ... .rotationEffect(.degrees(360 * phase)) }`, a 7 pt ring on a 1 s period), drawn by `MPStatusPill.indicator` for `case .processing: MPRingSpinner(color: dotColor, size: 7)`.
- `MPSteadyPulseDot` beside it (a 1.6 s opacity envelope), drawn by `MPStatusPill` for `.recording`.
- `PulseDot` in `LibraryToolbar.swift` (the toolbar's recording dot, a 1.6 s cosine envelope), on screen for the whole of every recording while the Library is open.

The owner's Mac (Mac16,5, built-in Liquid Retina XDR) is a ProMotion panel, so every refresh can mean 120 frames a second for an indicator whose motion needs 10 to 20. The `TimelineView` choice itself is deliberate and right: `PulseDot`'s doc comment records that the old `withAnimation.repeatForever` "restarted on every parent re-render, causing a ~1s stutter". Only the schedule is uncapped.

**Paste pending reuses the processing spinner, and it is a terminal state.** `MeetingRow.statusPill` renders `case (.manualPasteReady, _): MPStatusPill(kind: .processing, label: "Paste pending")`, and `MeetingStore.buildMeeting` makes it terminal and cacheable (`} else if pasteReadyURL != nil { status = .manualPasteReady; cacheable = true`). A BYO meeting therefore spins at the display rate whenever its row is visible, until the owner pastes a summary, which may be never. Two sources already say it should not move: the design kit's `SL_STATUS` in `design/ui_kits/macos_app/SummaryLibrary.jsx` draws it as `paste: { tint: "var(--mp-warning-600)", label: "Paste pending", icon: "alert" }` with no `spin`, and README's Library section says only that "Live recordings and rows whose pipeline run is still in flight pulse". On 2026-10-25 the owner's `~/Documents/Meetings/raw` held 0 `READY_FOR_MANUAL.md` bundles, so today the cost there is the Processing and Recording indicators, and Paste pending is a latent forever-spinner for the next BYO meeting.

**The HUD.** `RecordingHUDWindow`'s panel joins all Spaces (`panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`) over a `.behindWindow` blur, so it is rarely occluded and HYG1's occlusion pause of the meter seldom applies. For the whole recording:

- `PulseDotView.startPulsing()` adds a `CABasicAnimation(keyPath: "opacity")` with `anim.repeatCount = .infinity` and no `preferredFrameRateRange`, so the render server recomposites the blurred panel at the display rate for the whole meeting.
- `ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true)` calls `refreshElapsedLabel()`, which sets `label.stringValue` to the same `m:ss` text on every other tick.
- `meterTicker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true)` wakes main 10 times a second, 36,000 times an hour. The redraw itself is cheap (`LEDMeterView` redraws only when the lit-segment count changes); the wake is the cost.

Neither timer sets `tolerance`, so the system cannot coalesce them. The verifier put the HUD half at about 12 trivial main wakeups a second plus one small layer animation: real, small, and paid for every recorded hour.

**Magnitude is unmeasured.** The 2026-10-25 idle reading of the installed daemon (pid 77137, up 7 days 8 hours: 0.0% CPU and zero wakeups over a 10 s sample) had no recording, no Library window and no Processing row on screen, so it says nothing about these paths. The acceptance asks for before and after numbers.

## Scope

0. **Owner decision on the Paste pending look, before code**, because it changes what a row looks like: (a) the kit's look, warning tint and a static alert glyph with no motion (recommended: the kit and README already describe it, so no doc changes); (b) keep the processing tint with a static ring. Either way it stops animating.
1. **Cap the three SwiftUI schedules.** `MPRingSpinner`, `MPSteadyPulseDot` and `PulseDot` use `TimelineView(.animation(minimumInterval: ...))`, each interval a named constant beside its view (start at 1/20 s for the spinner and 1/12 s for the two pulses; the pickup states the values it ships). The two pulses keep reading the same clock so they stay phase-locked, as `MPSteadyPulseDot`'s doc comment requires. Passing `paused:` from the hosting window's occlusion state is optional.
2. **Paste pending** per step 0: `MeetingRow.statusPill` stops mapping `.manualPasteReady` to `.processing`. Lift the `(effectiveStatus, isNDA)` to `(kind, label)` mapping into a small pure function so it is testable.
3. **The HUD pulse.** Lift the animation `PulseDotView.startPulsing()` builds into an internal `static func` and set `preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)` on it (macOS 12 API, inside the macOS 14 floor).
4. **The HUD tickers.** `meterTicker` gets a `tolerance` of about 0.03 s. The elapsed ticker becomes 1 Hz with its first fire aligned to the next whole second since `startedAt`, so the seconds do not visibly skip, a `tolerance` of about 0.1 s, and `refreshElapsedLabel()` writes only when the text changed. If the run-loop-mode task filed from the same review (finding UI-7 ([CONC10](./CONC10.md))) has landed, schedule these through its common-mode helper rather than `Timer.scheduledTimer`; if not, that task moves them later.

## Explicitly not

- Replacing `TimelineView` with `withAnimation(.repeatForever)` or `phaseAnimator`: the stutter `PulseDot`'s comment records is the reason `TimelineView` is there.
- The HUD tickers' run-loop mode (they stall while an app-modal alert is up): the task filed from finding UI-7. Whichever lands second rebases onto the other.
- Porting the HUD to SwiftUI: [ARCH16](./ARCH16.md) (P3). If it is promoted, the hosted HUD's pulse uses this task's capped schedule.
- The meter's level path and HYG1's occlusion pause: unchanged.
- The 15 Hz playback clock and the 5 s processing heartbeat re-rendering Library subtrees: [PERF12](./PERF12.md) and [ARCH15](./ARCH15.md).

## Acceptance

- A source fence in `MeetingPipeTests` (the `TutorialFenceTests` style): no `TimelineView(.animation)` without `minimumInterval:` anywhere under `daemon/Sources`.
- A pure test of the lifted pill mapping: `.manualPasteReady` maps to the owner's chosen kind and never to `.processing`; `.processing` and `.recording` keep their kinds and labels; an NDA row still maps to "Kept local".
- A `RecordingHUDTests` case over the lifted pulse animation: `preferredFrameRateRange.maximum <= 15`, opacity keyPath, `repeatCount == .infinity` (no window server needed).
- `RecordingHUDTests` cases over the elapsed ticker's pure helpers: the first fire lands on the next whole second after `startedAt`, and an unchanged `m:ss` produces no write.
- `cd daemon && swift build` and `swift test` green, N new tests in the commit body; `bash scripts/ci-local.sh` green, including the design-token fences if the Paste pending glyph takes a colour.
- Evidence (confirms, does not gate), numbers in the commit body: `top -l 11 -s 1 -stats pid,cpu,idlew -pid $(pgrep -x MeetingPipe)` with the Library open on a row showing Processing, and again during a recording with the HUD up, before and after the change.

## Owner walkthrough

Needed because the Paste pending look is the owner's call, and the daemon's windows are not screenshotable from a session, so whether a capped animation still reads as smooth can only be judged by eye.

1. [session] Before writing code, ask the owner to choose (a) or (b) from Scope step 0, and record the answer in this file.
2. [session] After `./scripts/rebuild.sh`, run the `top` evidence above and put the numbers in the commit body.
3. [owner] Open the Library while a meeting is processing, and start a short recording with the Library open: the ring and both pulse dots still read as smooth, and the HUD dot still breathes.
4. [owner] Record a short BYO meeting (Record (BYO), then Stop) and wait for it to finish: its row shows Paste pending with no motion.
