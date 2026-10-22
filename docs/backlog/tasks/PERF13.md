# PERF13: smaller main-thread costs in the Library rails, the Guide and Diagnostics windows, and the logger

Band origin: filed 2026-10-23 from the traces and code audit run for the owner's "the app feels slow" report. Each item is small; together they are the remaining main-thread work after [PERF9](./PERF9.md), [PERF10](./PERF10.md) and [PERF12](./PERF12.md). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Items

Measured in the 2026-10-23 trace that switched Library rails through `meetingpipe://library?scope=...` (Library already open):

1. **People rail derivation on main.** `PeopleView.reaggregate` reads the disk in `Task.detached`, then runs `rederive()` inside `await MainActor.run { ... }`, and that calls `PeopleRail.derive(roster:meetings:commitments:)` on main. Measured: 146 samples. Fix: derive in the detached task and hand only the result to main. `rederive()` from a clustering landing can stay on main if it stays cheap, or move off main too.
2. **Facts "due" labels computed in row `body`.** `FactsView` calls `cluster.agingLabel(now: now)` inside the row's body, and `PeopleView` calls `commitment.agingLabel(now: Date())` (`Facts.swift`, `func agingLabel(now:)`). Measured: 81 samples under `OpenActionRow.body`. Fix: compute labels once per derivation, keyed on the day, so a midnight rollover still refreshes them.
3. **Logger file I/O on the caller's thread.** `Log.appendData(_:to:)` runs `rotateIfNeeded`, a `fileExists`, and then an open, seek, write and close of a `FileHandle` for every `Log.event` or `writeLine`, usually on main. Measured: 47 samples for a handful of events. Fix: a serial logging queue with long-lived handles, keeping rotation semantics (PERF7) and crash safety. State the crash-safety story before deferring any write: an unflushed tail on crash must be bounded and documented.

Confirmed by code reading, not measured:

4. **Guide window re-parses the document while scrolling.** `GuideView` renders a non-lazy `VStack` over every block and calls `AttributedString(markdown:options:)` in `inline(_:)` during body. Its scroll-position preference updates `@State`, so each section crossing re-parses the whole document. Fix: parse once in `load()`, use a `LazyVStack`, and isolate the rail's hover state in a child view.
5. **Diagnostics window loads logs on main.** `DiagnosticsView.reload()` calls `DiagnosticsLog.load(...)` synchronously, which reads up to four generations of `events.jsonl` and `pipeline_events.jsonl` (about 5 MiB each) and parses them line by line on every appear and filter change. Fix: load in a detached task and assign on main, with a loading state.
6. **`MeetingDiscoveryWatcher.sampleMicBusy` on a main `Timer`** (every 3 s, or 12 s idle). Measured cheap: 5 to 9 samples per minute. Listed so it is not rediscovered; move it only if it is touched for another reason.

## Explicitly not

- The Library meeting list ([PERF9](./PERF9.md)), playback ([PERF12](./PERF12.md)), and the per-call AX and CoreAudio polls ([PERF10](./PERF10.md)).
- [PERF8](./PERF8.md)'s speaker-naming re-derive, which has its own spec.

## Acceptance

- Items 1, 2, 4 and 5: a test per item pinning that the expensive call no longer runs in `body` or on main (for example derive called from a non-main context, labels computed once per derivation, `GuideDocument` parsed once per load, diagnostics loaded off main).
- Item 3: tests that rotation still happens at the PERF7 size, that a write after rotation lands in the new base file, and that the documented flush bound holds.
- `cd daemon && swift build` and `swift test` green, new test count in the commit body.
- Evidence (confirms, does not gate): repeat the 2026-10-23 rail-switch trace; `PeopleRail.derive` and `OpenActionRow.body` / `agingLabel` no longer appear under the main thread.
