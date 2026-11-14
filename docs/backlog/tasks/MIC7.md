---
id: MIC7
title: Browser/PWA mute oracle via a platform signal
category: Detection
status: partial
priority: P2
comment: Spike shipped: analysis doc (`docs/spikes/mic7-browser-mute-oracle.md`) + an owner-run read-only DOM probe (`daemon/scripts/mic7-meet-mute-probe.js`, pasted into a live Meet tab's console). Verdict: architecture GO (a `MeetMuteAdapter` fed by a content-script extension, no fusion changes), build DEFER (gate on a real browser meeting, END5's trigger). **Signal gate resolved GO 2026-07-20:** owner ran the probe on a live Meet call and `data-is-muted` flips `'false'`/`'true'` on every toggle (the spike's candidate 1); `aria-pressed` is absent entirely, and the localized `aria-label` + obfuscated `className` stay rejected. Gotchas pinned for the build: the attribute is *state* while the label is the *inverse action*, and it is a string that can be absent, so absent must degrade to unknown, not to unmuted. Remainder narrowed to one item: a real browser meeting (still 0 recorded; the 2026-07-20 probe call was prompted twice and declined both times, so the trigger has not fired). Amended 2026-11-13 by the audit band: D058 confirms browser recordings are RMS-gated only while the architecture doc claims a mute scrape; the owner now picks build the oracle or state browser mute unknown, stop the browser poller and fix the doc.
---

# MIC7: Browser/PWA mute oracle via a platform signal

Band origin: carried from Q4; base spec in q4-final.md, progress notes here. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Progress (2026-07-20): signal gate resolved GO; build gate still closed

**One of the two owner-owed items is done.** The owner ran `daemon/scripts/mic7-meet-mute-probe.js` on a live Meet call and toggled the mic. `data-is-muted` flips `'false'` / `'true'` on every toggle: the spike's candidate 1, a stable boolean, so **the signal-stability gate is GO** and the primary key is found. `aria-pressed` does not exist on Meet's mic button at all (probed `null`), so the fallback candidate is unavailable. The localized `aria-label` flips too (`Вимкнути мікрофон` / `Увімкнути мікрофон`) and stays rejected, as does the build-obfuscated `className`. Full dump and the two implementation gotchas (the attribute is *state* while the label is the *inverse action*, and it is a string that can be absent, so absent must degrade to unknown rather than to unmuted) are in [`docs/spikes/mic7-browser-mute-oracle.md`](../../spikes/mic7-browser-mute-oracle.md).

**MIC7 stays `partial` because the second gate did not fall.** The spike set two required gates, and the build needs both: a stable signal (now GO) *and* a real browser meeting in the corpus (still 0). The 2026-07-20 probe session did put a live Meet call on the machine, and the daemon handled it correctly (`prompt_shown` 13:05:15 local, timed out unanswered; `prompt_shown` again 13:12:19, `user_skipped`), which is useful evidence that browser *detection* works and asks. But a probe call the owner declined twice is not a meeting they wanted recorded, so the promotion trigger has not fired and the recorded-browser-meeting count stays 0. END5 shares this trigger and the extension artifact; build them together when browser usage becomes real.

**Owner-owed remainder (narrowed from two items to one):** a real browser meeting. If the oracle is wanted before that, the research is no longer the blocker and it becomes a scoped build decision (`MeetMuteAdapter` + content-script extension + consent gating). Re-run the probe at build time regardless: the verdict is 4 toggles in one session against one Meet build, which establishes the key exists but cannot measure Meet's deploy churn.

**MIC7 (P2, partial): browser/PWA mute oracle via a stable platform signal (Google Meet first).** Base spec in [`q4-final.md`](../q4-final.md) (search the id). **Progress (2026-07-12): architecture + measuring instrument shipped; the Meet DOM-stability verdict + the build are owner-owed.** The spike doc [`docs/spikes/mic7-browser-mute-oracle.md`](../../spikes/mic7-browser-mute-oracle.md) confirms the surface (browser meetings run `NoOpMuteAdapter` for both `.meet` and `.browser`, so they are energy-gated; MIC5 redaction degrades to an RMS guess there, though MIC4 already removed the data-*loss* mode, capping urgency) and the futureproof shape: a `MeetMuteAdapter: MicGateAdapter` fed by a content-script extension over a loopback/native-messaging channel, calling the same `sink(.muted/.unmuted)` the native adapters do, so no fusion changes. The crux, "spike the Meet DOM signal's stability," cannot be answered in this harness (no authenticated live Meet), so the deliverable is an owner-run, read-only console probe `daemon/scripts/mic7-meet-mute-probe.js` that dumps the mic button's candidate signals (`data-is-muted` / `aria-pressed` booleans vs the localized `aria-label`, the fragile native-title analog) and logs which one flips on every mute toggle. Verdict: **architecture GO, build DEFER, signal-stability owner-owed.** The build is gated on a real browser meeting appearing (END5's identical promotion trigger, 0 browser meetings in 19.8 days; they share the extension artifact + consent gating and should be built together), and on the probe finding a stable boolean rather than only a localized label (do not ship a localized-string oracle, the native incident settled that). Owner-owed remainder: run the probe on a live Meet call; a stable-boolean result promotes MIC7 + END5 to a real build, a localized-only result closes the Meet leg until Meet exposes something stabler.

## Owner walkthrough (for the session that picks this up)

Added 2026-07-30 at the owner's request: every task gated on an owner action carries one. Walk the owner through it step by step; the owner does not read code. Steps are tagged [owner] / [session] by who acts.

1. Nothing is runnable until a real browser (Google Meet) meeting happens; the task un-gates itself the day the owner records one (the daemon already detects Meet tabs and prompts, proved 2026-07-20). END5 shares the trigger and the extension artifact; build them together.
2. [owner] To have the oracle before that day, say so explicitly: the research is no longer the blocker and it becomes a scoped build (`MeetMuteAdapter` + content-script extension + consent gating).
3. [owner, at build time] Re-run the DOM probe on a live Meet call regardless: open the Meet tab's DevTools console, paste `daemon/scripts/mic7-meet-mute-probe.js`, toggle mute a few times, copy the output for the session. The 2026-07-20 GO was 4 toggles against one Meet build; the re-run is the deploy-churn check.
4. [session] Pass is `data-is-muted` still flipping `'false'`/`'true'` on every toggle. Then build, with the two pinned gotchas: the attribute is state while the label is the inverse action, and an absent attribute degrades to unknown, never to unmuted.

## Amendment 2026-11-13 (audit band)

Added from the [2026-11-13 recording-reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) finding D058 (low, demonstrated in log; full entry in the [evidence](../../audits/2026-11-13-recording-reliability-evidence.md)). Re-verified in code at HEAD (`3a2da4fc`) on 2026-11-13. Status stays `partial`, priority stays P2.

**What the audit confirms.** `MeetingAXHandleBuilder.build` returns `micGate: MicGateAdapterHandle()` (empty) for every `kind == .browser` source and logs its diagnostic with `foundMute: false`; `Coordinator` registers `NoOpMuteAdapter(config: .meet, ...)` and `NoOpMuteAdapter(config: .browser, ...)`, which log `meet_adapter_no_ax_signal` and supply nothing. No code scrapes the Meet or Teams-web mute button. A browser recording is therefore gated by RMS only. Yet `docs/architecture/signal-fusion-and-mic-gating.md` says otherwise in three places: "AX scrape of the meeting page's mute button is attempted when the active tab is a Meet or Teams-web tab", the Teams browser paragraph's "AX scrape can succeed because the Teams web client exposes the mute button", and the Meet paragraph's "AX scrape of the Meet mute button is attempted opportunistically". Separately, `MeetingSessionController.engageMicGate` builds and starts `MeetingAXWindowWatcher` (the 1 Hz mute poller) with no kind check, so a browser recording runs a poller that has no button to find.

**Field evidence.** The only browser recording in the work-laptop window, stem 20261005-180843 (com.google.Chrome, 13.4 min, 2026-10-05T15:08:43Z to 15:22:10Z): `meet_adapter_no_ax_signal` 1, `vad_unsupported` 1, `mute_state_cleared_blind` 1 (`poll_count` 3, previous null), 0 `mute_state_polled`, 0 `ax_mute_button_state`, and the verdict `silent_by_rms` for 88% of the time. The cost today is small: 1 browser recording in 74, capture-first keeps all audio, and `workflow_nda_mode` is false on every sidecar. It matters to a redact-muted workflow (nothing to redact on a browser call) and to the regulated gate (RMS-only zero-fill; [MIC18](./MIC18.md)'s amendment).

Correction at filing: the class named two doc passages; the Teams browser paragraph is a third with the same claim.

**Owner decision (added).** The audit asks the owner to pick one of two, and this amendment makes that the next step instead of waiting on a real browser meeting:

- **A. Build the oracle** the spike already validated (`MeetMuteAdapter` fed by a content-script extension, consent gating, built with END5), per the walkthrough above.
- **B. State plainly that browser mute is unknown.** `engageMicGate` skips `MeetingAXWindowWatcher` when `handles.context.kind == .browser` and logs once per recording `micgate` / `mute_oracle_unavailable` with `kind: browser`; the three doc passages say no browser mute signal is read; GUIDE.md and the README say muting in a browser call is not seen and the off-the-record hotkey is the only control there.

Under either option the architecture doc is corrected in the same commit as the code.

**Acceptance additions.**

- Option B: a `MeetingSessionController` engage test with a browser context starts no mute poller and emits one `mute_oracle_unavailable`; a native context still starts it. A grep fence (or a truth-fence line) that the architecture doc no longer claims a browser AX scrape.
- Option A: the acceptance of the build as already specified above, plus the doc correction.
- `cd daemon && swift build` and `swift test` green, `python3 scripts/truth_fences.py` green for any new event action, new test count in the commit body.

**Owner walkthrough addition.**

5. [owner] Choose A (build the browser mute oracle) or B (browser mute stays unknown and is said so). One line is enough.
6. [session] Implement the chosen option with the doc correction in the same commit.
