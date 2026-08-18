# VALOWN1: Run the CAL3 Teams title probe across five real meetings

Band origin: filed 2026-07-30, at the owner's request, to hold CAL3's owner-run measurement rather than leave CAL3 itself sitting in the P2 band with nothing an engineering session can do ("CAL3 - not sure, I need more team calls, for now we can keep with lower or create something like 'VALOWN' task and put it in the bottom of backlog with definitive instructions"). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

**VALOWN is a new letter band, and it is deliberately a band rather than a one-off task.** It means *validation only the owner can run*: work that is fully built, needs no engineering, and is blocked purely on the owner being in front of real conditions. The repo already had the pattern without a name (EGRESS1 is a waived validation leg at P4), and it is worth a home because twelve items sat `owner-owed` on 2026-07-30 and it was not obvious which of them a session could advance and which needed the owner in a live meeting. Anything landing here is P4, sits at the bottom of the backlog, and carries instructions complete enough to follow without reading the task it came from.

## What this is

CAL3's leg 1 is **built and committed** (`aec8788`). The probe script, the analysis doc, and the pre-registered verdict bars all exist. What does not exist is data, because it can only be captured during real Microsoft Teams calls, across separate instances of one recurring meeting. The owner does not have enough team calls yet.

CAL3's legs 2 and 3 (a `series_key` in the meta sidecar, then re-pointing CAL2, AI6 and AI7) are gated on this verdict and must not be built before it. Building a title pattern off a plausible guess is exactly what produced the current 3% coverage, so a guessed GO is worse than no GO.

## Definitive instructions

Read [`docs/spikes/cal3-teams-window-title-series.md`](../../spikes/cal3-teams-window-title-series.md) once before the first capture. The verdict bars in it were written down before any measurement and **must not be adjusted afterwards**; if they turn out to be the wrong bars, the honest move is a new document with new bars, not an edit to that one.

**One-time setup.** The probe needs Accessibility permission for whatever runs it: System Settings -> Privacy & Security -> Accessibility, enable Terminal (or the IDE you will run it from). Verify it took by running the probe once outside a meeting: its first output line reads `PRECONDITION  Accessibility access for this process: GRANTED`. If it says `NOT GRANTED` it exits 2 and writes nothing, on purpose, because an untrusted process reads zero Teams windows and a zero-window capture is indistinguishable from a real negative.

**Per meeting, five captures minimum.** Start the probe as the meeting starts, since its first sample approximates the moment the daemon actually resolves the title. Run one command per meeting, from the repo root:

- Three separate instances of the **same named recurring meeting**, passing the identical `--label` every time (the label is that meeting's own name as it appears in Teams or your calendar):
  ```
  swift daemon/scripts/cal3-teams-title-probe.swift --label "Weekly sync" --kind series
  ```
- At least one **1:1**, labelled with the other person's name:
  ```
  swift daemon/scripts/cal3-teams-title-probe.swift --label "Alice" --kind one-on-one
  ```
- At least one **ad-hoc** call:
  ```
  swift daemon/scripts/cal3-teams-title-probe.swift --label "budget call" --kind ad-hoc
  ```

The three series captures are the load-bearing ones: bar B is whether a whole title is byte-identical across instances, which a single capture cannot test. The 1:1 and ad-hoc captures test bar C, that a non-series call does not collide with the series title, which is the guard against AI7 silently merging commitments across unrelated meetings.

Captures accumulate in `docs/spikes/cal3-title-captures.jsonl`. Running the probe again never overwrites earlier captures, so the five runs can be spread across as many weeks as it takes.

**When all five exist, get the verdict:**
```
swift daemon/scripts/cal3-teams-title-probe.swift --report
```
It prints GO, MARGINAL, or NO-GO against the pre-registered bars, and emits a `window_titles.json`-shaped block.

**Then, whatever the verdict says**, hand the report to an engineering session. Three things follow and all three are worth doing even on a NO-GO:

1. The emitted fixture block goes into `daemon/Tests/MeetingPipeTests/Fixtures/window_titles.json` with `seeded: false`. Those 21 entries are wrong today either way, and the suite has been printing `0/21 captured` on every run since they were written. Two details HYG6 corrected on 2026-08-18, because as originally written this step could turn the whole capture into a red suite:
   - **Every emitted row carries `expected: "unknown"`, and that is deliberate.** The probe carries no Teams title pattern on purpose and never calls `MeetingSourceScanner.isActiveMeetingWindow`, so it cannot know whether a captured title is one the recognizer accepts, and it used to emit a hardcoded `"recognize"` that `WindowRecognizerFixtureTests` then hard-asserted. An `unknown` row is printed by the suite rather than asserted. Run `cd daemon && swift test --filter WindowRecognizerFixtureTests`, read the `[fixture] UNCLASSIFIED …` line for each pasted row, and write `recognize` or `reject` in by hand. **A real captured title that the recognizer rejects is a DET-band finding about `isActiveMeetingWindow`, not a paste error and not a bad capture**, and it is a plausible outcome here rather than a hypothetical one, since CAL3 exists precisely on the finding that real Teams titles do not match this repo's guessed formats. File it; never edit a captured title to make the suite green.
   - **Only one of the three emitted states replaces anything.** `in_call_one_on_one` exists in the fixture and its capture replaces that seeded row. `in_meeting_named_series` and `in_meeting_ad_hoc` are new names with no seeded counterpart, so they are added; decide deliberately which seeded Teams rows they supersede rather than leaving guesses sitting beside real captures.
   - **The paste is also what un-skips a test** (CI6). `test_fixture_is_backed_by_real_captures` currently **skips**, because with every row `seeded: true` the fence pins this repo's model of a Teams title rather than a Teams title, and XCTest's word for "not verified" is a skip rather than a failure. The first row landing with `seeded: false` clears it, so `swift test` going from "1 test skipped" to zero skipped is the machine-checkable half of this step being done.
2. The verdict gets written into the spike doc, quoting the sampled titles.
3. CAL3 is re-banded: promoted for legs 2 and 3 on a GO; on a MARGINAL, leg 2 plus CAL2 only, holding AI6 and AI7 (at partial coverage most meetings still ride the workflow fallback, which is where AI7's over-merge lives); on a NO-GO, CAL3 narrows to removing CAL2's "Last time" recap rather than working around the result. A NO-GO is a pre-registered acceptable outcome, not a failure to engineer past.

## Explicitly not in scope

Building legs 2 or 3. Adjusting the verdict bars or the MARGINAL tier definition after seeing data. Re-proposing EventKit (CAL1 closed it by measurement on 2026-07-17; ADR 0011 carries the revisit note). Browser-hosted meetings (DET6's problem, and the dogfood corpus is 100% native Teams).

## Acceptance

`docs/spikes/cal3-title-captures.jsonl` holds at least five captures, at least three of them sharing one `--label` with `--kind series`, plus a `one-on-one` and an `ad-hoc`. `--report` prints a verdict. The three follow-ups above are done, and the fixture test reports a non-zero captured count with no row left `unknown` (an unclassified row is a decision nobody has made yet, not a result). `swift test` reports **zero skipped tests**, which is the same claim stated in the runner's own vocabulary: `test_fixture_is_backed_by_real_captures` skips while the captured count is zero and passes once it is not (CI6). Then this task closes and CAL3 is re-banded per its verdict.
