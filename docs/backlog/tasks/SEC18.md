---
id: SEC18
title: Zero-egress (regulated mode or an NDA workflow) is enforced only for HTTP, so synced folders, BYO bundles and backups still carry meeting content off the Mac
category: Security
status: new
priority: P2
comment: Filed 2026-10-24 (audit band, arch S2, go-live fix 9 and DI-11 privacy half): zero_egress clamps only network calls; the filesystem sink defaults into iCloud-synced ~/Documents, BYO bundles and mp backup have no gate, and the mic usage string says audio never leaves the Mac. One sink rule on both paths, a synced-target gate at publish, a record-time warning, BYO and backup gates, honest copy. [Spec](./SEC18.md) Amended 2026-11-13 by the audit band: Preferences says regulated mode only drops Notion while the sidecar rule diverts an Obsidian-only workflow into the filesystem folder; mirror the sink rule in Swift beside effectiveBackend and build the copy from it, and strip all four managed tokens by policy (G034, F167).
---

# SEC18: zero-egress (regulated mode or an NDA workflow) is enforced only for HTTP, so synced folders, BYO bundles and backups still carry meeting content off the Mac

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) S2, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) fix 9 and the privacy half of DI-11). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

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

## Amendment 2026-11-13 (audit band)

From the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md): G034 (confirmed) and the low F167 (attached here as zero-egress spawn hygiene). Re-read in code at HEAD on 2026-11-14. Latent in the field: the [field evidence](../../audits/2026-11-13-field-evidence.md) pack from the work laptop used one non-NDA workflow with a single Obsidian sink for all 113 meetings, so the regulated sink diversion never ran there.

### What the code does today

- **The Preferences copy describes a rule the sidecar path does not apply (G034).** `RegulatedMode.footer(configured:)` says "Two things happen while it is on ...: no transcript or summary is uploaded to Notion, and every summary is produced on this Mac", and its already-local branch says "While it is on, no transcript or summary is uploaded to Notion." `RegulatedMode.sublabel(isOn:configured:)` has the same shape: both On branches say "Notion publish is disabled for every meeting" and nothing about the other sinks. Meanwhile `MeetingMetaSidecar.build` stamps `regulated_mode: true` on every recording made with regulated mode on, so `workflow.apply_overrides` takes the clamped branch and sets `overlay.output.sinks = ["filesystem"]` (`zero_egress→sinks=filesystem`). An Obsidian-only workflow under regulated mode therefore stops reaching the vault, and its summary, transcript and actions land in `FilesystemCfg.output_dir`, `~/Documents/Meetings/published` by default, a destination the workflow never ticked and the folder Context item 1 above already flags as iCloud-synced. Two sibling sources still describe the other rule: the `config.zero_egress` docstring says "Note the LAN sink is deliberately *not* clamped", and `test_publish_router.py`'s regulated test pins `[p.name for p in pubs] == ["obsidian", "filesystem"]` on the no-sidecar path. [UX45](./UX45.md) (owner-verify) corrected four strings around the sinks but not `RegulatedMode.swift`'s copy.
- **Swift shows a third answer.** `Workflow.effectiveSinks` is `flags.ndaMode ? [.filesystem] : sinks`, keyed on the workflow's NDA flag only, so under global regulated mode the workflow surfaces still show Obsidian while Python writes filesystem. The Swift mirror the copy is built from, `RegulatedMode.effectiveBackend(configured:regulated:workflowNDA:)`, covers the backend and has no sink counterpart. The tutorial's regulated-mode step ("This clamps summarization to the on-device model") does not mention sinks either way.
- **The daemon withholds two of the four managed tokens (F167, low).** `PipelineLauncher.freshEnvironment` takes `stripAnthropicKey` and `stripNotionToken` and removes only `ANTHROPIC_API_KEY` and `NOTION_TOKEN`, while `KeychainSecrets.managedKeys` is `["ANTHROPIC_API_KEY", "NOTION_TOKEN", "HF_TOKEN", "OPENAI_API_KEY"]` and the daemon seeds all four into its own environment (`Secrets.loadIfPresent`). `LocalModelPreloader` spawns `mp serve-local` with both strips on, under a comment that says it withholds "both managed tokens", so `HF_TOKEN` and `OPENAI_API_KEY` reach the warm server and, outside zero egress (where `egress_guard.child_env()` is a plain copy), the `mlx_lm.server` it execs. Four more spawn sites (`DoctorRunner`, `DoctorCommand`, `MCPStatusStore`, a Preferences pipeline action) call `freshEnvironment()` with no strip at all; the two doctor spawns check which credentials exist, so they legitimately keep them. Correction at filing: under zero egress the Python side already closes this, since `egress_guard.arm` pops every key in `MANAGED_SECRET_KEYS` (all four) and `load_secrets` returns early when the guard is armed. So F167 is defense-in-depth hygiene, not a zero-egress leak, and `freshEnvironment`'s note that "the Python child re-reads the token from the Keychain via load_secrets(), so a stripped token reappears" is stale for zero-egress runs since SEC13 (still true outside them).

### Added scope

7. **Item 1's owner question gains the Obsidian case (G034).** When the pickup session asks the owner which one sink rule zero egress applies, it asks about Obsidian as well as LAN: an Obsidian vault is a local folder (possibly synced, which item 2's gate already handles), and the current sidecar rule diverts it into the filesystem folder. The chosen rule then lives in `config.effective_sinks` only (`apply_overrides` calls it rather than hard-coding `["filesystem"]`), the `config.py` comment and the `test_publish_router.py` pin follow it.
8. **Mirror the rule in Swift and build the copy from the mirror (G034).** Beside `RegulatedMode.effectiveBackend`, add the sink counterpart (for example `effectiveSinks(configured:regulated:workflowNDA:)`, the mirror of the chosen Python rule), make `Workflow.effectiveSinks` consult it for global regulated mode as well as NDA, and build `RegulatedMode.footer` and `sublabel` from it, so a sink the rule drops or adds is named rather than implied by "Notion". The tutorial step names the sinks only if the owner wants it there.
9. **Strip by policy over the managed list (F167).** `freshEnvironment` takes a policy rather than two booleans and removes each key in `KeychainSecrets.managedKeys` the run does not need: under zero egress all four; the doctor and credential-status spawns keep what they inspect; for an on-device summary every cloud credential (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`); `NOTION_TOKEN` per item 1's sink rule; `HF_TOKEN` kept only for a spawn that may fetch a model outside zero egress (`serve-local`). `Secrets.scrubbedEnvironment(from:)` (SEC14, the all-four strip ffmpeg already gets) is the precedent to build on, so the daemon has one strip helper rather than two. The `LocalModelPreloader` and `freshEnvironment` comments say what is true. Whether the Python `load_secrets` should also stop refilling a token the daemon withheld outside zero egress is left to the pickup session, named in the commit body.

### Added acceptance

- One test that runs both paths (the existing acceptance's "pinned identically on both paths") covers an Obsidian-only workflow under regulated mode, with and without a sidecar, against the owner's chosen rule.
- `RegulatedModeTests`: the Swift sink mirror matches a table shared with the Python test (or a CI4-style golden fixture), and the footer and sublabel name the sinks the rule leaves for an Obsidian-only configuration.
- A `freshEnvironment` test per policy: zero egress removes all four managed keys; the serve-local policy outside zero egress keeps `HF_TOKEN` and removes the other three.
- Any tutorial copy change keeps `TutorialFenceTests` green.
