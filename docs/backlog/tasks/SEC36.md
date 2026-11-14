---
id: SEC36
title: The in-daemon FluidAudio model download has no zero-egress gate, so a missing speech-model cache makes the daemon fetch from huggingface.co mid-job under regulated or NDA mode
category: Security
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). F124: `FluidAudioRunner.ensureAsr` and `ensureDiarizer` call `AsrModels.downloadAndLoad` and `DiarizerModels.downloadIfNeeded` with no policy input, so a missing or corrupt cache makes the daemon request model files from huggingface.co during a regulated or NDA job (model files only, no audio); SEC13 gated only the pipeline's fetch and HYG10 proposes sanctioning this one, so the owner picks the rule first. Preflight the cache at the `SinkDispatcher` transcribe step and fail a zero-egress job with a download-models-first notice. Promote before enabling regulated or NDA. [Spec](./SEC36.md)
---

# SEC36: The in-daemon FluidAudio model download has no zero-egress gate, so a missing speech-model cache makes the daemon fetch from huggingface.co mid-job under regulated or NDA mode

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: [independent audit](../../audits/2026-11-12-independent-audit.md) finding F124 (security lens, partially confirmed). Re-read at HEAD `3a2da4fc` against the pinned FluidAudio 0.14.8 checkout.

**The path.** `SinkDispatcher` logs `engine_started` and calls `runner.transcribe(wavURL: job.file, languageHint: languageHint)`. `FluidAudioRunner.transcribe` calls `ensureAsr()`, which on a cold daemon runs `AsrModels.downloadAndLoad(version: asrVersion)`, and diarization runs `ensureDiarizer()`, which calls `DiarizerModels.downloadIfNeeded()`. The class comment says it plainly: "first model download is lazy via FluidAudio's bundled loader". Neither function, nor `transcribe`, takes any regulated or NDA input, so the fetch happens whatever the meeting's posture. Only model-file requests leave the Mac, no audio or transcript, but README's troubleshooting entry treats a huggingface.co request from a zero-egress meeting as a broken promise for the pipeline's model ("A zero-egress run refuses to download a model, because doing so would send a request to huggingface.co from a meeting that promised not to"), and CONVENTIONS says "The daemon stays offline".

**Reachable routes.** A failed or skipped install-time `MeetingPipe prefetch-models` (`PrefetchModelsCommand`), a cleared `~/Library/Application Support/FluidAudio`, or FluidAudio's own recovery: `DownloadUtils.loadModels` catches a first load failure, logs "Deleting cache and re-downloading", removes the repo folder and calls `loadModelsOnce` again, which downloads. **Correction at filing:** that recovery sits under every load, including the load-only `AsrModels.load(from:)`, which also routes through `DownloadUtils.loadModels`. So a cache that exists but fails to load passes an `AsrModels.modelsExist(at:)` preflight and is still wiped and re-fetched. No load-only API at 0.14.8 avoids it. The audit's drag-install route does not exist yet (no drag install ships).

**Rules in conflict.** SEC13 (done, [q6-final.md](../q6-final.md)) gated only the pipeline's model fetch. [HYG10](./HYG10.md) lists "FluidAudio downloads models from the daemon" against the daemon-offline rule and proposes naming it as a sanctioned daemon HTTP call, with no regulated or NDA exception. [DIST7](./DIST7.md) covers the unhashed fetch only. The owner decides whether a zero-egress meeting may fetch speech models at all; this task is the fix if the answer is no.

**Field evidence.** None: regulated mode is off and no workflow is NDA on this Mac (`workflow_nda_mode` false on 113 of 113 metas in the [field pack](../../audits/2026-11-13-field-evidence.md)), and the transcript model is parakeet-tdt-0.6b-v3 on 113 of 113 transcripts. The pack does not record whether any of those runs fetched models mid-job.

## Scope

1. **A pure decision.** A small `SpeechModelGate` (or a static on `FluidAudioRunner`) taking "is this job zero-egress" and "are the models present" (`AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for:))` and, since `DiarizerModels` has no `modelsExist` at 0.14.8, a file-presence check of the diarizer's model files under `DiarizerModels.defaultModelsDirectory()`) and returning proceed or refuse. Skipped when the runner already holds loaded managers (`asrManager` and `diarizer` non-nil), since nothing will be fetched.
2. **The seam is `SinkDispatcher`.** Before `runner.transcribe`, the job's posture comes from `MeetingMetaRead.load(at:)` on `<stem>.meta.json` (`isZeroEgress`, fail-closed on unreadable per SEC25) or the global `regulated_mode`. On refuse, no load is attempted: the job fails with a `PipelineFailureSidecar` whose reason `FailurePresentation.isValidation` recognises ("Speech models are not downloaded. Download them from a normal session first, then retry this meeting."), and `Log.event(category: "transcription", action: "models_missing_zero_egress", ...)` with the stem and which model is missing. `PrefetchModelsCommand` and the normal-mode lazy fetch stay as they are.
3. **The corrupt-cache residual.** Record it in `daemon/docs/gotchas.md` beside the gate. If the pickup session wants it closed, the candidate is pointing `ModelRegistry.baseURL` (a settable static at 0.14.8, read before every request) at an unroutable loopback URL for the length of a zero-egress load; it is a process-global and a prefetch can run at the same time, so it needs the owner's yes and a test, or it stays a written residual.

## Explicitly not

- Hash-checking model files or pinning revisions: [DIST7](./DIST7.md). A vendor fallback runner: [ASR6](./ASR6.md).
- Kernel-level egress enforcement: [SEC32](./SEC32.md) (the pipeline child only). Synced folders and backups: [SEC18](./SEC18.md).
- Gating `MeetingPipe prefetch-models`: it is the owner's explicit download and the way out of the refusal.

## Acceptance

- Swift tests, offline, with no FluidAudio call: the pure decision refuses for zero-egress with either model missing, proceeds for zero-egress with both present, proceeds for normal mode with models missing, and proceeds when managers are already loaded.
- `SinkDispatcherTests`, with a fake runner and an injected presence check: an NDA sidecar plus missing models fails the job with the validation reason, never calls `transcribe`, and emits `models_missing_zero_egress`; an unreadable sidecar behaves as NDA; a normal-mode job calls `transcribe` as today.
- `swift test` green with the new test count in the commit body; `python3 scripts/truth_fences.py events` green for the new action; `bash scripts/ci-local.sh` green. README's troubleshooting entry for zero-egress model refusals names the speech models too, and [docs/GUIDE.md](../../GUIDE.md) if it covers regulated mode, in the same commit.

## Owner walkthrough

1. [owner] Decide the rule against [HYG10](./HYG10.md): may a regulated or NDA meeting fetch speech models from huggingface.co? If yes, close this task with that decision recorded in HYG10 and CONVENTIONS; if no, the pickup session ships the scope above.
2. [owner] After the fix, simulate it: move `~/Library/Application Support/FluidAudio` aside, record a short meeting under an NDA workflow, and confirm the Library row shows the download-models-first failure and the daemon's `events.jsonl` has `models_missing_zero_egress`; then run `MeetingPipe prefetch-models`, restore normal state and retry the meeting.
