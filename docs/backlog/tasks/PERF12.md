# PERF12: playing a meeting's audio re-renders the whole detail pane 15 times a second

Band origin: filed 2026-10-23 from the code audit run for the owner's "the app feels slow" report. Confirmed by reading code; not yet profiled. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What is wrong

`AudioPlaybackController` publishes `currentTime` from a timer at `tickInterval = 1.0 / 15.0`. `MeetingDetailView` owns it as `@StateObject var playback = AudioPlaybackController()`, which subscribes the whole detail view. `TranscriptTab` and its list views, `AudioTab` (three views) and `PlaybackRateMenu` each hold `@ObservedObject var playback: AudioPlaybackController`. So while audio plays, every tick re-evaluates:

- `MeetingDetailView.body`.
- The transcript list's body, which recomputes its marker layout and segment ordering (both O(segments)) and re-renders the visible rows.
- On the Summary tab, the rendered summary, which re-parses its markdown per bullet.

That is about 15 full detail-pane passes a second for anyone scrolling a transcript while listening, which is exactly when scrolling has to be smooth.

## Scope

- Move the fast-changing time onto its own small observable (for example `PlaybackClock`), owned by the controller and observed only by the views that draw time: the playback bar and scrubber, the active-row highlighter, and the waveform cursor. `MeetingDetailView` keeps the controller without subscribing to its clock.
- Keep `isPlaying`, `duration` and the rate on the controller (they change rarely), so [UX78](./UX78.md)'s header transport still binds to them.
- Cache the transcript list's marker map and segment order in `@State`, keyed on the segment set, instead of computing them in `body`.

## Explicitly not

- [UX78](./UX78.md) (audio keeps playing after leaving the tab, no control on Summary). Adjacent, and both touch `MeetingDetailView`, so whichever lands second rebases on the other. This task does not change where playback is reachable.
- Changing the 15 Hz rate itself. The cursor needs it; the fix is who listens.

## Acceptance

- A test that counts `MeetingDetailView`-level (or transcript list) body evaluations, or an equivalent observable-subscription test, shows they do not grow with clock ticks: 30 ticks produce no detail-pane re-evaluation, while the playback bar's observable fires 30 times.
- A test fails without the change.
- `cd daemon && swift build` and `swift test` green, new test count in the commit body.
- Evidence (confirms, does not gate): `sample MeetingPipe 10` while audio plays with the Transcript tab open shows the main thread mostly idle, with no `MeetingDetailView.body` frames on every tick.
