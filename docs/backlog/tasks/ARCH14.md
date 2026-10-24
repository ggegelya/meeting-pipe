# ARCH14: the summarization backend is a String in ConfigStore and three forwarders, so locality and "needs the local model" are re-derived by string comparison at each site

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) B5). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

The daemon has three representations of the same six ids (`anthropic`, `local`, `auto`, `apple_intelligence`, `claude_cli`, `openai`):

- `WorkflowBackend` (`Workflow.swift`), a `String`-backed `Codable` enum for a workflow's pin.
- `SummarizationEngine` (`SummarizationEngine.swift`, UX31), a struct table with `id`, `name` and `locality: Locality` (`.cloud`, `.onDevice`, `.cloudThenLocal`) and `SummarizationEngine.resolve(_:)`. `SummarizationEngineTests` already fences that it stays in lockstep with `WorkflowBackend`.
- `ConfigStore.summarizationBackend: String` (`@Published var summarizationBackend: String`, read with `summ?["backend"]?.string ?? "anthropic"`), forwarded as `String` by `Coordinator.summarizationBackend`, `LibraryWindowModel.summarizationBackend` and the `summarizationBackend: () -> String` closure `MeetingLibraryService` takes.

Because the configured value is a string, each consumer restates a predicate over it. Read on 2026-10-24:

| Site | Predicate | What it means |
|---|---|---|
| `PipelineLauncher` secret policy (`onDeviceSummary`) | `backend == "local" \|\| backend == "apple_intelligence"` | runs on device |
| `LibraryWindowModel.canPreviewLocally` | `summarizationBackend == "local" \|\| summarizationBackend == "apple_intelligence"` | runs on device |
| `MeetingLibraryService` preview dispatch | `summarizationBackend() == "apple_intelligence"` | Apple path |
| `ConfigRefreshCoordinator` | `backend == "local" \|\| backend == "auto"` | may need the MLX model |
| `SetupChecklist.localReachable` | `$0 == "local" \|\| $0 == "auto"` | may need the MLX model |
| `PipelineSectionView` (Preferences) | `store.summarizationBackend == "local" \|\| ... == "auto"` | may need the MLX model |
| `LocalModelPreloader` | `backend == "local"` | preload the MLX model |
| `RegulatedMode.effectiveBackend` | `configured != "local" ? "local" : configured` | clamp under zero egress |
| `SetupChecklist.cloudReachable` | `$0 == "anthropic" \|\| $0 == "auto"` | needs the Anthropic key |

The fallbacks disagree too: `ConfigStore` and both forwarders default to `"anthropic"`, `MeetingLibraryService.init` defaults its closure to `{ "local" }`. The `MeetingLibraryService.summarizationBackend` doc comment lists four values ("local" / "apple_intelligence" / "anthropic" / "auto") where six are dispatched.

Correction to the audit's suggested fix ("replace the predicates with `engine.locality == .onDevice`"): that is right for the two on-device rows and wrong for the three "may need the MLX model" rows. `apple_intelligence` is on device and does not use the MLX model, and `auto` is `.cloudThenLocal` and does. Locality alone cannot express both, so the engine needs a second property. `SetupChecklist.cloudReachable` is really "needs the Anthropic key"; the checklist has no row at all for a missing `OPENAI_API_KEY` when `openai` is configured (observed, not filed; the key rows are a separate question).

## Scope

1. **Type the configured backend.** `ConfigStore.summarizationBackend` becomes a `SummarizationEngine` (or a typed id wrapping one), with an explicit representation for an id this build does not know, so an unknown value read from `config.toml` round-trips on save instead of being rewritten. The three forwarders and `MeetingLibraryService`'s closure return the typed value. One fallback, owned by `ConfigDefaults` (where the other daemon defaults live), replaces the three literals.
2. **Add the properties the predicates need** to `SummarizationEngine`: keep `locality`, and add `usesLocalModel: Bool` (true for `local` and `auto`) and `requiredSecret: String?` (the Keychain account it needs, nil for `local`, `apple_intelligence` and `claude_cli`). Replace every row of the table above with a property read.
3. **Fold `WorkflowBackend` into the same vocabulary** if it can be done without changing the workflow TOML format (its raw values are the file format); if not, give it a `var engine: SummarizationEngine` and keep the lockstep test.
4. Fix the stale four-value doc comment.

## Explicitly not / out of scope

- The Python side: `config.BACKENDS`, the four if/elif dispatch sites and speaker cleanup skipping `openai` and `claude_cli` are PIPE19.
- Whether Swift should derive egress policy at all, or ask `mp policy --json`, is ARCH11. This task makes today's Swift derivation typed; it does not change what it decides. `PipelineLauncher`'s secret policy must strip the same tokens for the same inputs before and after.
- How `config.toml` is parsed and saved (one reader, fail closed) is ARCH9. If ARCH9 lands first, item 1 types the field on the store it leaves; if this lands first, ARCH9 inherits the typed field.
- Run provenance (`<stem>.run.json`'s `backend`, the `workflow_backend` sidecar key) stays a string on disk; it is resolved through `SummarizationEngine.resolve(_:)` as today.
- Adding a checklist row for a missing OpenAI key. `requiredSecret` makes it a one-line change, but whether to nag for it is an owner call.

## Acceptance

- No string comparison against a backend id survives outside `SummarizationEngine.swift` and `WorkflowBackend`: a fence test fails on `== "`, `!= "` or `case "` followed by one of the six ids in any file that also names `backend` or `summarizationBackend`. (A bare `git grep` for the six literals is not the bar: it finds 69 lines in 22 files on 2026-10-24, many unrelated, such as `"auto"` as a transcription language.)
- `SummarizationEngineTests` gains cases for `usesLocalModel` and `requiredSecret` on all six engines, and an unknown id round-trips through `ConfigStore` load and save unchanged (true today because the field is a raw string; the test keeps it true once the field is typed).
- Table-driven tests for `PipelineLauncher`'s secret policy and `SetupChecklist`, run over all six engines, pass unchanged against `main`'s expectations before the refactor and after it (they pin behaviour, so they are written first).
- `cd daemon && swift build` warning-clean, `swift test` green, `python3 scripts/truth_fences.py config` green, `bash scripts/ci-local.sh` green, N new tests in the commit body.
