# ADR 0008: Verdict-fusion architecture for end-detection and mic-gating

| Property            | Value              |
| ------------------- | ------------------ |
| **Status**          | Accepted           |
| **Date**            | 2026-05-18         |
| **Decision Makers** | Project owner      |
| **Technical Area**  | Detection / capture|
| **Related Tasks**   | TECH-C13, TECH-G-MIC |

## Context

The Phase 0 end-detection path was a single AX probe: watch for the
"Leave" button on a Teams or Zoom window and stop recording when it
disappeared. The Phase 0 mic-gating path was a single boolean
`recorder.micPaused` flag set by a 1 Hz mute-state probe
(`MeetingMuteProbe`). Both surfaces accumulated edge cases (post-call
chat surfaces grabbing the mic, Webex retaining the mic for ultrasound
discovery, browser-hosted meetings without an AX Leave button, locale
drift in the Mute button label) and the single-signal designs ran out
of room.

The Q2 backlog (TECH-C13 and TECH-G-MIC) replaces both surfaces with
verdict-fusion subsystems: multiple independent signals feed a
coordinator that promotes a state transition only when the precedence
rules are satisfied. The two subsystems share infrastructure (the
one-time AX-tree walk, the CoreAudio HAL bus, the events.jsonl writer)
because they would otherwise duplicate the same machinery.

## Decision Drivers

- **No single signal is authoritative across vendors and locales.**
  AX Leave button covers Teams and Zoom but not Webex's lifecycle and
  not browser-hosted meetings. Process audio is running covers Teams
  and Zoom but lies on Webex. SCShareableContent window-presence
  covers all native apps but not which app is in the meeting.
- **Precedence beats voting.** A weighted-vote scheme is hard to debug
  ("why did this fire?"); explicit precedence rules with named leading
  and confirming signals are reviewable and auditable through the
  event log.
- **Per-app behaviour belongs in adapters, not in the coordinator.**
  Teams, Zoom, Webex, Slack, and the browser each have specific quirks
  (Webex's ultrasound retention, Slack's missing AX teardown, the
  browser's tab-title-as-leading-signal). Adapters encapsulate those.
- **The AX-tree walk is expensive and observable to the user.**
  Walking once per meeting and caching the references is required.
  Walking once for end-detection and again for mic-button location
  would double the cost; the subsystems share one walk.

## Options Considered

### Option A: Keep single-signal probes, patch the edge cases

Pros: smaller code change. Cons: each new edge case (a Sequoia AX
notification dropout, a vendor rename, a locale drift) ratchets the
patch tree another level deep. The post-call chat surface mic-grab
already required RepromptCooldown, which then required its own
suppression rules. The next edge case lands on top of that.

### Option B: Single coordinator that consumes all signals directly,
no per-app adapters

Pros: fewer types. Cons: the coordinator becomes the place where
"Webex specifically excludes process-audio because of ultrasound" lives
next to "Meet specifically uses the browser tab title as the leading
signal" next to seven other vendor-specific clauses. The 1500-line
Coordinator problem (TECH-H1) repeats inside the new subsystem.

### Option C: Verdict-fusion with per-app adapters, shared infrastructure

Pros: each adapter is self-contained and testable in isolation; the
coordinator's promotion rules are pure functions over verdict inputs;
shared infrastructure (AX bus, HAL bus, event log) prevents
duplicated AX walks and listener registrations.

## Decision

**Option C.** Two coordinators (`MeetingLifecycleCoordinator` for
end-detection, `MicGate` for mic-gating) consume an `AsyncStream` of
verdict transitions per signal. Each signal has its own file under
`Sources/MeetingPipeCore/Lifecycle/Signals/` or
`Sources/MeetingPipeCore/MicGate/Probes/`. Per-app adapters live under
`.../Adapters/`. Shared infrastructure (`CoreAudioHALBus`,
`AXObserverBus`, `EventLog`) lives under `.../Infra/` and is consumed
by both subsystems. Promotion rules are pure functions tested via
synthetic verdict-input sequences.

## Consequences

- The new code lives in a separate library target
  (`MeetingPipeCore`) so it can be unit-tested without AppKit or
  FluidAudio. The executable target (`MeetingPipe`) depends on the
  library and wires the coordinator outputs into `Recorder.swift` and
  `DetectionStateMachine.swift`.
- Every signal change and verdict transition is logged via
  `Log.event` so dogfood analysis (TECH-E4) can reconstruct what
  happened end-to-end from `events.jsonl`.
- The AX-tree walk happens once per meeting in
  `MeetingLifecycleCoordinator`; `MicGate` consumes the cached
  references for the Mute button. This is the load-bearing
  shared-infrastructure invariant.
- Adding a new meeting app means a new adapter file plus a TOML entry
  in `MuteLabels.toml` for the supported locales, not a coordinator
  edit.
- Old code paths (Teams-AX-Leave-button detector,
  `MeetingMuteProbe.swift`, `recorder.micPaused: Bool` seam) are
  removed when the verdict-fusion subsystems land. Until then they
  coexist behind the old wiring.
- `MicGateWriter` emits zero-amplitude frames on non-`.hot` verdicts
  rather than skipping frames or stopping the writer. The rationale
  (sample alignment with the system-audio channel, recoverability of
  the WAV by downstream diarization) is owned by ADR 0009.
