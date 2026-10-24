# SEC18: zero-egress (regulated mode or an NDA workflow) is enforced only for HTTP, so synced folders, BYO bundles and backups still carry meeting content off the Mac

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) S2, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) fix 9 and the privacy half of DI-11). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

`config.zero_egress` (SEC13) is the single owner of "may this run reach a cloud service", and everything it clamps is a network call: `effective_backend` pins the on-device engine, `egress_guard` blocks non-loopback httpx, tokens are scrubbed. Nothing it clamps writes a file. Latent on the owner's Mac today (`regulated_mode = false`, all three workflows `nda_mode = false`, checked 2026-10-24), live for anyone who turns either on.

**Premise correction.** The architecture review says that under NDA "`effective_sinks` drops only Notion, so the Obsidian, filesystem and LAN sinks still run". Re-read on 2026-10-24, that is only true for a meeting with no sidecar. Swift's `Workflow.effectiveSinks` is `flags.ndaMode ? [.filesystem] : sinks`, and Python's `workflow.apply_overrides` re-clamps every meeting whose sidecar resolves to zero-egress (`if overlay.output.sinks != ["filesystem"]: ... "zero_egress→sinks=filesystem"`). `effective_sinks` (Notion dropped, Obsidian and LAN kept, and `publish_router._build_one`'s comment that LAN is "Allowed under regulated mode") is reached only when `apply_overrides` returns early on an empty sidecar. So the two paths disagree about LAN and Obsidian, and the sidecar path is the one every recorded meeting takes.

What does leave the Mac under zero-egress, verified:

1. **The one sink that survives writes into iCloud by default.** `FilesystemCfg.output_dir` defaults to `~/Documents/Meetings/published`, inside iCloud Desktop & Documents scope, which SEC12 confirmed is on for the owner's Mac. The library root (`~/Documents/Meetings/raw`) is the same. SEC12 made this a doctor `[FAIL]` under zero-egress, and by the owner's call doctor still exits 0. Nothing at record or publish time checks it.
2. **BYO bundles.** `orchestrate._check_byo` writes `<stem>.READY_FOR_MANUAL.md` whenever `force_byo` is set, with no zero-egress check. The bundle's only purpose is to be pasted into a cloud chat.
3. **Backups.** `mp backup` archives the whole library, NDA and regulated meetings included, to any destination; `backup.check_destination` checks only that a `/Volumes` drive is mounted, not whether the destination is synced.
4. **Install copy.** `install.sh` writes `NSMicrophoneUsageDescription` as "MeetingPipe records meeting audio for transcription. Audio never leaves your Mac.", which is false while the library sits in a synced folder.

`cloudsync.detect_sync_provider` (Python) and `CloudSyncDetector.detect` (Swift) already answer "is this path synced", and `LibraryMover` already offers the assisted move.

## Scope

1. **One sink rule.** `config.effective_sinks` under `zero_egress` returns what `apply_overrides` already enforces (`["filesystem"]`), so the no-sidecar path stops keeping Obsidian and LAN. If the owner wants LAN allowed under regulated mode (the FEAT1 comment), that becomes the rule on both paths instead; the pickup session asks once and fixes the comment either way.
2. **Synced-target gate at publish.** In `publish_router.build_publishers`, under `zero_egress`, a file sink whose target `cloudsync.detect_sync_provider` reports as synced is not built: it becomes an `UnavailablePublisher` (PIPE16's existing stand-in for a sink that cannot be constructed), recorded as a failed sink with reason `synced_target` in `<stem>.publish.json`, so the exit-3 all-sinks-failed contract and the row's failure copy apply unchanged. The summary still exists in the library.
3. **Record-time warning, never a refusal.** When a recording starts with a zero-egress capture mode (`CaptureMode.resolve` returned `.regulatedGate`) and `CloudSyncDetector.detect` reports the library root synced, post one notification per session naming the provider, with the existing "Move library..." action, and log an event. Refusing to record was considered and rejected: it loses the meeting, and the audio is already gated live in that mode.
4. **BYO under zero-egress.** `_check_byo` declines when `zero_egress(cfg)` and falls through to the normal on-device summary, emitting `run_skipped`'s sibling event with `reason=byo_refused_zero_egress`.
5. **Backups.** `mp backup` refuses a destination `detect_sync_provider` reports as synced when the library contains any meeting `visibility.withheld_reason` marks `nda` or `regulated`, with a message naming the provider.
6. **Copy.** The mic usage string says what is true (for example "Audio is stored on this Mac"), and SETUP.md/GUIDE.md mention the synced-folder warning. DOC16 rewrites the neighbouring Screen Recording string in the same plist; whichever lands second rebases.

## Explicitly not

- Changing the default library location for new installs, the welcome-screen promise, and iCloud download-status handling: STOR6.
- Making doctor exit non-zero: the owner kept exit 0 for SEC12, not reopened here.
- Backup encryption, file modes and atomic writes: STOR8.
- Socket-level enforcement in the pipeline process: SEC19. The MCP surface: AUTO6.

## Acceptance

- pytest: `effective_sinks` under regulated mode with no sidecar returns `["filesystem"]` (or the owner's chosen rule, pinned identically on both paths by one test that runs both).
- pytest: a filesystem sink pointed at a fake synced root (the same xattr stub `test_cloudsync`/doctor tests use) under zero-egress is not built and `publish.json` records `synced_target`; outside zero-egress it publishes as before.
- pytest: `force_byo` under zero-egress writes no `READY_FOR_MANUAL.md` and produces the on-device summary; without zero-egress the bundle is written as before.
- pytest: `mp backup` to a synced destination with one NDA meeting in the library refuses with the provider named; with none it proceeds.
- Swift: a test of the start-time check (pure decision function over capture mode plus a stubbed detector) that it notifies once for `.regulatedGate` with a synced root and never for `.captureFirst`.
- New event actions reuse existing categories in snake_case, so `python3 scripts/truth_fences.py` (CI5) stays clean; ruff, pyright, `pytest -q`, `swift test` green with the new test counts in the commit body.
