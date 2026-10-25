# PIPE25: Apple Intelligence fails every Ukrainian meeting and the only recovery is a manual local re-summarize; fall back to local automatically on the typed unsupported-language error

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) FQ-13). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-verified against `main` at `45b8c6a` on 2026-10-24.

**Field evidence.** On the assessment Mac, 4 of 5 pipeline runs between 2026-10-12 and 2026-10-18 failed, 3 of them because Apple Intelligence rejected Ukrainian (go-live assessment, Perspective 1, "Pipeline reliability"). The owner's meetings are about 99 percent English or Ukrainian (backlog house rule), so on this backend roughly every Ukrainian meeting needs a hand-off.

**What PIPE6 shipped.** `AppleIntelligenceError.unsupportedLanguage` is raised from `AppleIntelligenceSummarizer.respondSummary` when `isUnsupportedLanguageError(_:)` matches the framework's message, and `errorDescription` embeds `unsupportedLanguageMarker` ("unsupported language or locale") so the Library can recognize it from `<stem>.error.json`. `isDeterministicBackendFailure` is true for it. The Library then shows **Re-summarize with <local>** (`MeetingDetailView`, `meeting.failureSuggestsLocalReSummarize`), which calls `libraryModel.regenerateMeeting(stem:backend: SummarizationEngine.local.id)`.

**What it does not do.** `PipelineLauncher.completeViaAppleIntelligence(wav:completion:)` catches any summarizer error and calls `completion(.failure(error))`. Nothing acts on `isDeterministicBackendFailure`. The meeting lands in Needs you, nothing is published, and the user has to notice, open the Library and click. The rejection is also not cheap: on a long transcript `generate` maps windows one by one, so a rejection on a late window discards the windows that already succeeded.

## Scope

1. **Auto-fallback on the typed error.** In `completeViaAppleIntelligence`, when the summarizer throws `.unsupportedLanguage`, run the same local summarize-and-publish chain the Library's re-summarize uses (a one-shot `backendOverride` of `local`, which `cloudSecretPolicy` already treats as on-device and which regulated and NDA cannot widen), instead of failing. Any other Apple error fails as today.
2. **Pre-check when cheap.** Before the first window, if the meeting's language is known (the ASR-detected language in the transcript JSON, or a pinned `transcription.language`) and the system model reports it unsupported (`SystemLanguageModel` exposes its supported languages on macOS 26; verify the API at pickup), skip Apple and go straight to local, so no window is wasted. A failed or unavailable pre-check falls through to item 1.
3. **Say it happened.** The substitution is a routing fact the user chose against, the PIPE12 precedent: emit one event (for example `summary_backend_substituted` with `requested=apple_intelligence`, `used=local`, `reason=unsupported_language`, and the language), and record it in `<stem>.run.json` so the Library's provenance line reads "Summarized on this Mac with <local model> (Apple Intelligence does not support <language>)".
4. **Fail honestly when local cannot run.** A local model that is not cached or does not fit RAM fails with the existing `model_missing` or `memory` causes and their remedies (Download model, choose a smaller model), not with the Apple error.

## Explicitly not

- Making Apple Intelligence a Python provider (ARCH11's follow-on leg). When that lands, this fallback moves into the provider table (PIPE19) with the same event; until then it lives where the Apple call lives.
- Falling back on other Apple errors (`unavailable`, `parseFailed`). `unavailable` already has its own remedy, and a parse failure is not deterministic.
- A user setting to turn the fallback off. If the owner wants one, it is a workflow flag decided at pickup, not a new global config key (HYG2).
- Falling back to a cloud backend. The user picked an on-device engine; the fallback stays on-device.

## Acceptance

- `PipelineLauncherTests` with an injected summarizer seam: `.unsupportedLanguage` triggers exactly one local summarize with backend override `local` followed by publish, and the completion succeeds; `.parseFailed` still fails; a regulated meeting's fallback still strips both tokens. The first case fails on the current code.
- A test for the pre-check decision as a pure function (language known and unsupported skips Apple; unknown or supported tries Apple).
- The substitution event is in `CONVENTIONS.md`'s event table and `python3 scripts/truth_fences.py events` is green; the `run.json` provenance case is pinned in the Swift run-sidecar tests.
- `cd daemon && swift build` and `swift test` green, new test count in the commit body.
- `docs/GUIDE.md` and the README's Apple Intelligence section say that unsupported languages fall back to the local model, in the same commit.
- Owner walkthrough after install (confirms, not a gate): with the Apple Intelligence backend, record a short Ukrainian meeting; it publishes with a local-model summary and the provenance line names the reason.

## Amended 2026-10-25 (observability audit band)

Source: [observability audit](../../audits/2026-10-25-observability-audit.md), amendments table, finder UI-8. Re-verified against `main` at `01e904a` on 2026-10-25.

**The manual recovery is ranked below the button that fails.** `MeetingDetailView.failureNotice` renders `FailureNotice` with `retryLabel` "Retry summary" inside the notice, and the **Re-summarize with <local>** button sits outside and below it, under `else if meeting.failureSuggestsLocalReSummarize`. The failure's metadata is nil (the Apple error is not a `reportedFailure`), `FailurePresentation.legacy` has no branch for `AppleIntelligenceError.unsupportedLanguageMarker`, so the cause is `.unknown` and the explanation is "Retry when you are ready, or open Details to inspect the failure.". The [GUIDE](../../GUIDE.md)'s section 10 "A meeting that failed" says a language refusal "leads with re-summarizing on the on-device model"; it does not, and the README's Library section says outright that "the plain same-backend retry stays available in the notice".

**Field evidence.** On the audit Mac, meeting `20261016-095827` failed with `Apple Intelligence: unsupported language or locale` at 2026-10-16T07:33:59Z. The owner pressed Retry at 07:38:16Z and again at 07:38:46Z (`retry_requested`, scope `run_all`); each failed identically about 12 s later (`pipeline_failed` at 07:38:28Z and 07:38:59Z). Two futile runs within 30 s, on the 2026-09-11 build; the current code ranks the controls the same way.

**Why this belongs here even after item 1.** The auto-fallback stops new refusals reaching the notice, but every meeting that failed before it shipped keeps its `<stem>.error.json` with this reason, and any path the fallback does not cover lands here too. The notice should not depend on the fallback for its ordering.

### Added scope

5. **A typed cause for the refusal.** Add `FailureMetadata.Cause.unsupportedLanguage` (`unsupported_language`), Swift side only, derived in `FailurePresentation.legacy` from `AppleIntelligenceError.unsupportedLanguageMarker` so old sidecars get it with no rewrite. It is never written into a sidecar's `failure` metadata, so the Python vocabulary and the failure-metadata golden fixture stay unchanged. Heading "Apple Intelligence can't summarize this language"; explanation "Re-summarize it on this Mac with <local model>.". UX94 (`config`) and PIPE28 (`model_rejected`) add causes to the same enum; land them together if they are in flight.
6. **The notice leads with the fix.** For that cause, `FailureNotice`'s primary action is **Re-summarize with <local>** (the existing `regenerateMeeting(stem:backend: SummarizationEngine.local.id)` call, moved inside the notice), and plain Retry is withheld while the meeting's resolved backend is still Apple Intelligence. When the local model is not cached, the primary action is **Download model** (the existing `downloadModel` closure) and the re-summarize follows it, matching item 4's honest-failure rule. Remove the outside-the-notice button and `meeting.failureSuggestsLocalReSummarize`'s separate branch, or have the predicate read the new cause; one source, not two.
7. **Docs in the same commit.** [GUIDE.md](../../GUIDE.md) section 10, "A meeting that failed", the "Some failures lead with a more specific fix" paragraph: name the button. README's Library section: drop "The plain same-backend retry stays available in the notice".

### Added acceptance

- `FailurePresentation` tests: a diagnostics string carrying the marker yields `.unsupportedLanguage` with the new heading and explanation; one without it is unchanged.
- A `FailureNotice` decision test (pure, over which actions are offered and in what order): the cause offers Re-summarize first and no Retry; with the local model missing it offers Download model first.
- Owner check (confirms, not a gate): open the 2026-10-16 meeting `20261016-095827` in the Library; the notice leads with **Re-summarize with <local>** and has no Retry.
