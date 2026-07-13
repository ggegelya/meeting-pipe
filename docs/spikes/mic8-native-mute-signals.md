# MIC8 spike: UI-independent native mute signals (logs / SDK / OS)

Spike, 2026-07-13. Probe: [`daemon/scripts/mic8-native-mute-probe.sh`](../../daemon/scripts/mic8-native-mute-probe.sh) (owner-run during a live call, read-only). This spike closes two of the three candidate signal classes from documentation and reduces the third to one empirical question a live mute/unmute cycle answers, so the per-app verdict is owner-owed.

## Question

The mute oracle meeting-pipe relies on (MIC6) reads a meeting client's mute *button* through Accessibility. That has proved fragile twice under vendor UI redesigns (the Teams mini-window incident; MIC9/MIC10). MIC8 asks the durable-direction question: **is there a UI-independent local signal that reports a client's mute-state transitions and survives every UI redesign?** If one exists for a tool, it supersedes that tool's AX read. Three candidate classes; the probe measures the only one left open.

## Candidate B (vendor SDK): CLOSED by documentation

The most authoritative signal would be the client's own audio-status callback. It is not reachable for our model (observe the user's *already-running* Zoom.app / Teams, we do not host the meeting):

- **Zoom.** Staff on the Zoom Developer Forum state the desktop client exposes no external interaction: "the official Zoom desktop client does not support external interaction." The Meeting SDK's `onUserAudioStatusChange` callback does report mute, but only inside an app that *joins the meeting through the SDK itself* (the ZoomOSC pattern) - i.e. you would run a second meeting client, not read the user's. No URL scheme, IPC, or accessibility read is offered for the native client's mute state.
- **Teams.** No public local API exposes the running client's mute state to a third-party process either; new Teams is an Edge WebView2 shell with no documented mute-read surface.

So the SDK path is a non-starter under the "watch the client the user is already in" constraint that the whole detection architecture rests on.

## Candidate C (OS-level system mute): CLOSED by category error

Tempting because it would be app-independent, but it measures the wrong thing. CoreAudio's device-level mute (what Mic Drop / MicControl / Control Center toggle) mutes the **hardware input**. A meeting client's in-call mute is a **client-side transmit gate**: by design it keeps the OS microphone live and simply stops sending audio (this is exactly the property that forced MIC1's capture-first architecture, and why a "mic in use" read cannot stand in for "muted"). Reading the OS device-mute therefore tells you nothing about whether the user clicked Mute in Teams, and macOS exposes no public API to read another app's client-side mute or its contribution to the system mute affordance. Dead end for the signal MIC6 needs.

## Candidate A (local client logs): the one empirically-open thread

The remaining UI-independent per-app signal is the client's own diagnostic log. If Zoom or Teams writes a stable line on each mute/unmute, tailing it is UI-independent (no button, no locale, no window scoping). Whether that line exists, and is stable, is undocumented and per-app, so it can only be measured live. That is what the probe does: it tails the client's diagnostic logs (read-only, storage subtrees pruned, matches truncated as a privacy guard) and timestamps any line matching a broad mute/audio-state token set, so the owner can correlate each toggle against a log line and read the latency + token stability.

On-disk recon on this Mac (2026-07-13) frames the measurement but cannot answer it:

- **Zoom** has `~/Library/Logs/zoom.us/` but its diagnostic logs are empty/stale (`Diagnostic/53061/` empty; newest text log ~285d old). Zoom's verbose troubleshooting logging is **opt-in**, not on by default - and a signal that exists only with troubleshooting logging enabled is, by that fact, weak evidence for durability.
- **Teams** writes `MSTeams_*.log` under `~/Library/Group Containers/UBF8T346G9.com.microsoft.teams/Library/Application Support/Logs/`, but the newest is ~405d old (the owner's recent Teams use looks browser-side, not the native app). Format is undocumented.

Neither app is logging live right now, so the latency/stability read is owner-owed: run the probe during an actual call.

## What a GO would look like (and the durability caveat)

If the log proves reliable for an app, the build is small and needs no fusion change, mirroring MIC7's `MeetMuteAdapter` shape: a per-app `LogMuteAdapter` tails the client log, parses the mute token, and injects an `AXMuteButtonProbe.Event`-equivalent into `MicGate` exactly where the AX poll does today (`MeetingAXWindowWatcher` / `injectAxMuteEvent`), superseding that app's AX read. No `PromotionEngine` / scorer change; the mute layer is already an injectable seam.

The caveat that reshapes the verdict: an **undocumented log format is not obviously more futureproof than the AX state-attribute read MIC6 targets.** A vendor changing its log line breaks a `LogMuteAdapter` the same way a UI change breaks the scrape - and unlike the AX read, the log path also depends on verbose logging staying enabled (Zoom). So MIC8's filed framing ("the strongest futureproofing") holds only if the log line turns out to be stable *and* default-on. The a-priori evidence (B and C closed, A undocumented/opt-in) already downgrades this from "the durable replacement" to "measure the log path before betting on it; MIC6 likely stays the primary durable track."

## Verdict: measure the log path per app; lean is a close

Per-app decision tree, owner-owed on the probe:

- **A stable line appears** (same token, < ~1 s after each toggle, default logging, survives a client update): GO a `LogMuteAdapter` for that app, superseding its AX read. Cleanest for that tool.
- **The line is flaky / format varies / only with troubleshooting logging on:** the log is not a durable oracle; close the native-signal bet for that app. MIC6 (read the mute button's stable *state attribute*, not its localized title) stays the durable direction, backed by the capture-first safety net (ADR 0016 / MIC9) that already removes the data-loss failure mode regardless of oracle accuracy.
- **No line at all:** close candidate A for that app; the native-signal track for it is dead.

Net: **do not build a log adapter yet.** B and C are closed by documentation; A is the only live thread and its durability is exactly what is unproven. The probe is the cheap instrument that settles it without a blind build.

## Follow-on

- Owner: during a live Zoom call and, separately, a live Teams call, run `bash daemon/scripts/mic8-native-mute-probe.sh`, toggle mute/unmute 3-4 times noting each press time, and read which token (if any) appears and how fast. For Zoom, enable troubleshooting logging first if the probe reports no live writes.
- On a stable default-on line for an app: promote MIC8 to a small `LogMuteAdapter` build for that app (the MIC7 adapter shape), superseding its `MeetingAXWindowWatcher` read.
- On flaky / opt-in-only / absent: record the per-app close in the backlog row; MIC6 + capture-first remain the durable answer, and MIC8's "supersedes the whole scrape class" promotion rationale does not hold.
