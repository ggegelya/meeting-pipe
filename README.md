# meeting-pipe

Background macOS daemon that detects video meetings, captures audio locally,
transcribes with speaker identification, generates a summary + action items, and
publishes to your sinks of choice. Zero recurring cost beyond the LLM call,
and the LLM call itself is optional (a fully on-device MLX backend is
available). Apple-Silicon-native ASR (MLX/Metal) + diarization (sherpa-onnx /
CoreML). Multilingual: 99 languages via Whisper, summary written in the same
language as the transcript. **macOS 14+ only.**

Two privacy modes:

- **Cloud (default).** Anthropic Claude does the summarization. Best quality
  today, ~$0.05/meeting on Sonnet 4.6.
- **Local.** Apple's MLX runs Qwen2.5-14B-Instruct-4bit on-device. Audio,
  transcript, and summary never leave the machine. Switch in Preferences →
  Pipeline. Pair with `regulated_mode = true` for a full zero-egress pipeline
  (a test in `tests/test_summarize_backend.py` locks this in).

Three output sinks, mix and match via `output.sinks`:

- **Notion** (default): REST publish to a database, idempotent.
- **Obsidian**: Markdown note in your vault with optional audio attachment
  and daily-note backlink.
- **Filesystem**: drops `<stem>.summary.md`, `<stem>.transcript.md`, and
  `<stem>.actions.json` into a directory; for tools that watch a folder.

See [`SPEC.md`](./SPEC.md) for the full design.

---

## What it does

1. **Detects** when you're in a meeting (Zoom, Teams, Slack huddles, Google Meet,
   Webex — native apps and browser tabs).
2. **Asks** to record via an on-screen panel (top-right, Notion-style).
3. **Captures** system audio (every other process) + your mic, mixes them, and
   writes a 16 kHz mono WAV to `~/Documents/Meetings/raw/`.
4. **Transcribes** with mlx-whisper (Apple Silicon native, all 99 Whisper
   languages) and labels speakers via sherpa-onnx diarization on CoreML.
5. **Summarizes** (title, decisions, action items, questions) in the same
   language as the transcript. Either Claude Sonnet via the Anthropic API
   (default) or Qwen2.5-14B-Instruct-4bit via on-device MLX, your choice.
6. **Publishes** to every sink in `output.sinks` (Notion, Obsidian, filesystem,
   or a combination). Each sink is idempotent and failures are isolated;
   one sink falling over does not block the others.
7. **Notifies** you when it's done; click to open the page.

A new recording can start while a previous one is still being processed —
processing runs in the background and you only get notified when each
meeting's Notion page is ready.

### Performance

Transcription and diarization happen **in parallel with the meeting**, so
the wait after you click Stop is essentially just summarize + publish.
Measured on a 17-min recording, M-series Mac:

| When |  | Wallclock after Stop |
|---|---|---|
| Original (whisperx + pyannote on CPU) | | ~38 min |
| Tier 1 (mlx-whisper + sherpa-onnx) | | ~5 min |
| Tier 2 (streaming transcribe during recording) | | ~3 min |
| Tier 2.5 (streaming diarize during recording) | | **~10-30 s** |

If streaming fails for any reason, the pipeline falls back to the offline
path automatically — you never lose a transcript.

A global hotkey (default `⌃⌥M`) toggles recording manually if detection misses a
meeting or you want a quick voice memo. A second hotkey (default `⌃⌥⇧M`) is a
stop-only force-stop — it never starts a recording, so you can panic-press it
without risking an accidental start.

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
- **Apple Silicon (M-series)** for the fast path. mlx-whisper requires
  arm64; on Intel Macs the pipeline falls back to faster-whisper-CPU and
  runs roughly 5× slower.
- ~3 GB free disk: ~1.5 GB for the MLX-converted Whisper model (downloaded
  on first recording) + ~32 MB for sherpa-onnx diarization models.
- A Notion integration token + a database to write to.
- An Anthropic API key.
- **Hugging Face token is no longer required.** sherpa-onnx pulls models
  from a public GitHub release. `HF_TOKEN` stays optional in the secrets
  file for users who deliberately opt back into a pyannote workflow.

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

1. **Fill in secrets** at `~/.config/meeting-pipe/secrets.env`:

   ```env
   ANTHROPIC_API_KEY=sk-ant-...
   NOTION_TOKEN=ntn_...
   # HF_TOKEN is optional — only needed if you opt back into pyannote.
   ```

   You can rotate these any time — the daemon re-reads `secrets.env` every
   time it spawns the pipeline, so a new value takes effect on the next
   recording. No restart needed.

   To verify: `~/.local/share/meeting-pipe/venv/bin/mp doctor` — pings each
   API, validates the ML runtimes, and tells you which secret is wrong.

2. **Configure** `~/.config/meeting-pipe/config.toml`:
   - Set `notion.database_id` to your Meetings database ID
     (the 32-char string in the database URL).
   - Optionally tune `transcription.diarize_cluster_threshold` if speaker
     splitting looks off (higher → fewer speakers, lower → more).

3. **Grant macOS permissions** when prompted on first launch:
   - **Microphone** — `AVAudioEngine` reads from the system default input.
   - **Screen Recording** — gates `SCStream.capturesAudio` in TCC.
   - **Accessibility** — reads window titles to detect when a meeting
     ends (Teams / Zoom / Webex / Slack desktop AND browser tabs). Without
     this, native apps will record fine but the call won't auto-stop -
     the daemon falls back to manual hotkey / silence-based stop, which
     can mean an extra 5 minutes of wav file. The daemon emits a startup
     banner + a rate-limited `ACCESSIBILITY DENIED` line in
     `~/Library/Logs/MeetingPipe/detector.log` if it's missing.
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

# Preflight check (validates secrets + live API access + which sinks
# are reachable + which summarization backend is selected)
mp doctor

# Filter the JSONL event streams (see Logs section)
mp logs --since 1h --category detector

# Audit detector end-signal reliability — pairs each recording with its
# preceding `detector.ended` and surfaces sessions you had to stop manually
mp analyze-detection --since 7d

# Compare Anthropic vs the local backend on one transcript; writes a
# scorecard you fill in by hand
mp dogfood <transcript.md>
mp dogfood --report   # aggregate filled scorecards into a ship/no-ship
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

## Library window

Click the menu bar icon → **Open Library…** to open the main window
(900x600, restorable, hides on Cmd+W with the daemon still running).

Three-pane layout: a left rail with `Library / Workflows /
Preferences` plus a status footer (idle / recording / processing-queue
badge / model-download progress and a Start/Stop button), a middle
column with the meetings list, and a placeholder detail column on the
right.

If you've never recorded anything the list shows
`No recordings yet - Start a meeting in Zoom / Teams / Meet / Webex /
Slack, or press ⌃⌥M.` Otherwise:

The list scans `~/Documents/Meetings/raw/` (or whatever is configured
in `recording.output_dir`) and shows one row per recording, grouped
into Today / Yesterday / This week / Last week / Earlier this month /
older months. Each row carries the meeting title (LLM-derived when
available, falling back to the source app + time), source-app glyph,
duration, and a status pill (Recording / Processing / Paste pending /
Ready). Live recordings and rows whose pipeline run is still in
flight pulse subtly so you can tell what's currently being worked on
at a glance. The list refreshes automatically when the pipeline
writes new sidecars - new meetings appear within a second of the
underlying file landing.

Select a row and the right pane fills with the per-meeting detail
view: an editable title, the meeting's date, the workflow chip when
present, duration, and shortcuts to open the published note in Notion
or Obsidian (when those sidecars are on disk) or reveal the raw audio
in Finder. Five tabs underneath:

- `Summary` renders `<stem>.summary.md` as Markdown and exposes an
  `Edit` button. The editor reuses the same field set as the
  standalone correction window: title, summary bullets, decisions,
  action items, open questions, attendees, language, notes. Saving
  writes a correction record (verdict=edited) and overwrites
  `<stem>.summary.json` so the list and Markdown views immediately
  reflect the new content. `Save & Republish` additionally re-runs
  `mp publish-notion` so the published page in Notion picks up the
  edit; the editor stays disabled and shows a progress indicator while
  the subprocess runs.
- `Transcript` renders the diarized segments from `<stem>.json` as a
  speaker-grouped list. Click any line to jump the audio play head to
  that segment and start playing; the active line is highlighted as
  playback advances. A compact play / pause / scrubber strip sits at
  the bottom of the tab; the same audio engine is reused by the Audio
  tab when it lands so seeking from a transcript line and switching
  tabs keeps the same play head.
- `Audio` shows a two-channel waveform (mic on top, system audio on
  the bottom) backed by downsampled peaks. The cache lives under
  `~/Library/Caches/MeetingPipe/waveforms/<stem>.peaks` and is keyed
  on the wav's size + modification time, so any change to the
  recording (re-record, repair, replace) invalidates the cache on the
  next open. Click anywhere in the waveform to seek; the play head
  syncs with the Transcript tab. A segmented zoom picker (Fit / 1× /
  2× / 4× / 8×) widens the rendered track when you need to land on a
  specific second.
- `Corrections` shows the on-disk correction record once you've
  edited (or graded) the meeting: verdict, timestamp, backend + model,
  notes, and a side-by-side Original / Corrected preview. **Re-edit in
  Summary tab** flips you back to the Summary tab; **Revert…** asks
  for confirmation and then restores the original LLM summary to
  `<stem>.summary.json` and deletes the correction record. Notion is
  not changed automatically — republish from the Summary tab if you
  want the page in sync.
- `Raw files` lists every sidecar in the recordings directory that
  shares the meeting's stem (`<stem>.wav`, `<stem>.json`,
  `<stem>.summary.json`, `<stem>.meta.json`, `<stem>.run.json`, and
  the publish-target sidecars) with size + modification date. Each
  row has **Reveal in Finder**, a double-click to open with the
  default app, and a context-menu option to copy the path. The footer
  shows the directory and an **Open folder** button.

Editing the title in the header writes the new value back to
`<stem>.summary.json` when that file exists, otherwise to
`<stem>.meta.json`. The list rescans on the next debounce tick and the
new title appears in both the row and the detail header.

Right-click any row in the list for per-meeting actions:
`Re-publish to Notion` (idempotent), `Regenerate summary` (re-runs
`mp summarize` against the existing transcript then re-publishes),
`Export…` (copies summary / transcript / audio into a chosen folder),
`Reveal in Finder`, and `Move to Trash…` (soft-delete every sidecar
for the stem; recoverable from the system Trash). Republish and
regenerate run as background subprocesses; the row's status pill
flips to a progress badge while the subprocess is in-flight.

Selecting `Preferences` in the rail opens the existing standalone
Preferences window.

---

## Improving local quality

When `summarization.backend` is `"local"`, you can grade each
published summary so the local model gets better over time. There
are two surfaces:

- **Done-meeting notification.** After publish, the banner shows
  three actions:
  - **Open in Notion** (when applicable) opens the published page.
  - **Looks good** records a verdict-good sample inline; nothing else
    to do.
  - **Edit summary** opens an editor sheet pre-populated with the
    summary, where you can fix any field (title, summary bullets,
    decisions, action items, questions, attendees) and save.
- **Recent meetings…** in the menu bar lists the last 10 published
  meetings; pick one to open the same editor sheet. Useful when you
  dismissed the notification.

Every grade lands as one JSON file under
`~/Library/Application Support/MeetingPipe/corrections/<stem>.json`.
The corpus stays on your machine. Nothing in this loop touches the
network, regardless of which summarization backend you use.

Run `mp corrections-stats` to see the current state of your corpus
plus a Phase 3 readiness check (the upcoming local-LoRA training
needs ~20 corrections covering ~200 minutes of speech before it can
fine-tune a per-user adapter). Pass `--json` for a script-friendly
form.

---

## Logs

Everything lives under `~/Library/Logs/MeetingPipe/`:

- `daemon.log`   — state transitions, recording start/stop, pipeline kick-off
- `detector.log` — meeting detection events (which app/tab, debounce timing)
- `recorder.log` — recording lifecycle, duration parity check
- `pipeline.log`: transcription, summarization, publishing
- `events.jsonl`: structured Swift-side events, one JSON object per line
- `pipeline_events.jsonl`: structured Python-side events
- `launchd.{out,err}.log` — daemon stdout/stderr

`tail -F ~/Library/Logs/MeetingPipe/*.log` is the fastest way to debug live.
For postmortem queries against a workday's worth of detection or pipeline
events, use `mp logs`:

```bash
mp logs --since 1h                                  # everything in the last hour
mp logs --since 30m --category detector             # just detector events
mp logs --since 2d --action pipeline_failed         # all pipeline failures
mp logs --since 1d --json | jq 'select(.bundle_id=="us.zoom.xos")'
```

`--since` accepts ISO timestamps (`2026-05-06T10:00:00Z`) or short relative
offsets (`Nh` / `Nm` / `Nd` / `Ns`).

---

## Configuration reference

See [`config.example.toml`](./config.example.toml). Highlights:

- `recording.auto_consent_apps` — bundle IDs that auto-record without a prompt
  (e.g. `["us.zoom.xos"]`).
- `detection.manual_hotkey` — global hotkey for manual record (default
  `ctrl+option+m`).
- `transcription.model` — MLX Whisper repo. Default `mlx-community/whisper-large-v3-turbo`.
- `transcription.language` — `"auto"` or an ISO 639-1 code (`"en"`, `"uk"`,
  `"ru"`, `"de"`, ...) to skip detection.
- `transcription.disable_diarization` — set to `true` to label all turns as
  "Speaker" and skip the diarization stage entirely.
- `transcription.diarize_cluster_threshold` — sherpa-onnx FastClustering
  cosine-distance threshold (default `0.85`). Higher merges more aggressively
  (fewer speakers); lower keeps more clusters separate. Used by the
  offline diarize fallback.
- `transcription.stream_diarize_threshold` — online (streaming)
  StreamDiarizer threshold (default `0.7`). Different scale than
  `diarize_cluster_threshold` because the algorithms are different.
  Used by the streaming sidecar that runs during recording.
- `summarization.summary_language` — `"auto"` (default; matches transcript
  language) or an ISO 639-1 code to force a specific output language.
- `summarization.team_context` — domain string injected into the system prompt
  so the summarizer does not extract domain terms ("validation", "QMS") as
  action items.
- `summarization.skip_above_chars` — long-meeting guard (default 80 000).
- `summarization.backend`: `"anthropic"` (default), `"local"` (on-device
  MLX, no outbound calls), or `"auto"` (try Anthropic first, fall back to
  local on network/auth failure). Switchable in Preferences → Pipeline.
- `summarization.local_model`: MLX model id when backend is `"local"` or
  `"auto"`. Default `mlx-community/Qwen2.5-3B-Instruct-4bit` (~2 GB on
  first use; cached in `~/.cache/huggingface/hub`). Use the preset
  picker in Preferences → Pipeline to swap to the curated
  Recommended (Qwen 14B-4bit, ~8 GB, slower, better quality) or Large
  (Qwen 32B-4bit, ~18 GB, slowest, best quality) options, or pick
  Custom and paste any HuggingFace MLX repo id. The daemon pre-fetches
  the configured model immediately on first launch / on backend flip,
  so the first meeting in local mode does not wait several minutes
  for the download to finish inside `mlx_lm.server`. Progress shows
  in the menu bar (title suffix `↓ NN%` plus a dedicated menu row
  with the byte breakdown).
- `summarization.local_endpoint`: where `LocalSummaryClient` will spawn
  `mlx_lm.server`. Default `http://127.0.0.1:8765`.
- `output.sinks`: ordered list of publishers to invoke. Default `["notion"]`.
  Add `"obsidian"` and/or `"filesystem"` to fan out. Each sink fails
  independently; one going down does not block the others.
- `obsidian.vault_path`: required when `"obsidian"` is in `sinks`. The
  publisher writes to `<vault>/<obsidian.folder>/<date> <slug>.md` with
  YAML front-matter; `obsidian.attach_audio = true` copies the recording
  into `<vault>/<obsidian.attachments_subfolder>/`. `obsidian.template_path`
  points at a custom template (the built-in template covers the common
  case).
- `filesystem.output_dir`: where the filesystem sink drops the three files.
- `modes.regulated_mode`: when `true`, the Notion sink no-ops at upsert
  time. Pair with `summarization.backend = "local"` for full zero-egress
  (every outbound HTTP request would assert in tests).

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

**Speaker labels look wrong (one person split across many speakers, or
multiple people collapsed into one).**
Two thresholds depending on which path produced the labels — check
`pipeline.log` for "streaming" or "offline" diarize lines.

- **Streaming (the common case):** tune `transcription.stream_diarize_threshold`
  (default `0.7`). Raise toward `0.85` if one person gets split; lower
  toward `0.55` if multiple participants get merged.
- **Offline (fallback path, only runs when streaming was unusable):**
  tune `transcription.diarize_cluster_threshold` (default `0.85`).

Both take effect on the next recording — no daemon restart, the
pipeline re-reads config each run.

**The transcript I see right after stop has speaker labels but the next
day they look different.**
That can't happen — transcript files (`<stem>.json`, `<stem>.md`) are
written once and not modified. If you see this, you're probably looking
at two different runs (a re-run via `mp run-all <wav>` overwrote the
first). Check `pipeline.log` for two "run-all" sections matching the
file's timestamp.

**The menu bar icon shows "Idle" but I'm in a meeting.**
Open Console.app, filter on `subsystem:com.meetingpipe.daemon`. The detector
emits an `os_log` line for every state change. If you see no events, restart
the daemon: `launchctl kickstart -k gui/$(id -u)/com.meetingpipe.daemon`.

**Notion publish fails with 401 / 404.**
- 401 → `NOTION_TOKEN` is wrong or revoked. `mp doctor` confirms.
- 404 → the integration isn't shared with your database, or
  `notion.database_id` is wrong (use the ID, not the page slug).

**The recording never ends; the daemon thinks the meeting is still going
long after I hung up.**
The end-detection probe scans the meeting app's window titles via
Accessibility. If you have an unrelated window whose title contains a
matching meeting word (e.g. a Slack channel named "team-calls", a
Zoom "Schedule Meeting" dialog left open, a Teams chat thread named
"Sprint planning meeting"), the per-app recognizer should reject it.
If it doesn't, capture the offending titles with
`swift scripts/dump_window_titles.swift <bundle_id> <state> reject`,
add the row to `daemon/Tests/MeetingPipeTests/Fixtures/window_titles.json`,
and the next test run shows whether `Detector.isActiveMeetingWindow`
needs a refinement.

As a safety net, the daemon also watches the audio level. After 90 s of
unbroken silence on both mic and system audio it surfaces a "Still meeting?"
notification with a Stop action; after 5 min it auto-stops and emits an
`auto_stop_silence` event. Look for that event in `events.jsonl` if a
runaway recording stopped on its own.

**Local backend won't start.**
- `mlx-lm not found`: rerun `scripts/install.sh` (or `cd pipeline && uv
  sync`). The dep is declared in `pyproject.toml` with an Apple-Silicon
  marker; non-arm64 hosts fall back to `backend="anthropic"` automatically.
- `mlx_lm.server did not become healthy within 120s`: the model is being
  downloaded for the first time (~9 GB). Check
  `~/.cache/huggingface/hub/models--mlx-community--Qwen2.5-14B-Instruct-4bit/`
  size growth.
- Output looks fine but `mp doctor` still warns "regulated_mode + backend
  = anthropic": expected. `regulated_mode` does not by itself force the
  local backend. Set `summarization.backend = "local"` explicitly for the
  zero-egress contract.

**I uninstalled and reinstalled but macOS still says "permission denied"
and won't re-prompt.**
TCC caches grants/denials per bundle id. `scripts/uninstall.sh --reset-tcc`
clears the cache so the next install behaves like a fresh install. See
the Uninstall section above.

---

## Uninstall

```bash
./scripts/uninstall.sh                    # keeps config + leaves TCC alone
./scripts/uninstall.sh --purge            # also removes ~/.config/meeting-pipe
./scripts/uninstall.sh --reset-tcc        # also resets macOS Microphone /
                                          # ScreenCapture / Accessibility /
                                          # AppleEvents permissions for the
                                          # bundle id, so the next install
                                          # re-prompts cleanly
./scripts/uninstall.sh --all              # shorthand for --purge --reset-tcc
```

Why `--reset-tcc` exists: macOS keys permission grants on the bundle id
(`com.meetingpipe.daemon`). If you denied a permission once, removing the
.app does NOT clear that denial. TCC keeps the cached state, and the next
install silently runs without the permission instead of re-prompting. The
flag uses `tccutil reset` to wipe the cache so a fresh install behaves
like a fresh install.

---

## License

MIT — see [`LICENSE`](./LICENSE).
