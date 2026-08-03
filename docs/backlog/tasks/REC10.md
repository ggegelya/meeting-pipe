# REC10: the REC8 auto-retry overwrites the system-audio partial that REC4 and REC8 both claim it preserves

Filed 2026-08-03 by the audit band. Proposed high, downgraded to medium by an independent skeptic on reachability, and the mechanism confirmed.

## What is wrong

`retrySystemAudio()` re-enters `startSystemCapture(systemURL:)` with the same URL, and `AVAudioFile(forWriting:)` truncates an existing file, so a recovery after a mid-meeting SCStream death destroys every system-audio sample captured before the death. The recovered channel then begins at retry time but merges at sample 0, so the remote side plays back early by the outage offset.

Evidence:

- `daemon/Sources/MeetingPipe/MeetingRecorder.swift:613-620` re-enters `startSystemCapture(systemURL: systemURL, isRetry: true)` with `self.systemURL`, the same path `start()` used.
- `daemon/Sources/MeetingPipe/MeetingRecorder.swift:528-531` opens it with `systemFile = try AVAudioFile(forWriting: systemURL, settings: ...)`. The overwrite is Apple's documented contract, not an inference: `AVAudioFile.h:68` in the macOS SDK reads "Will overwrite a file at the given URL".
- `daemon/Sources/MeetingPipe/MeetingRecorder.swift:703` documents `handleSystemAudioLost`'s contract as keeping the partial "on disk so a no-retry stop still merges what was captured", and `:715` clears only `systemCapture`, deliberately leaving `systemFile` and `systemWriter` pointing at the partial. That is exactly what the retry then overwrites.
- `daemon/Sources/MeetingPipe/MeetingRecorder.swift:720` calls `scheduleSystemAudioAutoRetry()`, which REC8 made hands-off, so no human decision stands between a death and the overwrite.
- `daemon/Sources/MeetingPipe/MeetingRecorder.swift:697-698` takes the same path from `handleDidWake`, which is REC8 walkthrough step 3's exact scenario.
- `docs/backlog/tasks/REC8.md:5` asserts the retry "preserves REC4's partial-recording rationale". It does not.

## Reachability, stated honestly

This path has never executed on the owner's machine. `system_capture_lost`, `system_capture_stall_detected` and `system_capture_auto_retry` are each **0** across `events.jsonl` and `events.1.jsonl`. That is why the skeptic downgraded it from high to medium, and the downgrade is correct: the defect is real in code and unobserved in practice. It is filed because the trigger is a designed-for state (REC4 exists for it) and because the cost when it does fire is silent loss of the remote half of a meeting.

## Scope

On a retry, do not reopen the same path. Two shapes work:

- Write the recovered stream to a numbered sibling (`<stem>.system.2.wav`) and teach `produceFinal` to concatenate the system legs with a silence gap before the merge.
- Or pre-pad the new file with silence covering the outage window so sample 0 still means recording start.

Either way the offset handling is shared with REC9's length policy, so pick these up together.

Fix `handleSystemAudioLost`'s doc comment and `REC8.md:5`'s preservation claim in the same commit.

## Acceptance

Suite green with new tests. A test drives `handleSystemAudioLost` then `retrySystemAudio` over a fake file sink and asserts the pre-loss bytes survive and the post-retry frames land at the right offset. Not owner-verifiable without killing an SCStream mid-call, so this closes on tests plus REC9's walkthrough, and the spec says so rather than pre-registering an observation the owner cannot make.
