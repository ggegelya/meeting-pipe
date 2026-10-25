# PERF23: Facts, People and Meeting time re-read the whole library on every store revision in uncancelled passes that can land out of order, and Meeting time's transcript cache dies on every rail switch

Band origin: filed 2026-10-25 from the performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified in code on 2026-10-25 against `01e904a` (review finding LIBRARY-4, confirmed by the verifier).

**Facts reloads on every revision, in passes nothing orders.** `LibraryRootView` runs `.onChange(of: meetingStore.revision) { _, _ in recomputeCounts(); reloadFacts(); resolveTranscriptJump() }`. `reloadFacts()` snapshots `meetingStore.meetings` and spawns `Task.detached(priority: .userInitiated) { let now = Date(); let raw = FactsLoader.load(meetings: meetings, now: now) ... await MainActor.run { facts = snapshot; refreshClustersIfNeeded(for: keys) } }`, whether or not Facts is the visible scope, because "the rail badge has to be right whether or not Facts is the active scope". `FactsLoader.load` decodes every `<stem>.summary.json`. The task handle is not kept, nothing cancels or coalesces it, and its result is applied in completion order, so a burst of revisions (several per pipeline run, one per local edit) runs N full passes at once and the last to finish wins even when it read an older snapshot: a stale Facts list or overdue badge until the next revision.

**People has the same shape.** `PeopleView` runs `.onChange(of: store.revision) { _, _ in reaggregate() }`, and `reaggregate()` is a `Task.detached` over every meeting that calls `SpeakerLabelStore.read(stem:in:)` and `MeetingSummary.load(from:)`, then `await MainActor.run { self.facts = loaded; ... rederive() }`, with the same ordering hazard.

**Meeting time loses its cache on every rail switch.** `StatsView` keeps `@State private var talkCache: [String: MeetingStats.Talk?] = [:]`, and its own comment says why: "Reading every transcript is the expensive half of this view (the whole library is roughly 80 MB of `<stem>.json` against under 1 MB of summaries)". But `LibraryRootView` builds `StatsView(store: meetingStore, ownerLabel: model.ownerLabel)` inside its scope `if / else if` chain, so a rail switch destroys the view and the cache, and every visit re-measures the library. `StatsView.reload()` passes `owner == cachedOwnerLabel ? talkCache : [:]` and writes the cache back only when a pass completes, so revisions that arrive during the first pass each start another full pass with an empty cache. The cache is keyed by stem alone, so a speaker rename (an overlay write) while the view is open keeps the old talk split for that meeting.

**Each measurement parses more than it needs, embeddings twice.** `StatsLoader.measure(meeting:ownerLabel:)` goes through `TranscriptLoader.load(stem:in:)`, which parses the transcript, reads corrections and the speaker overlay, and reads and parses `<stem>.embeddings.json` twice, because `MeetingStore.voiceprintLabels(stem:in:)` and `MeetingStore.nearMisses(stem:in:)` each do `Data(contentsOf:)` plus `JSONSerialization.jsonObject` on the same file. `MeetingStats.talk` reads only the segments and the overlay.

**Magnitude.** About 80 MB of JSON per Meeting time visit at the work library (the view's own figure), repeated in parallel during a pipeline run; Facts and People are under 1 MB of summaries per pass but run on every revision while the Library is open. Code-read; no trace captured these passes (PERF11's stall telemetry is not built).

**Facts may go away.** DV5 (measurement half shipped 2026-08-19, recommendation blocked on the owner) may recommend removing the Facts rail; its loader and badge would go with it, and items 1 and 4 would then cover People and Meeting time only.

## Scope

The seams are `LibraryRootView.reloadFacts()`, `PeopleView.reaggregate()`, `StatsView.reload()`, `StatsLoader.load` / `measure`, and `TranscriptLoader.load(stem:in:)`.

1. **One generation-checked loader per projection.** A small reusable type holds the in-flight `Task` and a generation counter: starting a pass cancels the previous task and bumps the generation, and a result is applied only if its generation is still current. `reloadFacts`, `reaggregate` and `StatsView.reload` use it, and `FactsLoader.load`, `StatsLoader.load` and People's loop check `Task.isCancelled` between meetings so a superseded pass stops reading.
2. **The Meeting time cache outlives the view.** `talkCache` moves to a long-lived owner (`LibraryWindowModel`, or a small cache object it holds), keyed by stem plus `TranscriptLoader.fingerprint(stem:in:)`, which already covers the transcript, the speaker overlay, the corrections and the markers. A rail switch keeps it, a rename invalidates exactly that stem, and an owner-label change still drops it.
3. **One embeddings read, and a lighter load for Stats.** `TranscriptLoader.load` reads `<stem>.embeddings.json` once and derives both `voiceprintLabels` and `nearMisses` from it; `StatsLoader.measure` uses a load that skips embeddings and markers.
4. **Per-stem caches for Facts and People**, keyed on the summary's and the overlay's mtimes, so a revision re-decodes only the stems whose files changed. Item 2's cache is the template.

## Explicitly not

- [PERF13](./PERF13.md) items 1 and 2 (`PeopleRail.derive` on main, `agingLabel` in row bodies): the same functions, a different cost; whichever lands second rebases.
- [PERF8](./PERF8.md) item 4 (a per-stem change signal instead of the global revision) and [ARCH15](./ARCH15.md)'s migration of `MeetingStore`: both reduce how often these loaders wake; this task makes each wake cheap and ordered regardless.
- Revisions bumped when nothing changed: the MeetingStore task filed beside this one from the same review.
- Skipping the Facts load while the rail is hidden: rejected, the badge needs it.
- [DV5](./DV5.md)'s decision on whether Facts should exist.

## Acceptance

- Tests for the loader type: two passes started in order whose first completes last leave the second's result applied (fails against apply-in-completion-order); starting a pass cancels the previous one.
- A Facts reload test with an injected loader, holding an older snapshot's pass until a newer one completes, shows the newer facts.
- Talk-cache tests: a second visit (a new view over the same owner object) with unchanged fingerprints measures zero meetings (counting seam on `measure`); an overlay mtime change re-measures only that stem; an owner-label change drops the cache.
- `TranscriptLoader` tests: `voiceprintLabels` and `nearMisses` equal today's values for a fixture carrying both keys, from one read of the embeddings file (counting seam, or a test of the single reader).
- `cd daemon && swift build` and `swift test` green, with the number of new tests in the commit body; `bash scripts/ci-local.sh` green.
- Evidence (confirms, does not gate): `sample MeetingPipe 10` while switching to Meeting time a second time shows no `TranscriptLoader.load` frames.
