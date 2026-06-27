# Meeting-level data-view UX

Research note, 2026-06-26. Decision-grade synthesis of a competitor survey plus repo grounding, with an adversarial fact-check folded in.

## Question

Does meeting-pipe need a view that operates at the **meeting / facts altitude** (people, decisions, topics, open actions, meeting types seen *across* meetings) rather than the **recording / file altitude** the Library has today? If yes: build directly, or spike first? And concretely, what should it be?

Today the Library is a `NavigationSplitView` at recording altitude: a list of recordings plus a three-tab detail (Summary / Transcript / Audio). Cross-meeting facts are extracted and sitting on disk, but the only places they surface are two CLI-only tools (`mp ask`, `mp actions`) and a single meeting's Summary tab. There is no cross-meeting "data view".

Short answer: yes, a facts-altitude view earns its place, but as a **derived, read-only, zero-egress** layer built from facts already on disk. The two capabilities that depend on data quality this research could not inspect (a People view, a local cross-meeting chat) should be **spiked before committing**. The heavy, CRM-shaped end (talk-time coaching, scorecards, pipeline) is out of register and should be skipped.

## What the mature tools do (competitor scan)

The market has converged on a small number of patterns. They sit on a lightweight (local-first, derived, zero-maintenance) to heavy (CRM-like, user-maintained, coaching-oriented) axis.

### Pattern A. Entity page from backlinks (lightweight, the natural fit)

The person/company page is *derived* from existing references, not a record the user maintains.

- **Obsidian Bases** (a core plugin: native database views over Markdown front-matter) is the cleanest reference. A Person note embeds a view filtered by `attendees.contains(this.file.name)`, which resolves to "the meetings whose attendees contain this person." Data stays in local Markdown; only the view logic lives in a `.base` file. This maps almost one-to-one onto meeting-pipe's typed `attendees` field and is the lowest-egress, most local-first model available. ([Bases syntax](https://help.obsidian.md/bases/syntax), [got.md Bases guide](https://got.md/obsidian-bases/))
- **Reflect / Mem** build the same thing through backlinks: referencing a person note in a meeting note makes that meeting appear in the person's incoming backlinks, building an activity feed of every meeting with that person. ([Reflect backlinks/tags](https://reflect.academy/using-backlinks-and-tags), [Reflect AI backlinks](https://reflect.app/blog/automatically-add-backlinks-using-ai))
- **Granola** ships explicit **People and Companies** views: clicking a person surfaces every note with them in one place. It positions this as deliberately lightweight, explicitly *not* a heavy CRM. The window is plan-gated (last 30 days on free/basic; "every meeting ever captured" as full relationship history on Business). ([Granola People & Companies](https://docs.granola.ai/help-center/people-and-companies), [Granola free vs paid](https://www.granola.ai/blog/granola-free-vs-paid-features-each-plan))

### Pattern B. Database plus saved views (medium weight, power-user)

- **Notion**: a meeting-notes database where each meeting is a row with Person / Multi-select / Date / Select properties. Users filter (by person, by meeting type), group (a board grouped by a person or select property), and sort, with each saved view holding its own settings. Powerful, but the user maintains the schema and properties by hand, which is heavier than a derived view. ([Notion views, filters & sorts](https://www.notion.com/help/views-filters-and-sorts), [using database views](https://www.notion.com/help/guides/using-database-views))

### Pattern C. Ask across the corpus (cross-meeting chat with citations)

Every modern competitor has converged on a conversational cross-meeting query, always with **source citations back to specific meetings and timestamps**.

- **Granola** folder chat: ask questions across multiple meetings at once; answers come back with inline citations that double-click into the original transcript. ([Granola chatting with your meetings](https://docs.granola.ai/help-center/getting-more-from-your-notes/chatting-with-your-meetings))
- **Otter AI Chat** answers questions from the full meeting history (for example "what has this client said about budget across the last three calls?"). ([Otter](https://otter.ai/))
- **Fathom "Ask Fathom"** is a chat interface over all meetings. ([Fathom](https://www.fathom.ai/overview))

This is exactly the semantic-RAG upgrade `ask.py` already names as its follow-up. The privacy-respecting version is local embeddings plus citations, with no cloud call when NDA/regulated.

### Pattern D. Action inbox

- **Otter "My Action Items"** (shipped Aug 2024) is the reference: a single centralized view of tasks across all meetings, each linking back to the exact conversation moment, plus a weekly digest. meeting-pipe's `mp actions` already computes this aggregation; it needs a daemon surface and a done flag. ([Otter My Action Items](https://otter.ai/blog/streamline-workflows-with-my-action-items-otter-ai-can-now-keep-track-of-all-your-action-items-across-all-your-meetings))

### Pattern E. Dashboards and trends (the heavy, CRM-like end, mostly out of register)

- **Fireflies** Conversation Intelligence: a Topic Tracker (keywords to conversation/mention counts across meetings), speaker talk-time, sentiment, monologue detection. **Correction to the raw finding:** Topic Tracker and individual-level talk-time analytics are available from **Pro** up, not Business/Enterprise only; only *team*-level analytics (speaker balance across people, org rollups) is Business+. ([Fireflies pricing](https://fireflies.ai/pricing), [Fireflies analytics guide](https://guide.fireflies.ai/articles/2608597716-understand-fireflies-analytics-and-conversation-intelligence))
- **Fathom** team analytics: talk ratios, speaking patterns, AI scorecards for coaching. ([Fathom](https://www.fathom.ai/))

The trend/coaching dashboards are oriented to *managing other people* (talk-ratio coaching, scorecards, pipeline CRM). That is the loud, CRM-like end and runs against meeting-pipe's quiet, local-first, single-user register (PRODUCT.md anti-references). The one analytic that arguably fits a single user is a self-directed talk-time view; everything multi-person-coaching-shaped is out of register and should stay out.

## On-device feasibility (honest about latency, quality, RAM)

The proposed work splits cleanly into a **read-only aggregation** layer (no model call at all) and a **model-dependent** layer (entity dedup, semantic RAG).

**Latency is not a blocker.** MLX sustains roughly 150-230 tok/s for sub-7B models on M-series silicon, with single-digit-millisecond per-token latency; the gap to llama.cpp/Ollama only matters at 27B+ where memory bandwidth dominates. Entity dedup, decision aggregation, and RAG over a personal-sized corpus are all well inside this envelope. ([MLX vs llama.cpp on Apple Silicon](https://groundy.com/articles/mlx-vs-llamacpp-on-apple-silicon-which-runtime-to-use-for-local-llm-inference/), [Apple Silicon LLM benchmarks](https://llmcheck.net/benchmarks))

**Local RAG is production-shaped.** A Qwen3-embeddings-MLX server exists (0.6B / 4B / 8B, REST, batch, hot-swap) with documented throughput on M2 Max. The `ask.py` "semantic RAG via the reused MLX model" follow-up is feasible on-device with no cloud call. ([qwen3-embeddings-mlx](https://github.com/jakedahn/qwen3-embeddings-mlx))

**Quality, not speed, is the risk.** The NER and small-model literature is consistent: small/local models are inconsistent run-to-run (studies run extraction multiple times and average to cope with non-determinism), and even large models lag on *recall* for entity extraction; small models reach parity only when fine-tuned for the specific task. ([SLM survey](https://arxiv.org/html/2501.05465v1), [LLM NER reproducibility](https://link.springer.com/article/10.1007/s40264-024-01499-1)) This is the technical reason a People view built on raw `attendees` is risky and a local cross-meeting chat needs grounded, verifiable citations rather than free prose.

**RAM** is not a constraint at the model sizes in play (sub-7B chat plus a 0.6-4B embedder fit comfortably in unified memory on the target hardware); the embedder can be the same family already pulled for summarization, so there is no new large download for the aggregation layer.

## What meeting-pipe already has to build on

The framing is accurate and the infrastructure is substantially in place. Verified by reading the files:

- **Typed facts on disk, per meeting.** `pipeline/src/mp/schemas.py` defines `MeetingSummary` with the exact pivot fields competitors charge for: `attendees: list[str]` (line 36), `decisions: list[str]` (33), `actions: list[ActionItem]` (34), `questions` (35), `detected_language` (37). `ActionItem` carries `task` / `owner` / `due` / `confidence` (15-19) and **no resolved/done flag**. Both `attendees` and `owner` pass an untrusted-field scrub (`_scrub_attendees`, `_scrub_owner`).
- **Swift already mirrors the schema.** `daemon/Sources/MeetingPipe/Library/MeetingSummary.swift` is a tolerant decoder over `decisions` / `actions` / `questions` / `attendees` (lines 19-22), so the daemon can read typed facts today without new parsing. `ActionItem` here also has no done flag (26-29).
- **Two cross-meeting engines exist, CLI-only.**
  - `pipeline/src/mp/actions.py` aggregates `actions` across every `<stem>.summary.json`, filters by `--owner` / `--due-before` / `--min-confidence`, sorts soonest-due-first, has a `--json` mode. Its own docstring (lines 1-9) flags the gap: there is no resolved flag in the schema, so **every extracted action counts as open**; "a resolved/done flag (and the UI to set it) is the named follow-up."
  - `pipeline/src/mp/ask.py` is a stdlib-only TF-IDF lexical ranker over `<stem>.summary.json` plus `<stem>.md`. Its docstring (lines 5-7) names "true on-device semantic RAG (embeddings + a vector index over the same library, reusing the MLX model)" as the follow-up it paves the way for.
- **The scope/smart-folder system is date/status/workflow-only.** `daemon/Sources/MeetingPipe/LibraryScope.swift` enumerates `allMeetings / today / last7Days / last30Days / needsYou / ndaOnly / untagged / workflow(id)` (lines 5-12). `needsYou` is the closest existing thing to a facts pivot, but it pivots on *pipeline status* (failed run, paste-ready), not on meeting content. There is no `person(...)`, `decision`, or `topic` scope. The sidebar is a natural insertion point for a new "People" section.
- **Meeting-type taxonomy already exists.** The sidecar (`CONVENTIONS.md` lines 200-223) persists `workflow_name`, `workflow_color`, `workflow_emoji` per meeting, so "pivot by meeting type" is already modeled, just not surfaced as a data view.
- **The privacy clamp is real and load-bearing.** `meta.json` carries `workflow_nda_mode` (forces backend=local + sinks=filesystem) and top-level `regulated_mode` (CONVENTIONS lines 220-221). The egress firewall (`pipeline/src/mp/egress_guard.py`) routes all outbound HTTP through httpx's default transport and raises on any non-loopback host; it is armed by `arm_for_config(cfg)` (called in `diarize_cleanup.py:125`). Any new intelligence must route through the configured engine and respect this clamp.

**The actual gaps:**

1. No daemon UI surfaces `mp ask` or `mp actions` at all; both are terminal-only.
2. No **person entity**: `attendees` are free-text, LLM-inferred from speaker labels, scrubbed by the validator, never deduplicated or rolled up. They are noisy and inconsistent across meetings ("Alex" / "Alex Chen" / "Speaker 2").
3. No **decision** or **topic** index across meetings (the data is in `decisions[]`; nothing aggregates it the way `actions.py` aggregates actions).
4. No **open/done state** on actions, so any "open actions" view inherits the "everything is open" limitation until a resolved flag lands.
5. No **trends/analytics** of any kind.

## Recommendation

Per capability, build / spike-then-decide / skip:

- **Decisions and topics index, plus surfacing `mp actions` in the daemon: BUILD.** This is the zero-egress, read-only, data-already-on-disk layer. It respects the engine and clamp by construction (no model call, no new egress), mirrors the proven `actions.py` aggregation shape, and is the highest-leverage low-risk win. A new "data view" altitude reachable from the existing rail, rendering decisions and open actions aggregated across the library, with each item linking back to its `<stem>`.
- **An open/done flag on actions: BUILD (sequenced first where it matters).** An honest "open actions inbox" is dishonest until a `resolved` (or status) flag exists; today every extracted action counts as open. This is a schema change, not a rendering task: it touches `schemas.py`, the Swift mirror, and the sidecar/summary contract, and must stay compatible with the tolerant decoders. It is the unblock for a truthful action inbox, and it is a small, well-scoped change. Treat it as a correctness fix that gates the inbox view, not a net-new feature.
- **People view: SPIKE-THEN-DECIDE.** The single biggest unknown is attendee quality on the real corpus. `attendees` are LLM-inferred and inconsistent across meetings; the NER literature says this noise is intrinsic, not a prompt detail. A People view is only as trustworthy as its dedup/naming. FEAT3-ROSTER (voiceprint naming, P2, depends on FEAT3-VOICEPRINT) and CAL1 (calendar-seeded identity) are the real upstreams. The spike: inspect real `summary.json` files, measure dedup hit-rate, and decide whether a People altitude is trustworthy now or must wait for ROSTER. Do not build a People view on raw `attendees` first.
- **Cross-meeting semantic chat ("ask across"): SPIKE-THEN-DECIDE.** Latency is settled; quality and citation grounding on *this* corpus with the *configured local engine under the clamp* are not. The spike: on a handful of real meetings with the actual local MLX model, measure whether it produces grounded, non-fabricated `<stem>`/line citations rather than plausible prose. Cloud-class quality cannot be assumed for the regulated/NDA path, which is precisely the path that forces local.
- **Trend/coaching dashboards (talk-time coaching, scorecards, sentiment, pipeline): SKIP.** Out of register for a quiet, single-user, local-first product. A self-directed talk-time view is the only arguably-in-register analytic and is not worth carrying now. Revisit only if the user explicitly asks.

The throughline: build the derived read-only layer now; spike the two data-quality-dependent capabilities before committing; skip the CRM-shaped end entirely.

## Proposed Q5 items

| ID | Title | Priority | Spike | One-liner | Acceptance | Depends on |
|---|---|---|---|---|---|---|
| DV1 | Action resolved/done flag in the summary contract | P1 | no | Add an optional `resolved` flag to `ActionItem` across the Python schema, the Swift mirror, and the sidecar/summary contract, staying compatible with both tolerant decoders. | A summary round-trips with and without `resolved`; both decoders ignore it when absent and read it when present; `mp actions` can filter to genuinely-open items; `test_workflow_overlay.py` and the action tests stay green. | "" |
| DV2 | Cross-meeting data-view altitude (decisions + open actions) | P1 | no | A new facts-altitude view reachable from the Library rail that aggregates `decisions[]` and open `actions[]` across the library read-only, each item linking back to its `<stem>`. | The view lists decisions and open actions from at least two meetings, each navigates to its source meeting, no model call and no new egress on render, NDA/regulated meetings honor the clamp. | DV1 |
| DV3 | Spike: attendee quality for a People pivot | P2 | yes | Inspect real `summary.json` `attendees` across the corpus, measure cross-meeting dedup hit-rate, and decide whether a People view is trustworthy now or must wait for FEAT3-ROSTER / CAL1. | A short written finding with a measured dedup/alias rate on real files and a go / wait recommendation tied to ROSTER and CAL1; no production UI shipped from the spike. | "" |
| DV4 | Spike: local cross-meeting RAG with grounded citations | P3 | yes | On a handful of real meetings with the configured local MLX engine under the egress clamp, measure whether semantic "ask across" returns verifiable `<stem>`/line citations rather than fabricated prose. | A finding that reports citation-grounding accuracy and hallucinated-attribution rate on the local engine, plus a go / no-go for a daemon "ask across" surface; runs fully local with the firewall armed. | "" |

DV1 is priced as P1 because it is a correctness fix (the existing "open actions" notion is dishonest without it) and it gates DV2. DV2 is P1 as the high-leverage, low-risk derived layer. DV3 and DV4 are spikes, deliberately ranked below the open correctness and infra work in the active backlog (net-new features rarely outrank open bugs); they exist to de-risk before any People or chat altitude is committed.

## Risks, privacy, and the configured-engine analysis

- **Privacy and egress, by construction.** DV1 and DV2 add zero egress: they read facts already extracted and on disk and render them. No model call on the aggregation path means nothing to clamp. This is the safe-by-construction property that makes the derived layer the right first build.
- **The clamp must hold for the model-dependent capabilities.** DV4 (and any future People view that calls a model for dedup) must route through the configured engine and never call cloud when `workflow_nda_mode` or `regulated_mode` is set. The httpx firewall (`egress_guard.py`, armed by `arm_for_config`) already enforces this at the transport layer, but the spike must verify the new path actually goes through it and adds no always-on egress.
- **Attendee/entity quality (the dominant residual risk).** Raw `attendees` are LLM-inferred and inconsistent; the NER literature confirms this is intrinsic to small-model extraction, not a fixable prompt. A People view built on them without ROSTER/CAL1 may misattribute or fragment people. This is why DV3 is a spike, not a build.
- **Local-engine extraction and citation quality.** When regulated mode forces local MLX, cloud-class quality cannot be assumed. Small models lag on recall and vary run-to-run. DV4 measures grounded-citation accuracy specifically on the local engine before any chat surface is committed.
- **The done-flag write path.** DV1 adds the flag; the affordance to *set* it (in the daemon's Summary tab) is a follow-up. Adding the field without a writer leaves "open actions" still effectively "all actions"; sequence the writer alongside DV2 so the inbox is honest on day one.
- **Vendor claims are unverified depth.** Every competitor analytics and "full relationship history" claim above traces to vendor docs/marketing, not independent testing. Treat them as "the feature exists and is described this way," not "the feature works well."
- **What this research could not inspect.** Real `summary.json` content and the running daemon UI (a menu-bar app, not screenshotable per project memory) were not inspected, so attendee quality and current Library rendering are unverified from files alone. That unverifiability is the explicit reason DV3 and DV4 are spikes.

## Sources

Competitor patterns: [Granola People & Companies](https://docs.granola.ai/help-center/people-and-companies), [Granola free vs paid](https://www.granola.ai/blog/granola-free-vs-paid-features-each-plan), [Granola chatting with your meetings](https://docs.granola.ai/help-center/getting-more-from-your-notes/chatting-with-your-meetings), [Granola how to organize meeting notes](https://www.granola.ai/blog/how-to-organize-meeting-notes), [Notion views, filters & sorts](https://www.notion.com/help/views-filters-and-sorts), [Notion using database views](https://www.notion.com/help/guides/using-database-views), [Obsidian Bases syntax](https://help.obsidian.md/bases/syntax), [got.md Bases guide](https://got.md/obsidian-bases/), [Reflect backlinks/tags](https://reflect.academy/using-backlinks-and-tags), [Reflect AI backlinks](https://reflect.app/blog/automatically-add-backlinks-using-ai), [Otter My Action Items](https://otter.ai/blog/streamline-workflows-with-my-action-items-otter-ai-can-now-keep-track-of-all-your-action-items-across-all-your-meetings), [Otter](https://otter.ai/), [Fathom overview](https://www.fathom.ai/overview), [Fathom](https://www.fathom.ai/), [Fireflies pricing](https://fireflies.ai/pricing), [Fireflies analytics guide](https://guide.fireflies.ai/articles/2608597716-understand-fireflies-analytics-and-conversation-intelligence).

On-device feasibility: [MLX vs llama.cpp on Apple Silicon](https://groundy.com/articles/mlx-vs-llamacpp-on-apple-silicon-which-runtime-to-use-for-local-llm-inference/), [Apple Silicon LLM benchmarks](https://llmcheck.net/benchmarks), [qwen3-embeddings-mlx](https://github.com/jakedahn/qwen3-embeddings-mlx), [SLM survey](https://arxiv.org/html/2501.05465v1), [LLM NER reproducibility](https://link.springer.com/article/10.1007/s40264-024-01499-1).

Repo grounding (read directly): `pipeline/src/mp/schemas.py`, `pipeline/src/mp/actions.py`, `pipeline/src/mp/ask.py`, `pipeline/src/mp/egress_guard.py`, `daemon/Sources/MeetingPipe/LibraryScope.swift`, `daemon/Sources/MeetingPipe/Library/MeetingSummary.swift`, `CONVENTIONS.md` (sidecar schema, lines 200-223), `docs/backlog/meetingpipe-q4-backlog.md` (FEAT3-ROSTER, FEAT4, CAL1).
