# DET6: Browser-tab meetings other than Meet are undetectable

Band origin: filed 2026-07-20, off the DET2 close (the removal of the dead process-audio corroborator exposed it). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

A meeting held in a plain browser tab can only be detected if it is Google Meet. Every other browser-hosted meeting is rejected, silently, with no event and no diagnostic trace.

The gate is the plain-browser branch of `MeetingSourceScanner.enumerateCandidates`, which after the DET2 cleanup reads `guard strongMatch else { continue }`, where `strongMatch = fragmentMatch || (titleMatched && anyWindowMatchesStrongMeetingTitle(pid: pid))`. Both disjuncts are far narrower than they look.

`anyWindowMatchesStrongMeetingTitle` resolves to `BrowserMeetingLifecycleAdapter.strongTitleMatchers`, which contains exactly one entry, `MeetingTitlePatterns.googleMeet` (a title containing `meet.google.com`, or containing "meet" plus a bounded 3-4-3 letter room code). Nothing else is ever strong.

`fragmentMatch` calls `anyWindowMatchesMeetingFragment`, which tests AX **window titles** against `browserURLFragments` from `daemon/Sources/MeetingPipe/Resources/meeting_apps.toml` (`meet.google.com`, `teams.microsoft.com`, `teams.live.com`, `zoom.us/j/`, `zoom.us/wc/`, `webex.com/meet`, `webex.com/wbxmjs`). The scanner's own comment in that branch records why this rarely fires: browsers put the PAGE TITLE in the window title, never the URL, and the fragment check is kept only as "a bonus signal for any browser that does surface the URL in the title". A normal Teams or Webex page title does not contain its own URL, so in practice this disjunct is dead for every product including Meet, which is carried by the strong matcher instead.

The resulting coverage, given `defaultTitleMatchers` is the weak OR of `googleMeet`, `browserTeams` (`contains("microsoft teams")`), `browserWebex` (`contains("webex")`) and `slackHuddle` (`\bhuddle\b`):

| Browser tab | `titleMatched` | `strongMatch` | Outcome |
|---|---|---|---|
| Google Meet | true | true | detected, unaffected |
| Teams (`teams.microsoft.com`, `teams.live.com`) | true | false | rejected at the strongMatch gate |
| Webex (`webex.com/meet`, `webex.com/wbxmjs`) | true | false | rejected at the strongMatch gate |
| Slack huddle (`app.slack.com`) | true | false | rejected at the strongMatch gate, and no Slack URL fragment exists in `meeting_apps.toml` at all |
| Zoom web client (`zoom.us/j/`, `zoom.us/wc/`) | false | not reached | rejected earlier at `guard titleMatched || fragmentMatch`, since `defaultTitleMatchers` has no Zoom entry |

The rejection is invisible, which is the part that makes this worth filing rather than merely noting. Rejected tabs are dropped by `continue` before they are appended to `candidates`, and `MeetingSourceScanner.scan` computes `droppedCandidates` by filtering that same already-built array, so a rejected browser tab never produces a `candidate_dropped` event. Nothing in `events.jsonl` records that a browser meeting was seen and refused, so the miss rate cannot currently be measured even in hindsight.

Scope of the gate: only the ten plain-browser bundle IDs in `meeting_apps.toml [browser.bundles]`. Native meeting apps are unaffected (their branch has no such gate). Chromium PWAs are unaffected too: the PWA branch admits on `titleMatched || nameMatched` with no strongMatch requirement, so Teams or Meet installed as a PWA still works.

**The corroborator this gate was designed around never functioned.** END5 shipped on 2026-07-12 and its start-side half admitted a bare brand-token title "only when live process audio corroborates it, since a real browser call holds the mic while a doc about those products does not". That corroborator was already dead when it shipped: `~/Library/Logs/MeetingPipe/events.1.jsonl` carries 13,419 `process_audio_unresolved` and 0 successful reads across 2026-05-18 to 2026-07-13, spanning END5's ship date. DET2 then closed the signal permanently on 2026-07-20 (probe on a real Mac with the Screen Recording grant held: the grant alone, a live bare process tap, and a private aggregate device all returned object 0), and the follow-up cleanup removed the disjunct so the guard stops reading as if corroboration were possible. So this is **not a DET2 regression**: the brand-token escape hatch was non-functional from the day it was written, and DET2 only made that legible. Recording it here so the owner knows a shipped P1's start-side leg was inert, without treating it as a reopen.

**Interaction with MIC7.** MIC7's remaining build gate is "a real browser meeting appears in the corpus". Since browser Teams, Webex, Slack and Zoom cannot enter the corpus at all, that count is biased and the gate is partly self-suppressing: only a Meet call can ever trip it. Whoever picks up either task should know the other exists.

**Why P2 and not P1.** The owner's dogfood is Teams-native and the corpus holds 0 recorded browser meetings, so today the live impact is nil. A silent detection miss is normally P1 material, so re-band to P1 the moment browser meetings become something the owner actually wants recorded. The band is deliberately not inflated on the strength of the failure mode alone.

## Scope

Probe first, matching the shape CAL1, MIC7 and DET2 each used: the headline questions are empirical and cannot be answered from inside the coding harness, so ship the instrument and the decision tree, not a blind widening.

Two measurable questions, in priority order.

1. **Can the real URL be read from the browser's AX tree?** If the address bar's `AXValue`, or the web area's `AXURL` / `AXDocument`, is readable for the registered browsers, then `fragmentMatch` can be repointed at the URL it was always meant to read, and the existing `browserURLFragments` list fixes Teams, Zoom and Webex in one move without inventing any new title heuristics. This is the outcome to hope for.
2. **Is a live call's window title distinguishable from a document about the product?** Measure real titles during a live browser Teams / Webex / Slack-huddle call and compare against a doc page mentioning the same brand. If calls carry a stable structural marker, a strong matcher can be added per product the way `googleMeet` has one.

Deliverables: an owner-run read-only probe at `daemon/scripts/det6-browser-url-probe.swift` plus an analysis doc under `docs/spikes/` carrying the pre-registered verdict tree (URL readable, fix `fragmentMatch`; title distinguishable, add strong matchers; neither, close the leg and document the limitation as permanent).

Seam for the fix once measured: `MeetingSourceScanner.anyWindowMatchesMeetingFragment` for the URL read, and `BrowserMeetingLifecycleAdapter.strongTitleMatchers` for any per-product strong matcher. Prefer lifting the admission decision into a pure function (the repo's `decide(...)` pattern, as in `MicInUseTier.decide` and `MeetingSourceScanner.shouldWalkControlAX`) so it can be unit-tested without a live browser, since the current guard sits in a `private` method and is structurally untestable.

**In scope regardless of the probe verdict: make the drop visible.** Emit an event at the rejection site carrying the bundle ID, the weakly-matching title, and the reason, so a refused browser tab leaves a trace in `events.jsonl` and `mp analyze-detection` can count the real rate. This is independently useful, is a precondition for ever measuring the gap's true cost, and does not depend on how the probe lands.

## Explicitly not in scope

**Widening `strongTitleMatchers` on a guess.** A bare `contains("microsoft teams")` or `contains("webex")` promoted to strong reopens exactly the doc-title false start END5 closed on purpose (a page titled "Webex vs Zoom Comparison" would prompt). Any widening must be backed by the measurement above.

**Substituting the mic-busy signal as the corroborator.** Assessed and rejected on 2026-07-20. `MicBusySpanTracker` reads `AVCaptureDevice.isInUseByAnotherApplication`, which is system-wide and cannot name the holder; its attribution is the frontmost app captured at the rising edge and frozen for the span; and the Webex ultrasound carve-out that protected the old per-process probe has no equivalent in the mic-busy path, so a post-call Webex session holding the mic would falsely corroborate an unrelated browser tab. It would reintroduce the misattribution class DET1's own postmortem already flagged as unfixed.

**Reviving process audio.** DET2 closed it NO-GO with the tap hypothesis refuted rather than untried. See `docs/spikes/det2-process-tap-attribution.md`.

**The PWA branch.** Unaffected by this gate and working; do not touch it while fixing the plain-browser branch.

Adjacent gaps noticed while filing, folded into this task rather than left loose: `defaultTitleMatchers` has no Zoom entry at all, and `meeting_apps.toml` has no Slack URL fragment. Both should be closed by the same measured change, not filed separately.

## Acceptance

The probe exists at `daemon/scripts/det6-browser-url-probe.swift`, is read-only, is typecheck-clean under `swiftc -typecheck`, and prints its own precondition line (AX trust state) before any verdict, so a run made without AX trust is obviously void rather than quietly reported as "nothing found". This is the DET2 lesson: a void measurement that agrees with the expected answer is the easiest kind to bank by mistake.

The analysis doc under `docs/spikes/` states the verdict tree before the run, and after the owner's run records which branch was taken with the measured titles and URL-read results quoted.

A browser tab rejected at the admission gate emits an event. Verified by opening a `teams.microsoft.com` tab and finding the event in `~/Library/Logs/MeetingPipe/events.jsonl` with the bundle ID, the matched title, and a reason field.

New tests extend `MeetingSourceScannerTests` and pin the admission decision through whatever pure seam the fix introduces, with cases for: a Meet room-code title (admitted), a `meet.google.com` title (admitted), a bare "microsoft teams" title (behaviour per the measured verdict), a bare "webex" title (same), a `\bhuddle\b` title (same), and a doc title such as "Webex vs Zoom Comparison" which must stay rejected in every branch of the verdict tree. That last case is the regression fence for END5's original concern.

`cd daemon && swift build` and `cd daemon && swift test` both green; the suite baseline at filing time is 1331 tests.

The repo dash guard stays green (no U+2014 in any changed line, and none at all under `daemon/Sources` or `daemon/Resources`).
