---
id: ASR8
title: Spike: does the menu-bar agent still get the Neural Engine on macOS 27.2, and does FluidAudio 0.18.3 hold on three long owner meetings; upstream the numbers either way
category: Transcription
status: new
priority: P2
comment: Filed 2026-11-13 (product-direction band, idea I32, 14.67 of 20, owner-advocate pick: "run it first, if the agent has lost the accelerator every other plan re-orders"): the audit measured Neural Engine dispatch only from a foreground CLI, upstream quotes Apple restricting background access on OS 27, and the pin is four minor versions behind. /spike shaped, three days: MLComputePlan from inside the agent plus foreground vs agent RTF on 0.14.8 and 0.18.3; all three bars pass bumps the pin, any miss becomes one upstream issue with the table. Needs a fresh build. Child of [EPIC1](./EPIC1.md).
---

# ASR8: spike, Neural Engine access from the menu-bar agent and a three-file FluidAudio 0.18.3 check

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), idea I32, "Upstream first: give FluidAudio the background-agent, long-form, bilingual regression case instead of extracting anything"). Child of epic [EPIC1](./EPIC1.md). `/spike` shaped. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## The one question

**On macOS 27.2, does the transcription that runs inside the menu-bar agent get the same Neural Engine dispatch and real-time factor as a foreground run, and does FluidAudio 0.18.3 keep or improve speech coverage on the owner's long meetings?**

## Context, verified 2026-11-13

- The 2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md) measured MLComputePlan from a foreground process only (encoder 1,381 ops on the Neural Engine and 4 on CPU, decoder and joint on CPU, wespeaker 1,149 ops on GPU) and lists background dispatch on 27.2 as an unmeasured fact worth knowing. Upstream FluidAudio issue 738 quoted Apple restricting background Neural Engine access on OS 27; [ASR6](./ASR6.md)'s 2026-11-12 amendment records it closed 2026-08-19 and 0.18.3 ready to qualify, with ModelHub (0.15.5) the one breaking API.
- `daemon/Sources/MeetingPipe/FluidAudioRunner.swift` is the only runner (ADR [0007](../../decisions/0007-python-sidecar.md) context, ADR 0002); it sits at 44.7% coverage with no inference test, `daemon/Package.resolved` is untracked, and the installed app was a 2026-09-11 binary driving HEAD Python (F021), so a measurement means something only on a fresh build.
- 0.14.8 deletes its model cache and re-downloads from huggingface.co on a load error; every run here uses an isolated home and model cache.

## Relation to existing tasks

This executes [ASR6](./ASR6.md)'s "qualify any bump" leg with a three-file measurement instead of waiting for [ASR4](./ASR4.md)'s golden set; ASR6 stays the watch task for a second runner. [ASR7](./ASR7.md) step 3 reads the same question coarsely from the event log; this is the direct measurement. [ASR9](./ASR9.md) reuses this spike's scratch 0.18.3 build.

## Pre-registered verdict thresholds (copied from the report)

Add an env-gated debug path that runs MLComputePlan for the four models from inside the running menu-bar agent and logs op counts per compute device. Transcribe the same three owner-chosen files (about 10, 60 and 120 minutes) in the foreground and in the agent, on 0.14.8 and on 0.18.3 in a scratch checkout.

| Verdict | Measured | Next |
|---|---|---|
| **PASS** | Agent Neural Engine op share within 5 percentage points of the foreground reading, AND agent real-time factor within 20% of foreground, AND 0.18.3 does not increase uncovered-speech seconds (`valid1_check.py --attribution`) on any file | Bump the pin (owner approves the dependency change) and close ASR6's open question |
| **MISS** | Any one bar missed | One upstream issue with the table attached; the pin stays with a dated reason in ASR6 |

Either way the open question ends inside the window.

## Explicitly not

- A second ASR runner or a Python fallback (ADR 0007 rejected it).
- Shipping the debug path enabled: it is env-gated and off by default, and it never writes audio or text, only op counts and timings.
- Re-transcribing the library; that is [ASR9](./ASR9.md).

## Owner walkthrough

The owner picks three files (about 10, 60 and 120 minutes; at least one Ukrainian or code-switched), runs `./scripts/rebuild.sh`, sets the env flag, and runs the probe command written into the spike doc. The READ line prints PASS or MISS with the three figures.

## Deliverables and acceptance

- `docs/spikes/<id-lowercase>-ane-agent-and-fluidaudio-0-18.md` with the thresholds verbatim and the owner command.
- The env-gated MLComputePlan dump path in the daemon, off by default, plus a test that it is inert without the flag; `swift build` and `swift test` green.
- The scratch 0.18.3 package lives outside `daemon/` and never touches the app's pin until PASS and the owner's approval.
- On MISS: the upstream issue text drafted in the spike doc for the owner to post (nothing is posted on the owner's behalf).
