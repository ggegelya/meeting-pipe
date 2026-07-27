# CAL3: Series-keyed continuity, replacing the workflow-as-series-key assumption

Band origin: filed 2026-07-27, off an owner observation while looking at the detection prompt during a live Teams meeting. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Three shipped features answer the question "what happened last time in this series?" and all three answer it with the **workflow**. AI6 injects the same workflow's prior decisions and open actions into the summarizer prompt ([summarize.py:255](../../pipeline/src/mp/summarize.py), `_prior_meeting_context`, which reads `workflow_id` from the meta sidecar at line 267). CAL2 renders the same relationship as the "Last time" card on the detection prompt ([PrepCard.swift:118](../../daemon/Sources/MeetingPipe/PrepCard.swift), `prepCard(for workflow:)`). AI7 groups restatements of one commitment into a `restated Nx` row, bucketed by workflow ([action_clusters.py:65](../../pipeline/src/mp/action_clusters.py)).

That key was chosen deliberately and recorded as a design decision, in AI6's spec: "The workflow is the series key (explicit, already resolved per meeting); no fuzzy series inference." AI7 inherited it by name. The decision was sound given what was available; the problem is that the owner's workflows are policy buckets, not meeting series.

**Measured on the owner's live library, 2026-07-27, 179 meetings carrying a meta sidecar.** Meetings per workflow: Personal 105, General 54, none 17, Client work 3. A workflow holding 105 meetings is not a series, so "the previous meeting in this workflow" is almost never the previous instance of the meeting about to start. This is the defect the owner saw: the prompt for a recurring call offered a recap of an unrelated meeting.

The owner's words, 2026-07-27: "it makes no sense to have 'Previous' meeting recap in here, cause usually meetings are not connected". The ask is a series identifier, so a recurring meeting shows the recap of its own previous instance.

**A series identifier already has a home and no working supply.** `<stem>.meta.json` already carries a `meeting_title` key, written from the AX window title at [MeetingMetaSidecar.swift:38](../../daemon/Sources/MeetingPipe/MeetingMetaSidecar.swift). On the same 179 meetings it is present on 6, which is 3% coverage. The only value appearing more than once is "Heorhii Hehelia", 5 times, which is a person and not a meeting name.

The cause is the extractor. [MeetingTitleResolver.swift:78](../../daemon/Sources/MeetingPipe/MeetingTitleResolver.swift), `extractTeamsNativeTitle`, matches exactly one pattern, `^\s*Meeting (?:in|with)\s+(.+?)\s*\|\s*Microsoft Teams\s*$`, and returns nil otherwise. A named recurring meeting does not produce that string. The daemon log agrees: `title=(none)` on nearly every `meta sidecar` line, with `title=Heorhii Hehelia` the only recurring exception.

That pattern was never field-verified. `daemon/Tests/MeetingPipeTests/Fixtures/window_titles.json` says so in its own README ("The current entries are seeded from `WindowRecognizerTests` and represent expected formats, not yet field-verified captures"), and the suite prints `[fixture] window_titles.json: 0/21 captured, 21 still seeded` on every run. All 21 title formats across every vendor are assumptions.

**The obvious alternative keys are already excluded.** Model-generated summary titles cannot group a series: 168 distinct titles over 169 summarized meetings on the same library, because the model writes a fresh title per meeting. The calendar is closed: CAL1 went NO-GO on 2026-07-17 because the owner's Teams and Outlook scheduling does not reach macOS EventKit, so there is no covering event to read a series identity from, and ADR 0011 carries that disposition.

## Scope

Probe first. The enabling signal is a measurement, not a design choice, and building on an unverified title format is exactly what produced the 3%.

**Leg 1, the probe (owner-run, read-only, gates the rest).** A script that dumps AX window titles for the Teams process across all its windows during a live meeting, and does so at a size that answers the series question rather than the format question alone: several instances of one named recurring meeting, plus a 1:1, plus an ad-hoc call. Enumerate every window including the `AXSystemDialog` compact call panel, since project memory records that the live in-call surface is that panel and not the backgrounded full call window, and that Teams exposes no `AXValue` or `AXIdentifier` to fall back on. Pre-register the verdict bars before running it, in the [`/spike`](../../.claude/commands/spike.md) shape: a series-identifying substring present on at least 80% of sampled meetings, and byte-identical across instances of the same named series. Record the raw captures into `window_titles.json` and flip those entries from `seeded: true` regardless of the verdict, since the fixture is wrong today either way.

**Leg 2, the key (only if leg 1 clears).** Derive a `series_key` in `MeetingMetaSidecar.build` from the captured title, by exact normalized match, not fuzzy inference. AI6's rule stands: no similarity scoring, no clustering of titles. A meeting with no resolvable title has no series key, exactly as a meeting with no workflow has no series today. This is a sidecar schema change, so it touches `mp.workflow.read_meta` and `test_workflow_overlay.py` on the Python side in the same commit, per the sidecar contract in [CONVENTIONS.md](../../CONVENTIONS.md).

**Leg 3, the readers (in this order).** Re-point CAL2 first, since it is the surface the owner is looking at and the cheapest to judge by eye. Then AI6. Then AI7, which is last on purpose: its failure mode is the sharpest, because an over-merge silently resolves a commitment nobody finished. Each reader falls back to the workflow key when a meeting has no series key, so a library of meetings recorded before leg 2 behaves exactly as it does today.

**If leg 1 fails**, the honest outcome is to narrow CAL2 rather than keep it. Showing an unrelated meeting's recap on the prompt is worse than showing nothing, because it costs panel space and reads as if the two meetings were related. State that as an acceptable verdict up front so the pickup session does not treat a negative probe as a failure to be worked around.

## Explicitly not in scope

**Fuzzy series inference.** Rejected in AI6's spec and rejected again here. Grouping by title similarity, attendee overlap, or time-of-week regularity all fail the same way: a wrong merge is silent, and AI7 turns a wrong merge into a resolved commitment.

**EventKit and any calendar read.** Closed by CAL1 on 2026-07-17 with a measurement, not an assumption. Do not re-propose it. If the owner ever connects their calendar to macOS, ADR 0011 carries the revisit note.

**Browser-hosted meetings.** DET6 owns the browser title problem and is a different gate (admission, not identity). This task is native Teams only, which is where 100% of the dogfood corpus sits.

**The duplicate workflow names** visible in the same screenshot (four "Client work", two "Personal") are WF9, already filed 2026-07-23. Not this task, though they are part of why the workflow reads as a policy bucket.

**Retrofitting a series key onto the 179 existing meetings.** Their AX titles were never captured and cannot be recovered. The fallback covers them.

## Acceptance

Leg 1: the probe exists, is read-only, and its verdict bars are written down before it is run. Real captures replace at least the Teams entries in `window_titles.json` with `seeded: false`, and the fixture test reports a non-zero captured count. A written verdict names GO or NO-GO against the pre-registered bars, with the sampled titles quoted.

Leg 2, if reached: `MeetingTitleResolver` recognizes the captured Teams format, pinned by a unit test per real captured title, including the negative case that a 1:1 or ad-hoc call produces no series key rather than a wrong one. `series_key` round-trips Swift to Python, pinned in `test_workflow_overlay.py`. `scripts/truth_fences.py` stays green.

Leg 3, if reached: a second instance of one recurring series shows the first instance's recap on the prompt, verified by eye on a real meeting, and a meeting in the same workflow but a different series does not. AI6's continuity block cites the same-series prior meeting. AI7 does not merge two actions from different series that share a workflow, pinned by a test built from two real stems. Both suites green, `swift test` and `pytest`, plus ruff and pyright.

Whole task: no meeting loses its recap relative to today. A meeting with no series key still gets the workflow-keyed behaviour, pinned by a test, so the change is additive for every meeting recorded before it.
