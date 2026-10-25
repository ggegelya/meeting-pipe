# REC21: the two start-time markers that make an interrupted off-the-record or redact-opt-in recording fail closed are written with `try?`, and orphan recovery reads a missing or malformed recovery manifest as an ordinary recording and processes it automatically

Band origin: filed 2026-10-25 from the 2026-10-25 observability audit band ([observability audit](../../audits/2026-10-25-observability-audit.md) row O17, finder SW-3). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Two files on disk are the only record that a lossless recording owes a redaction before anything reads it: `<stem>.capturemode` (the recording was started under `.captureFirstRedact`) and `<stem>.offrecord` (the owner opened a manual off-the-record span under lossless capture, MIC14). SEC16 made both survive until a mute timeline lands, and both decide whether the uncut audio may be consumed. Neither write reports failure. Re-read in code on 2026-10-25:

- `MeetingRecorder.start`: `try? captureMode.marker.write(to: modeMarkerURL, atomically: true, encoding: .utf8)`.
- `OffRecordMarker.write(forFinal:)` (`MuteTimeline.swift`): `try? Data().write(to: url(forFinal: final), options: .atomic)`. Its caller, `MeetingSessionController.toggleOffTheRecord`, writes it "BEFORE the recorder starts the span, so no off-record audio can exist on disk without the marker that flags it for quarantine", and then starts the span whether or not the marker landed.

Neither failure leaves a file-log line or an event; the start-time recovery manifest is the only one of the three start-time writes that logs (`RecordingManifest.write`: `WARN: could not write recovery manifest`).

**Where the markers are read.**

- *Crash recovery.* `OrphanRecordingRecovery.shouldQuarantine` returns `mode == .captureFirstRedact || OffRecordMarker.exists(forFinal: final)` when no timeline was written. A missing marker reads as "nothing owed", and `recover` appends the merged final to `ready` with `summaryMode: manifest?.summaryMode ?? .auto`, so the orphan is enqueued and published with its muted or off-the-record audio intact.
- *Clean stop.* `MuteRedactor.redact`'s `.missing` timeline branch fails closed (`timeline_missing`) only if `OffRecordMarker.exists(forFinal: wav) || CaptureMode.recorded(forFinal: wav) == .captureFirstRedact`. A failed marker write plus a failed timeline write on a clean stop reads as `.notNeeded` and the uncut recording goes on. SEC16 closed the timeline-write half of this; the marker writes are the remaining half.
- `CaptureMode.recorded(forFinal:)` is `(try? String(contentsOf: marker, encoding: .utf8)).flatMap(CaptureMode.init(marker:))`, so a marker that exists but cannot be read is the same as no marker.

**The manifest has the same shape.** `RecordingManifest.read` is `guard let data = try? Data(contentsOf: ...), let obj = try? JSONSerialization.jsonObject(...) else { return nil }`, and its doc comment says "A nil return leaves recovery on its legacy default (enqueue `.auto`, no synthesized sidecar)". So a present-but-unreadable `<stem>.recovery.json` turns a BYO, NDA or regulated orphan into an Anthropic-plus-Notion auto-summary, exactly the outcome REC2 built the manifest to prevent, with no log. The manifest carries `summary_mode` and the meta payload but not the capture mode or the off-record fact, so it cannot stand in for a lost marker.

Not observed on this Mac: events.jsonl has no `orphan_quarantined` or `orphan_meta_restored` rows and raw/ holds no leftover markers, so recovery has not run here. The trigger needs a marker write failure (disk full, which REC20 notes is unwatched, or a permissions fault) followed by a crash before stop, or by a failed timeline write at stop. REC12-class aborts are confirmed in the owner's history.

## Scope

1. **Marker writes report.** `OffRecordMarker.write` and the `.capturemode` write in `MeetingRecorder.start` throw (or return a result). A failure writes a `recorder.log` WARN and `Log.event(category: "recorder", action: "start_marker_write_failed", ...)` with `marker` (`capturemode` or `offrecord`), the stem, and the error's domain and code. The recording continues: a meeting is never refused for this.
2. **A second copy in the manifest.** `RecordingManifest` gains `capture_mode` (the `CaptureMode.marker` token, written at start from the mode the session already holds in `writeRecoveryManifest`) and `off_record` (bool). `toggleOffTheRecord` rewrites the manifest with `off_record: true` when it opens a span under lossless capture, in the same place it writes the marker. The CONVENTIONS.md entry for `<stem>.recovery.json` documents both keys.
3. **The session remembers.** `MeetingSessionController` records `redactionOwed` for the active recording (true for `.captureFirstRedact`, or once an off-the-record span opens under lossless capture) and passes it with the job (`ProcessingJob.redactionOwed`). `MuteRedactor.redact`'s `.missing` branch fails closed with `timeline_missing` when the job says a redaction was owed, alongside the two disk markers, so a clean stop no longer depends on either marker having landed.
4. **Recovery fails closed on what it cannot read.** `RecordingManifest.read` returns absent, parsed or unreadable. `shouldQuarantine` (with no timeline) is true when any of these holds: `.capturemode` says `capture_first_redact` or exists but cannot be read; `.offrecord` exists; the manifest's `capture_mode` or `off_record` says so; the manifest is present but unreadable. `OrphanRecordingRecovery.quarantine` takes the reason, and `orphan_quarantined` carries it (`capture_first_no_timeline`, `off_record_no_timeline`, `manifest_unreadable`, `marker_unreadable`) instead of the one fixed string. `CaptureMode` gains a reader that tells a missing marker from an unreadable one; the redactor's `.missing` branch uses it the same way.

## Explicitly not

- Refusing to start, or stopping, a recording when a marker write fails. Item 3 makes the clean path safe and item 2 the crash path; losing the meeting is worse than either.
- What happens to a quarantined file afterwards (the reaper, the row, Retry): SEC26. An unreadable `<stem>.meta.json`: SEC25.
- The timeline write itself and the SEC16 held-back path: shipped in SEC16, unchanged here except for the extra `redactionOwed` input.
- A general file-log helper for every os.Logger-only failure site: OBS1. This task adds only the one event it needs.

## Acceptance

- `RecordingManifestTests`: round-trip of `capture_mode` and `off_record`; a manifest written before this task (no new keys) still parses; unparseable bytes read as `unreadable`, a missing file as `absent`.
- `OrphanRecordingRecoveryTests`: with no timeline, each of these quarantines with its reason: a manifest saying `off_record: true` and no `.offrecord` file; a manifest saying `capture_first_redact` and no `.capturemode`; an unreadable manifest; an unreadable `.capturemode`. A plain capture-first orphan with a readable manifest and no markers still lands in `ready` with its summary mode.
- `MuteRedactorTests`: a job with `redactionOwed` and no timeline and no markers returns `.failed(.timelineMissing)`; without it, `.notNeeded` as today.
- `MeetingSessionControllerTests` (fake host and an injected failing writer): a failing off-record marker write emits `start_marker_write_failed`, still starts the span, and rewrites the manifest with `off_record: true`; the enqueued job carries `redactionOwed`.
- `cd daemon && swift build` and `swift test` green, new test counts in the commit body; `python3 scripts/truth_fences.py events` green for `start_marker_write_failed`; `bash scripts/ci-local.sh` green.
