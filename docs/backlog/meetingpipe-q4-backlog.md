# MeetingPipe Q4 backlog

This is the source of truth for TECH-* items. Q3 archived to `q3-final.md`; Q2 to `q2-final.md` and `q2-ui-addendum-final.md`. Q4 carries forward everything Q3 left open (not started, "done but ..." with an unmet bar, and items closed at low confidence), plus the findings from the Q4 full-scale review (architecture, security, performance, design) and the workflow-editor review.

## How to pick up a task (delegation)

Mechanics are codified in `/tech-task <ID>` (read the task here, read the orientation docs, implement, verify, one commit on `main`, do not push). This section is only the soft context that command does not carry:

- User locale: 99% English / Ukrainian. Do not default examples to German. `uk` is in `MuteLabels.toml`; verify any new `uk` labels with the user.
- The user is vibe-coding: high-level explanations, does not read code. Lean on the ARCHITECTURE.md diagrams.
- No em-dashes in any output (CI fails on a U+2014 in an added line; a whole-tree ban under `daemon/Sources` and `daemon/Resources`). Use hyphens, commas, or rewrite. Do not hardcode a personal name or email; commit with the repository's configured git identity. Do not push without permission.
- MicGate runtime knobs live in Preferences > Recording > Microphone and Preferences > Prompt > Stop conditions.
- Binding constraint (from CLAUDE.md): the primary user is the author, selling is tertiary. Technical excellence in core functionality comes first. The one promotion this quarter: GitHub repo presence and the app's visual identity are in scope (TECH-REPO1/REPO2), for contributor visibility. The full launch BRAND band stays deferred.

## Priority bands

- **P0**: correctness or a broken core promise; do first.
- **P1**: meaningful, not blocking.
- **P2**: polish and power-user payoff.
- **P3**: deferred; listed so the trail stays readable.

## Table of contents

| ID | Task | Category | Status | Description |
|---|---|---|---|---|
| TECH-SEC2 | Clamp sinks under global regulated mode | Security | DONE (was P0) | Global regulated mode forces the local LLM but does not strip the Notion sink, so the publish path still transmits meeting content; clamp sinks the way NDA does. |
| TECH-CONC1 | Move MicGate emit + lock off the render thread | Concurrency | P1 new | Every mic gate flip takes an NSLock and writes events.jsonl synchronously on the audio render thread; defer both and add a CI assertion. |
| TECH-SEC3 | Process-wide egress firewall under regulated/NDA | Security | DONE (was P1) | Replace seven scattered flag checks with one httpx transport that hard-fails any non-loopback request when regulated or NDA is active. |
| TECH-SEC4 | Gate or remove the daemon's direct Notion call | Security | P1 new | The daemon POSTs to api.notion.com for the DB picker, outside all egress enforcement and against its own "no Notion from the daemon" rule. |
| TECH-ARCH1 | Single effective_config() chokepoint | Architecture | P1 new | The regulated/NDA force-local rule is copied across four-plus sites; compute it once so a new code path cannot forget the clamp. |
| TECH-PERF1 | Stream diarize.py per segment | Performance | P1 new | The channel-aware fallback loads the whole stereo WAV plus two float copies (~2 GB at 3 h); read per-segment instead. |
| TECH-PERF2 | FluidAudio mono read + free input buffer (was A13 RAM half) | Performance | P1 carry | readMonoFloat32 holds the full clip plus a mono copy across ASR and diarization; halve the peak and free the input buffer early. |
| TECH-WF1 | Workflow backend unification + inherit | Workflow | P1 new | The per-workflow picker omits Apple Intelligence and always overrides the global backend; add it plus a "use global default" option. |
| TECH-DSN1 | Preferences IA pass | Design | P1 new | Seven panes, ~44 controls; collapse the local-MLX cluster behind a disclosure, cut cosmetic toggles, move regulated mode out of Prompt. |
| TECH-DSN2 | Detail-pane tabs + one republish path | Design | P1 new | Five tabs (two are debug surfaces) and 5+ overlapping republish/reprocess controls; reduce to three tabs and one canonical republish. |
| TECH-REPO1 | GitHub repo presence | Identity | P1 new | README hero, LICENSE, CONTRIBUTING, repo description / topics / social preview, for contributor visibility. |
| TECH-REPO2 | App visual identity | Identity | P1 new | A signal color that is unmistakably MeetingPipe (not generic system blue) plus icon polish; the MacPaw-grade identity. |
| TECH-H1-FINISH | Coordinator under 600 lines | Architecture | P1 carry | Still 1371 lines; only three extractions landed. See TECH-ARCH2. |
| TECH-C6-FINISH | Real detection-trace corpus | Detection | P1 carry | Still nine synthetic seeds; need 20+ real dogfood traces so detection cannot silently regress. |
| TECH-VALID1 | On-device acceptance for A15/A16/DIAR1/SUM1-APPLE/UX4 | Validation | P0 carry | Five Q3 tasks shipped code but their quality / latency / zero-egress / degraded-banner bars were never validated on a real Mac. |
| TECH-CONC2 | Strict-concurrency island for MeetingPipeCore | Concurrency | P2 new | Turn on Swift 6 strict concurrency for the core module and the recorder's shared fields, where the real cross-thread risk lives. |
| TECH-PERF3 | Vectorize render-thread RMS (vDSP) | Performance | P2 new | Two scalar sum-of-squares passes per mic buffer on the hot path; use vDSP_svesq once. |
| TECH-PERF4 | Replace the 60 fps dismiss-ring timer | Performance | P2 new | DismissProgressView wakes the main thread 60x/sec for a cosmetic ring; use TimelineView(.animation) or a CA keyframe. |
| TECH-ARCH2 | Extract MeetingSessionController | Architecture | P2 new | Lift per-meeting verdict plumbing and sidecar writing out of Coordinator; finishes H1-FINISH by construction. |
| TECH-ARCH3 | Collapse PipelineLauncher scaffolding onto runMP | Architecture | P2 new | Four near-identical ~90-line Process/watchdog blocks; the runMP helper already factors the pattern. |
| TECH-SEC5 | Fail-closed subprocess env on local/NDA | Security | P2 new | Drop ANTHROPIC_API_KEY and NOTION_TOKEN from the child env on local/NDA runs so an enforcement bug fails closed, not open. |
| TECH-SEC6 | Untrusted-transcript boundary + field scrub | Security | P2 new | Wrap transcript text as untrusted in all summarizers and scrub owner/attendee fields before they reach sinks and the correction corpus. |
| TECH-SEC7 | Obsidian YAML title injection | Security | P2 new | A title with a newline injects YAML keys; route the title through _yaml_str and strip control chars at the Swift extraction boundary. |
| TECH-SEC8 | Tokens in Keychain (extends SEC1) | Security | P2 new | Move NOTION_TOKEN / ANTHROPIC_API_KEY out of secrets.env into the macOS Keychain; closes SEC1 properly. |
| TECH-SEC1 | secrets.env read-permission check | Security | P2 carry | Neither reader refuses a 0644 secrets.env; warn or refuse on a too-open mode. Folds into SEC8 if Keychain lands. |
| TECH-WF2 | Workflow emoji picker | Workflow | P2 new | The emoji field is a bare 80pt text box that accepts arbitrary text; use a real emoji picker constrained to one grapheme. |
| TECH-WF3 | Workflow color picker | Workflow | P2 new | Replace the #RRGGBB hex field with a native ColorPicker or token-aligned swatches; keep hex as an advanced fallback. |
| TECH-WF4 | Workflow identity-section layout | Workflow | P2 new | Name / Color / Emoji rows are raggedly aligned (a stray Spacer, mismatched widths); make the section coherent. |
| TECH-WF5 | Workflow discoverability | Workflow | P2 new | Editing a workflow is buried behind selecting a Library scope and an unlabeled pencil; give it a findable home. |
| TECH-DSN3 | Token-enforcement pass | Design | P2 new | 126 raw .system fonts and 22 raw colors bypass the token system; enforce tokens, unify to one button language, add a CI guard. |
| TECH-DSN4 | Identity color | Design | P2 new | Signal blue reads as generic macOS blue; pick a distinct hue that survives the dark-mode auto-flip. Pairs with REPO2. |
| TECH-DSN5 | Motion + haptic + opt-in tone | Design | P2 new | Animate exactly three moments; Stop haptic for the consequential action; one opt-in post-call tone; never an in-call chime. |
| TECH-DSN6 | Persisted NDA flag + row badge | Design | P2 new | The Library infers NDA heuristically, so a row can read "Local only" without the user setting it; persist and read the resolved flag. |
| TECH-DSN7 | Dead elapsed placeholder + menu-bar title | Design | P2 new | The recording pill shows a permanent "-:-"; the menu-bar title can stack four clauses. Fix or remove. |
| TECH-FEAT1 | Local-network (LAN) sink | Feature | P2 new | A reachability-aware filesystem publisher for a mounted SMB/NFS share (on-prem, no cloud cost); deepens the regulated story. |
| TECH-FEAT2 | Local semantic search ("ask my meetings") | Feature | P2 new | On-device RAG over the transcript library using the MLX model already run; the biggest "why this over cloud" answer. |
| TECH-FEAT5 | Auto/anthropic fallback on 429/500 | Feature | P2 new | The auto backend only falls back on connection/auth errors; a sustained rate-limit fails the run instead of going local. |
| TECH-DIST1 | Bundle runtime for a drag-n-drop installer | Distribution | P2 new | Embed a standalone Python plus ffmpeg and notarize, so a clean Mac (no Homebrew, no Python) can install by dragging the app. |
| TECH-DOC1 | Merge GLOSSARY into ARCHITECTURE | Docs | P2 new | Fold the glossary into an ARCHITECTURE "## Glossary" section, rewire the five references, delete GLOSSARY.md. |
| TECH-DOC2 | Merge SPEC into README + ADRs | Docs | P2 new | Move surviving rationale to a README "Why it is shaped this way" section, dedupe the schema tables into CONVENTIONS, rewire six refs, delete SPEC.md. |
| TECH-DOC3 | Trim the signal-fusion doc | Docs | P2 new | Fix the stale file tree (actor wording, deleted signals, per-vendor adapters, InternalSpeechProbe, Locale path, Thresholds.swift); keep the durable "why". |
| TECH-UI-X1 | Extract MeetingDetailView per tab | Architecture | P2 carry | MeetingDetailView is ~1206 lines; split per tab (target under 250). |
| TECH-UI-X2 | Extract PreferencesView per section | Architecture | P2 carry | PreferencesView is ~1177 lines; split per section (target under 200). Pairs with DSN1. |
| TECH-T2 | Snapshot tests for three SwiftUI views | Tests | P2 carry | No snapshot harness yet; add swift-snapshot-testing gated by Appearance. |
| TECH-I6 | Partial-publish visibility | Observability | P2 carry | Scoped down: fanout already returns per-sink results; only a sidecar publish_state field and a per-row indicator remain. |
| TECH-W2 | Workflow precedence test | Tests | P2 carry | Near-noop: the acceptance bar is already met by WorkflowMatcherTests.test_ties_break_by_order_ascending; move or close. |
| TECH-E4-FINISH | Dogfood analysis script | Tooling | P2 carry | The events.jsonl acceptance-bar report (scripts/dogfood-report) was never built; pipeline/src/mp/dogfood.py is a different A/B harness. |
| TECH-ARCH4 | Golden-vector fixture for the dual chunkers | Architecture | P3 new | The Swift and Python chunkers must stay identical; pin parity with one shared input/expected fixture across both suites. |
| TECH-PERF5 | Adaptive backoff on poll timers | Performance | P3 new | The 1 Hz HAL/AX polls and 4 Hz engine tick run all meeting; back off when the listener is delivering. |
| TECH-SEC9 | Drop unused AppleEvents entitlement | Security | P3 new | NSAppleEventsUsageDescription is declared but browser detection uses Accessibility; remove the capability or document a use site. |
| TECH-FEAT3 | Speaker enrollment | Feature | P3 new | Label your own voice once so "me vs them" is reliable; leans on the diarization-cleanup work. |
| TECH-FEAT4 | Cross-meeting action tracking | Feature | P3 new | Extract open action items across meetings and surface the unresolved ones. |
| TECH-DIST2 | Spike: Swift port of the pipeline | Distribution | P3 new | Evaluate removing Python entirely (gated on MLX-Swift maturity for the local summarizer); would moot DIST1. Overlaps TECH-I7. |
| TECH-DOC4 | Delete Q2 archives + fix design READMEs | Docs | P3 new | Remove the two all-DONE Q2 archives (git preserves them) and trim the deleted-architecture prose in design/README.md and the ui_kits README. |
| TECH-DOC5 | Superseding ADRs | Docs | P3 new | Record that ADR 0001 (HAL tap) is superseded by ScreenCaptureKit and ADR 0002 is partially superseded by ADR 0007. |
| TECH-DSN8 | Summary-tab reading polish | Design | P3 new | Make the summary the app's "paper" moment: measured line length, the type ramp, generous rhythm. |
| TECH-BRAND1..9 | Launch readiness band | Brand | Deferred | Domains, trademark, landing page, demo GIF, screenshots, OG card, compliance pages. Selling is tertiary; do not pull forward without an explicit launch decision. |
| TECH-I7 | Drop Python entirely | Deferred | P3 | Promotion trigger: Apple Intelligence proves out and the local LLM swap is Swift-native. See DIST2. |
| TECH-I8 | Live transcription during recording | Deferred | P3 | A tar pit; promotion trigger is a Q4 streaming-summarization design that proves the floor. |
| TECH-G1 | Personal two-Mac hub | Deferred | P3 | All P0/P1 dogfood bars met first. |
| TECH-D8 | Developer ID + notarization in CI | Deferred | P3 | Partly overlapped by DIST1; full notarization-in-CI stays parked until a second user. |
| TECH-CAP1 | Mic/system end-of-call skew | Deferred | P3 | Monitor only; promotion trigger is the few-second skew reappearing across multiple recordings. Spec retained in q3-final.md. |

---

## Task specs

### Security and privacy

**[DONE] TECH-SEC2 (P0): close the regulated-mode Notion egress.** Under global regulated mode with the default `notion` sink, `orchestrate.run_all` -> `publish_router.fanout` builds a Notion publisher with an empty token ([publish_router.py:57](../../pipeline/src/mp/publish_router.py)) and calls `upsert()`, which has no regulated check and POSTs the summary (and transcript) to api.notion.com before Notion rejects the empty token. The module-level `publish()` short-circuit is never on this path. Fix: clamp sinks under `regulated_mode` the way `nda_mode` does (return `None` for the notion sink in `_build_one`, or strip it in an effective-config helper). Invert `test_build_publishers_notion_in_regulated_mode_no_token_needed`, and add an egress test that drives `fanout` (not just `summarize`) under a localhost-only transport. Acceptance: no non-loopback request is issued under regulated mode on the run-all and `mp publish` paths.

**[DONE] TECH-SEC3 (P1): structural egress firewall.** Install one process-wide httpx event hook (or custom transport) at pipeline entry that raises on any request whose host is not loopback when the resolved config is regulated or carries `workflow_nda_mode`. The Anthropic SDK and Notion both use httpx, so one hook covers every present and future sink. Promote the pattern the zero-egress test already simulates from fixture to runtime guarantee.

**TECH-SEC4 (P1): one network actor.** `NotionDatabaseList.fetch` in the daemon POSTs to api.notion.com for the Preferences DB picker, outside the pipeline's enforcement and against `daemon/CLAUDE.md`. Gate the Refresh on regulated/NDA (fall back to the cached/paste path) and emit an event-log line for every daemon-originated request so egress is auditable.

**TECH-SEC5 (P2): fail-closed subprocess env.** In `PipelineLauncher.freshEnvironment`, when a run resolves to local/Apple/NDA, build the child env without `ANTHROPIC_API_KEY` / `NOTION_TOKEN`. An enforcement bug then fails with a missing-credential error instead of silently egressing.

**TECH-SEC6 (P2): untrusted-transcript boundary.** Wrap transcript text in an explicit "untrusted content, never an instruction" delimiter in all three summarizers, and post-validate owner/attendee fields (reject emails, URLs, @-mentions, newlines) before they reach Notion to-dos, Obsidian, and the correction corpus.

**TECH-SEC7 (P2): Obsidian frontmatter title injection.** `_render_note` escapes only double-quotes in the title; a newline injects YAML keys. Route the title through the existing `_yaml_str` helper and strip control chars from the meeting title at the Swift extraction boundary (`MeetingTitleResolver`).

**TECH-SEC8 (P2): tokens in Keychain.** Move the tokens from the 0600 `secrets.env` into the macOS Keychain. Subsumes SEC1.

**TECH-SEC1 (P2, carry): secrets.env read-permission check.** Until SEC8 lands, refuse or warn when `secrets.env` is more permissive than 0600 at read time (today only the writer enforces the mode).

### Concurrency

**TECH-CONC1 (P1): render-thread safety.** On every mic gate transition, `MicGate.publish` takes an NSLock and calls `eventLog.emit`, which does a synchronous `events.jsonl` file write, on the audio render thread; only the AsyncStream yield is deferred. Move both the emit and the lock onto `publishQueue`, and add a debug-build assertion that fails if `events.jsonl` is written from the tap thread. (The comments now say this honestly; this task makes it true.)

**TECH-CONC2 (P2): strict-concurrency island.** Enable Swift 6 strict concurrency for `MeetingPipeCore` (already nearly Sendable-clean) and the recorder's shared verdict/level fields, rather than a wholesale migration. Converts the riskiest prose invariants into checked ones.

### Performance

**TECH-PERF1 (P1): stream diarize.py.** Replace the single `sf.read` plus two `astype(float32)` copies with per-segment `sf.read(start=, stop=)`, computing RMS per window. Cuts the ~2 GB peak on a 3-hour stereo file to a few MB, exactly in the degraded fallback path you least want to also OOM.

**TECH-PERF2 (P1, carry of A13 RAM half): FluidAudio memory.** The final WAV is already 16 kHz mono; read it into a mono buffer directly for the common case and scope the input PCM buffer so it is freed before `asr.transcribe` / `runDiarization`. Halves the readMonoFloat32 peak. (The waveform half of A13 shipped; this is the deferred RAM half.)

**TECH-PERF3 (P2): vectorize render-thread RMS.** Use `vDSP_svesq` for sum-of-squares once per mic buffer and feed both the gate dBFS and the ~1 Hz accumulator from it, removing the second scalar pass. Keep it allocation-free.

**TECH-PERF4 (P2): dismiss-ring timer.** Replace the 60 fps `Timer` in `DismissProgressView` with `TimelineView(.animation)` or a single CA keyframe so the CPU idles between frames.

**TECH-PERF5 (P3): poll backoff.** Back the 1 Hz HAL/AX poll fallbacks off to ~0.2 Hz once the listener has delivered recently, and gate the 4 Hz engine tick on a pending debounce.

### Architecture

**TECH-ARCH1 (P1): effective_config chokepoint.** Add one `effective_config(cfg)` (or `effective_backend` / `effective_sinks`) in `config.py` that applies the regulated/NDA forcing once, call it at the single entry of orchestrate/summarize/diarize_cleanup/publish, and delete the four-plus inline copies. Preserve the intentional apple_intelligence/auto differences per call site. This is the change that most reduces future egress drift and is the natural home for the SEC2 sink clamp.

**TECH-ARCH2 (P2): MeetingSessionController.** Extract the two verdict-consumer Tasks, engage/disengage, silence-detector arming, and meta-sidecar writing into a session controller that owns one meeting's lifetime. Coordinator drops to wiring plus the three UI-delegate conformances, under ~700 lines. Closes H1-FINISH.

**TECH-ARCH3 (P2): PipelineLauncher dedup.** Collapse the runAll/publish/summarize subprocess blocks onto `runMP` (lowest-risk first: `summarize`, which differs only in timeout). Removes ~270 lines of duplicated scaffolding.

**TECH-ARCH4 (P3): chunker golden vectors.** A checked-in input/expected-windows fixture exercised by both the Swift `TranscriptChunker` and Python `chunked_windows` suites, so the "must stay identical" comment is enforced by CI.

**TECH-H1-FINISH (P1, carry):** the under-600-line bar is unmet (Coordinator is 1371). Subsumed by ARCH2; track here until that lands.

### Workflow editor

**TECH-WF1 (P1): backend unification + inherit.** The per-workflow backend enum is `{anthropic, local, auto}` and the sidecar always stamps it, so a matched workflow always overrides the global backend, and global "Apple" is unreachable for any normal meeting. The Python overlay already allowlists `apple_intelligence`. Add `appleIntelligence` to `WorkflowBackend` and the editor picker (with the availability gating Preferences uses), add a "use global default" case, and only write `workflow_backend` when the workflow pins a non-default backend. Fixes the unreachable-Apple bug and the silent override, and corrects the "mirrors summarization.backend" docstring.

**TECH-WF2 (P2): emoji picker.** Replace the free `TextField("optional")` (width 80, accepts any text) with a real emoji picker (system Character palette via `orderFrontCharacterPalette`, or a curated grid) constrained to one grapheme.

**TECH-WF3 (P2): color picker.** Replace the `#RRGGBB` hex field with SwiftUI's native `ColorPicker` or a token-aligned swatch palette; keep hex as an advanced fallback.

**TECH-WF4 (P2): identity-section layout.** Fix the ragged alignment in the Identity section (the color row ends in a Spacer, emoji is width-80, name is full-width); give the rows a consistent field width.

**TECH-WF5 (P2): discoverability.** Workflow editing is only reachable by selecting a workflow filter-scope in the Library rail and clicking an unlabeled pencil. Add a labeled "Manage Workflows ..." entry (menu and/or a dedicated surface). Overlaps DSN1.

### Design and UX

**TECH-DSN1 (P1): Preferences IA.** Seven panes, ~44 controls. Collapse the local-MLX cluster (model id, endpoint, active model, preload, custom preset) behind a "Configure local model ..." disclosure or into Advanced; cut the two cosmetic toggles; move regulated mode out of the Prompt pane (it is a privacy/publishing concept). Pairs with UI-X2.

**TECH-DSN2 (P1): detail-pane tabs + republish.** Reduce the five detail tabs to three (drop "Raw files", demote "Corrections" to the "..." menu). Define two verbs only (Republish, Reprocess) and expose each once per altitude; remove the inline row buttons and the "Save & Republish" compound.

**TECH-DSN3 (P2): token enforcement.** Replace raw `.green/.orange/.red`, `.accentColor`, and the 126 `.system(size:)` literals with token equivalents; unify to one button language; add a CI grep guard (like the em-dash guard) for raw colors and bare `.font(.headline)` outside Tokens.swift.

**TECH-DSN4 (P2): identity color.** Choose a signal hue that is unmistakably MeetingPipe and survives the dark-mode auto-flip. Pairs with REPO2.

**TECH-DSN5 (P2): motion, haptic, sound.** Animate exactly three moments (HUD degraded grow/shrink, prompt fade-in, Library row-selection settle); add a Stop-button trackpad haptic; add one opt-in, default-off, post-call completion tone. Never an in-call chime, no shimmer, no skeletons, no bounce.

**TECH-DSN6 (P2): persisted NDA badge.** Persist the resolved NDA/regulated flag to the sidecar and drive the Library row badge from it; delete the heuristic guess in MeetingRow. A privacy badge must never be inferred.

**TECH-DSN7 (P2): dead placeholder + menu-bar title.** Show the real elapsed time in the recording pill (the HUD already tickers it) or drop the slot; collapse the multi-clause menu-bar title to one clause.

**TECH-DSN8 (P3): summary reading polish.** Treat the Summary tab as the app's "paper" moment: measured line length, the MP type ramp, generous vertical rhythm.

### Features

**TECH-FEAT1 (P2): local-network sink.** A first-class LAN publisher: write summaries (and optionally audio) to a mounted SMB/NFS share with reachability checks, atomic writes, and credential/host config, instead of pointing the plain filesystem sink at a network mount. On-prem, no cloud metering; strengthens the regulated story. Additive (publishers are already a Protocol with fan-out).

**TECH-FEAT2 (P2): local semantic search.** On-device RAG over the transcript library using the MLX model already in-process: "ask my meetings" with no new egress surface. The single biggest reason to use this over a cloud tool.

**TECH-FEAT5 (P2): auto fallback on rate-limit.** `_AutoFallbackClient` catches only connection/timeout/auth errors; extend it to fall back to local on 429/500 so a busy Anthropic does not fail the whole run. Note the default backend is `anthropic` (no fallback at all), so consider defaulting installs to `auto`.

**TECH-FEAT3 (P3): speaker enrollment.** Label the user's own voice once for reliable "me vs them"; builds on diarization cleanup.

**TECH-FEAT4 (P3): cross-meeting action tracking.** Surface unresolved action items across meetings.

### Distribution

**TECH-DIST1 (P2): bundle a runtime.** There is no drag-n-drop installer today; install needs Homebrew plus uv plus ffmpeg, and a clean Mac has no usable Python 3 (Apple removed it; the CLT shim is 3.9, below the required 3.11+). Bundle a relocatable Python (python-build-standalone) plus the pipeline wheels and a static ffmpeg into the app, and notarize. This is also what locked-down regulated Macs need, since they often cannot install Homebrew.

**TECH-DIST2 (P3): Swift-port spike.** Evaluate porting the pipeline (now summarize + publish only) to Swift to drop Python entirely. The hard blocker is the local MLX summarizer (mlx_lm is Python; MLX-Swift LM tooling is less mature). Would moot DIST1. Overlaps TECH-I7.

### Distribution note on Python

The pipeline is already "summarize + publish only" (ADR 0007). The realistic options are bundle-the-runtime (DIST1, near-term, unblocks distribution) or port-to-Swift (DIST2, the clean endgame). Relying on system Python is not viable on macOS.

### Docs (finish the consolidation started in Q4)

**TECH-DOC1 (P2): GLOSSARY into ARCHITECTURE.** Append the glossary as an ARCHITECTURE "## Glossary" section, repoint the five references (ARCHITECTURE self-link, CLAUDE.md, CONVENTIONS.md, daemon/CLAUDE.md, pipeline/CLAUDE.md, tech-task.md) to `ARCHITECTURE.md#glossary`, delete GLOSSARY.md.

**TECH-DOC2 (P2): SPEC into README + ADRs.** Fold the surviving user-relevant rationale into a concise README "Why it is shaped this way" section, confirm the architectural why is covered by ADRs 0007/0008/0009, move the duplicated event-log and sidecar schema tables to CONVENTIONS as the single owner (replace the copies in ARCHITECTURE and SPEC with links), rewire the six SPEC references, then delete SPEC.md. Also fix SPEC's own stale content if any survives the merge (it documents three backends, the Whisper/sherpa stack, and a stale repo layout).

**TECH-DOC3 (P2): trim the signal-fusion doc.** Reduce `docs/architecture/signal-fusion-and-mic-gating.md` to the durable "why" (signal classification, Webex ultrasound, Sequoia AX dropouts, zero-frame writer). Fix the stale file tree: the "actor" wording (both types are final class plus NSLock), the deleted InputDeviceSignal/CalendarContextSignal rows, the per-vendor adapter filenames (consolidated into NativeMuteAdapter/NoOpMuteAdapter and NativeLifecycleAdapter), the never-built InternalSpeechProbe, the Locale/ vs Resources/ path, the nonexistent Thresholds.swift, and the os_unfair_lock atomics description.

**TECH-DOC4 (P3): delete Q2 archives, fix design READMEs.** Remove q2-final.md and q2-ui-addendum-final.md (git preserves them; the addendum is also written against a path layout that never existed). Trim the deleted-architecture prose (two-signal AND, WhisperX, three-tab Preferences) from design/README.md and design/ui_kits/macos_app/README.md.

**TECH-DOC5 (P3): superseding ADRs.** Record that ADR 0001 (CoreAudio HAL tap) is superseded by ScreenCaptureKit/SCStream, and note ADR 0002 is partially superseded by ADR 0007.

### Identity and repo presence (promoted)

**TECH-REPO1 (P1): GitHub repo presence.** README hero, a LICENSE file, CONTRIBUTING, and repo metadata (description, topics, social-preview image). This is the in-scope slice of branding, justified by contributor visibility, distinct from the deferred launch band.

**TECH-REPO2 (P1): app visual identity.** Land the distinct signal color (DSN4) and polish the app icon / menu-bar glyph so the app reads as a crafted niche tool, not a default Mac app. The taste already exists in the HUD and tokens; this is consistent application plus a real identity mark.

### Carried-over Q3 items (unchanged specs)

- **TECH-C6-FINISH (P1):** 20+ real detection traces; the corpus has nine synthetic seeds. Add the `detection-corpus/README.md` redaction note required by the stop-and-ask before real traces land.
- **TECH-VALID1 (P0):** run the owed on-device validations for A15 (local cold-start within 10%), A16 (re-run quality/latency), DIAR1 (DER and under-10s), SUM1-APPLE (quality vs local, latency within 2x, zero egress via Little Snitch), UX4 (live degraded banner and `recording.degraded` event on a real failed SCStream). These are runtime acceptance, not code.
- **TECH-UI-X1 (P2):** split MeetingDetailView per tab (target under 250 lines). Pairs with DSN2.
- **TECH-UI-X2 (P2):** split PreferencesView per section (target under 200 lines). Pairs with DSN1.
- **TECH-T2 (P2):** snapshot tests for three SwiftUI views, gated by macOS Appearance.
- **TECH-I6 (P2):** scoped down to the sidecar `publish_state` field plus a per-row indicator; the per-sink result map already exists in `fanout`.
- **TECH-W2 (P2):** near-noop; `WorkflowMatcherTests.test_ties_break_by_order_ascending` already pins order-ascending precedence. Move the assertion into the W2-blessed file or close W2.
- **TECH-E4-FINISH (P2):** the events.jsonl acceptance-bar report script.
- **TECH-UX3/UX5/UX7/UX8:** if any Q3 P2 UX item is still open, re-confirm against current code before scheduling; UX5 and several others landed in Q3 with documented name drift only.

### Deferred (P3, unchanged trail)

TECH-I7 (drop Python; see DIST2), TECH-I8 (live transcription), TECH-G1 (two-Mac hub), TECH-D8 (notarization in CI; partly via DIST1), TECH-CAP1 (mic/system skew, monitor only; spec in q3-final.md), Group F compliance docs (partly activated by BRAND8). The full BRAND launch band (BRAND1-9) stays deferred until an explicit launch decision.
