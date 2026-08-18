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

**The corroborator this gate was designed around never functioned.** END5 shipped on 2026-07-12 and its start-side half admitted a bare brand-token title "only when live process audio corroborates it, since a real browser call holds the mic while a doc about those products does not". That corroborator was already dead when it shipped: `~/Library/Logs/MeetingPipe/events.1.jsonl` carries 13,419 `process_audio_unresolved` and 0 successful reads across 2026-05-18 to 2026-07-13, spanning END5's ship date. DET2 then closed the signal on 2026-07-20 (probe on a real Mac with the Screen Recording grant held: the grant alone, a live bare process tap, and a private aggregate device all returned object 0), and the follow-up cleanup removed the disjunct so the guard stops reading as if corroboration were possible. So this is **not a DET2 regression**: the brand-token escape hatch was non-functional from the day it was written, and DET2 only made that legible. Recording it here so the owner knows a shipped P1's start-side leg was inert, without treating it as a reopen.

**That close was not permanent, and the signal is now back.** A 2026-07-30 headless enumeration of `kAudioHardwarePropertyProcessObjectList`, holding no TCC grant, showed DET2 measured the wrong process: all three of its mechanisms translated the `MSTeams` shell PID, which never registers as a CoreAudio client, while the SlimCore `ModuleHost` helper that actually holds the mic (`com.microsoft.teams2.modulehost`) resolves with `OSStatus 0`. [DET8](../q6-final.md) shipped the revival on 2026-08-05 after an owner-run live-call probe returned GO across two calls, and its bundle-prefix matching is what would give a browser tab the same read (a Chrome helper matches the browser's own bundle prefix).

**But it is the END-side signal that came back, not this gate's start-side corroborator, and DET6 still has to stand on its own evidence.** DET8 rewired `ProcessAudioSignal`'s resolution and turned it on for the native lifecycle adapters. The DET2 cleanup had separately deleted the start-side probe from `MeetingSourceScanner.collectSignals` and its disjunct from `MeetingSourceScorer.hasCorroboratingSignal`, and DET8 did **not** put those back: re-admitting bare brand-token titles is a start-side false-positive question, which is DET6's to answer with the measurement below, not a free consequence of the end-side flip. So the corroborator this gate was designed around is once again *available* rather than *wired*, and a widening that leans on it is a decision this task takes deliberately, with the scanner change in its own diff.

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

**Reviving process audio.** Done, by [DET8](../q6-final.md) on 2026-08-05, end-side. The *native* start-side re-wiring (the per-scan enumeration cache, the scorer's corroboration disjunct, the `shouldWalkControlAX` precondition) is [DET12](DET12.md), filed 2026-08-05. What remains DET6's own call is narrower and unchanged: whether a **bare brand-token browser title** is re-admitted on an audio read, which is gated on the measurement below rather than taken as a consequence of DET8's flip or DET12's plumbing. The split is a risk-profile one: a native app's helper process on the mic names the app, while a browser on the mic names only the browser and never which tab. See the paragraph above.

**The PWA branch.** Unaffected by this gate and working; do not touch it while fixing the plain-browser branch.

Adjacent gaps noticed while filing, folded into this task rather than left loose: `defaultTitleMatchers` has no Zoom entry at all, and `meeting_apps.toml` has no Slack URL fragment. Both should be closed by the same measured change, not filed separately.

## Acceptance

The probe exists at `daemon/scripts/det6-browser-url-probe.swift`, is read-only, is typecheck-clean under `swiftc -typecheck`, and prints its own precondition line (AX trust state) before any verdict, so a run made without AX trust is obviously void rather than quietly reported as "nothing found". This is the DET2 lesson: a void measurement that agrees with the expected answer is the easiest kind to bank by mistake.

The analysis doc under `docs/spikes/` states the verdict tree before the run, and after the owner's run records which branch was taken with the measured titles and URL-read results quoted.

A browser tab rejected at the admission gate emits an event. Verified by opening a `teams.microsoft.com` tab and finding the event in `~/Library/Logs/MeetingPipe/events.jsonl` with the bundle ID, the matched title, and a reason field.

New tests extend `MeetingSourceScannerTests` and pin the admission decision through whatever pure seam the fix introduces, with cases for: a Meet room-code title (admitted), a `meet.google.com` title (admitted), a bare "microsoft teams" title (behaviour per the measured verdict), a bare "webex" title (same), a `\bhuddle\b` title (same), and a doc title such as "Webex vs Zoom Comparison" which must stay rejected in every branch of the verdict tree. That last case is the regression fence for END5's original concern.

`cd daemon && swift build` and `cd daemon && swift test` both green, with the number of tests this task adds recorded in the same commit.

The repo dash guard stays green (no U+2014 in any changed line, and none at all under `daemon/Sources` or `daemon/Resources`).

## Progress (2026-08-18, partial)

Shipped: the instrument, the decision tree, the visibility event and the pure seam. Owed: the measurement itself and any widening that follows it.

**The pure seam.** `MeetingSourceScanner.decideBrowserAdmission(windowTitles:urlFragments:)` returns `BrowserAdmission`, one of `.admit`, `.noMeetingSignal` or `.weakTitleOnly(matchedTitle:)`. It replaces the two inline guards the spec's Context section describes, and it is the seam the fix lands in whichever branch the verdict takes. Two things fell out of lifting it. Every case is now reachable from a test, which none were while the guards sat in a `private` method behind live AX reads; and the branch collects window titles once instead of once per predicate, so a browser costs one recursive AX window walk per scan rather than up to three. A refused tab also no longer pays for the three control-button AX walks in `collectSignals`, whose result was computed and then discarded on that path.

**The refusal is visible.** `MeetingSourceScanner.Result.rejectedBrowserTabs` carries each refused tab out of the scan, and `MeetingDiscoveryWatcher.logRejectedBrowserTabs` emits `detector.browser_tab_rejected` with `bundle_id`, `display_name`, `kind`, `title` and `reason` (`weak_title_only` today). It needed its own list for exactly the structural reason DET11's `unreadableNatives` did: both `droppedCandidates` and `unreadableNatives` are built by filtering the candidate array, and a refused tab never enters it. Throttled per bundle plus reason plus title, which differs from its two neighbours on purpose, since the tab's title is the unit being refused. Read it with `mp logs --action browser_tab_rejected`.

`mp analyze-detection` was deliberately **not** taught to read it. That auditor correlates a miss against a mic-busy span, and DET10 left the mic-busy dimension itself unestablished (zero spans across the whole dogfood log, cause unknown), so wiring a fifth correlation marker into it would build machinery on a signal that may be dead. `mp logs` needs no allowlist and reads the action already.

**The instrument.** `daemon/scripts/det6-browser-url-probe.swift`, read-only, typecheck-clean under `swiftc -typecheck`. It prints its Accessibility state before anything else and refuses to capture or emit any verdict without it, because an untrusted process reads zero windows and zero attributes from every browser and that empty read is indistinguishable from a genuine "the URL is not exposed". It probes by shape rather than by selector: it hardcodes no address-bar `AXIdentifier` and no candidate title pattern, dumps every text field it finds in a depth-bounded chrome walk, and reports which held something URL-shaped. Bounded twice (depth and node budget) and with a one-second AX messaging timeout, since a browser's AX tree contains the whole rendered page.

**The verdict tree is pre-registered** in `docs/spikes/det6-browser-url-readability.md`, with an explicitly empty Measured section so a filled-in result cannot be confused with a prediction.

**Tests.** 13 added to `MeetingSourceScannerTests`, in two groups the file marks apart by comment. Unconditional fences: the two Meet admissions, and "Webex vs Zoom Comparison" plus two more doc titles which must stay refused in every branch of the tree (END5's original concern). Pre-verdict, pinning today's behaviour rather than the intended end state: the bare `microsoft teams`, `webex` and `huddle` refusals. The rest pin the seam's contract, including that Zoom-in-browser is refused one step earlier and for a different reason, and that the two refusal kinds stay distinct so a clean miss stays silent.

**Not done, and deliberately.** `strongTitleMatchers` was not widened. The missing Zoom `defaultTitleMatchers` entry and the missing Slack URL fragment in `meeting_apps.toml` were both left alone: the spec folds them in but says they close by the same measured change, and both are unreachable until an admission path exists.

## Owner walkthrough

Steps tagged [owner] / [session] by who acts. What it costs you: two browser calls you were going to have anyway, plus about five minutes of pasting. Nothing is installed and nothing is changed on your Mac.

1. [session] Build the probe and the verdict tree. **Done 2026-08-18:** `daemon/scripts/det6-browser-url-probe.swift` and `docs/spikes/det6-browser-url-readability.md`.

2. [owner] Check the refusal event is real, which needs no call at all and takes a minute. Open a browser tab at `teams.microsoft.com` and leave it open for half a minute, then paste:

       mp logs --action browser_tab_rejected

   Pass: at least one line naming your browser's bundle id and the tab's title, with `reason weak_title_only`. That line is the whole point of this half of the task: before it, a browser meeting was refused with nothing written down anywhere. If nothing appears, MeetingPipe is either not running or does not hold the Accessibility grant, which is worth knowing on its own.

3. [owner] The measurement needs a **live browser call**, in Chrome, Safari or Edge, in Teams, Webex or a Slack huddle. It does not need to be a real meeting; a test call with yourself is fine, and you do not have to record it. Open Terminal **yourself** (not from the app, not from an editor or an agent) so it carries its own permissions. From the repo root, once the call is joined and its tab is frontmost:

       swift daemon/scripts/det6-browser-url-probe.swift --product teams --kind call

   Substitute `webex` or `slack` for `teams` to match the product you are in. It watches for twenty seconds and exits; carry on with the call while it runs.

   Pass: it prints `PRECONDITION  Accessibility access for this process: GRANTED` and then a per-sample line. If it says NOT GRANTED, stop and say so, because that is the harness caveat and not a result; the probe refuses to go further by design. Fix it at System Settings, Privacy and Security, Accessibility, by enabling Terminal, then re-run.

4. [owner] Then, with the call over, open an ordinary page **about** the same product (the vendor's own marketing page, or a comparison article, anything that is not a call) and run the same command with `--kind doc`:

       swift daemon/scripts/det6-browser-url-probe.swift --product teams --kind doc

   This half is not optional and is easy to skip. The question is whether a call's title can be told apart from a page about the product, and a corpus of calls alone answers nothing.

5. [owner] Repeat steps 3 and 4 once more for the same product, so there are two of each. The bars were set at two per side because one call and one page cannot tell a real marker from a coincidence of that particular page.

6. [owner] Paste the report back:

       swift daemon/scripts/det6-browser-url-probe.swift --report

   It prints both legs against bars written down before any of your data existed, then names branch A, B or C. Branch C (neither leg clears) is a pre-registered acceptable answer, not a failure.

7. [owner] Privacy note worth reading before step 3: the capture log lands in the repo at `docs/spikes/det6-browser-captures.jsonl`. URLs are recorded cut down to host plus one path segment, and printed in full only to your own terminal. **Window titles are recorded whole**, because their exact shape is the question, so a meeting title with a client's name in it will be written to that file. Redact it before it is committed if that matters, or pass `--out ~/det6.jsonl` to keep it out of the repo entirely.

8. [session] Files the report into the spike doc's **Measured** section, takes the branch the tree names, and lands the widening (or the NO-GO close) as its own change.
