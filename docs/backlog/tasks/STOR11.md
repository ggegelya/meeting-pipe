# STOR11: a recordings folder that exists but cannot be read shows as an empty library everywhere, stops live updates, skips orphan recovery and stranded-job marking without a word, and doctor reports it healthy

Band origin: filed 2026-10-25 from the 2026-10-25 observability audit band ([observability audit](../../audits/2026-10-25-observability-audit.md) O18: SW-10). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified in code on 2026-10-25 against `main` at `01e904a`. Every daemon reader of the library directory treats a failed listing as an empty one:

- `MeetingStore.performScan(directory:)`: `guard let entries = try? fm.contentsOfDirectory(at: directory, ...) else { scanCache.removeAll(); return [] }`. The Library renders the ordinary empty list.
- `MeetingStore.attachWatcher()`: `let fd = open(recordingsDir.path, O_EVTONLY); guard fd >= 0 else { return }`. No watcher, no log, so the Library stops live-updating for the session.
- `OrphanScan.scan(directory:)` returns `Report(wavsWithoutRow: [], rowsWithoutWav: [])` on a listing error, and `DoctorCommand.probeOrphans` then reports `.ok` "No orphaned recordings or sidecars in <dir>."
- `Coordinator.reconcileStrandedJobs()`: `guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }`, so a job stranded by a crash is never marked interrupted.
- `OrphanRecordingRecovery`'s listing returns `[]` on error ("Returns [] on error" in its own doc comment), so crash-orphaned intermediates are not merged.
- `MeetingLibraryService.failedMeetingCount()` returns `0` on the same `try?`, so the menu's failed row disappears too.

None of `DoctorCommand`'s probes (`accessibility.trusted`, `permission.*`, `app.resources`, `pipeline.binary`, `pipeline.roundtrip`, `events.writable`, `library.orphans`, `search.index`) checks that the library can be listed. The Python doctor does not either: `doctor.check_storage` calls `storage.bytes_on_disk(library)`, which walks `path.rglob("*")`; on Python 3.11 that yields nothing for a directory it cannot list, so doctor prints `[ok] library 0 B`. Reproduced on 2026-10-25 against a `chmod 000` scratch directory holding one file: `exists()` is `True` and `bytes_on_disk` returns `0`.

**Triggers.** A TCC denial of `~/Documents` (the per-build permission churn D8 describes, while the app is ad-hoc signed), an offline network or external volume whose mount point still exists, or wrong permissions after a restore. The owner opens the Library, sees no meetings, and doctor says everything is fine; reading that as "my meetings were deleted" is reasonable. TCC-gated, so not exercised here; `library.orphans` has run 19 times on this Mac per `events.jsonl`, always on a readable directory.

**What UX89 already covers.** UX89 item 3 makes a **missing** root visible ("Your recordings folder is not at <path>" with **Choose folder…**). It does not cover a root that exists and cannot be read, and note that `attachWatcher` runs `createDirectory(at: recordingsDir, withIntermediateDirectories: true)` first, which turns a missing root into a readable empty one. This task is the unreadable half and should share UX89's state type rather than add a second one.

## Scope

1. **One library-root state.** A small `LibraryRootState { case readable, missing, unreadable(errno: Int32, reason: String) }` computed by one function over the directory (`contentsOfDirectory` error mapped to its POSIX code), in `MeetingStore` beside `performScan`. If UX89 has landed, extend its missing-root type with the `unreadable` case instead.
2. **The Library says so.** `performScan` publishes the state alongside the empty array; the Library's empty state for `unreadable` reads "Can't read your recordings folder at <path>: <reason>" with **Open Privacy & Security** when the code is `EPERM`/`EACCES` and **Reveal in Finder** otherwise, instead of the first-run empty list. A later readable scan clears it.
3. **The watcher retries.** `attachWatcher` logs the `open` failure with its errno once per state change (file log, OBS1's `Log.failure` if landed) and is re-attempted on the next successful scan, so live updates resume when access is granted without a relaunch.
4. **Background sweeps log their skip.** `reconcileStrandedJobs`, `OrphanRecordingRecovery` and `failedMeetingCount` keep returning early, but emit `coordinator` `library_unreadable` with `reason` and `site` once per state change, not once per call (the menu count runs on every menu open).
5. **A `library.readable` doctor probe**, in both `DoctorCommand.defaultProbes()` and `daemonSelfCheckProbes()`, ahead of `library.orphans`: `.fail` naming the path and reason when unreadable, `.warn` when missing, `.ok` otherwise; `probeOrphans` reports `.warn` "skipped: library unreadable" instead of `.ok` when the listing fails. `doctor.check_storage` in Python `_warn`s when `os.scandir(library)` raises, before it reports a size.

## Explicitly not / out of scope

- The missing-root empty state, the free-text output-dir field and re-rooting the Library: UX89.
- Getting TCC grants to survive rebuilds: D8 (P3, signing). This task only makes the denial visible.
- iCloud-evicted files inside a readable folder: STOR6, and PIPE35 for the pipeline's library-wide readers.
- Unreadable individual sidecars: SEC25 (meta), STOR9 (user-data stores), PIPE34 (run and publish sidecars), siblings in this band.

## Acceptance

- `MeetingStoreTests`: a `chmod 000` temp library yields `unreadable` with `EACCES` and an empty meeting list; restoring the mode and rescanning yields `readable` and the meetings; a missing directory yields `missing` (or UX89's state).
- `OrphanScanTests` / `DoctorCommandTests`: `library.readable` fails on the `chmod 000` directory and passes on a readable one; `library.orphans` is no longer `.ok` when the listing fails. Fails on `main`.
- A test that `library_unreadable` fires once across repeated `failedMeetingCount()` calls on the same unreadable directory, and again after a readable scan followed by a new failure.
- pytest in `test_doctor.py`: `check_storage` on a `chmod 000` library prints a WARN and does not print `[ok] library 0 B`.
- `library_unreadable` documented in `CONVENTIONS.md`; `python3 scripts/truth_fences.py` green. `cd daemon && swift test` and `cd pipeline && uv run --extra dev pytest -q` green, ruff and pyright clean, N new tests per tree in the commit body.
- `docs/GUIDE.md` gains one troubleshooting line for "the Library is empty and says it can't read the folder", in the same commit.
- Evidence (confirms, does not gate): owner revokes Files and Folders access for MeetingPipe to Documents, opens the Library and sees the named state; Preferences doctor shows `library.readable` failing.
