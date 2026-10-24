# ARCH15: The view state layer is ObservableObject only, so any published write re-renders every view holding the object, and each hot surface gets its own workaround

Band origin: filed 2026-10-24 (go-live assessment SA-2, the root-cause class behind it; the 2026-10-24 audit band mapped SA-2 to [PERF12](./PERF12.md), which fixes one symptom, the 15 Hz playback clock). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What is wrong

With `ObservableObject`, any `@Published` write fires `objectWillChange` and invalidates every view that holds the object, whatever property that view reads. Observation (`@Observable`) tracks the properties a body actually reads. The package floor is `.macOS(.v14)` (`daemon/Package.swift`, re-confirmed by DOC16 on 2026-10-24), where Observation is available, and the daemon does not use it.

Counted in `daemon/Sources` on 2026-10-24: 24 `ObservableObject` classes, 141 `@Published` properties, 0 `@Observable`; 20 `@StateObject`, 65 `@ObservedObject`, 4 `@EnvironmentObject`. `CONVENTIONS.md`'s `ObservableObject + Combine` section codifies the pattern, and no doc names Observation.

The code pays for it one surface at a time, each with its own workaround:

- `AudioPlaybackController` publishes `currentTime` at `tickInterval = 1.0 / 15.0`, and `MeetingDetailView` holds it as `@StateObject var playback`, so the whole detail pane re-evaluates 15 times a second while audio plays. PERF12 (filed 2026-10-23) splits the time onto a `PlaybackClock`.
- `TranscriptTab.installRightClickPause` pauses playback on every right-click, because "every `playback.currentTime` tick re-evaluated it and tore down the open "Assign to..." submenu".
- `MeetingRow` "holds no `@ObservedObject`/`@EnvironmentObject` so model broadcasts (status flips, processing ticks) don't invalidate every row" (TECH-A12), and `WaveformBody` in `AudioTab` holds the playback controller as a plain `let` (TECH-A13).
- `ProcessingTracker` is split out of `LibraryWindowModel` "so bursts don't cascade re-renders", and the toolbar observes it directly.
- `LibraryWindowModel` still carries 13 `@Published` properties, among them `activeProcessing`, which the Coordinator's pipeline progress callback rewrites on every heartbeat, so every view holding the model re-evaluates for a field most of them never read.
- `MeetingStore.revision` is one `@Published` counter bumped on any library change. Seven Swift files read it (`LibraryListView`, `TranscriptTab`, `SummaryTab`, `StatsView`, `PeopleView`, `MeetingDetailView`, `LibraryWindow`) and `SearchIndexer` subscribes to `store.$revision`; each consumer then guards with its own fingerprint to skip work it did not need.

Correction carried from the go-live verifier (2026-10-21), so the pickup session does not oversell this: the per-tick cost is small on Apple Silicon because transcript rows are lazy, and PERF8's 2 to 5 s naming stall is the reassign path, not this layer. This is a structural tax (every new surface needs its own isolation trick, and the tricks are invisible until someone breaks one), not a measured stall.

## Scope

Migrate the Library's view-facing models to `@Observable`, green-to-green, one model per commit:

1. `LibraryWindowModel`. Once views track per property, check whether `ProcessingTracker` still earns its split; fold it back only if a test shows the toolbar no longer drags the window through re-renders.
2. `MeetingStore`. Views read the properties they use instead of `revision`. `SearchIndexer`'s `store.$revision` sink either moves to `withObservationTracking` or `revision` stays as a plain counter for that one non-view consumer; say which in the commit.
3. `AudioPlaybackController`, after PERF12 lands (its `PlaybackClock` becomes `@Observable`). If PERF12 is still open at pickup, land it first rather than doing both in one change.

For each: `@StateObject` to `@State`, `@ObservedObject` to a plain property or `@Bindable`, `@EnvironmentObject` to `@Environment(Type.self)`. Classes whose `$` publishers feed Combine outside SwiftUI (`indexer.$indexRevision` and `indexer.$health` in `LibraryWindow`, `center.$microphone` and its siblings in `StatusBarController`) either stay `ObservableObject` for now or move their consumer to `withObservationTracking`; decide per class.

Delete the workarounds the migration makes dead, each in the commit that kills it: the TECH-A12 and TECH-A13 isolation comments and their fingerprint guards where the guard no longer prevents anything. The right-click pause in `TranscriptTab` is a behaviour, not only a workaround (it matches how the owner names speakers, by stopping playback first), so ask the owner before removing it even if the submenu then holds open while audio plays.

Rewrite the `CONVENTIONS.md` section in the first migration commit: Observation for new view models, Combine only for non-view subscribers.

The other 20-odd classes (Preferences stores, `TutorialSession`, `AskModel`, and so on) migrate on touch, not in this task.

## Explicitly not

- The playback clock itself: [PERF12](./PERF12.md). It is this task's first slice and lands on its own.
- PERF8's optimistic model and watcher self-trigger (the naming stall), and [ARCH10](./ARCH10.md)'s single summary writer and per-meeting document model, which explicitly leaves the `@Observable` document model out.
- [ARCH12](./ARCH12.md)'s `LibraryHost` protocol. Adjacent: both touch `LibraryWindowModel`, so whichever lands second rebases on the other.
- Swift 6 language mode or strict concurrency: [CONC6](./CONC6.md).
- Migrating all 24 classes in one change.

## Acceptance

- Per migrated model, an observation test with `withObservationTracking`: reading property A registers no change when only property B is written. At minimum: a view reading `LibraryWindowModel.status` is not invalidated by an `activeProcessing` write, and a reader of one meeting's fields is not invalidated by an unrelated `MeetingStore` change. Each test fails against the `ObservableObject` version.
- Existing Library, transcript and playback tests green, adapted only where they assert the property wrapper.
- `bash scripts/ci-local.sh` green, with the number of new tests in each commit body.
- `CONVENTIONS.md` updated in the first migration commit.
- Evidence (confirms, does not gate): `sample MeetingPipe 10` with the Library open during a pipeline run shows no detail-tab body frames per progress heartbeat.
