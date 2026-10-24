# ARCH10: the per-meeting file contract has no owner type, so 30 Swift files spell sidecar paths by hand, views rewrite pipeline-owned summary.json through try?, and a job's outcome is inferred from which files exist

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) A4 with the A10 placement note, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) SA-10 writer half). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

A meeting is a stem plus about 30 sibling files (`.wav`, `.mic.wav`, `.system.wav`, `.meta.json`, `.summary.json`, `.summary.md`, `.summary.candidate.json`, `.run.json`, `.publish.json`, `.empty.json`, `.apple_pending.json`, `.recordfail.json`, `.recovery.json`, `.markers.json`, `.speaker_labels.json`, `.transcript_corrections.json`, `.embeddings.json`, `.offrecord`, `.capturemode`, `.READY_FOR_MANUAL.md`, ...). Counted in `daemon/Sources/MeetingPipe` on 2026-10-24: `.summary.json` is spelled out in 30 files, `.meta.json` in 18, and `JSONSerialization.` is called 74 times in 31 files. `meta.json` is read as `[String: Any]` everywhere; `MeetingMetaSidecar.build` writes a dictionary. The typed reader that does exist, `MeetingSummary` ([ADR 0014](../../decisions/0014-typed-summary-model.md), `Library/MeetingSummary.swift`), is `Decodable` only and decodes a subset of keys, so it cannot be used to write the file back without dropping fields.

Views write pipeline-owned files directly and swallow failures:

- `MeetingDetailView.writeTitle` (in `MeetingDetailView+Header.swift`) reads the target with `try? Data(contentsOf:)` and `try? JSONSerialization.jsonObject`, falls back to `var existing: [String: Any] = [:]` when either fails, sets one key and writes with `try? data.write(to: target, options: .atomic)`. A `summary.json` that fails to parse (truncated, or caught mid-rewrite by a pipeline job) is therefore replaced by `{"title": ...}` alone, and the summary is gone. The failure is silent: the `title_edited` event is logged either way.
- `SummaryTab.persistEdit` documents "Returns false on disk-write failure", writes the correction record with `do`/`catch`, then overwrites `summary.json` with `try? data.write(...)` and returns `true` regardless. A failed summary write reports success.

Neither write checks whether a pipeline job for the same stem is running and about to rewrite the same file.

A job's outcome reaches Swift through exit status plus file presence. `mp run-all` (`orchestrate.main`) already builds a result dictionary: `run_all` returns `_skip_result(t, reason, ...)` with `skipped` (`no_speech`, `suspect_transcript`, `byo`, `too_long`, `apple_pending`), the transcript and summary paths, and `page_url`. `main` discards it and returns `0`, `1`, or `EXIT_PUBLISH_FAILED`. Swift then reconstructs the reason by probing `.apple_pending.json` (`PipelineLauncher`), `.empty.json` (`EmptyMarker`), `.READY_FOR_MANUAL.md` (`MeetingRow`, `StrandedJobRecovery`, `LibraryMover`), and a failure file at the temp path it passed in `MP_FAILURE_PATH`. stdout carries only the progress heartbeat (`PipelineLauncher.progressSentinel`). `<stem>.publish.json` (CONVENTIONS "Publish result") is the one place this was done as a typed contract with a golden fixture, and it is the precedent to follow.

## Scope

1. **`MeetingFiles`**, a value type in `MeetingPipeCore` (the A10 note: the contract decoders already live in Core and the target's dependency floor allows Foundation): `MeetingFiles(stem:dir:)` with one named `URL` per suffix and a `static let` suffix list that `StrandedJobRecovery` and `LibraryMover` read instead of their own `hasSuffix` chains. Migrate call sites as they are touched; this task migrates the writers in item 3 and the outcome readers in item 4, and adds a fence that fails on a new `"\(stem).summary.json"`-style literal outside `MeetingFiles`.
2. **Codable `MeetingMeta`** with tolerant decoding (unknown keys preserved for round-trip, missing keys optional), used by the meta writer and by any reader this task touches. The sidecar schema in CONVENTIONS stays the contract, and `test_workflow_overlay.py` plus the Swift side stay in agreement.
3. **One Swift writer for `summary.json`: `SummaryDocument.update(_:in:)`.** It reads the file as a JSON object, refuses (throws) when the file exists but does not parse, applies the patch preserving every key it does not own, writes atomically, and refuses while a pipeline job for that stem is queued or running. `PipelineJobDispatcher` has no per-stem query today (`enqueue`, `cancelActive`, `removePending(id:)` only), so add a read-only `isBusy(stem:)` there rather than inferring it from the Library's `ProcessingTracker`. `writeTitle` and `persistEdit` call it and surface a refusal: the title field reverts and the edit sheet shows an error, `persistEdit` returns `false`. This is also the natural seam for PERF8's self-write suppression.
4. **One `--result` envelope from `mp` job subcommands.** `mp run-all --result <path>` (then `summarize` and `publish`) writes `{"outcome", "skip_reason", "paths", "failure"}` atomically from the dictionary `run_all` already returns; `PipelineLauncher` passes the path and branches only on it, keeping the sentinel files as on-disk state the Library still renders, not as the outcome channel. Pin it with a cross-tree golden fixture generated by `scripts/gen_contract_fixtures.py`, the way the CI4 three are.

## Explicitly not / out of scope

- Migrating all 30 `.summary.json` sites in one commit. Item 1's fence stops new ones; the rest move as they are touched.
- Making `MeetingSummary` the writer. It decodes a subset by design (ADR 0014); writing through it would drop keys the pipeline owns.
- PERF8's optimistic model and watcher suppression, and an `@Observable` per-meeting document model (go-live SA-10's larger half): this task supplies the single writer they need, not the model.
- STOR7 (deleting a meeting leaves derived files behind) will want `MeetingFiles`' suffix list; it is not done here.
- ARCH11 decides which tree owns summarization; the envelope here is neutral to that answer.

## Acceptance

- `MeetingFilesTests` (Core): every suffix the pipeline writes resolves to the expected name for a stem with spaces and dots; the suffix list matches a golden list shared with `pipeline/tests` so a new Python sidecar without a Swift name fails one side.
- `SummaryDocumentTests`: a malformed existing file throws and leaves the file byte-identical (fails on `main`, where `writeTitle` replaces it); unknown keys survive an update; an update while the stem's job is running throws; a write failure propagates.
- A `persistEdit` test where the summary write fails asserts it returns `false` (fails on `main`).
- Envelope: a Python test per skip reason asserting the written envelope, a Swift decoder test against the golden fixture, and the `CI4ContractFixtureTests` pattern extended to it.
- `cd daemon && swift test` green, `cd pipeline && uv run --extra dev pytest -q` green, ruff and pyright clean, `python3 scripts/truth_fences.py` green, `bash scripts/ci-local.sh` green, N new tests per tree stated in the commit body. CONVENTIONS gains a "Job result" section beside "Publish result" in the same commit.
