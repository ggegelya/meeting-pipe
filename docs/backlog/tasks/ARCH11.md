# ARCH11: features are implemented in both trees, and the Swift copies drift; write the ADR that fixes the Swift/Python boundary, then make Apple Intelligence a provider only

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) A5, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) DI-14). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

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
