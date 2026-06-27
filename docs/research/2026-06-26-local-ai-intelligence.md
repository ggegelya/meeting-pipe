# Local-first AI intelligence layer

Research synthesis, 2026-06-26. Decision-grade. Read alongside the Q5 backlog items it produced (the `AI` band).

## Question

Which cross-meeting AI-intelligence capabilities are worth building for a single privacy-first user, which need a spike first, and which to skip?

Candidate capabilities under review:

- Ask-AI over the whole library, wired to the configured engine (not the CLI TF-IDF ranker we ship today).
- Weekly stats plus a weekly review.
- Trend and pattern / behaviour analysis.
- Notifications / digests.
- Short concise reports.
- Automatic meeting grouping / classification by type.
- Action-item intelligence: open / closed / ownership / aging, building on `mp actions`.

The frame is deliberately narrow. meeting-pipe is a single-user, local-first, privacy-first product. A capability that is genuinely useful to a sales team of forty can be demo-ware for one person. The egress clamp and the configured engine are hard constraints, not preferences.

## What the mature tools do

Nine cloud and local note-takers were surveyed. The short version: ask-across-all-meetings chat is now table stakes, scheduled digests and action-item lifecycle are the under-served seams, and trend dashboards are real but team-shaped.

| Tool | Ask across all | Cited answers | Weekly digest / review | Trend / pattern | Action aging / owner / reminders | Auto meeting-type | Local-first |
|---|---|---|---|---|---|---|---|
| Granola | Yes | Marketing claims yes; help docs silent | No | Yes (themes across a folder) | Partial | `?` | No |
| Notion AI | Yes | Yes | Partial (Custom Agents) | Partial | Partial | Partial (manual templates) | No |
| Otter | Yes | `?` | Partial ("what did I miss") | Partial | Partial (owners, no due/reminders) | No | No |
| Fathom | Yes (account-wide, Apr 2026) | Yes | `?` | Yes | Partial | Partial (manual) | No |
| Fireflies | Yes (AskFred) | `?` | `?` | Yes (analytics dashboard) | Yes (native tracking + reminders + push) | No | No |
| tl;dv | Yes | `?` | Yes (recurring AI reports) | Yes | Partial | No | No |
| Reflect | Yes | Partial (grounded in notes) | Partial (manual weekly prompt) | Partial | No | No | Partial (E2E encrypted, cloud AI) |
| Mem | Yes | `?` | Yes (daily digest) | Partial | No | No | No |
| Hyprnote | Yes | `?` | `?` | `?` | No | No | Yes (fully on-device, BYO-LLM) |

A few load-bearing details:

- **Ask-across-all is table stakes.** Fathom shipped account-wide "Ask Fathom" in April 2026 (confirmed via BusinessWire and Product Hunt; Fathom 3.0, #1 Product of the Day, 15 Apr 2026). Granola scopes its chat three ways (all notes / folder / hand-picked) and Fireflies, tl;dv, Otter, and Notion all ship a version of it.
- **Cited answers are less universal than marketed.** Granola's help docs confirm cross-meeting scope but are silent on inline citations; only the marketing blog claims them. Treat cited cross-meeting answers as a feature to build, not as proven competitor parity.
- **Scheduled digests are rarer and more differentiated.** tl;dv ships recurring AI Reports (weekly / monthly, configurable scope and timing; confirmed on tldv.io). Mem's daily digest is confirmed as a category but the "curated by relevance to upcoming meetings" detail rests on a single secondary source. Granola's own docs explicitly state there is no automatic digest.
- **Action-item lifecycle is where almost everyone is weak.** The recurring honest critique across independent reviews is "action items get captured but do not move anywhere". Fireflies is the one confirmed exception with native tracked actions, reminders, and push to Asana / Jira / Slack. Most tools rely on pushing to an external task tool rather than tracking in-platform.
- **Auto meeting-type classification is uncommon.** MeetGeek auto-detects call type (sales / team / onboarding / interview) and applies the matching template; most others offer manual template selection. None of the nine in-scope tools verifiably auto-classify.
- **Hyprnote is the posture twin.** Fully on-device, mic plus system audio, no bots, markdown on disk, BYO-LLM via Ollama. It validates meeting-pipe's exact stance and stops at per-note chat: no verifiable digests, action aging, or classification. That is the differentiation opening, because it is the same gap meeting-pipe has.

## On-device feasibility

Honest read of what runs locally on Apple Silicon, because this is the load-bearing risk the capability set understates.

**Embedding the library is cheap.** A Qwen3-0.6B MLX embedding server hits ~44K tok/s with 1-3 ms single-embedding latency on an M2 Max. Building and refreshing a semantic index over the library is well within budget. The indexing half of "upgrade `mp ask` from TF-IDF to embeddings" is sound.

**MLX is the right runtime.** Independent benchmarks show llama.cpp's Metal shaders mis-handle the Qwen 3.5 Gated DeltaNet architecture (about 20.7 s per response), while MLX's native kernels recover it to about 6.9 s with a slight quality gain. Reusing the existing `mlx_lm.server` is technically justified.

**The generation latency does not generalise to long context, and this is the catch.** The widely cited 6.9 s figure is for a 4B model emitting one short response. MLX does full prefill before it emits any token, so time-to-first-token rises linearly with input length. At roughly 8.5K tokens on an M1 Max, effective throughput collapsed to about 3 tok/s with 94% of wall-clock spent in prefill. RAG synthesis (retrieved chunks stuffed into context) and weekly digests (several meetings concatenated) are precisely the long-prompt regime where the short-prompt number breaks. On older or base M-series laptops these tasks risk multi-second to tens-of-seconds first-token latency.

**Synthesis quality of a small local model is unmeasured for this task.** The one quality datapoint is a single short-response metric, not multi-document faithfulness or citation accuracy. The risk of a hallucinated cross-meeting claim ("we decided X in the Tuesday sync") is real and unmeasured.

The practical consequence: the lowest-risk first build is the embedding index plus an async, background-generated digest, both of which are latency-tolerant. A real-time, interactive chat UI over the library is the latency-sensitive part and should not be committed to before a spike measures TTFT and total wall-clock at realistic context lengths (4K / 8K / 16K) on the actual Mac.

## What meeting-pipe already has to build on

Verified by reading the files. The foundation is unusually strong, which is what makes a small, focused build defensible.

- **Typed cross-meeting facts on disk.** `pipeline/src/mp/schemas.py` defines `MeetingSummary` with `summary`, `decisions`, `actions[task, owner, due, confidence]`, `questions`, `attendees`, `detected_language`. `ActionItem.due` is already an ISO 8601 date string and `confidence` is a `low | medium | high` enum. This is the schema a facts-altitude view needs, and it is richer than what most competitors expose.
- **A cross-meeting action aggregator already ships.** `pipeline/src/mp/actions.py` (`mp actions`) scans every `<stem>.summary.json`, flattens all `actions`, and supports `--owner`, `--due-before`, `--min-confidence` with a sort that puts dated / soonest / highest-confidence first. Its own docstring names the gap: "'Open' is not yet modeled in the schema, so every extracted action counts as open. A resolved/done flag (and the UI to set it) is the named follow-up." CLI-only, no daemon UI.
- **A cross-meeting ask already ships, and names its own successor.** `pipeline/src/mp/ask.py` (`mp ask`) is a stdlib TF-IDF lexical ranker over `<stem>.summary.md` plus the transcript, returning the best-matching line as a snippet. Its docstring: "the true on-device semantic RAG (embeddings + a vector index over the same library, reusing the MLX model) is the follow-up this paves the way for." CLI-only.
- **A configurable engine that already honours privacy.** `pipeline/src/mp/config.py` `backend` is `anthropic | local | auto | apple_intelligence`; `effective_backend()` forces `local` under regulated / NDA. `summarize_local.py` lazy-launches an `mlx_lm.server` on `127.0.0.1:8765` (an OpenAI-compatible localhost endpoint) and clamps any non-loopback host back to loopback. Any new RAG, digest, or classification call reuses this server.
- **A structural egress clamp.** `pipeline/src/mp/egress_guard.py` patches httpx transports process-wide; under regulated / NDA every non-loopback request raises `EgressBlocked`. Any new intelligence that routes its LLM call through httpx inherits the clamp for free, as long as it adds no new always-on egress.

What is missing is exactly the seam the survey identifies: no conversational chat, no semantic index, no digest or weekly review, no action-item lifecycle, no meeting-type field, and no daemon UI at the facts altitude (`mp ask` and `mp actions` have no surface in the app at all).

One caveat that gates the people / decisions view: whether `attendees` and `decisions` are populated reliably on the real library is a data-quality question, not a schema-shape question. It is answerable only by inspecting the actual library and is unverifiable from the schema alone.

## Recommendation

Per capability, with the reasoning.

**BUILD: Action-item lifecycle (open / done / aging), schema plus daemon surface.** This is the most under-served competitor capability, it is already named as the next step in `actions.py`, and it does not depend on the LLM at all (it is a `done` flag on `ActionItem`, an aging computation off the existing ISO `due`, and a daemon control to toggle it). It is the highest-leverage, lowest-risk item in the set. Lifecycle status is a `MeetingSummary` schema change, so it touches the Swift sidecar contract and every publisher; treat that surface area as the real cost, not the logic.

**BUILD (async, background): Weekly review digest.** A scheduled, locally generated digest (aging open actions, recent decisions, what changed this week) is the single-user-relevant slice of "trend analysis", and it is latency-tolerant because it runs in the background. It is the differentiated half of the survey (most ask-tools have no scheduled push at all) and it respects the egress clamp as long as generation is on-device. It depends on the action lifecycle for the "aging actions" section to be meaningful, and it can ship a useful first version from `decisions` and `actions` alone without RAG.

**SPIKE-THEN-DECIDE: Semantic Ask-AI over the library, wired to the configured engine.** The indexing half (embeddings) is cheap and de-risked. The synthesis half (cited natural-language answers) carries two unmeasured risks: long-context generation latency on the actual hardware, and small-model multi-document faithfulness. Build the embedding index and measure both before committing to an interactive chat UX versus an async one. The `<stem>` plus line-snippet structure already supports citations, so cited answers are a differentiator to build, not parity to copy.

**SPIKE-THEN-DECIDE: Auto meeting-type classification.** Uncommon among competitors and cheap to prototype (a single short-prompt local call per meeting, or even a heuristic over attendees / cadence / title), but its value to one user is unproven and it adds a schema field. A small spike should classify the existing library and let the user judge whether the labels are useful enough to wire into grouping and digests before it earns a permanent field.

**SKIP: Trend / pattern / behaviour dashboards and speaker analytics.** The real instances (tl;dv competitor tracking, Fireflies speaker and sentiment analytics) are aggregate-across-people, team-and-sales-shaped metrics. For one user they are largely demo-ware. The only single-user-relevant slice is "aging actions plus recent decisions this week", which is the digest, not a dashboard. Do not scope trend dashboards.

**SKIP: Standalone weekly stats and notifications beyond the digest.** Talk-time, filler-word, and sentiment coaching metrics are frequently shown and rarely change behaviour. A separate notification channel beyond the one weekly digest adds always-on surface for thin payoff. Fold any "stats" worth keeping into the digest.

The unifying judgement: the recurring critique of this whole product category is that "the summary sits in a standalone app nobody returns to". meeting-pipe's publish step (Notion / Obsidian / filesystem / LAN) is already its strongest answer to that critique. The intelligence layer should reinforce that loop (close actions, surface aging, push a weekly digest) rather than add another analytics surface the user has to remember to open.

## Proposed Q5 items

| ID | Title | Priority | Spike | One-liner | Depends on |
|---|---|---|---|---|---|
| AI1 | Action-item lifecycle: done flag + aging | P1 | No | Add a `done` state to `ActionItem`, compute aging off the existing ISO `due`, and teach `mp actions` open / closed / overdue filters. | (none) |
| AI2 | Daemon surface to close an action | P2 | No | A control in the Summary tab (and a facts-altitude list) to mark an action done, persisted through the sidecar so it survives republish. | AI1 |
| AI3 | Weekly review digest (async, on-device) | P2 | No | A scheduled, locally generated digest of aging open actions and recent decisions, written to disk and publishable, no new always-on egress. | AI1 |
| AI4 | Semantic index spike (embeddings + latency) | P1 | Yes | Build an on-device embedding index over the library and measure RAG synthesis TTFT and faithfulness at 4K / 8K / 16K context on the real Mac. | (none) |
| AI5 | Wire Ask-AI to the configured engine, cited answers | P2 | Yes | Replace the TF-IDF ranker with engine-backed retrieval-augmented answers carrying `<stem>` citations, honouring `effective_backend()` and the egress clamp. | AI4 |
| AI6 | Meeting-type classification spike | P3 | Yes | Prototype on-device meeting-type labels over the existing library and let the user judge usefulness before committing a schema field. | (none) |

## Risks, privacy, and the configured-engine analysis

**The load-bearing risk is long-context generation latency.** The cited 6.9 s figure is a short-prompt number; MLX's full-prefill-first behaviour makes RAG synthesis and weekly digests the worst case, not the happy path. This is why AI4 is a spike and AI3 is explicitly async / background. Do not ship an interactive cross-meeting chat UX until AI4 measures TTFT at realistic context lengths on the user's actual hardware.

**Small-model synthesis quality is unmeasured for multi-document cited answers.** A hallucinated cross-meeting claim is a credibility failure in a tool whose whole value is trustworthy recall. AI4 must measure faithfulness and citation accuracy, not just latency.

**Data-quality gates the facts-altitude views.** Whether `attendees` and `decisions` are populated reliably on the real library is unverifiable from the schema and must be checked against the actual data before any people / decisions view is scoped. The action lifecycle (AI1 / AI2) depends only on `actions`, which the summarizer populates as its primary output, so it is the safest place to start.

**Every proposed capability respects the privacy invariant.** Embeddings, RAG synthesis, digest generation, and classification all route through the existing local `mlx_lm.server` (`127.0.0.1:8765`) and inherit the `egress_guard` httpx clamp under regulated / NDA. None requires new always-on egress. The constraints any AI-band implementation must hold:

- Route every LLM call through httpx so `egress_guard.arm_for_config` clamps it under regulated / NDA.
- Honour `effective_backend()`: under regulated / NDA the engine is forced to `local` regardless of the configured backend, and the feature must not silently fall back to a cloud call.
- Add no new always-on egress. The weekly digest (AI3) adds a recurring trigger, but its compute is local, so the invariant holds.
- A schema change to `ActionItem` or `MeetingSummary` (AI1, and AI6 if it lands a field) touches the Swift `MeetingMetaSidecar` contract and every publisher; update both sides plus `test_workflow_overlay.py`, per `CONVENTIONS.md`.

**Single-source claims to treat with caution.** Mem's "curated by relevance to upcoming meetings" digest detail and the "neither tl;dv nor Fireflies lets you close a task in-platform" comparison both rest on single or vendor-biased sources. The action-lifecycle gap is real (Fireflies' native tracking is the one confirmed exception), but its exact width is fuzzy. This does not change the recommendation, since AI1 / AI2 are justified by meeting-pipe's own named follow-up, not by the competitor gap alone.

## Sources

- Granola: [multi-meeting chat docs](https://docs.granola.ai/help-center/getting-more-from-your-notes/chatting-with-your-meetings), [chat-with-meetings blog](https://www.granola.ai/blog/chat-with-meetings-search-analyze-ai-2026)
- Notion AI: [product/ai](https://www.notion.com/product/ai), [AI Meeting Notes help](https://www.notion.com/help/ai-meeting-notes)
- Otter: [AI Chat overview](https://help.otter.ai/hc/en-us/articles/19682180167575-Otter-AI-Chat-Overview), [AI Chat across meetings blog](https://otter.ai/blog/otter-ai-chat-unlocking-hidden-gems-across-all-your-meetings)
- Fathom: [overview](https://www.fathom.ai/overview), [platform update, BusinessWire, Apr 2026](https://www.businesswire.com/news/home/20260415965820/en/Fathom-Unveils-Major-Platform-Update-Adding-Bot-Free-Capture-Account-Wide-Meeting-Insights-and-Widely-Expanded-LLM-Integrations)
- Fireflies: [AskFred overview](https://docs.fireflies.ai/askfred/overview), [analytics and conversation intelligence](https://guide.fireflies.ai/articles/2608597716-understand-fireflies-analytics-and-conversation-intelligence)
- tl;dv: [conversational intelligence](https://tldv.io/features/conversational-intelligence/), [recurring AI reports](https://tldv.io/blog/tldv-recurring-ai-reports/)
- Reflect: [AI search and chat blog](https://reflect.app/blog/ai-search)
- Mem: [Daily Digest / Mem Chat guide](https://productivitystack.io/guides/mem-ai-guide/)
- Hyprnote: [Launch HN](https://news.ycombinator.com/item?id=44725306), [GitHub (Anarlog fork)](https://github.com/fastrepl/anarlog), [opensource page](https://hyprnote.com/opensource), [local note-takers review](https://heymumble.com/blog/local-ai-meeting-note-takers-mac)
- MeetGeek (auto meeting-type classification): [meetgeek.ai](https://meetgeek.ai/)
- On-device feasibility: [qwen3-embeddings-mlx](https://github.com/jakedahn/qwen3-embeddings-mlx), [Qwen 3.5 MLX latency-regression writeup](https://medium.com/@aejaz.sheriff/from-qwen-3-to-qwen-3-5-on-apple-silicon-a-14x-latency-regression-and-how-mlx-got-us-back-0ed9ed21fa68), [Apple Silicon LLM runtime decision framework, MLX prefill / TTFT scaling](https://medium.com/@michael.hannecke/choosing-an-on-device-llm-runtime-on-apple-silicon-a-decision-framework-beyond-benchmarks-2449067b8b67), [MLX vs llama.cpp benchmarks](https://yage.ai/share/mlx-apple-silicon-en-20260331.html), [native LLM inference at scale on Apple Silicon (arXiv)](https://arxiv.org/html/2601.19139v2)
- Skeptical / daily-use signal: [alfred_ notetakers tested](https://get-alfred.ai/blog/best-ai-meeting-notetakers), [tl;dv vs Fireflies](https://tldv.io/blog/tldv-vs-fireflies/)
