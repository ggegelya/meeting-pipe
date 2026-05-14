# Security Policy

meeting-pipe is a personal-use macOS tool maintained by a single author. It
records meeting audio locally and (optionally) sends transcripts to the
Anthropic API for summarization. A real vulnerability here would most likely
involve unintended audio capture, leaking transcript content past the
configured backend, or escalating local privileges via the daemon's TCC
grants. Issues in that envelope are taken seriously even though the project
isn't shipped commercially.

## Supported versions

There are no released versions. Only the current `main` branch is supported.
Fixes are not backported to older commits.

## Reporting a vulnerability

Two private channels:

1. **GitHub Security Advisories** (preferred): the repo has private
   vulnerability reporting enabled. Open a draft advisory at
   `https://github.com/<owner>/meeting-pipe/security/advisories/new` and the
   author is notified privately.
2. **Email**: `security@meetingpipe.app`. The address forwards to the
   author's personal inbox.

Please **do not** open a public GitHub issue, post on social media, or
publish a write-up before the fix lands.

A typical report should include:

- A description of the vulnerability and its impact.
- Steps to reproduce, ideally against the current `main` HEAD.
- The macOS version and Apple Silicon model you tested on.
- Whether you tested with the Anthropic backend, the local MLX backend, or
  both.

The author will acknowledge receipt within 7 days, agree on a disclosure
timeline (target 90 days from acknowledgement), and credit reporters in the
commit fixing the issue unless you ask to remain anonymous.

## Scope

In scope:

- The Swift daemon (`daemon/`): recording, detection, permission handling,
  hotkeys, sidecar files, codesigning identity stability.
- The Python pipeline (`pipeline/`): transcription, diarization, summarization
  backend, publishers, the `mp` CLI.
- The installer and uninstaller scripts in `scripts/`.

Out of scope:

- The Anthropic API, Notion API, Obsidian, Homebrew, `uv`, sherpa-onnx, MLX,
  `whisperx`, or any other upstream dependency. Please report those to the
  respective projects.
- macOS itself (TCC, ScreenCaptureKit, AVFoundation behaviour, etc.).
- Findings that require an attacker who already has root or full-disk access
  on the target Mac — at that point the audio capture story is moot.
- Theoretical attacks on the local MLX summarization path that don't escape
  the user's own machine.
