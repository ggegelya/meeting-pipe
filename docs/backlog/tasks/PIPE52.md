---
id: PIPE52
title: Regenerate, Retry and the local preview dispatch on the global backend instead of the meeting's effective one, so Apple Intelligence meetings can never be re-summarized and the on-device preview can run on a cloud backend
category: Pipeline
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). Every nil-backend re-summarize (Regenerate, Retry with a reusable transcript, Re-summarize all, the Change workflow follow-up, restoreHeldTail) spawns mp summarize, whose apple_intelligence builder raises, so an Apple meeting fails every attempt and merge fails after committing its audio (F022, F023); Re-run locally (preview) is gated and dispatched on the global backend while the pipeline applies the workflow's, so a non-NDA meeting pinned to anthropic goes to Anthropic under "Re-running on-device" (F123). Latent in the field window (anthropic on 110 of 110 since 2026-07-14, 86 apple_pending runs before it). One Swift resolver of the meeting's effective backend for gate and dispatch, Apple meetings through the Swift summarizer then mp publish, and an explicit local backend for the preview.
---

# PIPE52: Regenerate, Retry and the local preview dispatch on the global backend instead of the meeting's effective one, so Apple Intelligence meetings can never be re-summarized and the on-device preview can run on a cloud backend

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: the 2026-11-12 [independent audit](../../audits/2026-11-12-independent-audit.md), findings F022 ("Regenerate and Retry always spawn `mp summarize`, which rejects the apple_intelligence backend", quality lens), F023 (the same defect from the architecture lens, "Regenerate and Retry always fail for Apple Intelligence meetings"), and F123 ("'Re-run locally (preview)' is gated and dispatched on the global backend while the pipeline resolves the meeting's workflow backend", security lens). All three confirmed, backlog New. They are one class: the Library decides which engine runs from a different value than the one the pipeline then uses.

Re-verified in code at HEAD `3a2da4fc` on 2026-11-14:

**Apple meetings cannot be re-summarized (F022, F023).**

- `MeetingLibraryService.regenerateMeeting(stem:backend:)` always calls `launcher.summarize(transcriptMD:backend:)`, which spawns `mp summarize <md>` plus `--backend` only when one is passed. Callers that pass `nil`: the row's Regenerate (`LibraryListView`, `MeetingDetailView+Header`), Re-summarize all (`BatchActionsPane`), the Change workflow follow-up's Regenerate button, `LibraryWindowModel.restoreHeldTail` (END17), and `retryMeeting` whenever the failure is not at the transcribe stage and `hasReusableTranscript` holds (`regenerateMeeting(stem: stem) { _ in }`).
- In Python, `summarize._select_backend` looks the effective backend up in `providers`, and `providers._apple_summary` raises `ValueError("summarization.backend='apple_intelligence' runs in the daemon (Swift), ...")`. `workflow.apply_overrides` maps a sidecar `workflow_backend` onto `summarization.backend`, so a workflow pin to Apple reaches the same raise as a global Apple setting.
- Only run-all hands off: `orchestrate._check_apple_handoff` writes `<stem>.apple_pending.json`, and `PipelineLauncher.runAll` sees the sentinel and calls `completeViaAppleIntelligence`, which runs the Swift summarizer and then `mp publish`. No Library re-run path does this.
- So for a non-NDA, non-regulated meeting whose effective backend is `apple_intelligence`, each of those actions exits 1, and the failure branch of `regenerateMeeting` writes a `PipelineFailureSidecar`, so a healthy meeting turns into a failed row whose Retry loops into the same error. A Retry after a failed Apple run (model not ready) can never recover on its own backend.
- `merge_meetings.merge_meetings` calls `summarize(md_path, cfg=cfg, client=client)` after committing the merged transcript and swapping in the merged audio, so a merge of Apple meetings fails after the irreversible step; its resume branch then re-raises on every retry.
- The verifiers' qualification holds: explicit "Re-summarize with" Local MLX or Anthropic works (PIPE6), and the Summary tab's candidate preview plus Keep runs Apple when the global backend is Apple and a summary exists. Neither covers a failed meeting with no summary, or a workflow-only Apple pin.

**The on-device preview can egress (F123).**

- `LibraryWindowModel.canPreviewLocally` is `summarizationBackend == "local" || summarizationBackend == "apple_intelligence"`, the global value only, and gates the Summary tab's **Re-run locally (preview)** button, whose progress line reads "Re-running on-device…" and whose help says "with the on-device model".
- `MeetingLibraryService.previewSummary` dispatches on the same global value: Apple goes to `summarizePreviewViaApple`, anything else to `PipelineLauncher.summarizePreview`, which spawns `mp summarize <md> --candidate` with no `--backend`. The pipeline then applies the meeting's `workflow_backend`.
- `PipelineLauncher.cloudSecretPolicy` resolves `backendOverride ?? sidecarBackend ?? globalBackend`, so for a workflow pinned to `anthropic` it keeps the Anthropic key, and the transcript goes to Anthropic while the UI says on-device. With a workflow pinned to Apple the same click fails on the `ValueError`. The FEAT7 reprocess editor goes through the same `previewSummary`.
- NDA and regulated meetings are not exposed: `config.effective_backend` forces `local` under `zero_egress`, and `cloudSecretPolicy` strips the key.

Field evidence: the 2026-11-13 [field evidence report](../../audits/2026-11-13-field-evidence.md) lists F022 and F023 as not seen in the window (86 `run_skipped` with reason `apple_pending` from 2026-05-28 to 2026-07-14, backend anthropic on 110 of 110 since), and F123 has no log surface. The same report records `workflow_backend` as `anthropic` on 113 of 113 meetings, and the daemon writes that key only when a workflow pins a backend, so the moment the global backend is switched to local or Apple, every preview the button offers would run on Anthropic.

Correction at filing: two narrowings. "Reassign follow-up" in the audit is the Change workflow sheet's Regenerate button, not speaker reassignment. And F123's preview is not reachable for an NDA or regulated meeting, so this is not a regulated-mode-only defect and needs no promotion before enabling those modes.

Related: [ARCH14](./ARCH14.md) (types the backend string; it lists `canPreviewLocally` and the preview dispatch but changes no decision, and this task changes the decision, not the type), [ARCH11](./ARCH11.md) (making Apple a provider only would remove the hand-off; if its provider leg lands first, the Apple legs here collapse into it), [PIPE25](./PIPE25.md) (Apple's language refusal and fallback), [PIPE36](./PIPE36.md) (done; the Apple summarize's ceiling and cancel, which the new route must keep), PIPE6 and UX80 (done, archived in [q6-final.md](../q6-final.md)).

## Scope

1. **One resolver.** Extract the backend resolution out of `PipelineLauncher.cloudSecretPolicy` into one static function (for example `PipelineLauncher.effectiveBackend(for:override:configURL:)`) that returns `local` for regulated, NDA or an unreadable sidecar, else `override ?? workflow_backend ?? global`, mirroring `config.effective_backend` plus `workflow.apply_overrides`. `cloudSecretPolicy` calls it, so the key decision and the dispatch decision cannot disagree.
2. **Apple re-summarize through Swift.** In `MeetingLibraryService.regenerateMeeting`, when `backend` is nil and the resolver says `apple_intelligence`, run the Swift Apple summarizer over `<stem>.md` and then `performRepublish`, inside the same lane slot and with the same cancel, ceiling and `writeAppleRunSidecar` behaviour `completeViaAppleIntelligence` has (factor the shared part out rather than copying it). Drive it from the transcript and sidecar anchor, not the audio file, since retention may have removed the audio.
3. **Merge.** `merge_meetings.merge_meetings` hands off with the `apple_pending` sentinel when the effective backend is Apple (the `_check_apple_handoff` shape), and `MeetingLibraryService.mergeMeetings` completes through the step 2 route. If this leg makes the change larger than one reviewable commit, split it into its own task at pickup and say so here.
4. **Preview gate and dispatch.** `canPreviewLocally` becomes per meeting (true when the resolver gives `local` or `apple_intelligence`), and `previewSummary` dispatches on the resolver: Apple to `summarizePreviewViaApple`, otherwise `summarizePreview` with an explicit `--backend local` passed as `backendOverride`, so the run is on-device whatever the workflow pins and `cloudSecretPolicy` strips the Anthropic key for it.
5. Emit the resolved backend on `regenerate_started` and `summary_preview_started` (an attribute, not a new event), so the field log shows which engine each re-run used.

## Explicitly not

- Typing the backend: [ARCH14](./ARCH14.md).
- Apple's unsupported-language fallback: [PIPE25](./PIPE25.md).
- Adding Apple to the Re-summarize with… menu (PIPE6 kept it out on purpose).
- Making Apple a Python provider: [ARCH11](./ARCH11.md).

## Acceptance

- New tests in `MeetingLibraryServiceTests` with the fake driver: a meeting whose sidecar pins `workflow_backend: apple_intelligence` and a global `anthropic`, on Regenerate and on Retry with a reusable transcript, calls the Apple summarizer and then publish and spawns no `mp summarize`; the same meeting with global Apple and no pin does the same; a failed Apple summarize writes the failure sidecar and spawns no publish; a cancel leaves the previous summary and spawns no publish.
- New preview tests: global `local`, sidecar `workflow_backend: anthropic`, non-NDA: the preview is offered and spawns `mp summarize <md> --candidate --backend local` with the Anthropic key stripped; global `anthropic`, sidecar pinned `local`: the preview is offered; global `local`, sidecar pinned `apple_intelligence`: the preview goes to `summarizePreviewViaApple`.
- `PipelineLauncherTests` pins the extracted resolver against the existing `cloudSecretPolicy` cases, which stay green unchanged.
- A pytest in `test_merge_meetings.py`: a merge whose effective backend is Apple writes the sentinel and calls no Python summarizer; its resume branch does the same.
- `bash scripts/ci-local.sh` green (swift test, pytest, ruff, pyright, truth fences) with the new tests counted by the session that writes them.
- README's Summary-tab and Regenerate paragraphs and [docs/GUIDE.md](../../GUIDE.md)'s re-summarize recipe updated in the same commit if any user-visible wording changes (the preview button's label and help must stay true).
