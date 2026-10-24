# REC18: the meeting prompt opens the microphone with a second AVAudioEngine only to animate a level meter, before the user has said yes

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) M12). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

`MeetingPromptWindow` owns `private let levelMonitor = MicLevelMonitor()`. `MeetingPromptWindow.present(...)` orders the panel front and then calls `levelMonitor.start { [weak self] level in self?.liveWaveform?.push(level: level) }`; `dismiss(animated:)` calls `levelMonitor.stop()`. `MicLevelMonitor` (`Design/MicLevelMonitor.swift`, 246 lines) owns its own `AVAudioEngine`, separate from `MeetingRecorder`'s, and on its private `MeetingPipe.MicLevelMonitor` queue reads `engine.inputNode.outputFormat(forBus: 0)`, installs a 1024-frame tap on the input node, and starts the engine. The RMS it computes drives `LiveWaveformView` (65 lines), four bars in the prompt pill. Nothing else consumes it.

So the input device is opened at the moment the app asks "Record this meeting?", which is the consent question, and before any answer:

- macOS attributes mic use to MeetingPipe (the menu-bar mic indicator and Control Center's list) while the user is still deciding, and for the whole prompt timeout if they ignore it. That contradicts the product's quiet, deliberate posture (PRODUCT.md) on exactly the screen where the user is choosing whether the app may listen.
- It is a second HAL client of the input device at the moment the meeting app is negotiating the same device. That window is where all four MeetingPipe crash reports on the owner's machine came from (read 2026-08-14): `installTapOnBus` raising inside `MicLevelMonitor.start` within 100 ms of `prompt_shown` ([REC12](./REC12.md)).
- `MicLevelMonitor` does not check `AVCaptureDevice.authorizationStatus(for: .audio)` before touching the input node. What opening the input does at `.notDetermined` from the prompt path is not established; the pickup checks it.

REC12 made the call safe rather than removing it: format validation, the `GuardedTapInstall` Objective-C `@try` barrier, `startBounded` / `runBoundedSync` around `engine.start()`, and a scoped configuration-change observer. REC12's spec states the alternative and leaves it to the owner: "Not removing the live waveform as the first move ... Worth naming as the fallback if the barrier turns out to be disproportionate; the owner decides that, not the pickup." The barrier was not disproportionate, so this is not a crash task any more. It is a consent and hardware-access question: decoration should not open a device. REC12 itself is still in [owner-verification.md](../owner-verification.md), and its walkthrough items 3 and 4 exercise the waveform.

The meter is also part of the design system: `design/README.md` lists "the live mic waveform" among the On-air accent's uses, and `design/ui_kits/macos_app/MeetingPrompt.jsx` draws it as "4 bars driven by RMS while the prompt is up".

## Scope

0. **Owner decision, before code**, because REC12 recorded it as the owner's: replace the live meter, and with what. Options: (a) a static mic glyph in the same slot; (b) an activity pulse driven by a signal the app already has without opening the device, such as `MeetingDiscoveryWatcher`'s mic-busy state (`isInUseByAnotherApplication`), which says the meeting app holds the mic but carries no level; (c) keep the live meter but start it only after the user chooses Record, which removes the prompt-time open but leaves the second engine. (a) or (b) is the recommendation; (c) is listed so it is not re-proposed.
1. For (a) or (b): delete `MicLevelMonitor.swift` and `MicLevelMonitorTests.swift`, drop the `levelMonitor` calls from `MeetingPromptWindow.present` and `dismiss`, and either delete `LiveWaveformView` or turn it into the glyph or pulse. Remove the `MicLevelMonitor` references in comments in `GuardedTapInstall`, `RunWithTimeout` and `MeetingRecorder` (each names it as a caller); `GuardedTapInstall` and `runBoundedSync` stay, since `MeetingRecorder` and `EngineTeardown` use them.
2. Same commit: update `design/README.md` and `MeetingPrompt.jsx` so the kit matches the shipped prompt, and add a line to REC12's owner-verification row noting that its waveform walkthrough items no longer apply.

## Explicitly not / out of scope

- The recording HUD's live level (`RecordingHUDWindow`'s `levelProvider`, fed from `MeetingRecorder.meterLevelDb` on the recorder's own engine), which runs only after Record was chosen. Not touched.
- Any change to the recorder's tap or to REC12's barrier.
- Prompt keyboard operability and its hand-laid-out AppKit (UX27, and ARCH5's `makeContentView` view leg).

## Acceptance

- After the change, no code path opens an `AVAudioEngine` input while the prompt is up: a test (or a source fence where no seam exists, saying so) pins that `MeetingPromptWindow` owns no `AVAudioEngine` and never calls `installTap`.
- For option (b), a test drives the pulse from a fake mic-busy signal and asserts it reads idle when the signal is false.
- `cd daemon && swift build` warning-clean, `swift test` green (tests removed with the deleted type are listed in the commit body, N new tests stated), `bash scripts/ci-local.sh` green, including the design-token fences on any new glyph colour.
- Owner walkthrough (confirms, does not gate): with a Teams call starting, the prompt appears without the macOS mic indicator naming MeetingPipe until Record is chosen.
