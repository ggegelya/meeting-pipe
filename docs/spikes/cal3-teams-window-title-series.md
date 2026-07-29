# CAL3 spike (leg 1): does a Teams window title carry a series identity?

Spike, 2026-07-29. Probe: [`daemon/scripts/cal3-teams-title-probe.swift`](../../daemon/scripts/cal3-teams-title-probe.swift) (owner-run, read-only, not in the SPM target). This spike ships the analysis and the measuring instrument; the empirical verdict is owner-owed because it needs several live Teams meetings. Legs 2 and 3 of [CAL3](../backlog/tasks/CAL3.md) are deliberately not built: leg 1 gates them, and building a title extractor before the measurement is the exact mistake that produced the 3% coverage this task exists to fix.

## The question

**Does a live Microsoft Teams meeting expose, in some AX window title, a string that identifies the meeting series, and is that string the same across separate instances of the same recurring meeting?**

That is one question with two halves, and both have to hold. A title that names the meeting but is worded differently each week cannot key a series. A title that is perfectly stable but says "Microsoft Teams" identifies nothing.

Everything in CAL3 hangs on it. Three shipped features (AI6's prior-meeting context, CAL2's "Last time" card, AI7's `restated Nx` clustering) answer "what happened last time in this series?" with the **workflow**, and on the owner's library the workflows are policy buckets: Personal holds 105 meetings, General 54, out of 179 with a meta sidecar. The previous meeting in a workflow is almost never the previous instance of the meeting about to start, which is the defect the owner reported on 2026-07-27.

## Why it cannot be answered here

The signal exists only inside a running Teams process during a live call, and it needs a *corpus*, not a single reading: several instances of one named recurring series, spread over days, plus a 1:1 and an ad-hoc call as negative controls. This harness has no live meeting, and no way to schedule three instances of one.

Worse, it has no usable Accessibility grant. Project memory records that a probe run from a disclaimed parent process reports "NOT granted" and would otherwise happily print a verdict off an empty window list. That false zero is indistinguishable from a real "Teams exposes nothing", so the probe refuses to run rather than guess. That refusal was exercised: running the probe in this harness prints `Accessibility access for this process: NOT GRANTED` and exits 2 without writing a record.

## Closed before measuring anything

Five of the six candidate mechanisms are settled without a probe, each with a citation. Only the sixth needed an instrument.

**The calendar is closed.** CAL1 went NO-GO on 2026-07-17: 0 of 55 recorded meetings had a covering EventKit event, because the owner's Teams and Outlook scheduling never reaches macOS Calendar.app. ADR 0011 carries the disposition. There is no covering event to read a series identity from. Do not re-propose it; the revisit trigger lives in ADR 0011.

**Model-generated summary titles are closed.** 168 distinct titles over 169 summarized meetings on the same library. The model writes a fresh title per meeting, so grouping by it would put every meeting in its own series.

**The workflow is closed as the key**, which is what filed this task. It is retained as the *fallback*, which is a different job and one it does adequately.

**Non-title AX attributes are closed, from this repo's own field evidence.** [`MeetingAXHandleBuilder.swift:225`](../../daemon/Sources/MeetingPipe/MeetingAXHandleBuilder.swift), written off a live AX dump of a real Teams call on 2026-07-14, records that Teams exposes no `AXValue` and no `AXIdentifier` anywhere in its tree, which is why MIC10 had to anchor on the `AXSystemDialog` subrole instead. Title text is the only content channel Teams offers. The probe still captures `AXValue` and `AXIdentifier` per window, so a future Teams build that starts exposing them shows up as a finding rather than staying invisible behind this assumption.

**Fuzzy series inference is closed by decision, not measurement.** AI6's spec rejected it and CAL3 rejects it again. Title similarity, attendee overlap and time-of-week regularity all fail the same way: a wrong merge is silent, and AI7 turns a silent wrong merge into a commitment marked resolved that nobody finished.

**Browser-hosted meetings are out of scope.** DET6 owns the browser title problem, and 100% of the dogfood corpus is native Teams.

## What the existing evidence does and does not say

This matters because the repo contains *partial* evidence that looks like an answer and is not one.

The 2026-07-14 dump quoted in `MeetingAXHandleBuilder.swift:198-200` shows three windows during a backgrounded call, and their titles are elided in the comment as `"Meeting compact view | ..."`, `"Calendar | ..."`, and `"Meeting with ... | ..."`. So the shape of the tree is known and the *content* of the titles is not. The elision hides exactly the bytes CAL3 needs.

The 3% coverage is consistent with the extractor working correctly on the one case it was written for. `extractTeamsNativeTitle` matches only `^\s*Meeting (?:in|with)\s+(.+?)\s*\|\s*Microsoft Teams\s*$`, and the only `meeting_title` value appearing more than once across 179 meetings is a person's name, 5 times. That is what a "Meeting with `<person>`" title yields. So the evidence says the 1:1 branch fires and says nothing at all about what a *named recurring* meeting produces.

**No new pattern is written in this spike, and none should be written from the strings above.** They are elided and they are a year of Teams releases old. All 21 entries in `daemon/Tests/MeetingPipeTests/Fixtures/window_titles.json` are seeded guesses that the suite still reports as `0/21 captured, 21 still seeded`; adding a 22nd guess with more confidence behind it is how this defect got here.

## Two failure modes the probe has to separate

The 3% has two possible causes and they have different fixes, so the probe measures both.

**Format.** No window title matches the one pattern the extractor knows. The fix is a new extractor written from real captures.

**Timing.** `MeetingTitleResolver.resolve` is called exactly once, from `MeetingSessionController.appSource(from:)` at prompt time, which is near the start of the meeting. If the window carrying the meeting name does not exist yet at that instant, a perfect extractor still returns nil. Teams is known to create and destroy the compact call panel as the call moves between surfaces, so this is not hypothetical.

The probe therefore samples over a window rather than once, and records `label_present_at_first_sample` separately from `label_present`. A corpus where the name is present overall but absent at the first sample is a timing finding, and it would mean leg 2 needs a re-resolve rather than only a new regex.

## Method: what the probe measures, and why it contains no title pattern

The probe never parses a Teams title. It measures two format-agnostic things, using the meeting's own name as supplied by the owner on the command line:

1. **Containment.** Does any captured window title contain the meeting's name, case-insensitively and whitespace-normalized? This needs no knowledge of delimiters, suffixes, or word order.
2. **Byte identity.** Across separate instances of the same recurring meeting, is at least one *whole* title string byte-for-byte identical, and does that stable title carry the meeting's name? The name restriction is load-bearing: without it, a constant like "Microsoft Teams" passes the stability bar and would key every meeting in the library to one series.

It enumerates every window the app exposes, unioning `AXWindows`, `AXFocusedWindow` and `AXMainWindow`, and it does not filter by role, because the live in-call surface is the floating compact panel whose subrole is `AXSystemDialog` and a role filter is how a walk misses it. It rebuilds the application element on every sample rather than holding a handle, since Teams destroys and recreates that panel mid-call. It records role, subrole, title, `AXValue`, `AXIdentifier`, description and frame per window, and it bounds AX messaging at 2 s.

It is read-only. It writes one file, its own append-only capture log at `docs/spikes/cal3-title-captures.jsonl`, and touches no recording, sidecar, or config.

### Why this is not just `scripts/dump_window_titles.swift`

That script already exists, already checks the Accessibility grant, and already prints a `seeded: false` fixture entry, so the overlap is real and worth justifying rather than leaving for someone to notice later. It stays; it is what README's troubleshooting section points at when an unrelated window is being recognized as a meeting, and it is the right tool for a one-off `reject` row on any vendor.

It cannot answer CAL3, for four reasons. It takes a **single snapshot**, so it cannot separate the format failure mode from the timing one. It keeps **no corpus**, printing to stdout and remembering nothing, while CAL3's question is inherently cross-instance: byte identity across three separate meetings on three separate days is not computable from one run. It reads **titles only**, from `kAXWindowsAttribute` alone, so it records neither the subrole that says which window carried the name nor the `AXValue` / `AXIdentifier` absence this spike wanted confirmed rather than assumed. And it has **no bars and no verdict**, which is the actual deliverable of a spike.

Folding sampling, a persistent labelled corpus, and CAL3's verdict rules into a 79-line general-purpose helper used by four vendors and by the reject cases would couple a shared tool to one task's decision logic. Per-task probe files under `daemon/scripts/` are the established shape here (`cal1-`, `det2-`, `end6-`, `mic7-`, `mic8-`, `auto1-`), so this follows it.

## Pre-registered verdict bars

**These are written down before any measurement exists, and they are not to be refitted afterwards.** The probe computes them itself and prints the verdict, so the owner needs no interpretation help and no later session gets to reinterpret a number.

**Corpus adequacy, checked first.** No verdict is emitted at all unless the corpus holds at least 3 instances of one named recurring series captured under the same label, at least 1 one-on-one call, and at least 1 ad-hoc call, and every capture was taken with Accessibility granted. Short of that the probe exits 3 saying what is still needed. An underpowered corpus produces no verdict rather than a weak one.

**Bar A, coverage.** The meeting's name appears in some window title on **at least 80%** of sampled meetings. Reported twice: over all captures (the primary, and the number the spec named), and over the named-series captures alone (the fallback, which separates "Teams names nothing" from "Teams names scheduled meetings but not ad-hoc calls").

**Bar B, stability.** At least one name-bearing title is **byte-identical across every captured instance** of the same named series.

**Bar C, the negative control.** No 1:1 and no ad-hoc call emits a title byte-identical to that stable series title. A collision here means an exact-match key silently merges unrelated meetings, which is precisely the failure AI7 converts into a wrongly resolved commitment.

| Verdict | Measured condition | What it authorizes |
|---|---|---|
| **GO** | Bar A over all captures >= 80%, and B, and C | Leg 2 as specced, then leg 3 in order: CAL2, then AI6, then AI7 |
| **MARGINAL** | A over all captures < 80% but A over series captures >= 80%, and B, and C | Leg 2 as specced, and leg 3's **CAL2 leg only**. AI6 and AI7 are held until the owner has eyeballed CAL2 |
| **NO-GO** | Anything else: B fails, or C fails, or coverage is short on both denominators | Neither leg 2 nor leg 3. Narrow CAL2 instead |

MARGINAL is a real and fairly likely outcome, not a fudge. Leg 2's own rule is already that a meeting with no resolvable title has no series key, so a 1:1 yielding nothing is correct behaviour rather than a miss. What the coverage shortfall changes is how much of the library still rides the workflow fallback, and the workflow fallback is exactly where AI7's over-merge risk lives. Hence: ship the surface the owner can judge by eye, hold the two that fail silently.

If Bar B passes, note what it licenses directly: the **whole normalized title** works as the series key, with no parsing at all. Leg 2 still needs a rule for *which* title in the window set to take, which is why the report prints the subrole each title appeared on. Writing a regex to extract a sub-part is optional polish that Bar B does not by itself evidence.

## A NO-GO is an acceptable, expected outcome

Stated up front so a later session does not treat a negative probe as a failure to engineer around.

If Teams does not hand out a stable series identity, the honest response is to **narrow CAL2, not to substitute another mechanism**. A "Last time" card keyed by a 105-meeting workflow does not merely fail to help. It costs panel space on the detection prompt and it falsely implies the two meetings are related, which is worse than showing nothing. The owner's own words on 2026-07-27 were that the Previous-meeting recap makes no sense because the meetings are not connected.

Under a NO-GO, do not reach for fuzzy title similarity, attendee overlap, time-of-week regularity, or reading Teams' private on-disk storage. The first three are already rejected above and fail silently. The fourth trades a measured no for an unmeasured dependency on another app's internals, which is the same bet that produced the 3%. A NO-GO closes legs 2 and 3 and files the CAL2 narrowing as its own task for the owner to band.

## The owner-owed remainder

Run from the repo root, in a **normal Terminal window you opened yourself**, with Accessibility granted to that Terminal in System Settings -> Privacy & Security -> Accessibility. A shell launched by an agent or another disclaimed parent inherits the parent's TCC identity and will refuse.

One run per meeting, started as the meeting starts, so the first sample approximates the moment the daemon actually resolves the title:

```
swift daemon/scripts/cal3-teams-title-probe.swift --label "<the meeting's name>" --kind series
swift daemon/scripts/cal3-teams-title-probe.swift --label "<the person>"        --kind one-on-one
swift daemon/scripts/cal3-teams-title-probe.swift --label "<short description>" --kind ad-hoc
```

Use the **same `--label` for every instance of the same recurring meeting**; that string is what Bar B is computed over. Three instances of one series are needed, plus one 1:1 and one ad-hoc. Each run watches for 30 s by default (`--watch`, `--interval`).

Then, once the corpus is complete:

```
swift daemon/scripts/cal3-teams-title-probe.swift --report
```

It prints the corpus, every observed title with the subrole it sat on, the three bars, the verdict, and a `window_titles.json`-shaped block. Three follow-ups:

- Paste the report output into this file under a `## Measured (<date>)` heading, and record GO, MARGINAL or NO-GO with the sampled titles quoted. Do not restate the bars afterwards.
- Paste the emitted fixture entries into `daemon/Tests/MeetingPipeTests/Fixtures/window_titles.json`, replacing the seeded Teams rows of the same state. This happens **regardless of the verdict**, because the fixture is wrong today either way, and it is what turns `0/21 captured` into a non-zero count.
- If a pasted row turns `WindowRecognizerFixtureTests` red, that is a genuine finding about `MeetingSourceScanner.isActiveMeetingWindow`, not a bad capture. File it. Do not edit the captured titles to make the suite green.

**Privacy.** The capture log and the fixture entries hold real meeting names and real colleague names, and both live in a git tree. Redact before committing if you want to, and redact **consistently**, because Bar B is byte identity and an inconsistent redaction would break a title that was genuinely stable.

## What leg 1 establishes, and what it cannot

It establishes the decision rule before the data exists, which is the entire point: the bars, the corpus minimum, and the three authorizations are fixed now and cannot be bent to fit whatever the first capture happens to show. It closes five of six candidate mechanisms with citations. It separates the format failure mode from the timing one, which the task spec treated as a single cause. And it makes the false zero unreportable: without an Accessibility grant the probe refuses to capture and refuses to emit a verdict, so an empty read can never be handed over as a NO-GO.

It cannot tell you whether Teams emits a series-identifying title. Nothing in this repo or this harness can, which is why it is a spike.

Two residual risks worth naming. First, every code path in the probe was exercised against synthetic corpora rather than a live Teams tree, so a Teams-specific AX surprise (windows reachable only through some attribute this probe does not union, or titles that differ between the panel and the full window in a way the sampling misses) would surface on the owner's first real run, not here. Second, Bars A and B establish that an identifying string is present and stable; they do not establish that it is cleanly *parseable*. If leg 2 ends up wanting a sub-part rather than the whole title, that extraction still has to be written and tested against the real captured strings.
