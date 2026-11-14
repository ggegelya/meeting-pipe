---
id: PIPE34
title: A failed write of the run or publish sidecar leaves the previous run's file in place, and the daemon reads it as this run's outcome
category: Pipeline
status: new
priority: P2
comment: Filed 2026-10-25 (observability band, O20: PY-5, FB-8): run.json and publish.json write failures only log a WARNING, so a stale sidecar keeps the old backend attribution, the UX41 staleness ts and the Unpublished badge, and blocks retention. Unlink a stale run.json on failure, write an unknown publish marker before sinks run, a failed final write exits 3, Swift reads unknown, sidecar_write_failed event. [Spec](./PIPE34.md) Amended 2026-11-13 by the audit band: a leftover `<stem>.apple_pending.json` from a hand-run or killed run-all diverts a later successful run-all to an on-device re-summarize once the backend has changed, so run_all removes a stale sentinel at start (F054).
---

# PIPE34: a failed write of `<stem>.run.json` or `<stem>.publish.json` leaves the previous run's sidecar in place, and the daemon reads it as this run's outcome

Band origin: filed 2026-10-25 from the 2026-10-25 observability audit band ([observability audit](../../audits/2026-10-25-observability-audit.md) O20: PY-5, FB-8). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Verified in code on 2026-10-25 against `main` at `01e904a`. Both per-run sidecars are written atomically (tmp plus replace), which protects against a torn file but not against a write that fails outright: the replace never happens, and the file on disk is whatever the **previous** run left there. Every write site logs a WARNING to `pipeline.log` and carries on, with no event and exit 0.

**The run sidecar (`<stem>.run.json`).** `orchestrate.run_all` wraps `write_run_sidecar(...)` in `except Exception as e: log.warning("run sidecar write failed: %s", e)`, and the later `set_publish_state(sidecar, publish_state(pub))` in `log.warning("publish_state update failed: %s", e)`. `summarize.rewrite_run_sidecar` (PIPE11's standalone re-summarize path) does the same: `log.warning("run sidecar rewrite failed (non-fatal): %s", e)`. `corrections.set_publish_state` returns silently on an unreadable sidecar ("a missing or unreadable sidecar is a no-op"). The daemon trusts `run.json` for three things: backend and model attribution and correction eligibility (`CorrectionWindow`, `PublishLanding`'s `canCorrect`), the UX41 rename-staleness cue (`MeetingStore` compares the overlay against `run.json`'s `ts` precisely because it is "stamped by the run that actually wrote the prose"), and the pre-PIPE1 publish-state fallback in `PublishResult.resolveState`. After a re-summarize on a different engine whose rewrite failed, the Library and the corrections corpus attribute the new summary to the old engine, and the staleness cue compares against the old run's time.

**The publish sidecar (`<stem>.publish.json`).** `publish_router._write_publish_sidecar` ends in `except OSError as e: log.warning("publish sidecar write failed: %s", e)`, and its docstring says "The daemon degrades to 'no page URL' when the file is absent", but a failed write does not make it absent. `PublishResult` documents the file as "Written fresh by `publish_router.fanout` on every run, so unlike the per-sink sidecars it can never be a leftover from a previous one", which is the invariant this breaks. Readers: `PublishResult.load`, `resolveState`, `Notifier.notifyDone`, `MeetingStore` (the badge and Needs-you membership) and `AudioRetentionSweep` (which waits for a settled publish). A Republish that reached every sink but could not write the sidecar keeps the Unpublished badge and keeps retention blocked; a republish to a different sink names the old destination in the done banner and the **Open** button.

**What a plain unlink would get wrong.** With `publish.json` gone, `resolveState(publish: nil, runPublishState:)` falls back to `run.json`'s `publish_state`, which only `run-all` refreshes; after a standalone `mp publish` that fallback is itself stale. So the publish side needs a marker the reader understands, not just an absence.

**Reachability.** Latent: no `run sidecar write failed`, `publish_state update failed` or `publish sidecar write failed` line in this Mac's `pipeline.log`. It needs an I/O error on the library volume at write time (disk full, permissions, an iCloud-managed folder under STOR6).

## Scope

1. **Run sidecar: drop the stale one.** `corrections.write_run_sidecar` unlinks an existing `<stem>.run.json` when its own write raises, then re-raises; the callers in `orchestrate.run_all` and `summarize.rewrite_run_sidecar` keep their non-fatal stance (a summary already on disk is not failed for attribution metadata). No `run.json` reads as "unknown engine, not correctable", which is honest; a wrong engine is not. `set_publish_state` logs at WARNING when the sidecar is present but unreadable instead of returning silently.
2. **Publish sidecar: a pending marker first.** At the top of `fanout`, before any sink runs, replace `<stem>.publish.json` with `{"schema_version", "state": "unknown", "ts"}`. If that write fails, unlink the old file; if the unlink fails too, abort before publishing with `EXIT_PUBLISH_FAILED` and a message naming the sidecar, since the outcome could not be recorded either way. The final write then overwrites the marker as today.
3. **A failed final write is a failed publish.** `_write_publish_sidecar` returns whether it landed; on failure `fanout` sets `result["sidecar_write_failed"] = True`, and every caller that honours the exit-3 contract (`orchestrate`, `publish_cmd`, `publish_from_paste`, `merge_meetings`, `digest --publish`) exits `EXIT_PUBLISH_FAILED` with a cause naming the sidecar. The sinks that succeeded are recorded in their own per-sink sidecars, so the Republish this offers updates rather than duplicates where PIPE23's handling applies.
4. **Swift reads `unknown`.** `PublishResult.resolveState` returns `"unknown"` for the marker and never falls back to `run.json` past it; the Library badges it like `none` ("Publish outcome unknown", with Republish), `AudioRetention.isSettled` is false for it, and `Notifier.notifyDone` does not name a destination.
5. **One event.** `pipeline` `sidecar_write_failed` with `file` (`run` or `publish`), `error` (exception type) and `errno`, from every site above.
6. **No stray temp files.** Each of these writers builds `<file>.tmp` and then replaces; on a failed replace the `.tmp` is left in `raw/` beside the stale file. Remove it in the same `except`, so a later scan never sees two candidates.
7. **Contract.** CONVENTIONS "Publish result" gains the `unknown` state and the write order; regenerate the CI4 publish-result golden fixture with `scripts/gen_contract_fixtures.py` and extend the Swift decoder test to it.

## Explicitly not / out of scope

- A typed job-result envelope replacing file-presence inference: ARCH10 item 4. This task keeps the existing files truthful; the envelope can carry the same `sidecar_write_failed` bit when it lands.
- `<stem>.meta.json` writes: SEC25. User-data overlays: STOR9. Both siblings in this band.
- Notion create idempotency on retry: PIPE23.
- Retrying the write. A disk that refused one write is not made reliable by a second attempt inside the same run.

## Acceptance

- pytest in `test_corrections.py`: `write_run_sidecar` with `os.replace` patched to raise leaves no `run.json` (was: the old one) and emits `sidecar_write_failed`. `test_orchestrate.py`: the run still exits 0 with the summary in place.
- pytest for `summarize.rewrite_run_sidecar` (in `test_corrections.py` or the summarize suite): a failed rewrite after a re-summarize on a different backend leaves no `run.json` naming the old backend, and no `.tmp` beside it.
- pytest in `test_publish_router.py`: the pending marker is on disk while a fake sink runs; a final write patched to raise leaves the marker, not the previous run's file, and the caller exits 3; a marker write that fails with an unlink that also fails aborts before any sink is called.
- Swift: a `PublishResult` test that `"unknown"` resolves to `unknown` even with a `run.json` `publish_state` of `full`; an `AudioRetention` test that it is not settled; the CI4 fixture decoder test passes on the regenerated fixture.
- `sidecar_write_failed` documented in `CONVENTIONS.md`; `python3 scripts/truth_fences.py` green. `cd pipeline && uv run --extra dev pytest -q` and `cd daemon && swift test` green, ruff and pyright clean, `bash scripts/ci-local.sh` green, N new tests per tree in the commit body.

## Amendment 2026-11-13 (audit band)

Source: [independent audit](../../audits/2026-11-12-independent-audit.md) F054 (low, partially confirmed). Same root cause as this task, a file left by an earlier run read as this run's outcome, on a third per-stem file: `<stem>.apple_pending.json`. Re-verified in code at HEAD on 2026-11-13.

**The writer never cleans up.** `orchestrate._check_apple_handoff` writes the sentinel (`sentinel.write_text(...)`) whenever `effective_backend(cfg) == "apple_intelligence"` and returns the `apple_pending` skip. Nothing in `pipeline/src` ever removes it. The only remover is the daemon: `PipelineLauncher.runAll`'s success branch checks `FileManager.default.fileExists(atPath: sentinel.path)`, removes it and diverts to `completeViaAppleIntelligence`. So a sentinel survives when no daemon run-all consumes it: a hand-run `mp run-all <wav>` on the Apple backend (the README documents that command), or a daemon run-all cancelled or killed after the write and before a clean exit 0 (a narrow window, since the function returns right after writing).

**What it hijacks.** A later run-all on the same stem that succeeds through Python (summarized and published on another backend) exits 0, and Swift then finds the leftover, removes it, and runs `completeViaAppleIntelligence`: an on-device re-summarize that overwrites `<stem>.summary.json`, rewrites the run sidecar as Apple, and republishes, or fails the meeting when the system model is unavailable. `MeetingLibraryService.retryMeeting` reaches that run-all through its full path (`enqueue(audioURL, ...)`) whenever the failure was at transcribe or no reusable transcript exists; every daemon run-all goes through `SinkDispatcher`'s single `launcher.runAll` call, so any other path that re-enqueues an existing recording does the same.

Correction at filing: the hijack needs the effective backend to have moved off `apple_intelligence` between the leftover write and the later run. While the backend is still Apple, Python rewrites the sentinel on the later run and the diversion is the right one. The owner's history has that move in it (86 `run_skipped` rows with reason `apple_pending` between 2026-05-28 and 2026-07-14, backend anthropic on 110 of 110 runs since, per the [field evidence](../../audits/2026-11-13-field-evidence.md) cross-check), and no leftover `*.apple_pending.json` was found in the library at filing, so this is latent here.

### Scope additions

8. **Python removes a stale sentinel at run start.** `orchestrate.run_all` unlinks an existing `<stem>.apple_pending.json` before any stage runs (missing-file is fine; an unlink that fails logs at WARNING and the run continues), so the only sentinel the daemon can find after exit 0 is the one this run wrote. The Swift reader stays as it is.

### Explicitly not (addition)

- An mtime-versus-spawn check in `PipelineLauncher.runAll`. It would work, but two guards on one file split the ownership PIPE34 puts with the writer; the writer clearing its own leftovers is the shape the rest of this task uses.
- F022/F023 (Regenerate and Retry spawn `mp summarize`, which rejects `apple_intelligence`): a separate class, not a leftover file.

### Acceptance additions

- pytest in `test_orchestrate.py`: a pre-existing `<stem>.apple_pending.json` with the backend set to anthropic leaves no sentinel after a successful `run_all` (fails on `main`); with the backend set to `apple_intelligence` the run still ends with exactly one sentinel naming this run's transcript.
- `cd pipeline && uv run --extra dev pytest -q` green, ruff and pyright clean, the number of new tests in the commit body.
