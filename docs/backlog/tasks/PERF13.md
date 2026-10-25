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

## Amended 2026-10-24 (audit band)

The [architecture review](../../audits/2026-10-24-architecture-review.md) (M8) adds a correctness half to item 3, verified in `daemon/Sources/MeetingPipe/Logger.swift` on 2026-10-24: the logger is not thread-safe, not only slow. `Log.appendData(_:to:)` has no lock and no queue. It calls `rotateIfNeeded`, then, when the file is missing, `FileManager.default.createFile(atPath:contents:attributes:)`, which replaces whatever is there; otherwise it opens `FileHandle(forWritingTo:)` (no `O_APPEND`), calls `seekToEnd()`, and writes. About 385 `Log.event` and `Log.writeLine` call sites reach it from main, the audio writer queues, GCD workers and pipe-reader handlers. So two lines written at the same moment can seek to the same offset and the second overwrites the first in `events.jsonl`; two writers can both see a missing file after a rotation and one `createFile` discards the other's line; and two threads can both pass `rotateIfNeeded`'s size check and shift generations twice, dropping a generation early. `PipelineLauncher` has the same shape for `pipeline.log`: each `mp` spawn opens a long-lived `FileHandle`, seeks to the end once, and writes stdout chunks at that handle's own offset, so two concurrent spawns overwrite each other, and a rotation while a handle is open leaves that spawn writing into the renamed generation. The Python side is not affected: `mp.events` opens `pipeline_events.jsonl` with `path.open("a")`, which is `O_APPEND`.

Item 3's fix already proposes one serial logging queue; with this amendment it must also guarantee ordering and no loss:

- Every append, rotation and first-create for a log family goes through that one serial queue, on a descriptor opened with `O_WRONLY | O_APPEND | O_CREAT` and mode 0600, so the kernel places each write at the end even if a second process ever appends.
- `pipeline.log` either gets a per-spawn file (`pipeline.<stem>.<pid>.log` or similar, which also makes a run's output findable) or routes its chunks through the same queue. The pickup picks one and says why in the commit body.

Added acceptance for item 3:

- A test that 8 concurrent writers each appending 1,000 distinct `Log.event` lines produce exactly 8,000 parseable JSONL lines across the base file and its generations, none lost or interleaved mid-line.
- A test that concurrent writers crossing the rotation size rotate once, not twice (generation count and contents checked).
- A test that two simulated `mp` output streams written concurrently to the pipeline log lose no bytes, under whichever `pipeline.log` design is chosen.

## Amended 2026-10-25 (observability audit band)

The [observability audit](../../audits/2026-10-25-observability-audit.md) (finders LG-4, LG-5, SW-17) found the 2026-10-24 amendment's last sentence true for `pipeline_events.jsonl` and false for `pipeline.log`, and the races reached in the owner's real logs. Verified in code on 2026-10-25.

**`pipeline.log` has two writers on every run, not only under concurrent spawns.** `orchestrate._configure_logging` adds a `StreamHandler(sys.stderr)` and a `logging.FileHandler(log_file)` on the same `pipeline.log`, and `PipelineLauncher.runMP` opens its own `FileHandle(forWritingTo: logURL)`, calls `seekToEnd()` once, and writes every stdout and stderr chunk at that handle's offset. So every `run-all` line reaches the file twice (Python's own append, then the daemon's copy of stderr), and because the daemon's handle is not `O_APPEND`, its writes land at a stale offset over whatever Python appended since. Measured on this Mac: 5 of the 8 `run-all:` runs in `pipeline.log` end in a torn fragment line (for example `ing sentinel written: .../raw/20261016-095827.apple_pending.json`), and the 2026-10-16 12:46:34 `MissingSecretError` traceback appears twice. Other subcommands (`summarize`, `merge-meetings`, `ask`) only `basicConfig` to stderr and have the daemon as their single writer. Separately, the `emit_progress` docstring says the progress sentinel is "stripped from the daemon's view of `pipeline.log`", but `runMP`'s stdout handler writes the chunk before scanning it for the sentinel.

**The `events.jsonl` race was reached, and every reader hides it.** `events.jsonl` line 651 is the tail of a row (`n ","ts":"2026-10-16T09:46:28.265Z"}`), written in the same millisecond as `lifecycle` / `idle` while a recording entered stopping; it is 1 unparseable line of 1,148, and it sits exactly where OBS5's stop-trigger question needed a row. `mp logs` (`logs_cmd`, "Skip rather than abort") and `mp analyze-detection` skip a `json.JSONDecodeError` silently, `DiagnosticsLog` drops a line whose `JSONSerialization.jsonObject` fails, and `jq` aborts on it. A lost row is indistinguishable from an event that never fired.

**The logger drops whole events and lines silently.** `Log.event` returns without writing when `JSONSerialization.isValidJSONObject(dict)` is false, which is the case for `Double.nan`, `Double.infinity`, `URL`, `Date` and `UUID` values (measured with a Swift snippet). `appendData` returns on `guard let handle = try? FileHandle(forWritingTo: url)`, and `runMP`'s `logHandle` is `try?` too, so a failed open loses the whole run's output except the 4 KB stderr tail. No current call site passes a non-JSON value (spot grep); latent. CONVENTIONS.md "Non-serializable attributes" documents the drop as intended.

Item 3 additionally must:

- **Give `pipeline.log` one owner per file.** Either Python skips its `FileHandler` when the daemon spawned it (an `MP_RUN_ID` from OBS4, or a dedicated flag) and the daemon's copy, through the serial queue on an `O_APPEND` descriptor, is the only writer; or the daemon writes a per-spawn `pipeline.<stem>.<pid>.log` and stops appending stderr to the shared file. The pickup picks one and says why in the commit body; a hand-run `mp run-all` must still get a log. Either way the sentinel is stripped or the docstring is corrected.
- **Coerce instead of dropping.** A non-JSON attribute value is written as its string form (and `NaN` and infinity as `null` with a sibling `<key>_invalid: true`), so the event survives, and CONVENTIONS.md's "Non-serializable attributes" section is rewritten to match Python's `default=str` in the same commit.
- **Report a failed append.** When the descriptor cannot be opened or written, fall back to one os.Logger `.error` per log family per launch with the path and errno `privacy: .public` (OBS1's helper cannot be used here, because it writes through this same path).
- **Count what readers skip.** `mp logs` and `mp analyze-detection` print `N unparseable lines skipped` to stderr when N > 0, and `DiagnosticsView` shows the count, so a torn log is visible.

Added acceptance:

- A test that one spawned `run-all` writing through both Python logging and stderr leaves each line exactly once in its log, with no torn fragment, under the chosen design.
- `Log.event` with a `URL`, a `UUID` and `Double.nan` attribute writes one parseable row with string and null values.
- A fixture log with one torn line makes `mp logs` and `mp analyze-detection` report 1 skipped line, and `DiagnosticsLog` return a skipped count of 1.
