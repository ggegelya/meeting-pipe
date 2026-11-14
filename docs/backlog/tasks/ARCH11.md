---
id: ARCH11
title: Features are implemented in both trees, and the Swift copies drift; write the ADR that fixes the Swift/Python boundary, then make Apple Intelligence a provider only
category: Architecture
status: new
priority: P2
comment: Filed 2026-10-24 (audit band, arch A5, go-live DI-14): the Swift Apple summarizer has its own prompt, schema, chunking and renderer and has drifted (no WF7 extra_sections, prior context, evidence or language repair); prep, doctor and egress rules are doubled; DIST2's hybrid dismissal is stale. Owner-approved ADR on the boundary first, then Apple as a provider only and Swift asking Python for policy. Amended 2026-11-12 ([security review](../../audits/2026-11-12-security-review.md)): the Swift Apple summarizer also has no untrusted-content fence or guidance; becoming a provider closes it. [Spec](./ARCH11.md) Amended 2026-11-12 (upgrade review): on macOS 27.2 SystemLanguageModel.default.contextSize is 8192, not the 4096 AppleIntelligenceSummarizer hard-codes, and the 27 SDK adds PrivateCloudComputeLanguageModel, off-device inference that regulated and NDA mode must never reach. Amended 2026-11-13 by the audit band: the Swift summarizer also skips the speaker-label and correction overlays and the flagged-moments block and writes outside pydantic, so Python composes one input and an mp verb writes the result (F108, F125).
---

# ARCH11: features are implemented in both trees, and the Swift copies drift; write the ADR that fixes the Swift/Python boundary, then make Apple Intelligence a provider only

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) A5, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) DI-14). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Re-verified against `main` at `45b8c6a` on 2026-10-24.

**The Apple Intelligence summarizer is a second summarizer, not a provider.** [`AppleIntelligenceSummarizer.swift`](../../../daemon/Sources/MeetingPipe/Summarization/AppleIntelligenceSummarizer.swift) (484 lines) owns its own instruction prompt (`instructions(teamContext:summaryLanguage:)`, whose doc comment says it "does not reuse the Python `meeting_summary.md` master prompt"), its own schema string (`schemaDirective`), its own JSON recovery (`parse`, `largestJSONObject(in:)`), its own map and hierarchical reduce (`generate`, `batched`, `renderForReduce`), and its own markdown renderer (`renderMarkdown`, pinned against Python's by the CI3 golden fixture). It has already drifted from the Python path in `pipeline/src/mp/summarize.py`:

- `schemaDirective` lists `title, summary, decisions, actions, questions, attendees, detected_language` and never asks for `extra_sections`, so a workflow's WF7 sections (`_extra_sections_directive`) are never filled on this backend, although `renderMarkdown` renders them if present.
- No prior-meeting context (`_prior_meeting_context`), no evidence verification (`_verify_evidence`), no cross-backend language repair (`_verify_and_repair_language`).
- Team context comes from `PipelineLauncher.appleContext(for:)`, a separate config read (see ARCH9).

**Other doubled features**: Prep (`PrepCard.swift`, 212 lines, against `prep.py`, 317), doctor (`CLI/DoctorCommand.swift`, 415, against `doctor.py`, 848), and the zero-egress rules (`PipelineLauncher.cloudSecretPolicy` re-derives "regulated forces local" and the workflow override from the sidecar, while Python owns `config.effective_backend` and `zero_egress`). The `cloudSecretPolicy` comment itself admits its strip is defense-in-depth only, because the Python child re-reads tokens from the Keychain in `load_secrets()`. `CONVENTIONS.md#cross-tree-golden-fixtures` lists the fixtures that exist mainly to keep twins in sync.

**The decision record is stale (DI-14).** DIST2 (archived in [`q4-final.md`](../q4-final.md)) dismissed porting the pipeline, and [I7](./I7.md) gates "drop Python entirely" on an MLX-Swift candidate LOCAL12 found does not exist. The go-live assessment costed a third shape, porting orchestration, cloud summarizers and publishers to Swift and keeping Python as an optional local-model server, at about 10k LOC and 6 to 10 weeks, and called DIST2's dismissal of it stale. Nothing in `docs/decisions/` says which tree owns what, so each new feature picks a side by convenience.

## Scope

1. **The ADR (this task's deliverable, owner-approved before any code moves).** `docs/decisions/<next free>-swift-python-boundary.md` in MADR form. The next free number at filing is 0017; 0012 and 0013 were named in q3 specs but never written, so do not reuse them. It decides:
   - Python owns model services and the summarize-and-publish pipeline: prompts, schemas, rendering, evidence, language repair, sinks. Swift owns capture, transcription, UI and scheduling. No feature is implemented in both trees; an existing twin is either retired or recorded as a deliberate exception with its reason.
   - Apple Intelligence becomes a provider only: the daemon exposes a completion primitive (for example `MeetingPipe fm-complete`, prompt on stdin, raw text out), Python calls it like any other provider, and Python renders everything.
   - Swift asks Python for egress decisions instead of re-deriving them (for example `mp policy --json` per meeting, or the resolved policy written into the sidecar by run-all). The ADR must cost the spawn: `cloudSecretPolicy` runs before every `mp` spawn, so a second Python start per spawn is a latency the ADR accepts or designs out.
   - The hybrid (port orchestration and publishers to Swift) and the full port (I7) as considered options, each with the trigger that would reopen it, replacing DIST2's dismissal.
   - Which existing twins are retired, in what order, and which stay (Prep and doctor each get a line).
2. **Follow-on legs, each its own commit after approval, filed or amended here as the ADR orders them.** The first is the provider conversion: the Swift summarizer shrinks to the completion primitive plus availability, `orchestrate._check_apple_handoff` and the `apple_pending` sentinel go, and the provider table PIPE19 introduces gains an `apple_intelligence` row.

## Explicitly not

- Porting anything to Swift or deleting Python. The ADR records those options; it does not choose them by default.
- The automatic local fallback for Apple Intelligence's unsupported-language error. PIPE25 ships it now in Swift; once the provider conversion lands it moves into the provider table with the rest.
- Locale-aware prompt behaviour for the on-device model (LOCAL7's directive). It moves with the prompt; it is not redesigned here.
- The surface cut of secondary features (FEAT18). Some twins may simply be deleted there; the ADR should cite FEAT18's outcome where it overlaps rather than decide it twice.

## Acceptance

- The ADR exists, is linked from the README's "Why it is shaped this way" section and from `ARCHITECTURE.md`, and carries the owner's approval date. Until then no code leg starts.
- The ADR names every doubled feature found at pickup (re-grep, do not copy this list) with a keep or retire verdict.
- For the provider leg, when it is picked up: an Apple Intelligence summary has the same prompt, `extra_sections`, prior context, evidence verification and language repair as the local backend (a Python test with a fake `fm-complete` pins each), `cd daemon && swift test` and `cd pipeline && uv run --extra dev pytest -q` green with new test counts in the commit body, the CI3 renderer golden fixture retired or regenerated with its retirement noted in `CONVENTIONS.md`.
- `python3 scripts/truth_fences.py links` green on the filing and on the ADR commit.

## Amended 2026-11-12 (security review)

From the [security review](../../audits/2026-11-12-security-review.md) finding 11 (verified, Low). `AppleIntelligenceSummarizer` builds its prompt as header + schema + raw body (`let prompt = header + ... + body`); neither `instructions()` nor `reduceInstructions` carries `UNTRUSTED_GUIDANCE`, and the body is not fenced, so this backend lacks TECH-SEC6's soft defence. The on-device model has no tools, so the consequence is steered summary content only, more likely on a weaker model.

Added acceptance: once Apple is a completion provider, a test that its prompt is the Python-composed one, with the transcript between the untrusted markers. If this task stays unstarted for long, the interim fix (wrap the body and append the guidance in Swift) is small enough to land on its own.

## Amendment 2026-11-12 (upgrade review)

**Context size.** A scratch probe on the owner's Mac (macOS 27.2, 2026-11-12) printed:
- `SystemLanguageModel.default.availability`: `available`;
- `SystemLanguageModel.default.contextSize`: `8192`.

`AppleIntelligenceSummarizer` documents "The system model's context is 4096 tokens TOTAL" and sizes `maxWindowChars = 1000` for it.

In the 27 SDK's FoundationModels interface, `contextSize` is `@available(macOS 26.0)` with `@backDeployed(before: macOS 26.4)`, and `tokenCount(for:)` (prompt, instructions, schema, transcript entries) is `@available(macOS 26.4)`. So the window can be sized from the model rather than a constant. On 27 that roughly halves the map calls.

**Private Cloud Compute.** The 27 SDK adds `PrivateCloudComputeLanguageModel` (`@available(macOS 27.0)`), which runs inference off the device. Nothing in `daemon/Sources` references it today.

Added scope:
- When Apple becomes a completion provider here, size windows from `contextSize` / `tokenCount(for:)` behind `#available(macOS 26.4, *)`, keeping the constant as the fallback below that.
- Add a source fence, like `mcp_serve`'s transport fence, that fails if `PrivateCloudComputeLanguageModel` appears anywhere a regulated or NDA run can reach.

Added acceptance: a test that the window size follows an injected `contextSize`, and the PCC fence.

## Amendment 2026-11-13 (audit band)

From the [independent audit](../../audits/2026-11-12-independent-audit.md) F108 and F125 (both confirmed), re-verified in code at HEAD on 2026-11-13. The Context above lists the missing extra sections, prior context, evidence checks and language repair; four more gaps are named nowhere.

- **No overlays.** `AppleIntelligenceSummarizer.summarizeFile(transcriptMD:teamContext:summaryLanguage:outputSuffix:onCall:)` reads the file it is handed with `String(contentsOf: transcriptMD, encoding: .utf8)` and summarizes that text. Both callers hand it the raw `<stem>.md`: run-all's hand-off (`orchestrate._check_apple_handoff` writes `"transcript_md": str(t["md"])` into `<stem>.apple_pending.json`, which `PipelineLauncher.onDeviceSummarize` passes through) and the Apple candidate re-run (`MeetingLibraryService.previewSummary` builds `\(stem).md` and calls `PipelineLauncher.summarizePreviewViaApple` when `summarizationBackend() == "apple_intelligence"`). `summarize.py` instead composes `transcript_corrections.overlaid_structured(transcript_md)` (falling back to `overlaid_markdown`), so a meeting whose speakers were renamed or whose lines were corrected in the Library is re-summarized on this backend with the old labels and the uncorrected text, while the same re-run on local or anthropic reflects both.
- **No flagged moments.** `summarize.py` appends `flagged_moments_block(transcript_md)` (FEAT8, read from `<stem>.markers.json`) and sets `flagged_note` so the system prompt tells the model to reflect them. The Swift summarizer never reads `<stem>.markers.json`, so flags pressed during a recording are ignored on the first summary and on every re-run, with no warning.
- **The write bypasses the pipeline's schema.** `AppleIntelligenceSummarizer.write(summary:transcriptMD:suffix:)` serialises `summary.jsonObject()` and writes it with a plain `data.write(to: jsonURL)`, so pydantic's `ActionItem._scrub_owner` (`clean_person`), the evidence cap and the field limits never run on this backend's output. The non-atomic, default-permission write is [PIPE30](./PIPE30.md)'s, the schema shapes `mp publish` later rejects are [PIPE54](./PIPE54.md)'s, and the unscrubbed owner reaching the MCP surface is noted in [AUTO8](./AUTO8.md); this amendment owns only the fact that a second writer exists outside the contract.
- **Unsupported workflow features are invisible.** Nothing in the workflow editor or the prompt says that extra sections, flags and overlays do not apply on `apple_intelligence`.

The audit's scenario, read from code and not reproduced on the owner's Mac: a workflow with an extra section and two flagged moments on the Apple backend produces a summary with neither, and after a speaker rename the Apple preview still shows the old label.

**Added to scope:** the provider conversion in item 2 is where this closes. Python composes one model input for the daemon (the overlaid transcript, the flagged block with its trusted instruction, the extra-section spec, the untrusted fence from the 2026-11-12 amendment), and the Apple result is validated and written through an `mp` verb (pydantic plus `storage.atomic_write_text`), so one contract owns `summary.json`. If the ADR orders the provider conversion late, the interim is the cheaper leg: the workflow editor marks extra sections and flag reflection as unsupported when the effective backend is `apple_intelligence`, and the run logs a `pipeline` event naming the skipped features.

**Added to acceptance:** with a fake `fm-complete`, a Python test per gap: the composed prompt carries a renamed speaker label from `<stem>.speaker_labels.json`, a corrected line from `<stem>.transcript_corrections.json`, the flagged block from `<stem>.markers.json` and the workflow's extra-section directive; a test that an Apple result carrying an owner with an email address is written with the owner dropped, through the same writer `summarize` uses. If the interim leg lands first, a Swift test that the workflow editor shows the unsupported note for `apple_intelligence` and not for `local`.

Related tasks filed by the same band: [PIPE52](./PIPE52.md) (the effective backend a re-run resolves), [PIPE54](./PIPE54.md), [PIPE30](./PIPE30.md), [AUTO8](./AUTO8.md), [PIPE25](./PIPE25.md), [LOCAL24](./LOCAL24.md).
