# Q4 DONE-task validation (2026-06-26)

Audit of every item the Q4 backlog marked DONE, to confirm each is really finished and wired end to end (UI included where it is a UI feature), before archiving Q4 and opening Q5. Trigger: FEAT4 (cross-meeting action tracking) was marked DONE but is invisible in the app. Confirmed root cause: it shipped as a CLI-only MVP (`mp actions`) with no daemon surface, and the same pattern holds for FEAT2 (`mp ask`).

## How this was run

Two-stage, evidence-first: a per-subsystem agent read each item's done-note then verified it against the actual Swift / Python / CI code (not the note), classifying each as done-done / done-no-ui / partial / not-done with file:line evidence; a second adversarial agent re-checked every verdict and defaulted to the more conservative call. The first pass hit server-side API rate limiting (two large agent fan-outs running at once); it was recovered by re-running the failed clusters alone and re-verifying the 24 rate-limited rechecks throttled to 3 agents at a time. Two verdicts were hand-corrected: PERF2 (a no-UI perf task mislabeled done-no-ui -> done-done) and MIC6 (never audited because of a cluster-list omission; audited by hand -> partial, see below).

## Result

| Bucket | Count | Meaning |
|---|---|---|
| done-done | 68 | Claim verified against code; fully wired (UI present where expected). Archived. |
| done-no-ui | 2 | Backend/CLI works and is tested, but the user-facing UI a normal user expects is absent. Carried to Q5. |
| partial | 9 | Shipped with an explicitly deferred remainder, or scaffolding with runtime/data owed. Carried to Q5. |
| not-done | 1 | The done-claim does not hold. Carried to Q5. |

**Headline: nothing was fabricated.** No item claimed-done is outright false except T2 (whose snapshot infrastructure was later removed as non-portable). The real gaps are two CLI-only features with no UI (FEAT2, FEAT4) and ten items with honestly-documented deferred remainders or owner-owed runtime validation.

## Carried to Q5 (the gaps)

| ID | Verdict | Gap to close in Q5 | Evidence |
|---|---|---|---|
| T2 | not-done | T2 acceptance bar (Appearance-gated snapshot tests for 3 SwiftUI views via swift-snapshot-testing) is unmet; image snapshots were abandoned as non-portable across macOS/Xcode versions. Carry forward: either close T2 as … | Note claims swift-snapshot-testing dep + SnapshotTests.swift + 6 PNG refs under Tests/MeetingPipeTests/__Snapshots__/. None exist: Package.swift test deps=["MeetingPipe"] only; no SnapshotTests.swift… |
| FEAT2 | done-no-ui | Faithful on-device vector/embedding RAG over the library (reusing the MLX model + a persisted index) still deferred; and surfacing "ask my meetings" through a daemon SwiftUI surface (currently CLI-only). | ask.py is a real stdlib TF-IDF ranker; registered __main__.py:111 + USAGE:43; 7/7 test_ask.py pass asserting ranking/snippet/JSON; README:310-317. Daemon shells only doctor/prefetch/serve-local, neve… |
| FEAT4 | done-no-ui | No daemon SwiftUI cross-meeting actions surface (CLI-only). ActionItem schema has no resolved/done flag, so every extracted action counts as open and cannot be marked done; a done flag + UI to set it is the named Q5 fol… | actions.py discover/filter/sort wired at __main__.py:114 + USAGE:46; test_actions.py 5 tests assert real sets/order/empty; README:319. Daemon only renders one meeting's actions (SummaryRenderedView.s… |
| C6-FINISH | partial | Acceptance bar (20+ real dogfood detection traces) unmet: corpus still 9 synthetic seeds, 0 real. Real traces explicitly owed by the user (runtime data captured from live meetings, redacted via scripts/redact_detection_… | redact_detection_trace.py fails closed on PII (exit 1, email caught) + rewrites pid->1234; README.md:13-46 redaction note; DetectionCorpusTests.swift INDEX-driven, CI .github/workflows/ci.yml:153-175… |
| DSN3 | partial | Font-literal migration (~135 .system(size:) sites) and the "one button language" unification, both named in DSN3's own scope, are explicitly deferred; only new font drift is blocked by the diff-guard. Carry both to Q5. | Tokens.swift:144-174 (.mpDanger/.mpWarning/.mpSuccess/.mpSignal on Color+ShapeStyle) + :43-53 speakerPalette; ~25 token sites across 11 views; raw-color guard returns 0; ci.yml:59-105 design-tokens j… |
| DSN9 | partial | Owner-owed pixel-level spacing/alignment retune of the General/Recording/Prompt/Pipeline panes: needs a Claude-Design review against rendered pixels + paired primitives.jsx revision to set new spacing/column targets bef… | Commit bb1fd40 is a literal->token swap only (16->s4,4->s1,8->s2,12->s3; Tokens.swift:214-217 confirms identical values), zero visual change. All 4 named panes route through primitives (General 11/Re… |
| END2 | partial | Apply requiresCorroboration to the handleEndingProvisional fast path so ax-leave+window-gone (correlated-pair, 2026-06-09 fragments 1/4) no longer promotes instantly; land a genuinely-independent corroborator (device-id… | Confirmed: re-walk seam wired (AXLeaveButtonSignal.resolveElement <- LifecycleAdapter.resolveLeaveButton <- findAllLeaveButtons; rescueProvisionalEnd:659->confirmProvisionalEnd). Guard at PromotionEn… |
| END3 | partial | Clock-feed IdleStopBackstop.ingest from the ~1 Hz onMicLevel callbacks or a 1 Hz tick so a stabilized-silent meeting keeps re-evaluating and the nudge/auto-stop horizons can fire. Tracked as END7 (P1) in the Q4 backlog;… | MicGate.swift:238 dedupes identical verdicts; ingest fed only from that stream (MeetingSessionController.swift:72), no tick/onMicLevel. IdleStopBackstop.ingest advances elapsed only when called, so a… |
| FEAT3 | partial | FEAT3-VOICEPRINT (real voiceprint for mono/merged/non-dominant) + FEAT3-ROSTER; plus a Preferences field + README note for summarization.user_label so enrollment isn't TOML-hand-edit only. | rg user_label daemon/ = 0 hits (exit 1); ConfigStore.swift:113-118,180-184 persists 5 summarization keys, not user_label. Wired orchestrate.py:469,495 from cfg.summarization.user_label (:239); config… |
| MIC6 | partial | The headline part-1 migration (read the button's stable state attribute AXValue/pressed-state instead of the localized title scrape) is owed, gated on an owner-run live AX dump (daemon/scripts/ax-dump-meeting.swift) to … | Parts 2/3/4 verified+green: AXMuteButtonProbe.swift:49 defaultRearmThreshold=5 + noteUnknownAndMaybeRearm (3 tests), MeetingAXWindowWatcher.swift:167-190 blind-clear decoupled from lastEmitted (test_… |
| PERF5 | partial | 4 Hz engine-tick gating: expose PromotionEngine pending-debounce/deadline state and arm/disarm the coordinator tick on engine-state changes (engineQueue<->main timer lifecycle) so the 0.25s detection tick backs off when… | Poll-backoff half real: AdaptivePollCadence wired into ProcessAudioSignal/AXLeaveButtonSignal/AXMuteButtonProbe via noteListener+self-rearming startPoll; 5 asserting tests. Engine-tick half absent: M… |
| VALID1 | partial | Run the 5 owed on-device measurements on a real Apple-Silicon Mac: A15 cold-start within 10%, A16 quality/latency, DIAR1 DER + under-10s (and step-ratio 0.1 vs 0.2), SUM1-APPLE quality/2x-latency/zero-egress via Little … | Both artifacts exist & match note: scripts/valid1_check.py (158L, stdlib, ruff-clean; ran it: UX4 exits 1, prints timings) + docs/validation/valid1-acceptance-runbook.md (empty results table). Events… |

## Archived as done-done (68)

Each verified against code; full per-item evidence is in the run transcripts. Grouped by area:

- **Security/privacy:** SEC1, SEC2, SEC3, SEC4, SEC5, SEC6, SEC7, SEC9, install-keep-tcc
- **Concurrency:** CONC1, CONC2, MIC2
- **Performance:** PERF1, PERF2, PERF3, PERF4
- **Architecture/extractions:** ARCH1, ARCH2, ARCH3, ARCH4, H1-FINISH, UI-X1, UI-X2
- **Capture/MicGate:** MIC1, MIC3, MIC4, MIC5, MIC9, A17
- **End-detection:** END1, END4
- **Workflow editor:** WF1, WF2, WF3, WF4, WF5
- **Design/Library:** DSN1, DSN2, DSN4, DSN5, DSN6, DSN7, DSN8, DSN10, DSN11, DSN12, DSN13, DSN14, DSN16, DSN17
- **UI/UX detail:** UX11, UX12, UX13, I6, FEAT6, FEAT7
- **Features:** FEAT1, FEAT5
- **Docs/identity/tests:** DOC1, DOC2, DOC3, DOC4, DOC5, REPO1, REPO2, W2, E4-FINISH, DIST2

## Notes on the consequential calls

- **FEAT4** (cross-meeting action tracking): `mp actions` aggregates open action items across the library, registered and tested, but no daemon view calls it; the app only renders one meeting's actions in its Summary tab. `ActionItem` has no resolved/done flag, so every action counts as open forever. -> Q5: schema done-flag + a cross-meeting actions surface.
- **FEAT2** (local semantic search): `mp ask` is a real stdlib TF-IDF ranker, CLI-only; the named vector/embedding RAG successor and any daemon surface were never built. -> Q5: engine-backed cited Ask-AI + a daemon surface (spike-gated on latency).
- **MIC6** (native mute oracle): the four shipped parts (cross-locale fallback, element re-arm, decoupled blind-clear, uk labels) are present and tested; the headline part-1 migration (read the button's stable state attribute instead of the localized title) is owed, gated on an owner-run live AX dump. -> Q5 (overlaps MIC8/MIC10).
- **T2** (snapshot tests): the swift-snapshot-testing dependency, SnapshotTests.swift, and the PNG references were removed (commit de3bf35, non-portable across macOS/Xcode on the macos-15 runner) and replaced by construction-only smoke tests. The Appearance-gated visual-regression bar is unmet. -> Q5: close as won't-do or adopt a CI-portable approach.
- **END2/END3** partial residuals are exactly the open END6/END7 specs (corroboration fast-path; clock-feeding the idle backstop); folded there in Q5.
