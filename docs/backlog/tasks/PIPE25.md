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
