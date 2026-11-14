---
id: DET24
title: Spike: does a browser's or Zoom's audio process read input true through a real call on the work laptop (bars B1, B2, B3, Z1)
category: Detection
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). Every browser and Zoom rule in the 2026-11-13 plan rests on facts no log holds (0 browser mic rows by construction, 3 Zoom calls), so the session writes the analysis doc with bars B1, B2, B3, Z1 and the duplex-playback bar pre-registered, adapts the read-only DET8 probe to name a family, print ancestry and a READ line, and the owner runs it idle, through Chrome Meet joins, one Zoom call and a playback check. P2 in DET rather than VALOWN P4 because the verdict gates P2 engineering; DET16's count runs first.
---

# DET24: Spike: does a browser's or Zoom's audio process read input true through a real call on the work laptop (bars B1, B2, B3, Z1)

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: stage 3 ("Probe calls (owner)") of the staged plan in the [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md), with the bars taken verbatim from that audit's measurement table (the rows for Z1, for B1, B2 and B3, for duplex playback, and for the no-grant list read). Re-verified against HEAD `3a2da4fc` on 2026-11-13 by code reading of the probe and the scanner.

**Why it is a spike.** The plan's browser target (a session opened by the browser family holding the mic) and its Zoom target (mic release as Zoom's end) each depend on one fact that no field data holds. Browsers: `MeetingSourceScanner.readsProcessAudio` returns `kind == .native && NativeLifecycleConfig.usesProcessAudio(...)`, so no browser process has ever been read and the work-laptop pack has 0 browser mic rows by construction. Zoom: 3 calls in 38 active days, 5 `process_audio_is_running_input` true readings in all (the [DET12](./DET12.md) and [DET15](./DET15.md) amendments rest on them). Every direct CoreAudio check in the audit ran on the home Mac. This harness has no live call, so the owner measures.

**The pre-registered bars (copied from the audit, not to be moved after a run).**

| Bar | Script | Pass |
|---|---|---|
| L0 (idle, no grant) | One-shot probe on the work laptop from an ordinary Terminal, `sw_vers` recorded | The process-object list reads and the Teams objects are present with input false at idle |
| B1 | Chrome Meet, pre-join then join, 10 joins in total over time | A Chrome object attributable by bundle prefix or ancestry reads input true within 5 s of pre-join or join in 9 of 10 |
| B2 | Mute 60 s in the call | Input stays true through the mute in 10 of 10 |
| B3 | Leave with no other mic tab, then close the tab | Input false within 15 s of leaving in 9 of 10. With a second tab holding the mic it is expected to stay true, and the page-gone rule must carry that end |
| Z1 | One Zoom call: mute 120 s five times, then Leave | Zero flips while muted; false within 15 s of Leave; the object that reads true carries the `us.zoom.xos` prefix or descends from it |
| P | One input-and-output headset as default, play audio in Chrome, Teams and Zoom with no call up | Input reads false for 60 s in each |

Fallbacks, also fixed now: B1 fails, browsers stay on the title opener ([DET17](./DET17.md)) and [DET20](./DET20.md) is skipped; B2 fails, the browser takes the ambiguous end rule; B3 fails, the recording runs on with the page-gone Finish offer and the ceilings bound it; Z1 fails, Zoom stays on the ambiguous rule (or the union attribution rule first) and the Zoom legs of [END23](./END23.md), DET12 and DET15 do not proceed; P fails, the open debounce needs a second condition for that device class.

**Correction at filing.** The class summary says the owner runs `daemon/scripts/det8-process-object-probe.swift` as it stands. That probe is Teams-shaped: it marks only `com.microsoft.teams2` objects (`teamsPrefix`), prints APPEARED and VANISHED lines only for a Teams object or one already reading input true, prints output transitions only for Teams, has no parent-PID column (Z1's descendant test and B1's ancestry attribution need one), and prints no READ line. Its header also carries DET8's own bars named B1, B2 and B3 (fixed 2026-07-30, Teams, a 60 s end window), which are not these. The plan's B1 to B3 also count 10 joins, so one scripted Meet call cannot decide them alone; the verdict reads pending until 10 joins are logged. The spike therefore makes a small read-only change to the probe (or a sibling probe beside it), and the analysis doc names these bars distinctly from DET8's.

**Ordering with DET16.** [DET16](./DET16.md)'s one-day count runs first: a PASS deletes browser detection and with it every browser leg here, leaving L0, Z1 and P. The audit's D003 verifier counted 7 Chrome prompts and 1 Chrome `recording_started` in the work-laptop pack, which is DET16's FAIL condition if that is the log it counts, so the browser legs most likely stay.

## Scope

1. **Analysis doc** `docs/spikes/det24-mic-flag-probe-calls.md` per `/spike`: the question, what is settled a priori (DET8's 2026-07-30 Teams result, the no-grant list read on the home Mac), the table above with its fallbacks, and the exact owner commands.
2. **The probe**, read-only, under `daemon/scripts/`: a `--family <bundle-prefix>` argument replacing the hard-coded Teams prefix for marking and APPEARED or VANISHED lines, a parent-PID column and an "is a descendant of the family's main PID" flag, timestamped transitions for every family object, and a READ line per leg that maps straight onto the bars (PASS, FAIL, or PENDING with joins counted so far). `swiftc -typecheck` clean. No taps, no aggregates, no audio capture, safe during a real meeting.
3. **Ride-alongs on the same Meet call** where the owner agrees: [DET6](./DET6.md)'s URL probe (`daemon/scripts/det6-browser-url-probe.swift`) and [MIC7](./MIC7.md)'s mute probe (`daemon/scripts/mic7-meet-mute-probe.js`), each judged against its own pre-registered verdict, not these bars.

## Explicitly not

- Any production change, and any bar moved after a run.
- Safari attribution (responsible-process tie for WebKit): only if the owner uses Safari for Meet and permits a private call, as its own leg.
- Teams mute, audio-off joins and listen-only events: the plan measures those with the shadow monitor ([DET23](./DET23.md)), not this probe.
- Filing as [VALOWN1](./VALOWN1.md)-style P4: that band is for validation that gates nothing; this verdict gates P2 engineering.

## Acceptance

- The analysis doc and the probe land in one commit; the probe typechecks and prints a READ line per leg; the task goes to `status: partial` with the owner-owed commands in its comment, per `/spike` step 7.
- After the owner runs it, a dated verdict per bar is written here (PASS, FAIL or PENDING with counts) with the macOS version, and each failed bar names the fallback it selected. No titles or names in the written result: bundle ids, PIDs, timestamps and counts only.
- `bash scripts/ci-local.sh fences` green (doc links, no em-dashes).

## Owner walkthrough

1. [session] Confirm DET16's verdict is written; on PASS, drop the browser legs from the commands.
2. [owner] On the work laptop, from an ordinary Terminal (not a harness-spawned shell, whose negative result is void per DET8), run the one-shot probe idle with Teams open and paste the READ line for L0. Cost: 1 minute.
3. [owner] Run the probe in watch mode with `--family com.google.Chrome` through one scripted Meet call: pre-join, join, mute 60 s, switch tabs, minimise, leave, close the tab; then once more with a second tab holding the mic. Leave it running across later real Meet joins until 10 joins are logged. Cost: about 20 minutes plus ordinary meetings.
4. [owner] Run it with `--family us.zoom.xos` through one Zoom call: mute 120 s five times, then Leave and wait 60 s. Cost: one 15 minute call.
5. [owner] With one duplex headset as default and no call up, play audio in Chrome, Teams and Zoom for 60 s each with the probe watching. Cost: 5 minutes.
6. [session] Write the verdicts into this file and tell DET20, END23, DET12 and DET15 which legs their gate now allows.
