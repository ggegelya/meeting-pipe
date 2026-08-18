# DET6 spike: is a browser tab's URL readable, and is a call title separable from a doc title?

Spike, 2026-08-18. Probe: [`daemon/scripts/det6-browser-url-probe.swift`](../../daemon/scripts/det6-browser-url-probe.swift) (owner-run, read-only, refuses without an Accessibility grant). This spike ships the analysis, the instrument, and the verdict tree. **The measurement itself is owner-owed**: both questions need real browsers holding a real call under a real TCC grant, and neither is answerable from inside a coding harness.

The verdict tree below was written **before** any capture existed. It is not to be refitted afterwards. If a bar looks wrong once data arrives, say so in the Measured section rather than moving the bar.

## The gap being measured

A meeting held in a plain browser tab is detected only if it is Google Meet. Everything else is refused, and until this task shipped the refusal was silent.

The gate is `MeetingSourceScanner.decideBrowserAdmission`, which DET6 lifted out of the inline guards in `MeetingSourceScanner.enumerateCandidates`. It admits on either of two things, and both are far narrower than they look:

- **A strong title.** `MeetingSourceScanner.browserWindowIndicatesStrongMeeting` resolves to `BrowserMeetingLifecycleAdapter.strongTitleMatchers`, which holds exactly one entry, `MeetingTitlePatterns.googleMeet`. Nothing else is ever strong.
- **A registered URL fragment.** The fragment check reads the AX **window title** against `browser.url_fragments` from `meeting_apps.toml`. Browsers put the page title in the window title and never the URL, so a normal Teams or Webex page title does not contain its own URL and this disjunct effectively never fires, for any product including Meet (which is carried by the strong matcher instead).

The result, given `BrowserMeetingLifecycleAdapter.defaultTitleMatchers` is the weak OR of `googleMeet`, `browserTeams` (`contains("microsoft teams")`), `browserWebex` (`contains("webex")`) and `slackHuddle` (a `huddle` word):

| Browser tab | Weak title match | Admission today |
|---|---|---|
| Google Meet | yes | **admitted**, via the strong matcher |
| Teams web (`teams.microsoft.com`, `teams.live.com`) | yes | refused, `weak_title_only` |
| Webex web (`webex.com/meet`, `webex.com/wbxmjs`) | yes | refused, `weak_title_only` |
| Slack huddle (`app.slack.com`) | yes | refused, `weak_title_only`, and no Slack URL fragment is registered at all |
| Zoom web client (`zoom.us/j/`, `zoom.us/wc/`) | no | refused earlier, `noMeetingSignal`: `defaultTitleMatchers` has no Zoom entry |

Only the ten plain-browser bundle IDs in `meeting_apps.toml [browser.bundles]` are affected. Native apps have no such gate, and neither does the Chromium PWA branch, which admits on `titleMatched || nameMatched`.

## Why this is probe-first rather than a widening

The obvious "fix" is to promote `browserTeams` and `browserWebex` into `strongTitleMatchers`. That is exactly the false start END5 closed on purpose: a page titled "Webex vs Zoom Comparison" contains `webex`, a browser title stands alone in `MeetingSourceScorer` with no per-tab Leave or mute button to corroborate it, and the result is a Record prompt over a comparison article. END5's own escape hatch for this (admit a bare brand token when live process audio corroborates it) was inert on the day it shipped, and re-admitting bare brand tokens on the strength of DET8's end-side revival is a start-side false-positive question this task has to answer with evidence rather than inherit.

So the deliverable is the instrument and the decision, not a guess. Both questions are cheap to measure and impossible to reason about from here.

## Question 1: can the real URL be read through an accessible channel?

This is the outcome to hope for, because it needs no new heuristic at all. If the URL is readable, the fragment check is repointed at the URL it was always meant to read, and the `browser.url_fragments` list already in `meeting_apps.toml` fixes Teams, Zoom and Webex in one move.

Three candidate channels, which the probe reads in this order:

1. **The address bar's `AXValue`.** The omnibox is a text field in the window chrome. The risk is that it shows what the user typed rather than the loaded URL, and that a focused or empty omnibox reads as nothing.
2. **The web area's `AXURL`.** `AXWebArea` is the root of the rendered page. If this attribute is populated it is the authoritative answer and it is per-tab rather than per-window.
3. **The web area's `AXDocument`.** The same element's document attribute, historically the one WebKit populated.

**The probe deliberately hardcodes no selector for any of them.** It does not guess at Chrome's omnibox `AXIdentifier` or assume Safari and Firefox spell it the same. It walks the window chrome to a bounded depth, dumps every text field it finds with its role, subrole, identifier and description, and reports which of them held something URL-shaped. Picking the selector is this document's job once the dump exists, not the probe's.

Two things that would make a naive read look like a success when it is not, both of which the bar below is shaped to exclude:

- A **transient**. A single read of a focused omnibox can catch a partially typed string. The bar therefore requires two separate captures, not two samples inside one.
- A **readable URL that matches nothing**. A URL the app can read but that contains no registered fragment fixes nothing, so the bar is "matched a `browser.url_fragments` entry", never "a URL was readable".

## Question 2: is a live call's title separable from a document about the same product?

If the URL is unreachable, the fallback is a per-product strong matcher of the kind `googleMeet` already is: it works because a live Meet tab carries a 3-4-3 room code alongside the brand, which a page about Meet does not. The question is whether Teams web, Webex web or a Slack huddle carries an equivalent structural marker.

The measurement is a comparison, not an observation. A capture of a live Teams call title on its own proves nothing; what matters is a token present in **every** call title and absent from **every** doc title for the same product. That is why the probe takes `--kind call` and `--kind doc` and refuses to produce a per-product verdict without both.

## Pre-registered verdict tree

Bars, fixed before any capture:

- **Leg 1 (URL) passes** when at least one accessible channel produces a string containing a registered `browser.url_fragments` entry, in at least **two separate captures**.
- **Leg 2 (title) passes** for a product when there are at least **two `call` captures and two `doc` captures** for it, and at least one token appears in every call title and in no doc title.

The tree, in priority order. The probe prints the branch it lands on:

**Branch A: leg 1 passes.** Repoint the fragment check at the URL. `decideBrowserAdmission` gains the read URL alongside the window titles, the existing fragment list closes Teams, Zoom and Webex together, and the missing Slack fragment is added in the same change. This is the preferred outcome: it invents no title heuristic, so it cannot reopen END5's doc-title problem, and it is per-tab rather than per-window. Leg 2 is then moot and the corpus is kept only as documentation.

**Branch B: leg 1 fails, leg 2 passes.** Add one entry to `BrowserMeetingLifecycleAdapter.strongTitleMatchers` per product that cleared the bar, keyed on the discriminating structure the report names and never on the bare brand token. The missing Zoom `defaultTitleMatchers` entry is added in the same change, since a Zoom web tab has to become a weak match before it can become a strong one. Each new matcher ships with the "Webex vs Zoom Comparison" fence in `MeetingSourceScannerTests` still asserting a refusal.

**Branch C: neither passes.** Close the widening leg and record the limitation as permanent: a browser tab hosting Teams, Webex, Slack or Zoom cannot be distinguished from a page about that product by any signal available on this platform, and admitting it anyway reopens a known false-positive class for a surface with zero recorded meetings. The `detector.browser_tab_rejected` event stays as the standing record of what is being missed, so a later reader can see the rate rather than rediscover the gap. Under this branch DET6 closes NO-GO and the two adjacent gaps (the Zoom title matcher, the Slack fragment) close with it, since neither is reachable without an admission path.

A NO-GO is a pre-registered acceptable outcome. Branch C is not a failure of the spike.

## What is deliberately excluded

- **The mic-busy signal as a corroborator.** Assessed and rejected 2026-07-20. `MicBusySpanTracker` reads `AVCaptureDevice.isInUseByAnotherApplication`, which is system-wide and cannot name the holder; its attribution is the frontmost app at the rising edge, frozen for the span. A post-call Webex session holding the mic would corroborate an unrelated browser tab.
- **Reviving start-side process audio.** DET8 revived the signal end-side on 2026-08-05; the native start-side rewiring is DET12's. A browser on the mic names only the browser and never which tab, which is the whole reason the browser case does not follow from the native one.
- **The PWA branch.** Unaffected by this gate and working. Do not touch it while fixing the plain-browser branch.
- **Web-content AX as a general strategy.** MIC7 already rejected reading Meet's rendered DOM through AX as more churn-prone than the DOM itself. Leg 1 is narrower than that and stays narrow: it reads one attribute off the web area's root element, not the page's contents.

## What shipped ahead of the measurement

Three things do not depend on how the probe lands, and shipped with this document.

**The refusal is no longer silent.** A refused tab emits `detector.browser_tab_rejected` carrying the bundle ID, the weakly-matching window title and a reason. Before this, a refused tab was dropped by a bare `continue` before entering `candidates`, and `MeetingSourceScanner.Result.droppedCandidates` is built by filtering that same array, so nothing anywhere recorded that a browser meeting had been seen and refused. The miss rate could not be measured even in hindsight. It rides out of the scan on `Result.rejectedBrowserTabs` for the same structural reason DET11's `unreadableNatives` needed its own list. `mp logs --action browser_tab_rejected` reads it.

**The admission decision is a pure function.** `MeetingSourceScanner.decideBrowserAdmission(windowTitles:urlFragments:)` returns `admit` / `noMeetingSignal` / `weakTitleOnly(matchedTitle:)`. The guards it replaced sat inline in a `private` method behind live AX reads, so not one case could be pinned without a browser holding a real call. Whichever branch the verdict takes, the change lands in that one function with the tests already around it.

**The gate's cases are pinned.** `MeetingSourceScannerTests` carries the Meet admissions and the "Webex vs Zoom Comparison" refusal as unconditional fences, and the three brand-token refusals as explicitly pre-verdict state.

## Measured

_(Owner-owed. Nothing here has been measured. Paste the probe's `--report` output below with the date, quote the titles and URL reads it names, then take the branch the tree above names. Do not fill this in from expectation: an Accessibility-untrusted run reads zero windows and would produce a confident-looking branch C that measures the permission rather than the browsers, which is the DET2 lesson this probe's refusal exists to prevent.)_

**Leg 1 result:** not measured.

**Leg 2 result:** not measured.

**Branch taken:** none yet.

## Owner walkthrough

See the `## Owner walkthrough` section of [`docs/backlog/tasks/DET6.md`](../backlog/tasks/DET6.md), which carries the step-by-step with what a pass looks like and what it costs.
