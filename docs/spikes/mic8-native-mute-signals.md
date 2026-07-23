# MIC8 spike: UI-independent native mute signals (logs / SDK / OS)

Spike, 2026-07-13. **Measured and resolved 2026-07-23: GO for Teams.** Instruments: [`docs/spikes/mic8_log_correlation.py`](./mic8_log_correlation.py) (the offline measurement that settled it) and [`daemon/scripts/mic8-native-mute-probe.sh`](../../daemon/scripts/mic8-native-mute-probe.sh) (the live tail, still the instrument for Zoom).

This spike closes two of the three candidate signal classes from documentation. The third, the client's own local log, was owner-owed on a live instrumented call; it was instead answered **offline against 11 days of real dogfood**, which is a strictly stronger read than 3-4 toggles in one meeting would have been. The measured result is in [Candidate A: measured](#candidate-a-local-client-logs-measured-go-for-teams) below.

## Question

The mute oracle meeting-pipe relies on (MIC6) reads a meeting client's mute *button* through Accessibility. That has proved fragile twice under vendor UI redesigns (the Teams mini-window incident; MIC9/MIC10). MIC8 asks the durable-direction question: **is there a UI-independent local signal that reports a client's mute-state transitions and survives every UI redesign?** If one exists for a tool, it supersedes that tool's AX read. Three candidate classes; the probe measures the only one left open.

## Candidate B (vendor SDK): CLOSED by documentation

The most authoritative signal would be the client's own audio-status callback. It is not reachable for our model (observe the user's *already-running* Zoom.app / Teams, we do not host the meeting):

- **Zoom.** Staff on the Zoom Developer Forum state the desktop client exposes no external interaction: "the official Zoom desktop client does not support external interaction." The Meeting SDK's `onUserAudioStatusChange` callback does report mute, but only inside an app that *joins the meeting through the SDK itself* (the ZoomOSC pattern) - i.e. you would run a second meeting client, not read the user's. No URL scheme, IPC, or accessibility read is offered for the native client's mute state.
- **Teams.** No public local API exposes the running client's mute state to a third-party process either; new Teams is an Edge WebView2 shell with no documented mute-read surface.

So the SDK path is a non-starter under the "watch the client the user is already in" constraint that the whole detection architecture rests on.

## Candidate C (OS-level system mute): CLOSED by category error

Tempting because it would be app-independent, but it measures the wrong thing. CoreAudio's device-level mute (what Mic Drop / MicControl / Control Center toggle) mutes the **hardware input**. A meeting client's in-call mute is a **client-side transmit gate**: by design it keeps the OS microphone live and simply stops sending audio (this is exactly the property that forced MIC1's capture-first architecture, and why a "mic in use" read cannot stand in for "muted"). Reading the OS device-mute therefore tells you nothing about whether the user clicked Mute in Teams, and macOS exposes no public API to read another app's client-side mute or its contribution to the system mute affordance. Dead end for the signal MIC6 needs.

## Candidate A (local client logs): measured, GO for Teams

The remaining UI-independent per-app signal is the client's own diagnostic log. If Zoom or Teams writes a stable line on each mute/unmute, tailing it is UI-independent (no button, no locale, no window scoping). Whether that line exists, and is stable, is undocumented and per-app.

### Correction to the 2026-07-13 recon

The original recon concluded Teams was not logging, from `MSTeams_*.log` being ~405 d stale and "recent Teams use looks browser-side". **That read the wrong file family.** `MSTeams_*.log` is the Electron/WebView2 *shell* log. The call media stack writes a separate family in the same directory, `MSTeamsNM_SlimCore_*.log`, and that one was live: its generation `.10` dates from 2026-06-12 and already held 218 mute transitions, a month before the spike was written. The dogfood was native Teams all along (which the meeting corpus independently says), and the signal was on disk the whole time.

Two properties of this directory explain how the miss survived, and both were defects in the probe until 2026-07-23:

- **The shell log drowns the media log.** `MSTeams_*.log` and `TeamsSwitcher.log_*` roll every ~2 MB, hourly on a working day; `MSTeamsNM_SlimCore_*` rolls only when Teams restarts, roughly weekly. The probe took the newest 6 files in the tree, so on any busy day the six newest are shell-log rotations and the one file carrying mute lines is evicted. (Observed live: during the 2026-07-23 session a single shell rotation pushed SlimCore from 5th to 10th newest.) It now takes the newest 2 per log *family*.
- **The shell log fakes a hit.** Once an hour it dumps a ~100 KB ECS config blob whose feature-flag keys include `hfpOsUnmuteFixEnabled`. The probe's `mute` token matched that, and truncated to 200 chars it reads exactly like a mute event, so the noise is the same shape as the signal. The token set now requires a non-identifier character after the token: shell-log false positives went 3 to 0 while all 216 real SlimCore lines still match.

Left unfixed, those two would have produced a confident false close: config noise scrolling past on every hour boundary while the real file sat out of view.

### The signal

Three line forms, all from the `AirPodsService` component of the SlimCore media stack:

```
AirPodsService: Input mute event received: mute|unmute
AirPodsService: AirPodsService::SetMuteState: true|false with cause_id: <uuid>
AirPodsService: AirPodsService InputMuteStateChangeNotification received with value: true|false
```

`AirPodsService` is a **misnomer** for our purposes: the component logs the transmit gate on the built-in mic too. On every day carrying mute lines (2026-07-20 through 07-23, 52/36/23/51 lines) the daemon resolved `MacBook Pro Microphone` as the input device; AirPods appear as an input device exactly once in the entire event log (2026-07-14). What this data cannot separate is whether the component still requires AirPods *connected for output*, so the build must degrade an absent line to **unknown, never to unmuted** (the same rule MIC7 pinned for an absent `data-is-muted`).

### The measurement

[`mic8_log_correlation.py`](./mic8_log_correlation.py) replays every mute transition already on disk and pairs the two oracles: source A the SlimCore log, source B meeting-pipe's own `micgate` / `ax_mute_button_state` events, i.e. the incumbent AX label scrape. Aggregates in [`mic8-log-correlation-results.json`](./mic8-log-correlation-results.json). Over 2026-06-12 to 07-23:

| Measure | Result |
|---|---|
| SlimCore mute transitions | 594 across 9 log generations |
| AX transitions available to pair | 62 (2026-07-13 to 07-23) |
| Paired within 30 s | 61 (1 unmatched) |
| State agreement | 59 agree, 2 disagree |
| Log line arrived **before** the AX read | 59 of 61 |
| \|delta\| ms | min 22, p50 50, p90 812, max 16773 |

Against the spike's own pre-registered GO bar: same token every time **yes**; under ~1 s **yes** (p50 50 ms, and it *leads* the incumbent rather than trailing it); default logging **yes**, no troubleshooting toggle involved; survives a client update **yes**, identical across all 9 generations spanning six weeks and at least one client update (the 2026-07-17 relaunch).

The four imperfect pairs were read individually and three are AX-side defects, not log misses:

- `07-23T07:39:54` the log recorded `mute` and the daemon's own poll confirmed it 391 ms later, but the AX *notification* did not fire for **16.8 s**. That is the p90/max tail, and it is the incumbent lagging.
- `07-20T07:35:22` AX announced a transition to `unmuted` when the state had already been unmuted for 68 s; the log shows only the two real transitions. An AX bookkeeping artefact.
- `07-20T13:37:22` a 1.8 s AX poll lag, the log leading.
- `07-20T13:44:26` AX saw a `muted` transition with no log line within the window. One unexplained gap in 62, and the only one that goes against the log.

So the log is not merely as good as the AX scrape on this corpus, it is **better**: it leads on 59 of 61 pairs, it caught a transition the AX notification missed for 16.8 s, and it declined to invent one the AX side invented.

### Not candidate C in disguise

Worth stating explicitly, because the component name invites the confusion. This is the client-side transmit gate, not the OS device mute that section C closes as a category error: across the same window meeting-pipe's `system_mute_state` was `false` in **34 of 34** observations, i.e. the hardware input mute never toggled at all, while the log tracked 60 in-call transitions. The `cause_id` on each `SetMuteState` is Teams' own internal mute-cause bookkeeping. Client-side, as required.

### Zoom: still open, and effectively moot

`~/Library/Logs/zoom.us/` is empty/stale (newest text log from 2023; `Diagnostic/` empty) and Zoom's verbose troubleshooting logging is **opt-in**, so a signal that appears only with it enabled is weak evidence for durability. Unresolved, but the dogfood has recorded **zero** Zoom calls, so this stays unmeasured until a Zoom meeting actually happens. The live probe remains the instrument for it.


## Verdict: GO for Teams, build a `LogMuteAdapter`; Zoom unmeasured

The pre-registered decision tree resolves on the first branch for Teams: a stable, default-on line, sub-100 ms at p50, unchanged across 9 log generations. Two things this changes from the spike's a-priori lean:

- **The lean was wrong.** The doc leaned toward a close on the grounds that an undocumented log format is no more futureproof than the label scrape it would replace. That argument still holds in principle, but it was an argument about an unmeasured signal, and the measurement beat it: 42 days and 9 generations of format stability, sub-100 ms median, and a demonstrated accuracy edge over the incumbent. A vendor can still break the line, but the same vendor broke the AX scrape twice in the period this project has existed (the Teams mini-window incident, MIC9/MIC10) and did not break this line once.
- **The comparison MIC8 was filed against is gone.** MIC8 was filed as beating MIC6's AX state-attribute read; MIC6 was **refuted** by the 2026-07-14 live dump (Teams exposes no `AXValue` and no `AXIdentifier` on any element) and closed as unachievable. So the incumbent this actually has to beat is the localized-description scrape in `MuteLabels.toml` plus MIC10's `AXSystemDialog` structural anchor. On the measured corpus it beats that incumbent on latency and on accuracy, and it is locale-independent, which the scrape structurally cannot be.

The build is small and needs no fusion change, mirroring MIC7's `MeetMuteAdapter` shape: a `LogMuteAdapter` conforming to `MicGateAdapter` (alongside `NativeMuteAdapter` / `NoOpMuteAdapter`) tails the newest `MSTeamsNM_SlimCore_*.log`, parses the transition line, and hands an `AXMuteButtonProbe.Event` to the sink, landing in `MicGate.injectAxMuteEvent` exactly where the AX poll does today. No `PromotionEngine` / scorer change; the mute layer is already an injectable seam.

**Open design question for the build, owner's call: supersede or fuse.** The spike assumed a log adapter *replaces* that app's AX read. The measurement supports fusing instead, and it is barely more code: the one case that went against the log (`07-20T13:44:26`) is exactly what a fusion covers, and the three that went against AX are cases the log already covers. Precedence "log wins when present, AX carries when absent" keeps both, costs one comparison, and never leaves the gate blind if Microsoft renames the line. Replacing outright is simpler but bets the whole Teams mute oracle on one undocumented string.

Build gotchas, all measured and all easy to get wrong:

- **The timestamps lie about their timezone.** SlimCore prints UTC and suffixes the machine's local offset, so a line stamped `13:31:12+03:00` happened at 13:31:12 **UTC**. Parse the naive reading as UTC and discard the offset, or every event is wrong by the local offset, and correct-looking on a UTC machine, which is the worst kind of wrong.
- **Pick the file by family, not by mtime.** The shell log rotates hourly and will always look fresher than the media log that carries the signal.
- **Absent means unknown, not unmuted.** See the AirPods-misnomer caveat above.
- **Rotation is per Teams restart**, so the adapter re-resolves the newest generation rather than holding one file handle.

## Follow-on

- Build the Teams `LogMuteAdapter`. The supersede-vs-fuse question above wants an owner decision first.
- Re-run `python3 docs/spikes/mic8_log_correlation.py` after a Teams update to confirm the line held. That is the regression test for this bet, and it costs one command.
- Zoom stays unmeasured: `bash daemon/scripts/mic8-native-mute-probe.sh` during a live Zoom call, enabling troubleshooting logging first if it reports no live writes. Not worth chasing until a Zoom meeting actually happens; the corpus has none.
