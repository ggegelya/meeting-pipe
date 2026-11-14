---
id: REC35
title: Nothing is captured before consent, so each recording's first sample trails the prompt by the owner's reaction (median 4.4 s, p90 12.7 s, max 24 s) on top of the scan wait
category: Recording
status: new
priority: P3
comment: Filed 2026-11-13 (audit band 2026-11-13). Capture starts only at Record, with no pre-roll, so on the work laptop the first sample trails the prompt by a median 4.4 s (p90 12.7 s, max 24 s, n=61) and first sighting by 5.5 s (p90 17.0 s), and 18 of 58 prompt-answered transcripts open on speech inside 3 s; the deliberate consent-before-capture design, so P3. Owner decides whether pre-consent in-memory audio is acceptable, then a short memory-only ring opened on the call edge, prepended on Record, dropped otherwise, never under regulated or NDA.
---

# REC35: Nothing is captured before consent, so each recording's first sample trails the prompt by the owner's reaction (median 4.4 s, p90 12.7 s, max 24 s) on top of the scan wait

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: D020 (low, demonstrated in log) in the [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md), cause (4) of its start-edge summary, with the measurement in the [evidence file](../../audits/2026-11-13-recording-reliability-evidence.md). Code re-read at HEAD 3a2da4fc on 2026-11-13.

**Capture begins at Record and not before.** `MeetingSessionController.beginRecording` resolves the workflow (`WorkflowMatcher.resolve`, with the prompt's `pendingWorkflowOverride`) and the capture mode (`CaptureMode.resolve(regulated:nda:redactMuted:)`), then calls `self.coordinator.audioRecorder.start(outputDir:captureMode:voiceProcessing:)`. That is the first moment any call audio is kept. `daemon/Sources` has no pre-roll or ring buffer (the only grep hit for "ring buffer" is an unrelated comment in `InputDeviceRecovery.swift`). The prompt does open the microphone earlier, but only to animate a meter (`MeetingPromptWindow`'s `MicLevelMonitor`), which [REC18](./REC18.md) wants removed.

**Field (work laptop, 2026-09-29 to 2026-11-13, all three build eras).**
- Prompt to `recording_started`, pairing each `prompt_shown` with the next same-bundle `recording_started` (unanswered prompts reset the pair, gaps of 120 s or more excluded): n=61, median 4.4 s, p90 12.7 s, max 24.0 s, min 1.5 s.
- First sighting to `recording_started`, 52 Teams calls recorded on the prompt: median 5.5 s, p90 17.0 s, max 26.1 s. The scan wait before first sighting is not measurable (the log has no join timestamp).
- 18 of 58 prompt-answered transcripts open with speech inside the first 3 s, i.e. the recording began on talk already in progress.
- Era C (2026-11-12 and 2026-11-13, detection code equal to HEAD): two of five answers took 15.0 s and 24.0 s (stems 20261112-163040 and 20261112-170131); the Zoom one was recorded from 48 s after Zoom first showed a control, and its transcript opens on speech at 0.5 s.

**Why P3.** This is the deliberate consent-before-capture design, not a regression. The audit's "minutes of every call" is overstated: typically a few seconds, sometimes tens of seconds. Minutes are lost only when a prompt is answered very late or never, and those are [DET18](./DET18.md)'s (prompt timeout, flicker, bundle-keyed skip).

Correction at filing: the batch and the audit direction attribute the regulated and NDA exclusion to "ADR 0016's consent clause". [ADR 0016](../../decisions/0016-capture-first-mute-redaction.md) has no consent clause; what it says is that the regulated and NDA path keeps a real-time gate because "no audio at rest is permitted" there. No ADR records consent-before-capture at all: it is the prompt's behaviour, unwritten. So the owner decision below is a new one, best recorded as an ADR (or an ADR 0016 amendment) before any code. Correction at filing: the title's figures are prompt-to-first-sample, the owner's reaction; the scan wait comes on top and is unmeasured, so the title says so rather than presenting 4.4 s as the sum.

## Scope

Gated on the owner walkthrough's decision. If the owner says yes:

1. **Open the ring on the call edge.** When a call session opens (the process-audio edge that the mic-session work in [DET23](./DET23.md), [DET25](./DET25.md) and [DET26](./DET26.md) is building; until then, the moment `MeetingSessionController` raises a prompt), start capture into an in-memory ring of at most N seconds per channel (N set by the owner, default 30 s, covering the measured max of 26.1 s first sighting to start). Memory only: no file, no temp file, nothing in raw/ or originals/.
2. **Consent decides.** On Record, `beginRecording` resolves the capture mode as today; if it is `.captureFirst` or `.captureFirstRedact`, the ring is handed to `MeetingRecorder.start` and written ahead of the first live buffer, keeping ADR 0009's per-channel frame parity and offsetting the mute timeline, flag markers and `held_end_trim_sec` by the prepended length. On Skip, prompt timeout, a withdrawn prompt or a lifecycle end before Record, the ring is zeroed and released.
3. **Never under regulated or NDA.** With global regulated mode on (known before consent), no ring is opened. When the resolved capture mode at Record is `.regulatedGate` (an NDA workflow, which may be picked on the prompt itself), the ring is dropped unused.
4. **Say so.** Emit `recorder` / `preroll_prepended` (`seconds`, per channel) or `preroll_dropped` (`reason`: `skip`, `timeout`, `withdrawn`, `regulated`, `nda`), document them in `CONVENTIONS.md`, and state the behaviour in `docs/GUIDE.md` and the prompt's own copy in the same commit.

## Explicitly not

- Shortening the prompt or auto-recording: the default prompt action and its 30 s timeout are [DET18](./DET18.md)'s, and auto-consent is the owner's per-app choice.
- A provisional file instead of a memory ring. The audit offers it; it is audio at rest before consent, which the posture this task protects rules out.
- Pre-starting system capture alone to dodge the SCStream start hang (33.2 s of far-side audio lost in 20261015-170719): a capture-health question, not filed here.
- Detection latency before first sighting (the scan wait): the detection band.
- REC18's meter mic. If REC18 removes it and this task lands, the mic indicator lights from the call edge instead, which is the trade the owner weighs below.

## Acceptance

- A pure ring type in `MeetingPipeCore` with tests: holds at most N seconds per channel and overwrites the oldest; `drain` returns frames in order with the count; `discard` leaves it empty.
- A pure keep-or-drop decision with a test per branch: Record under `.captureFirst` prepends; Record under `.captureFirstRedact` prepends and shifts the timeline; Record resolving to `.regulatedGate` drops with `nda`; global regulated mode never opens one; Skip, timeout, withdrawn prompt and an end before Record each drop with their reason.
- `MeetingRecorderTests`: a start handed a 10 s ring produces intermediates 10 s longer at frame parity, and a manual off-the-record span and a flag pressed after start land 10 s later in the timeline and markers than without the ring.
- `cd daemon && swift test` green with the number of new tests in the commit body; `python3 scripts/truth_fences.py events` green; `bash scripts/ci-local.sh` green.
- Field bar: over the next 20 prompt-answered recordings, the share whose transcript opens on speech inside 3 s falls from 18 of 58 to at most 2 of 20, and no `preroll_prepended` row exists for a recording whose meta sidecar says NDA or regulated.

## Owner walkthrough

1. [owner] Decide whether call audio may sit in memory for up to N seconds before you answer the prompt, with the macOS microphone indicator lit from the moment a call is detected, and dropped if you skip. Pick N. Record the answer as an ADR or an ADR 0016 amendment. A no closes this task as declined.
2. [session] If yes, implement per Scope, then confirm the installed build on the work laptop is newer than the landing commit.
3. [owner] Answer the next prompts as usual, a few seconds into each call; skip one deliberately.
4. [session] Grep `events.jsonl` for `preroll_prepended` and `preroll_dropped` per stem, check the skipped call left no file anywhere under raw/ or originals/, and count transcripts that open on speech inside 3 s against the field bar.
