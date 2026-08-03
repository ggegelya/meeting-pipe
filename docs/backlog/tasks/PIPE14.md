# PIPE14: publish state is read from `run.json` while every document names `publish.json`

Filed 2026-08-03 by the audit band. Found independently by the pipeline-contracts angle and the doc-truth angle. Proposed high by both, downgraded to medium by an independent skeptic on reachability.

## What is wrong

`Meeting.publishState` has exactly one assignment and it reads the run sidecar, not the publish sidecar. Only `mp run-all` ever writes a fresh value, so `mp publish`, `mp merge-meetings` and `mp publish-from-paste` all rewrite `<stem>.publish.json` and leave the value the whole Library branches on frozen at its previous state.

- `daemon/Sources/MeetingPipe/MeetingStore.swift:661` is `publishState: (run?["publish_state"] as? String),`.
- `pipeline/src/mp/orchestrate.py:533` is `set_publish_state(sidecar, publish_state(pub))`, the only site that writes a fresh value. `summarize.py:913` merely carries the prior value forward.
- `pipeline/src/mp/publish_cmd.py` contains no `set_publish_state` call anywhere in the file. `merge_meetings.py:236-241` ends at `publish_fanout` with none either.
- The six branch sites all read the run-sourced value: `MeetingRow.swift:277` and `:278` (the retry-vs-publish action), `MeetingRow.swift:198` (the badge), `AudioRetention.swift:59` (`isSettled`, so a stale value keeps the audio forever), `LibraryScope.swift:134` (Needs-you membership), `MeetingDetailView+Header.swift:209` and `:212`.

Four documents assert the other file:

- `ARCHITECTURE.md:496` calls `<stem>.publish.json` "this run's publish outcome ... Rewritten every run, so it is never stale (PIPE1)".
- `CONVENTIONS.md:360` attributes the six literal-comparing branch sites to `publish.json`'s `state`.
- `daemon/CLAUDE.md:30` instructs "Read `<stem>.publish.json` via `PublishResult.load` (PIPE1)".
- `MeetingStore.swift:708-711`'s own doc comment repeats it.

## Reachability, stated honestly

The skeptic checked the owner's disk and the loop has never been reachable in this configuration: `"partial"` needs two or more sinks and every workflow the owner has recorded under has exactly one, and `"none"` has never once been written (95 of 95 run sidecars and 37 of 37 publish sidecars read `"full"`). Publish has also never failed here: 0 non-residue `publisher.sink_failed` rows across 173 `sink_started` / `sink_completed` pairs.

So this is a latent trap plus a live documentation lie, not an active bug. It is filed at medium because the trap arms the moment a second sink is configured or a publish fails, and because four documents currently instruct the next reader to believe the opposite of the code.

## Scope

Pick one source of truth and delete the other read. Either have `publish_cmd`, `merge_meetings` and `publish_from_paste` call `corrections.set_publish_state` after `fanout` the way `orchestrate.py:533` does, or change `MeetingStore` to source `publishState` from `PublishResult.load` and fall back to the run sidecar only when `publish.json` is absent. The second is closer to what every document already claims and to what `daemon/CLAUDE.md:30` instructs.

Then correct `ARCHITECTURE.md:496`, `CONVENTIONS.md:356-360`, `daemon/CLAUDE.md:30`, `MeetingStore.swift:708-711` and `summarize.py:890-893` so they name the file the branches genuinely read.

Note the interaction with UX62, which fixes the sibling blindness in `needsRepublish`. Both are about the Library inferring publish outcome from the wrong file, and both should reuse whatever helper lands first.

## Acceptance

Suite green with new tests. A test drives a run that publishes to zero sinks, then a successful `mp publish`, and asserts the Library's derived publish state reflects the second outcome. The cross-tree golden fixture that CI4 pins covers whichever file becomes the source of truth. The five doc sites are corrected in the same commit.
