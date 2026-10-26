---
id: LOCAL20
title: Cancelling a model download reports it as failed, and a failed download has no exit but Retry
category: Local models
status: partial
priority: P2
comment: Filed 2026-08-10 from the owner's 2026-08-04 notes ("there's still indication of failed download that I cannot discard. I can only click retry"). **The banner was manufactured by their own backend switch, proved by one line in their `daemon.log`:** `[2026-08-04T15:00:14.626Z] model prefetch terminated rc=15 state=failed(... "prefetch exited 15")`. `rc=15` is SIGTERM, which is what `ModelDownloadSupervisor.cancel()` sends; the prefetch had run three healthy minutes from 14:57:02Z and was killed 99 s before the 18:01:53 screenshot. Chain: a config persist calls `ensureModelPrefetchIfNeeded`, `prefetchDecision` returns `.cancelAndIdle`, and the apply site correctly cancels then pushes `.idle`, which is why this looks impossible from that file alone. But `cancel()` (`ModelDownloadSupervisor.swift:139`) never touches `state`, so it stays `.downloading`, and `handleTermination` (`:250`) takes **no identity check against `self.process` and no cancel marker**, sees a non-zero exit, and synthesizes `.failed`, firing the observer and putting the banner back. Then nothing clears it: `.completed` auto-collapses on a timer (`StatusBarController.swift:255`) and `.failed` has no such path, no dismiss exists, and Retry re-downloads the model the owner just moved away from. Same hole makes `ensure`'s replace-in-flight path able to report the *previous* model as failed over the new one's `.downloading`. Second-order: `"↓ failed"` outranks the `Processing (N)` clause while idle, so a phantom failure indefinitely suppresses real queue state in the menu-bar title. Scope: an explicit cancelled marker plus a process-identity check, then a dismiss and a rule that a `.failed` for a no-longer-configured model is stale. Keep a real, current failure visible. Worth fixing before LOCAL13's bench exercises the replace-in-flight path across ~33 GB of candidates. **Engineering shipped 2026-08-19; the remainder is the owner walkthrough only.** Both defects fixed. **1, the cancel.** The spec offered two routes and named the second as preferable; it is the one taken, and the `ensure` interaction is why. The pure `ModelDownloadSupervisor.terminationOutcome(isTrackedProcess:state:terminationStatus:)` returns `.ignore` for any process the supervisor is no longer tracking, and `handleTermination` returns **before** its teardown rather than after. That ordering is the part worth reading: the handler also nils `process` and `stdoutHandle` and clears `currentModelId`, so an abandoned prefetch could tear down the download that replaced it, not merely mislabel it. `cancel()` also now leaves `.idle` instead of `.downloading`, so the supervisor stops believing work is in flight; both halves are wanted rather than either alone. **2, the exit that is not Retry.** `.failed` gained `dismissible`, rendered as a `Dismiss` row under the retry row, wired through `ConfigRefreshCoordinator.dismissModelDownloadFailure` so Retry and Dismiss share one collaborator. The staleness rule the spec preferred falls out of the cancel fix rather than needing its own reconciliation pass: `.cancelAndIdle` cancels, and a `.failed` for a model being switched away from does not survive that; pinned by its own test. One seam added to production for testing, an `init(state:)` defaulted to `.idle`, because reaching `.failed` honestly needs a network failure; injection rather than a test-only setter, matching how `ConfigRefreshCoordinator` already takes its supervisor. 11 tests added, including the second-order cost the spec named: a phantom failure suppressed `Processing (N)` in the menu-bar title indefinitely, so clearing it has to give that clause back. `swift build` clean, `swift test` 2788 tests 0 failures, truth fences and dash guard clean, no pipeline change. Docs: `README.md` (its download paragraph said Retry was the only affordance), `ARCHITECTURE.md`, and `daemon/docs/gotchas.md` for the reusable lesson, that a terminating subprocess must prove it is still the tracked one, with the owner's `rc=15` line as its evidence. `docs/GUIDE.md` checked and unaffected: its Retry recipes are about the Library's failed-meeting rows, a different surface. No design mock models the menu-bar download row at all, so there was nothing to re-mock; `MenuBarDropdown`'s wider lag is already DSN30's. **Owner-owed:** the walkthrough, proposed weight `complex` rather than `simple` because step 2 pulls several GB and asks the owner to wait past the 99-second mark the original defect appeared at, and step 3 wants Wi-Fi off; no meeting or call audio is involved, so neither weight fits cleanly and the owner should pick. Needs the owner's approval before the row moves to `owner-verification.md`.
---

# LOCAL20: cancelling a model download reports it as failed, and a failed download has no exit but Retry

Band origin: filed 2026-08-10 from the owner's 2026-08-04 testing notes, with a screenshot of the menu at 18:01: "when the state is failed and after I switch back to Anthropic or other local existing model, there's still indication of failed download that I cannot discard. I can only click retry, and then it disappear. non obvious overall." The investigation found the banner was manufactured by the owner's own switch. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## What the owner's log proves

One line settles it, from `~/Library/Logs/MeetingPipe/daemon.log` (timestamps are UTC, the owner is UTC+3):

```
[2026-08-04T15:00:14.626Z] model prefetch terminated rc=15 state=failed(modelId: "mlx-community/Ministral-8B-Instruct-2410-4bit", error: "prefetch exited 15")
```

**`rc=15` is SIGTERM**, which is precisely what `ModelDownloadSupervisor.cancel()` sends. Nothing failed. The prefetch began at 14:57:02Z (17:57 local), ran for about three minutes of healthy Hugging Face traffic, and was killed at 15:00:14Z (18:00:14 local), 99 seconds before the owner's 18:01:53 screenshot of "⚠ Model download failed (Ministral-8B-Instruct-2410-4bit) - Retry".

So the banner the owner could not discard was not a stale failure they were trying to clear. It was created by the act of switching away.

## The chain, re-derived from source on 2026-08-10

1. The owner changes the summarization backend or local model. `ConfigStore` persists, and `ConfigRefreshCoordinator.handleConfigPersisted` ([:93](../../../daemon/Sources/MeetingPipe/Coordination/ConfigRefreshCoordinator.swift#L93)) calls `ensureModelPrefetchIfNeeded`.
2. `prefetchDecision` ([:49](../../../daemon/Sources/MeetingPipe/Coordination/ConfigRefreshCoordinator.swift#L49)) returns `.cancelAndIdle` for any non-local, non-auto backend, and the apply site ([:139](../../../daemon/Sources/MeetingPipe/Coordination/ConfigRefreshCoordinator.swift#L139)) does the right thing in the right order:

```swift
case .cancelAndIdle:
    modelDownload.cancel()
    onModelDownloadState(.idle)
```

So the banner is cleared, correctly, at this instant. This is why the defect looks impossible when you read only this file.

3. `cancel()` ([ModelDownloadSupervisor.swift:139](../../../daemon/Sources/MeetingPipe/ModelDownloadSupervisor.swift#L139)) calls `p.terminate()`, then clears `process`, the stdout handle, the buffer, and `currentModelId`. **It does not touch `state`**, which is still `.downloading`, and `terminate()` is asynchronous, so the process is not dead yet.
4. The process dies and `handleTermination` ([:250](../../../daemon/Sources/MeetingPipe/ModelDownloadSupervisor.swift#L250)) runs:

```swift
// Non-zero exit without a prior "failed" event - synthesize the failure state.
if case .downloading(let modelId, _, _, _) = state, proc.terminationStatus != 0 {
    state = .failed(modelId: modelId, error: "prefetch exited \(proc.terminationStatus)")
}
```

It takes no identity check against `self.process` and knows nothing about the cancel, `state` is still `.downloading` because step 3 left it alone, and SIGTERM is a non-zero exit. So it synthesizes a failure, `state`'s observer fires `onStateChange`, and the banner comes back, now claiming a failure that never happened.

5. Nothing clears it. `StatusBarController.setModelDownload` ([:255](../../../daemon/Sources/MeetingPipe/StatusBarController.swift#L255)) gives `.completed` an auto-collapse timer back to `.idle` and gives `.failed` **no equivalent path**. There is no dismiss affordance. The row is `retryable: true` ([StatusBarModel.swift:374](../../../daemon/Sources/MeetingPipe/StatusBarModel.swift#L374)) and Retry is the only exit, which re-downloads the model the owner deliberately moved away from. That is exactly the owner's "I can only click retry, and then it disappear."

The supervisor is also left internally inconsistent: `currentModelId` was cleared in step 3 and again at the end of step 4, so it holds `.failed(modelId:)` for a model it is no longer tracking.

## Second-order cost, worth naming

`downloadTitleClause` ([StatusBarModel.swift:181](../../../daemon/Sources/MeetingPipe/StatusBarModel.swift#L181)) maps `.failed` to `"↓ failed"`, and `applyTitle` ([StatusBarController.swift:283](../../../daemon/Sources/MeetingPipe/StatusBarController.swift#L283)) gives the download clause priority over the processing clause while idle. So a phantom failure also suppresses `Processing (N)` in the menu-bar title indefinitely. The owner's screenshot shows `↓ failed` in the menu bar with "24 meetings failed" sitting below it in the menu, so the one clause the title had was spent on the untrue thing.

## Scope

Two defects. Fix the first and the second stops firing spuriously, but both are worth fixing, because a genuine failure should also be dismissible.

**1. A cancelled download is not a failed download.** Make `cancel()` and `handleTermination` agree. Two options, and the second is the one to prefer:

- Have `cancel()` set `state = .idle` before terminating. Simple, but it races: the termination handler still runs later and its `if case .downloading` guard is what happens to save it, which is fragile reasoning to depend on.
- Give the supervisor an explicit cancelled marker, and have `handleTermination` check both that marker and the process identity (`proc === self.process`, which is nil after a cancel) before synthesizing anything. This also fixes the abandoned-process case in `ensure`, where replacing an in-flight download with a different model calls `cancel()` then `spawn()`, so the old process's termination can currently write `.failed` over the new download's `.downloading` state.

The second option is the real fix, and the `ensure` interaction is the reason: today a model switch mid-download can report the *previous* model as failed while the new one is running.

**2. `.failed` needs an exit that is not Retry.** A dismiss on the menu row, and a rule for when it self-clears. The obvious rule, and the one that matches what the owner expected: a `.failed` state for a model that is no longer the configured one is stale by definition and should not be shown. `prefetchDecision` already knows the configured backend and model, so the state can be reconciled against them instead of persisting on its own.

Keep the failure visible when it is real and current. A genuine download failure for the model the app is about to summarize with is exactly the sort of thing the menu bar is for, and the comment at `StatusBarModel.swift:372` is right that clicking to retry is the useful action there.

## Explicitly not / out of scope

**Not the prefetch subprocess or `mp prefetch-model`.** It ran correctly for three minutes and then received SIGTERM. Nothing in the pipeline is implicated.

**Not the "24 meetings failed" row** in the same screenshot. That is a different surface with its own retry path and the owner did not report it as wrong.

**Not the `.completed` auto-collapse timer.** It works and is the model for what `.failed` lacks.

**Not the eager-prefetch policy.** Whether the daemon should prefetch on launch, and `LocalModelPreflight`'s deliberate manual download for a workflow-level local backend under a global cloud one (UX21), are both unchanged.

**Not LOCAL13's candidate churn.** That bench downloads roughly 33 GB across many models and will exercise `ensure`'s replace-in-flight path repeatedly, which is a reason to fix defect 1 before it runs, not a reason to widen this task.

## Acceptance

- A `ModelDownloadSupervisor` test cancels an in-flight download, then delivers a termination with a non-zero status, and asserts the state is **not** `.failed`. It must fail against `main`, which synthesizes the failure. This is the reported defect and the SIGTERM log line above is its fixture.
- A test drives `ensure` with a second, different model while the first is downloading, then delivers the first process's non-zero termination, and asserts the new download's state survives. This is the abandoned-process case, which is reachable today and was not reported.
- A test asserts a genuine non-zero exit with no cancel still produces `.failed`, so the fix does not blind the real case.
- A test asserts a `.failed` state whose model is no longer the configured local model does not reach the menu, or is dismissible, per whichever rule ships.
- A test asserts the menu-bar title stops preferring the download clause once the failure is cleared, so `Processing (N)` is reachable again.
- `cd daemon && swift build` clean, `swift test` green, with the number of tests this task adds recorded in the ship note. Do not pin an absolute suite total.
- No em-dashes in changed lines; repo dash guard green.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts. Note step 2 downloads several GB, so run it when that is acceptable.

1. [session] `./scripts/rebuild.sh` after landing, then tell the owner it is ready.
2. [owner] Reproduce the report deliberately: in Preferences ▸ Pipeline set the backend to Local with a model that is **not** cached, let the download run for a few seconds, then switch the backend back to Anthropic. Pass: no failure banner appears, at the switch or in the minute after it. The original defect appeared about 99 seconds later, so wait before calling it clean. **Set the backend back to Anthropic when done if it is not already.**
3. [owner] Then the real-failure check: with the backend on Local, turn off Wi-Fi and pick an uncached model so the prefetch genuinely fails. Pass: the failure does appear, and you can dismiss it without clicking Retry.
4. [owner] While a phantom-free state is showing, queue a re-transcribe and confirm the menu-bar title shows the processing clause rather than a download clause.
5. [owner] Say "LOCAL20 good to close" (or what is wrong); [session] moves the row and this spec into `q6-final.md` and deletes this file.
