# meeting-pipe

Background macOS daemon that detects video meetings, captures audio locally,
transcribes with speaker identification, generates a summary + action items via
Claude, and publishes to Notion. Zero recurring cost. Fully on-device audio.
**macOS 14+ only.**

See [`SPEC.md`](./SPEC.md) for the full design.

---

## What it does

1. **Detects** when you're in a meeting (Zoom, Teams, Slack huddles, Google Meet,
   Webex — native apps and browser tabs).
2. **Asks** to record via an on-screen panel (top-right, Notion-style).
3. **Captures** system audio (every other process) + your mic, mixes them, and
   writes a 16 kHz mono WAV to `~/Documents/Meetings/raw/`.
4. **Transcribes** with WhisperX + pyannote diarization, fully on-device.
5. **Summarizes** with Claude Sonnet (title, decisions, action items, questions).
6. **Publishes** to a Notion database with idempotent updates.
7. **Notifies** you when it's done — click to open the Notion page.

A global hotkey (default `⌃⌥M`) toggles recording manually if detection misses a
meeting or you want a quick voice memo.

For meetings longer than ~1 hour, the pipeline writes the transcript to disk
along with a paste-into-Claude-Code bundle and **does not call the Anthropic
API**. See "Long meetings" below.

The on-screen prompt also has a **Record (BYO)** button: same flow, but
opt-in per-meeting — useful for sensitive calls or when you'd rather
hand-summarise. After the recording finishes, save your summary as
`<stem>.summary.md` next to the transcript and run
`mp publish-from-paste <stem>.md` to push it to Notion.

---

## Requirements

- **macOS 14 (Sonoma) or later** — required for ScreenCaptureKit's
  `excludesCurrentProcessAudio`.
- ~10 GB free disk (large-v3 Whisper model + pyannote).
- A Notion integration token + a database to write to.
- An Anthropic API key.
- A Hugging Face token (free) — pyannote's diarization models are gated behind
  a TOS acceptance.

---

## Install

```bash
git clone https://github.com/<you>/meeting-pipe.git
cd meeting-pipe
./scripts/install.sh
```

The installer will:

1. Verify Homebrew, install `ffmpeg` and `uv` if missing.
   (`ffmpeg` is used by the Python pipeline for audio loading; the daemon
   itself records natively via ScreenCaptureKit — no subprocess.)
2. Build the Swift menu-bar daemon (`swift build -c release`), generate
   an `AppIcon.icns` from SF Symbols, wrap the binary in a `.app` bundle,
   and `ditto` it into `~/Applications/MeetingPipe.app` so Spotlight
   can launch it.
3. Install the Python pipeline into `~/.local/share/meeting-pipe/venv/`.
4. Stage `~/.config/meeting-pipe/config.toml` and `secrets.env` (mode 0600).
5. Pre-fetch HF models if `HF_TOKEN` is set.
6. Install the LaunchAgent so the daemon starts at login.

**First launch & Gatekeeper.** The app is unsigned (no Apple Developer
subscription required for personal use). On first launch from Spotlight,
macOS shows an "unverified developer" dialog. Right-click the app icon
in Finder → Open, confirm once, and macOS remembers the decision. The
LaunchAgent path runs the binary directly so it's not subject to that
dialog after the first manual approval.

### One-time manual steps

The installer can't do these for you:

1. **Accept Hugging Face TOS** for the pyannote models:
   - <https://huggingface.co/pyannote/speaker-diarization-3.1>
   - <https://huggingface.co/pyannote/segmentation-3.0>

2. **Fill in secrets** at `~/.config/meeting-pipe/secrets.env`:

   ```env
   ANTHROPIC_API_KEY=sk-ant-...
   NOTION_TOKEN=ntn_...
   HF_TOKEN=hf_...
   ```

   You can rotate these any time — the daemon re-reads `secrets.env` every
   time it spawns the pipeline, so a new value takes effect on the next
   recording. No restart needed.

   To verify: `~/.local/share/meeting-pipe/venv/bin/mp doctor` — pings each
   API and tells you which secret is wrong.

3. **Configure** `~/.config/meeting-pipe/config.toml`:
   - Set `notion.database_id` to your Meetings database ID
     (the 32-char string in the database URL).

4. **Grant macOS permissions** when prompted on first launch:
   - **Microphone** — `AVAudioEngine` reads from the system default input.
   - **Screen Recording** — gates `SCStream.capturesAudio` in TCC.
   - **Accessibility** — reads browser tab titles to detect Meet/Teams Web.
   - **Notifications** — record/skip prompts and completion alerts.

   No audio devices to set up. The daemon captures whatever your system
   audio is currently playing (regardless of output device — speakers,
   wired headphones, AirPods, anything) and the mic that macOS treats as
   the default input. Change the input in System Settings ▸ Sound and the
   next recording adapts.

---

## Notion database schema

Create a database with at least these properties:

| Name     | Type     | Notes                                  |
| -------- | -------- | -------------------------------------- |
| `Name`   | Title    | Meeting title; written by the pipeline |
| `Date`   | Date     | Auto-set to publish time (UTC)         |
| `Status` | Select   | Default value `Captured` — add this option |

Share the database with your Notion integration (••• → "Add connections").

---

## Running by hand

You can run any pipeline stage on its own audio file — useful for debugging
or re-publishing a fixed transcript:

```bash
# Full pipeline
~/.local/share/meeting-pipe/venv/bin/mp run-all ~/Documents/Meetings/raw/20260428-1430.wav

# Or step-by-step
mp transcribe   <wav>
mp summarize    <transcript.md>
mp publish-notion <summary.json>

# Preflight check (validates secrets + live API access)
mp doctor
```

---

## Long meetings

The Anthropic API charges per token. A 1-hour meeting can cost real money to
auto-summarize — and you might prefer to handle it yourself in Claude Code,
where you have access to the full conversation context anyway.

Default behavior: if the transcript exceeds **80 000 characters** (~20 000
tokens, ~1 hour of speech), the pipeline:

1. Saves the transcript markdown as usual at `<stem>.md`.
2. Writes a sidecar `<stem>.READY_FOR_MANUAL.md` containing the exact system
   prompt the pipeline would have used, plus a pointer to the transcript.
3. **Skips** the Anthropic call and the Notion publish.
4. Sends a desktop notification.

To process the meeting yourself: open Claude Code, paste the system prompt
from the `.READY_FOR_MANUAL.md` file, attach (or paste) the transcript
markdown, and ask for the summary. No API charge.

To change the threshold or disable the guard, edit
`summarization.skip_above_chars` in `~/.config/meeting-pipe/config.toml`.
Set to `0` to disable.

---

## Logs

Everything lives under `~/Library/Logs/MeetingPipe/`:

- `daemon.log`   — state transitions, recording start/stop, pipeline kick-off
- `detector.log` — meeting detection events (which app/tab, debounce timing)
- `recorder.log` — recording lifecycle, duration parity check
- `pipeline.log` — transcription, summarization, Notion publishing
- `launchd.{out,err}.log` — daemon stdout/stderr

`tail -F ~/Library/Logs/MeetingPipe/*.log` is the fastest way to debug.

---

## Configuration reference

See [`config.example.toml`](./config.example.toml). Highlights:

- `recording.auto_consent_apps` — bundle IDs that auto-record without a prompt
  (e.g. `["us.zoom.xos"]`).
- `detection.manual_hotkey` — global hotkey for manual record (default
  `ctrl+option+m`).
- `transcription.disable_diarization` — set to `true` for languages where
  pyannote struggles (e.g. Ukrainian); transcript will label all turns as
  "Speaker".
- `summarization.team_context` — domain string injected into the system prompt
  so Claude doesn't extract domain terms ("validation", "QMS") as action items.
- `summarization.skip_above_chars` — long-meeting guard (default 80 000).
- `modes.regulated_mode` — when `true`, skip Notion entirely and produce only
  a local Markdown summary. Use this for client/regulated calls.

There are no microphone or output-device settings — the daemon auto-detects
both. Change the system default input in System Settings ▸ Sound to swap mics.

---

## Troubleshooting

**No recording starts when I join a Zoom call.**
Check `detector.log`. Two-signal AND requires both (a) a known meeting app
running and (b) some app holding the mic. If you join muted, the mic signal
doesn't fire — Zoom only opens the input device when you unmute. Use the
`⌃⌥M` hotkey or set `auto_consent_apps`.

**The recording is silent / very quiet.**
Check `recorder.log` for the `duration check` line at the end of a recording.
With the in-process recorder it should always read `ratio=~100%`. If it
doesn't, the Screen Recording permission may not have been granted (system
audio capture is gated). Check System Settings ▸ Privacy & Security ▸
Screen Recording — MeetingPipe should be enabled.

**The recording is missing system audio (only my voice).**
ScreenCaptureKit needs Screen Recording permission. After granting, restart
the daemon: `launchctl kickstart -k gui/$(id -u)/com.meetingpipe.daemon`.

**Diarization fails with HTTP 401.**
You haven't accepted the pyannote TOS. Visit the URLs in the install section
above, click "Agree to Terms", then re-run. `mp doctor` flags this.

**The menu bar icon shows "Idle" but I'm in a meeting.**
Open Console.app, filter on `subsystem:com.meetingpipe.daemon`. The detector
emits an `os_log` line for every state change. If you see no events, restart
the daemon: `launchctl kickstart -k gui/$(id -u)/com.meetingpipe.daemon`.

**Notion publish fails with 401 / 404.**
- 401 → `NOTION_TOKEN` is wrong or revoked. `mp doctor` confirms.
- 404 → the integration isn't shared with your database, or
  `notion.database_id` is wrong (use the ID, not the page slug).

---

## Uninstall

```bash
./scripts/uninstall.sh           # keeps your config
./scripts/uninstall.sh --purge   # also removes ~/.config/meeting-pipe
```

---

## License

MIT — see [`LICENSE`](./LICENSE).
