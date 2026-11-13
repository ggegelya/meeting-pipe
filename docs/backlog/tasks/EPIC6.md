---
id: EPIC6
title: Epic (parked): every product-direction idea below the filing bar, one line each with its first probe and what would promote it
category: Feature
status: deferred
priority: P3
comment: Umbrella, not a work item, and parked: nothing here is to be started. Filed 2026-11-13 (product-direction band) so no idea from the 2026-11-12 report is lost: the 27 ideas that scored under 14 of 20 or were folded into a filed child. Not-for-sale crossings marked NFS. Promotion is an owner decision that files a real task from the line here.
---

# EPIC6: epic (parked), product-direction ideas below the filing bar

Band origin: filed 2026-11-13 as the parking umbrella of the product-direction band ([report](../../research/2026-11-12-product-direction.md), "Ranked ideas" and "The top ideas in detail"; the raw ideation result carries every idea's full pitch, probe and judge notes). This file is the P3 rule in practice: listed so the trail stays readable, not work to start. Promoting an idea means the owner asks for it, and a session files it as a real task with `/file-task` from the line below and the report's text. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

The bar: an idea got its own task if all three judges picked it, if it was a judges' subtraction pick, if it was a rewrite verdict, or if it scored 14 or more and was not a duplicate. Duplicates scoring 14 or more were folded into the task they duplicate (idea I38 into [ASR9](./ASR9.md), idea I31 into [SEC32](./SEC32.md)). "Score" is the three judges' mean total out of 20.

## Folded into filed tasks (kept here for the trail)

- **I15** Airgap by construction, whole-app kernel deny (12.33, duplicate of I01). Folded into [SEC32](./SEC32.md), which wraps only the mp child; confining the daemon is refused because FluidAudio 0.14.8 deletes its cache on a load error and cannot refetch under a deny.
- **I17** One process, one language: retire the Python sidecar (10.33, radical). Its stage zero is [LOCAL24](./LOCAL24.md); the port itself waits on that verdict.
- **I34** Clean-room Rust reader of the bundle format (12.00, radical, duplicate of I14). Filed as the P3 experiment [ARCH23](./ARCH23.md).

## Parked ideas

| Idea | Score | Pitch in one line | First probe (from the report) | Promote when |
|---|---|---|---|---|
| I30 Meeting-shaped speech benchmark | 13.33 | ASR4's harness in two modes: public corpus turned recorder-shaped stereo, and the owner's private set, counts-only results | 8 days; owner gate on corpus licence and channel layout, 10 synthetic stereo meetings through an env-gated XCTest | [ASR7](./ASR7.md) returns CLOSED and ASR4 needs a public half |
| I22 The minute after: spoken debrief | 12.67 | After a call, speak up to 60 s, mic only; it steers the summary and proposes names, title and series as confirmable labels | 10 working days, zero product code, debriefs via `meetingpipe://record?byo=1` | The owner asks for it after the voice census reports |
| I21 Muted asides as a private margin (market-skeptic pick) | 12.66 | Owner speech while muted becomes an owner-only margin layer, never sent to sinks | 5 days retroactive, MeetingPipeCore-linked Swift package over the Teams log plus a week of deliberate asides; 18 of 20 really muted for GO | The audit's F036, G027 (mute fusion fixes not holding) and F107 are fixed; the F041 truth gap (muted speech is published today) is a defect, not this idea |
| I02 Consent ledger (NFS) | 12.34 | Asserted notice state per recording, set by a key or workflow default, never inferred | 10 days, three legs, counts only, a log-only `consent` event | A second user or an external obligation; crosses the not-for-sale line |
| I05 Sealed record, chain of custody | 12.33 | Hash the raw capture at stop and append every transform, edit and publish to a custody log | 14 days, seal-only script plus nightly verifier; 0 unexplained changes | An external need to prove a record unaltered |
| I44 Close the language question by deleting the second copy | 12.33 | Delete the Swift Apple summarizer, the staged summarizer and the LoRA trainer, cut unused engines | 4 days, tally `backend` across `.run.json`; delete under 10% of last 200 | Its deletion half is [PIPE20](./PIPE20.md)'s; its boundary half waits on [LOCAL24](./LOCAL24.md) |
| I12 Agent-composed pre-meeting brief | 12.00 | An assistant holding the calendar asks the library for `person(name)` with receipts | Under two weeks, 10 meetings, attendee resolution counts | [AUTO9](./AUTO9.md) usage GO and the voice census GO |
| I40 Meeting key from the Teams client log | 12.00 | Find a series identifier in the Teams logs the daemon already tails | Script only, never prints a token; coverage first, then byte-for-byte repeat across instances | CAL3's measurement (VALOWN1) still unrun and a series key wanted |
| I03 One footprint per meeting, retention classes and deletion certificate | 11.67 | A footprint enumerator owning every destructive path | 5 days, scratch home, canary tokens deleted through each path | The audit's F001 and F020 class recurs after their fixes |
| I28 CallSense: publish MeetingPipeCore as a package | 11.67 | Sensing layer as its own package, contributions as redacted traces | 6 days, scratch package, `callsense watch` beside the daemon for 10 calls | The END and MIC fixes hold (7 of the 18 unheld fixes sit in this layer) |
| I23 Notes that cite | 11.66 | A short one-voice recording is a Note and a retrieval query over past meetings | 7 days, zero product code, embed_index lookups | The owner asks for voice notes |
| I04 Voiceprint register (NFS) | 11.00 | Basis, retention clock and off switch for embeddings | 4 days read-only, simulated clocks | A second user or a legal need; works against the naming the owner wants |
| I18 A recorder that outlives its UI | 10.34 | Headless capture agent with thin clients over a socket | Under a week: TCC persistence of an ad-hoc LaunchAgent and agent Neural Engine dispatch | [ASR8](./ASR8.md) PASS and a stable signing identity (Developer ID is NFS); [ARCH22](./ARCH22.md) takes stages 1 and 2 |
| I39 The person is the unit (radical) | 10.34 | One page per confirmed voice becomes the Library's home | Script only, five person pages, after the census | [DIAR10](./DIAR10.md) GO |
| I19 Satellites, not companions | 10.33 | An inbox folder ingests phone or room recordings as meetings | Under two weeks, 8 to 10 in-person recordings, owner hand labels | A two-week tally of wished-for in-person captures is not zero (assessor's demand check) |
| I25 Inbox: the phone is the in-person recorder | 10.33 | Duplicate of I19 with a drop folder and Add recording action | 10 days, 8 consented in-person recordings | Same as I19 |
| I11 Agent-resolved commitments via inert proposals | 10.32 | The library's first write tool, a reversible proposals overlay | One week, 50 old actions given to an agent session, search only | [AUTO9](./AUTO9.md) usage GO; every judge refused an MCP write tool this quarter |
| I14 The memory kernel (radical) | 9.67 | One sandboxed read-only process owns every read | Two weeks, fixture library, second implementation of three tools | Closed in-tree by the assessor; reopen only with a real need to read the library off the Mac |
| I07 One door: a Rust egress broker (radical) | 9.66 | A standard-library-only CONNECT broker as the whole trusted base | 6 days, a 150-line Python broker first | [SEC32](./SEC32.md) FAIL and SEC19 insufficient |
| I13 Spotlight and Siri tools on macOS 27 (NFS) | 9.33 | Donate open-tier entities and three read intents on a local development identity | 10 days, fixtures, step 0 checks search without signing | App Intents survive [FEAT22](./FEAT22.md) and step 0 needs no signing change |
| I09 Sealed tier, unreadable at rest (radical) | 8.67 | NDA and regulated meetings stored encrypted | One week, fixtures, coding-agent sessions against a canary | AUTO5's file-reading bypass recurs on a withheld meeting |
| I24 Conversations, not apps | 8.67 | Detect any two-way voice conversation by audio shape | 8 days, existing det10 and det8 probes during real calls | [DET16](./DET16.md) FAIL shows calls outside Teams matter |
| I27 Own-voice ledger, always armed (radical) | 8.33 | Mic armed outside calls, keeping only verified owner speech | 5 days offline, voiceprint trials over stereo meetings | Safety scored 1 by a judge; reopen only on the owner's explicit ask |
| I20 Rust as a portable library kernel (radical) | 8.00 | One static Rust binary owning format, gate, search and MCP | Under a week, read path only, parity on fixtures | The library has to leave the Mac (not a current need) |

## Not-for-sale crossings (NFS)

I02, I04 and I13 cross the project's not-for-sale list as filed in the report. Also recorded: idea I01's durable replacement for `sandbox-exec` (App Sandbox or a NetworkExtension filter) needs a Developer ID; idea I33's publication half (a launch post or site) and idea I31's public kit are publishing; idea I18's stage 3 needs stable signing. None is filed above P3.

## Done when

Never closes by work: each line either stays parked or leaves by a promotion that files its own task.
