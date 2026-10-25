# PIPE34: a failed write of `<stem>.run.json` or `<stem>.publish.json` leaves the previous run's sidecar in place, and the daemon reads it as this run's outcome

Band origin: filed 2026-10-25 from the 2026-10-25 observability audit band ([observability audit](../../audits/2026-10-25-observability-audit.md) O20: PY-5, FB-8). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

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
