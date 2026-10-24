# DOC16: the Screen Recording usage string tells the user capture uses the process-tap API and reads no pixels, while capture is a ScreenCaptureKit display stream, and the plist claims macOS 13 against a macOS 14 package

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) M1, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) DI-9, plist half only). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified on 2026-10-24.

**The consent text describes a capture stack that was removed in April.** `scripts/install.sh` writes the app's `Info.plist` from a heredoc, and its `NSScreenCaptureUsageDescription` reads: "MeetingPipe captures system audio (other participants' voices) directly via Apple's process-tap API on macOS 14.2+. The same TCC entitlement gates audio process taps; no screen pixels are read." The process tap shipped in `ec57e17` ("drop BlackHole on macOS 14.2+ via Apple's process-tap API", 2026-04-29) and was replaced the same day by `029abac` ("replace capture stack with ScreenCaptureKit + AVAudioEngine"). What runs now is `SystemAudioCapture`, whose doc comment says it "Replaces the prior ProcessTapRouter + aggregate-device approach, which silently dropped channels on macOS 26". It builds an `SCStream` over a display filter with `config.width = 2`, `config.height = 2`, `minimumFrameInterval` of one second, and adds a `.screen` output ("required even for audio-only; startCapture errors without it"). So the stream does deliver screen frames, two pixels square, which are discarded. Both halves of the sentence are false: it is not the process-tap API, and pixels are read. This is the one string macOS shows beside the permission it gates. `grep -rn "AudioHardwareCreateProcessTap\|CATapDescription" daemon/Sources` returns nothing.

**ARCHITECTURE.md repeats it.** Its `SystemAudioCapture.swift` entry reads "ScreenCaptureKit + ProcessTap (macOS 14.2+) capture of every-other-process audio." README ("System audio is captured with ScreenCaptureKit") and `docs/SETUP.md` ("meeting-pipe captures the audio stream only. It never records your screen, and no video is written to disk at any point") are accurate and are the register to match.

**The OS floor disagrees with itself.** `daemon/Package.swift` declares `platforms: [.macOS(.v14)]`, and `scripts/install.sh` refuses below 14 (`die "macOS 14 (Sonoma) or newer required. Detected: $SW_VERS"`), but the same script's plist sets `LSMinimumSystemVersion` to `13.0`. The installed app on the owner's Mac reads `13.0` (`PlistBuddy -c "Print :LSMinimumSystemVersion"`). The install-time check covers `install.sh`; a copied or drag-installed app (DIST1's path) is gated only by the plist, so Finder would launch a macOS 14 binary on 13. The stated reason for the floor is also inconsistent: README, `install.sh` and ARCHITECTURE say `excludesCurrentProcessAudio` is the macOS 14 hard floor, while the code comment beside `config.excludesCurrentProcessAudio = true` says "macOS 13.3+".

## Scope

1. Rewrite `NSScreenCaptureUsageDescription` in `scripts/install.sh` to say what happens, in the SETUP.md register: system audio is captured through ScreenCaptureKit, the API requires a video stream which is kept at two pixels and thrown away, nothing of the screen is saved. Keep it to two short sentences. Read `docs/GUIDE.md` and `PRODUCT.md` before writing it (root `CLAUDE.md` rule for user-facing copy).
2. Set `LSMinimumSystemVersion` to `14.0` in the same heredoc. (`scripts/test-app-relocation.sh`'s staging plist does not carry the key and needs nothing.)
3. Fix ARCHITECTURE.md's `SystemAudioCapture.swift` entry ("ScreenCaptureKit display stream, audio output only"), drop "ProcessTap" and "14.2+", and state the macOS 14 floor's real reason once: check the SDK availability of every API the floor is claimed for, then make README, `install.sh`'s comment, ARCHITECTURE and the `excludesCurrentProcessAudio` code comment agree.
4. Note in the commit body that `scripts/rebuild.sh` reuses the installed app's `Info.plist`, so the new strings reach an existing install only through `scripts/install.sh`.

## Explicitly not

- `NSMicrophoneUsageDescription` ("Audio never leaves your Mac"), which is false when the default engine sends transcripts to Anthropic. SEC18 (architecture review S2, "Fix the install text") owns that string; if SEC18 has not landed, leave it for SEC18 rather than half-fix the zero-egress wording here.
- The Swift 6 toolchain check (DI-9's other half): DIST5. Version stamping in the same plist: DIST6.
- HYG10 lists this consent text among its false comments (D2); this task is the fix, and HYG10 should cite it rather than redo it.
- A Core Audio tap (CATap) backend. The review suggests revisiting it behind a flag once macOS 26 behaviour is stable; that is a capture change with its own consent text, not a docs fix, and nothing is filed for it.

## Acceptance

- `grep -rn -i "process-tap\|process tap\|ProcessTap" scripts/install.sh ARCHITECTURE.md README.md docs/SETUP.md docs/GUIDE.md` returns no claim that the current capture uses a process tap (history in `docs/spikes/` and ADRs stays as it is).
- A shell check in `scripts/ci-local.sh fences` (or an extension of an existing one) that extracts `LSMinimumSystemVersion` from `install.sh`'s heredoc and the `.macOS(.vN)` floor from `daemon/Package.swift` and fails when they differ. 1 new check.
- `bash scripts/test-app-relocation.sh` and `bash scripts/ci-local.sh` green; `python3 scripts/truth_fences.py links` green.
- After `scripts/install.sh` on the owner's Mac (confirms, does not gate): `PlistBuddy -c "Print :LSMinimumSystemVersion"` prints `14.0`, and the Screen Recording grant survives the reinstall (the usage string is not part of the TCC identity).
