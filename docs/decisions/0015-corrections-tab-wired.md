# ADR 0015: Transcript corrections are wired end-to-end (verify-then-close)

| Property            | Value                  |
| ------------------- | ---------------------- |
| **Status**          | Accepted               |
| **Date**            | 2026-05-28             |
| **Decision Makers** | Project owner          |
| **Technical Area**  | Library / corrections  |
| **Related Tasks**   | TECH-A14               |

## Context

The next.md note flagged that "corrections are persisted, but the UI loop may not be complete" and asked to verify before building anything. TECH-A14 is the verify-first pass.

Terminology: the UI "Corrections" tab (`CorrectionsTab.swift`) shows the summary-grading record. The transcript line corrections the acceptance is about live in the Transcript tab's line editor and persist to `<stem>.transcript_corrections.json` via `TranscriptCorrectionStore`.

## Decision

No code rewire needed: the transcript-correction loop is already complete end-to-end.

- Edit: `TranscriptTab.saveCorrection` calls `TranscriptCorrectionStore.upsert(...)`, patches the in-memory row, and emits `Log.event(category: "correction", action: "transcript_correction", ...)` with `original_text` / `edited_text` (the before/after payload the acceptance asks for). A write failure emits `transcript_correction_failed` instead.
- Persist: `upsert` writes the sidecar atomically and preserves the earliest pipeline-original across re-edits; reverting to the original deletes the sidecar.
- Reload: `TranscriptLoader.load(stem:in:)` reads `<stem>.json`, then overlays the saved corrections via `TranscriptCorrectionStore.apply`, so an edit survives a reopen.

The only gap was test coverage of the real reload path (the store round-trip was covered, but `TranscriptLoader.load`'s overlay was not). Added `TranscriptTabTests.test_load_overlays_a_saved_correction_on_reload`, which writes a pipeline `<stem>.json`, saves a correction, and asserts the reloaded segments show the edited text. No schema or persistence change.

## Consequences

- TECH-A14 closes as verified-wired. No production change beyond the added test.
- The persistence schema (`{ "segments": [{ index, original_text, edited_text }] }`) is unchanged; per the task stop-and-ask, any future rendering fix must not alter it without its own ADR.
