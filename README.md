# meeting-pipe

Background macOS daemon that detects video meetings, captures audio locally,
transcribes with speaker identification, generates a summary + action items via
Claude, and publishes to Notion. Zero recurring cost. Fully on-device audio.
**macOS only.**

See [`SPEC.md`](./SPEC.md) for the full design.

---

## What it does

1. **Detects** when you're in a meeting (Zoom, Teams, Slack huddles, Google Meet,
   Webex — native apps and browser tabs).
2. **Asks** to record via a notification (or auto-records if you tagged the app).
3. **Captures** system audio + your mic to `~/Documents/Meetings/raw/`.
4. **Transcribes** with WhisperX + pyannote diarization, fully on-device.
5. **Summarizes** with Claude Sonnet (title, decisions, action items, questions).
6. **Publishes** to a Notion database with idempotent updates.
7. **Notifies** you when it's done — click to open the Notion page.

A global hotkey (default `⌃⌥M`) toggles recording manually if detection misses a
meeting or you want a quick voice memo.

---

## Requirements

- macOS 13+ (Ventura or later) on Apple Silicon or Intel.
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
2. Build the Swift menu-bar daemon (`swift build -c release`).
3. Install the Python pipeline into `~/.local/share/meeting-pipe/venv/`.
4. Stage `~/.config/meeting-pipe/config.toml` and `secrets.env` (mode 0600).
5. Pre-fetch HF models if `HF_TOKEN` is set.
6. Install the LaunchAgent so the daemon starts at login.

### One-time manual steps

The installer can't do these for you:

1. **Install BlackHole 2ch** (system-audio routing — macOS forbids apps from
   capturing other apps' audio without it):

   ```bash
   brew install --cask blackhole-2ch
   ```

2. **Create an Aggregate Device** in `Audio MIDI Setup.app` combining
   BlackHole 2ch + your physical mic. Name it `Aggregate Device` (or set a
   different name in `config.toml`).

3. **Accept Hugging Face TOS** for the pyannote models:
   - <https://huggingface.co/pyannote/speaker-diarization-3.1>
   - <https://huggingface.co/pyannote/segmentation-3.0>

4. **Fill in secrets** at `~/.config/meeting-pipe/secrets.env`:

   ```env
   ANTHROPIC_API_KEY=sk-ant-...
   NOTION_TOKEN=ntn_...
   HF_TOKEN=hf_...
   ```

5. **Configure** `~/.config/meeting-pipe/config.toml`:
   - Set `notion.database_id` to your Meetings database ID
     (the 32-char string in the database URL).
   - Adjust `recording.audio_device` if you named your aggregate differently.

6. **Grant macOS permissions** when prompted on first launch:
   - Microphone (for ffmpeg recording)
   - Screen Recording (avfoundation requires this on some macOS versions)
   - Accessibility (for reading browser tab titles to detect Meet/Teams Web)
   - Notifications (for record / skip prompts)

   The daemon checks each on startup; if any are missing, the menu bar item
   shows a banner with deeplinks to the right Settings panes.

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
```

---

## Logs

Everything lives under `~/Library/Logs/MeetingPipe/`:

- `daemon.log`   — state transitions, recording start/stop, pipeline kick-off
- `detector.log` — meeting detection events (which app/tab, debounce timing)
- `recorder.log` — ffmpeg lifecycle
- `ffmpeg.log`   — ffmpeg's own stderr, so you can see why a recording failed
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
- `modes.regulated_mode` — when `true`, skip Notion entirely and produce only
  a local Markdown summary. Use this for client/regulated calls.

---

## Troubleshooting

**No recording starts when I join a Zoom call.**
Check `detector.log`. Two-signal AND requires both (a) a known meeting app
running and (b) some app holding the mic. If you join muted, the mic signal
doesn't fire — Zoom only opens the input device when you unmute. Use the
`⌃⌥M` hotkey or set `auto_consent_apps`.

**ffmpeg recording produces a 0-byte file.**
Check `ffmpeg.log`. Most common cause: the configured `audio_device` name
doesn't match anything in `Audio MIDI Setup`. Run
`ffmpeg -f avfoundation -list_devices true -i ""` to see exact names.

**Diarization fails with HTTP 401.**
You haven't accepted the pyannote TOS. Visit the URLs in the install section
above, click "Agree to Terms", then re-run.

**The menu bar icon shows "Idle" but I'm in a meeting.**
Open Console.app, filter on `subsystem:com.meetingpipe.daemon`. The detector
emits an `os_log` line for every state change. If you see no events, restart
the daemon: `launchctl kickstart -k gui/$(id -u)/com.meetingpipe.daemon`.

**Notion publish fails with 401 / 404.**
- 401 → `NOTION_TOKEN` is wrong or revoked.
- 404 → the integration isn't shared with your database, or
  `notion.database_id` is wrong (use the ID, not the page slug).

**ffmpeg processes survive after the daemon exits.**
This is the bug we explicitly guard against — `Recorder.stop()` sends `SIGINT`
and waits up to 5 s for a clean flush. If you find an orphan, run
`pkill -INT ffmpeg` and file an issue with `ffmpeg.log`.

---

## Uninstall

```bash
./scripts/uninstall.sh           # keeps your config
./scripts/uninstall.sh --purge   # also removes ~/.config/meeting-pipe
```

---

## License

MIT — see [`LICENSE`](./LICENSE).
