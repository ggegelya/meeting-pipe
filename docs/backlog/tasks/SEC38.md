---
id: SEC38
title: The event and daemon logs carry window titles, display names and published note paths, so a diagnostics pack cannot be shared without scrubbing
category: Security
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). The field pack held 3,007 window titles in 1,484 shareable_content_no_match rows, browser_tab_rejected and window_title_changed write titles verbatim (F163), and 70 pipeline_succeeded rows plus 838 daemon.log "pipeline OK" lines carry a note path or page address that embeds the title slug, so the logs cannot go to an analysis session unscrubbed. Log counts and shape classes instead of titles and sink names instead of note paths, in both trees, behind a truth-fence denylist of attribute keys.
---

# SEC38: The event and daemon logs carry window titles, display names and published note paths, so a diagnostics pack cannot be shared without scrubbing

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Sources: the "Logs carry window titles and note paths" row of the [field evidence](../../audits/2026-11-13-field-evidence.md), "Daemon health and cross-check of the code audit" section (class key daemon-health-and-audit-crosscheck#20), and F163 in the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) (low, "Titles of browser tabs judged not to be meetings are persisted verbatim to the event log"). Code re-read at HEAD 3a2da4fc on 2026-11-13.

**Field evidence (work laptop, event log 2026-09-29 to 2026-11-13).** 1,484 `signal/shareable_content_no_match` rows list 3,007 window titles in `candidate_titles`; 70 `coordinator/pipeline_succeeded` rows and 838 daemon.log "pipeline OK" lines carry the published note path or page address, which embeds the meeting title slug. Present in every build era, the newest (installed 2026-11-12) included. The field audit's verdict: the pack could not be shared outside without scrubbing. Every audit and analysis session the owner runs is handed exactly this pack, so the logs are a disclosure surface, not only a local file.

**Where the content is written, at HEAD.**
- `ShareableContentSignal` (Core) logs `"candidate_titles": candidatesToLog`, every on-screen window title of the bundle, whenever none matches; the comment says it exists "to distinguish "no window" from "title mismatch"". It is deduped on the list, not throttled.
- `MeetingDiscoveryWatcher.logRejectedBrowserTabs` logs `detector/browser_tab_rejected` with `"title": tab.title`, the full title of a browser tab refused at admission, and `emitRejectedBrowserTabs` throttles on a signature that includes the title (F163). DET6 made this deliberate ("It carries the page title in full, which is the point", `CONVENTIONS.md`), and README tells the owner the row names the tab title.
- `WindowTitleSignal.evaluate` logs `signal/window_title_changed` with `"title"` and `"previous"`, both verbatim (found at filing; the field row does not count it).
- `SinkDispatcher`'s success branch writes `Log.writeLine("daemon", "pipeline OK -> \(pageURL?.absoluteString ...)")` and `pipeline_succeeded` with `"page_url"`. `MeetingLibraryService` does the same on `republish_succeeded` and `merge_succeeded` (found at filing).
- `MeetingSessionController`'s stop path writes the daemon.log line "meta sidecar ... title=\(source?.meetingTitle ?? "(none)") workflow=..." (found at filing; F040's field count of 391 of 402 lines reading `(none)` is how this line was measured).
- Python, found at filing: `mp.orchestrate` emits `pipeline/stage_completed` (publish) and `pipeline/run_completed` with `page_url=pub.get("page_url")` and logs `done: page_url=%s` to pipeline.log; `mp.publish_cmd` logs `publish done: page_url=%s` the same way.
- `SinkDispatcher`'s failure branch logs `pipeline_failed` with `"error": err.localizedDescription` and the daemon.log line `pipeline FAIL -> ...`; the field pack's one `pipeline_failed` row carries a 27 character title in that field (the field evidence's "names a failure by title only" row), so the failure text can carry the title too.

**Correction at filing (display_name, ax_label, label).** The field row also counts 481 rows with `display_name`, 387 with `ax_label` and 292 with `label`. At HEAD these do not carry meeting content: `display_name` is the app's `localizedName` (`MeetingSourceScanner`, `app.localizedName ?? bid`), `ax_label` and `label` on the micgate rows are the mute button's accessibility label (`MicGate.attributes(for:)`, `AXMuteButtonProbe`), and `label` on the roster and speaker rows is the diarizer's cluster label, with the typed name never logged (`SpeakerLabelStore.setLabel(label, to: trimmed, ...)` logs only `label`). They stay as they are; the fence below allows them by name so the decision is recorded.

**History.** SEC11 (q4, done) answered "events.jsonl is 0644 with verbatim meeting titles" by making the file 0600 (`mp.events.emit`'s "SEC11: the event log carries verbatim meeting titles" comment). That protects the file on disk, not the copy handed to an analysis session. The detection trace extractor already treats titles as content that "never leaves the log" (`scripts/extract_detection_trace.py`, `UNMAPPABLE_SIGNALS = {"window_title_changed"}`), and DET17's new `browser_identity` row logs a shape class only, so the pattern exists; this task applies it to the rows that predate it.

**What the titles bought.** END14's diagnosis (2026-10-08) read `shareable_content_no_match` to see that Teams windows had started carrying titles with no brand token. Any replacement has to keep that question answerable, which a shape class does.

## Scope

1. **A shape classifier, in Core.** A pure `WindowTitleShape.classify(_ title: String?, patterns:)` returning a fixed class name: `nil`, `empty`, `matches` (one of the adapter's matchers), `brand_token` (carries a known product token but no matcher), `other`. Coordinate the class names with [DET17](./DET17.md)'s `browser_identity` shapes so one vocabulary covers both.
2. **Titles out of the event rows.** `shareable_content_no_match` logs `candidate_count` and `candidate_shapes` (the classes, in order) instead of `candidate_titles`; its dedupe may keep comparing the titles in memory. `browser_tab_rejected` logs `shape` instead of `title`, and its throttle signature keeps the title in memory only. `window_title_changed` logs `shape` and `previous_shape`. No row carries a hash of a title.
3. **Note paths out of the success rows.** `pipeline_succeeded`, `republish_succeeded` and `merge_succeeded` log `published` (bool) and the sink names from the run's publish result instead of `page_url`; the daemon.log "pipeline OK" line names the sinks or "local-only". The "meta sidecar" daemon.log line logs `title_known=true|false` instead of the title. Python's `stage_completed` and `run_completed` drop `page_url` for the sink names, and pipeline.log's "done:" and `publish_cmd`'s "publish done:" lines likewise. `pipeline_failed` and its daemon.log line log the stage and the error's type rather than free text that can quote the title; the full reason stays in `<stem>.error.json` (`PipelineFailureSidecar`), which is the Library's and not a log. `<stem>.publish.json` keeps `page_url`; it is the Library's link and not a log.
4. **A fence.** `scripts/truth_fences.py events` (CI5) gains a denylist of attribute keys that may not appear in a Swift `Log.event` / `.emit` call or a Python `events.emit` call: `title`, `titles`, `candidate_titles`, `page_url`, `note_path`, `meeting_title`. (`previous` is a key many rows use for a non-title value, so `window_title_changed`'s is pinned by its test instead.) An explicit allowlist names `display_name`, `ax_label` and `label` with the reason above. The fence also greps `Log.writeLine` for an interpolated `meetingTitle` or `pageURL`.
5. **Docs, same commit.** `CONVENTIONS.md`'s event-schema paragraphs for `browser_tab_rejected` and `shareable_content_no_match`, and README's "A meeting in a plain browser tab" paragraph (which says the row names the tab title), describe the shape classes.

## Explicitly not

- The verbose-mode transcript and correction text in `events.jsonl`: [OBS6](./OBS6.md).
- The committed detection and promotion traces and their redaction check: [T20](./T20.md). This task changes what the live log writes, not what the corpus accepts.
- Scrubbing the logs already on disk, or a "share diagnostics" export that redacts on the way out. The fix is at the writer; a scrubber over free text is the approach that misses the next new key.
- Unsalted short hashes of titles: a guessable title is recovered by hashing guesses, so a hash is not redaction. A salted per-install hash was considered and left out until a session needs title identity across rows, which none does today.
- Workflow names in `routing_hint_shown` and `override_picked` rows: they are the owner's own configuration, not meeting content. Named here so a later pass can decide.
- The Diagnostics window (UX20) and `mp logs`: they read whatever the rows carry and need no change.
- The meeting title in the meta sidecar, the summary and the sinks: that is the product, not a log.

## Acceptance

- Core tests for `WindowTitleShape.classify` over nil, empty, a matching title, a brand-token-only title and an unrelated title, using synthetic placeholder titles.
- `ShareableContentSignalTests`: a no-match read emits `candidate_count` and `candidate_shapes` and no `candidate_titles`; an unchanged candidate list still emits once.
- `MeetingSourceScannerTests` or a watcher test: `logRejectedBrowserTabs` emits `shape` and no `title`; a second tab with a different title in the same browser still re-logs.
- A `WindowTitleSignal` test: `window_title_changed` carries `shape` and `previous_shape` and neither title.
- A `SinkDispatcher` test: `pipeline_succeeded` carries `published` and the sink names and no `page_url`; a failing run whose error text contains a placeholder title logs `pipeline_failed` without that text, while `<stem>.error.json` keeps it. A pytest over `run_all` with a stub publisher: `run_completed` and the publish `stage_completed` carry no `page_url`.
- `python3 scripts/truth_fences.py events` fails on a planted `"title":` attribute in a scratch emit call and passes at the change; `bash scripts/ci-local.sh` green; `cd daemon && swift test` and `cd pipeline && uv run --extra dev pytest -q` green with the number of new tests in the commit body.
- Owner check, no walkthrough needed: a grep of the first week's `events.jsonl` after the landing for `candidate_titles`, `"title"` and `page_url` returns no rows written by the new build.
