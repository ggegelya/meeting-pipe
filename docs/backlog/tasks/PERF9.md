# PERF9: scrolling the Library meeting list lags, because the SwiftUI `List` measures and rebuilds every row on the main thread

Band origin: filed 2026-10-23 from the owner reporting that the app "feels slow", that scrolling lags by 1 to 3 s and does not react immediately, and that it gets worse "the more down I scroll", while Teams and Claude Desktop scroll smoothly on the same machine at the same time. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What was measured

All measurements on 2026-10-23 with `sample` (1 ms interval) against the owner's running build (pid 46231), with no recording in progress and no pipeline running. The library held about 434 meetings (`mcp_serve_started` reports `visible: 393, withheld: 41`). Sampling inflates absolute times, so the numbers are shares of main-thread samples, not wall-clock latencies.

- **Idle, Library closed:** the main thread was waiting in `mach_msg` for 8584 of 8648 samples. Nothing periodic is loading the UI thread when no window is open, so this is not background load and not the OS.
- **While the owner scrolled the Library list (45 s, 17 scroll-wheel events in the trace):** the main thread was busy for 22,160 of 36,737 samples (about 60%), waiting for only 14,577. Scroll events queue behind that work, which is the lag the owner feels.

Where the busy time went, by subtree:

| subtree | samples | what it is |
|---|---|---|
| `_NSScrollingConcurrentMainThreadSynchronizer` -> `NSTableView prepareContentInRect:` -> `_automaticRowHeightsUpdateVisibleRowViews` -> `_uncachedAutomaticRowHeight` -> `NSHostingView.SizeConstraints.update` -> `ViewGraph.sizeThatFits` | about 5,400 | AppKit asks each row scrolled into view for its height, and the SwiftUI row answers by laying itself out completely |
| `CA::Transaction::commit` -> `NSHostingView.layout` -> `ViewGraphRootValueUpdater.render` (incl. `PlatformItemList.Key` preference reduce, `ResolvedTextFilter`) | about 5,700 | building and rendering the realised rows |
| `Update.dispatchActions` -> `OutlineListCoordinator.update(diff:...)` -> `diffRows` -> `_doAutomaticRowHeightsForInsertedAndVisibleRows` | about 5,980 across 13 updates | a whole-list update (selection change, `recomputeDerived` from an `onChange`) re-diffs the list and re-measures every visible row |

App frames inside those, by inclusive samples: `MeetingRow.body.getter` 399, `MeetingRow.stackedTile` 310, `AppGlyphRepresentable.makeNSView` / `AppGlyphView.init(source:)` 263, `RelativeMeetingDateFormatter.string(from:now:calendar:)` 89, `WorkflowChip.body` 55 with `HexColor.parse` 46, `MPStatusPill.body` 33.

## Why it is shaped this way

`LibraryListView.listBody` renders `List(selection: $selection)` with `.listStyle(.inset)`, sections from `ForEach(derived.groups, id: \.title)`, and one `MeetingRow` per meeting. On macOS that `List` is an `NSTableView` (`OutlineListCoordinator`) with automatic row heights, and each row is its own `NSHostingView`. Because the rows have no fixed height, AppKit measures each one the first time it becomes visible, through a full SwiftUI layout. With about 430 rows, scrolling further down reaches more never-measured rows, which matches "worse the more down I scroll".

`MeetingRow` is heavy per row even though it is `Equatable` and observes nothing (TECH-A12 already fixed the invalidation side):

- an `NSViewRepresentable` (`AppGlyphRepresentable`, an `NSImageView` subclass) created per realised row. The glyph image is cached (`AppGlyphView.glyphCache`), but the view is not.
- up to a dozen `.help(...)` tooltips, `.draggable(MeetingDragItem(...))`, a `.contextMenu`, and several conditional pills.
- a relative date string and a workflow-chip colour parsed from hex on every render.

Two more amplifiers sit in `listBody`. Each section is built from `group.meetings.filter { !pinnedStems.contains($0.stem) }` inside an `if !rows.isEmpty`, so a section's view count is not constant per `ForEach` element. And `.animation(.easeOut(duration: MPMotion.durFast), value: selection)` turns every selection change into an animated whole-list update, which is one of the `OutlineListCoordinator.update` passes above.

## Scope

Make scrolling the Library list stay responsive at the owner's library size, with the seam in `LibraryListView.listBody` and `MeetingRow`:

1. Replace the `List` with a `ScrollView` over a `LazyVStack` with pinned section headers and app-owned selection, so only on-screen rows are laid out and no per-row height measurement happens. Keep what the `List` gives today, explicitly: single and multi-select (click, Cmd-click, Shift-click), up and down arrow navigation, the selection wash in `MeetingRow` (DSN10, no system blue), context menus, the glyph's drag-to-export, and `LibraryEmptyState`.
2. Make each row cheaper regardless of the container. Draw the app glyph as a SwiftUI `Image` from the cached `NSImage` instead of an `NSViewRepresentable`. Compute the relative date string and the workflow chip colour once in `DerivedList`, not in `body`. Drop `.help` where the control's label already says the same thing.
3. Remove the whole-list `.animation(value: selection)`. The selection wash can animate on the row.
4. Build each section's rows in `recomputeDerived`, not in `listBody`, so `listBody` does no per-render filtering.

If step 1 proves too costly for keyboard and multi-select parity, the fallback is to keep `List` but give every row one fixed height, which lets the table skip the measure pass. The pickup session decides with a measurement, not by preference.

## Explicitly not

- The other rails (Facts, People, Meeting time, Digests) and the transcript list. They have their own costs ([PERF13](./PERF13.md), [PERF12](./PERF12.md)) and are measured separately.
- The playback re-render ([PERF12](./PERF12.md)) and the AX and CoreAudio polls on main ([PERF10](./PERF10.md)). Neither was active during this trace.
- First-open cost of the Library window (about 4,900 samples in `+[NSWindow _windowWithContentViewController:]` on a cold open). It is a one-off per launch. Re-measure it after this lands, since the list is most of it.

## Acceptance

- The owner's scroll trace repeated after the change (same library, `sample MeetingPipe 20` while scrolling top to bottom and back): main-thread busy share at most 25%, down from about 60%, and no `_uncachedAutomaticRowHeight` frames under the meeting list. Record both numbers in the commit body.
- Tests: a `LibraryListView` or derived-list unit test that pins per-section rows being computed in `recomputeDerived` (pinned "In progress" rows excluded from date groups, empty groups omitted), plus selection-model tests for click, Cmd-click, Shift-click range, and arrow navigation if step 1 replaces `List`.
- The DSN3 token guard and the no-system-blue rule still hold. `TutorialFenceTests` stays green, since `.tutorialAnchor(.search)` and `.scopeRail` must stay attached.
- `cd daemon && swift build` and `swift test` green (CI if local XCTest is unavailable), with the number of new tests stated in the commit body. `docs/GUIDE.md` updated in the same commit if any list interaction changes.
- Owner walkthrough after install (confirms, does not gate): scroll the full Library list and select rows with click, Cmd-click, Shift-click and arrows. Nothing lags noticeably.
