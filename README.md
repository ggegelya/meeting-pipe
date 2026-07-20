<div align="center">

<img src="design/assets/readme-hero.png" alt="meeting-pipe, an on-device macOS menu-bar app for meeting capture, transcription, and summaries" width="820">

[![CI](https://github.com/ggegelya/meeting-pipe/actions/workflows/ci.yml/badge.svg)](https://github.com/ggegelya/meeting-pipe/actions/workflows/ci.yml)
[![Platform](https://img.shields.io/badge/macOS-14%2B_Apple_Silicon-1a1b1e)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/license-MIT-0e8c82)](./LICENSE)

</div>

# meeting-pipe

Record your video meetings on-device, transcribe them with speaker labels, and publish a summary to Notion, Obsidian, or your filesystem. Personal-use, single-Mac, no cloud database.

## Why

1. **On-device by default.** Audio, transcript, and diarization stay on your Mac. Summarization is the only step that leaves the machine, and only when you keep the Anthropic backend on. Flip `summarization.backend = "local"` for a fully zero-egress pipeline (MLX-Qwen on Metal, no outbound calls).
2. **Hands-off recording.** Detects Zoom, Teams, Meet, Webex, and Slack huddles across native apps and browser tabs, pops a prompt before each call, and auto-stops when the meeting ends. Transcription runs on-device right after Stop (FluidAudio on the Apple Neural Engine).
3. **Owns nothing.** Recordings live in `~/Documents/Meetings/raw/`. Output is plain Markdown. Notion, Obsidian, and filesystem sinks fan out independently, and one going down doesn't block the others.

**Architecture overview:** see [ARCHITECTURE.md](./ARCHITECTURE.md) for the subsystem map, meeting-lifecycle sequence, and the verdict-fusion stack that drives mute handling.

## Quickstart

```bash
git clone https://github.com/ggegelya/meeting-pipe.git
cd meeting-pipe
./scripts/install.sh
```

Then `⌃⌥M` to record manually, or join any meeting and answer the prompt. Detailed install steps, requirements, and the configuration reference live below. The design rationale is in [Why it is shaped this way](#why-it-is-shaped-this-way) and the [ADRs](./docs/decisions/).

---

## What it does

1. **Detects** when you're in a meeting (Zoom, Teams, Slack huddles, Google Meet, Webex — native apps and browser tabs).
2. **Asks** to record via an on-screen panel (top-right, Notion-style).
3. **Captures** system audio (every other process) + your mic into a stereo WAV (mic left, system right) in `~/Documents/Meetings/raw/`.
4. **Transcribes** on-device with FluidAudio (Parakeet TDT for ASR, pyannote for speaker diarization, both on the Apple Neural Engine).
5. **Summarizes** (title, decisions, action items, questions) in the same language as the transcript. Either Claude Sonnet via the Anthropic API (default) or a local MLX model via on-device `mlx_lm`, your choice.
6. **Publishes** to every sink in `output.sinks` (Notion, Obsidian, filesystem, or a combination). Each sink is idempotent and failures are isolated; one sink falling over does not block the others.
7. **Notifies** you when it's done; click to open the page.

A new recording can start while a previous one is still being processed — processing runs in the background and you only get notified when each meeting's Notion page is ready.

### Performance

After you click Stop, the daemon transcribes the recording on-device with FluidAudio (Parakeet TDT + pyannote on the Apple Neural Engine), then runs summarize + publish. ASR and diarization are Swift-native and accelerated on the Neural Engine, so the post-Stop wait is short on Apple Silicon. There is no Python ASR process and no torch / whisperx dependency.

A global hotkey (default `⌃⌥M`) toggles recording manually if detection misses a meeting or you want a quick voice memo. A second hotkey (default `⌃⌥⇧M`) is a stop-only force-stop — it never starts a recording, so you can panic-press it without risking an accidental start.

The same controls are reachable through a `meetingpipe://` URL scheme (AUTO1), so Shortcuts (via its built-in "Open URL" action), Raycast, Stream Deck, or a plain `open meetingpipe://toggle` in the shell can drive the daemon:

| URL | Does |
| --- | --- |
| `meetingpipe://toggle` | Start or stop, like `⌃⌥M` |
| `meetingpipe://record` | Start a recording if idle (`meetingpipe://record?byo=1` for the BYO variant) |
| `meetingpipe://stop` | Stop only, like force-stop |
| `meetingpipe://library` | Open the Library (`?scope=ask` / `?scope=digests` / `?scope=facts` to jump to a rail) |
| `meetingpipe://ask?q=<question>` | Open the Ask rail with the question prefilled and run it |
| `meetingpipe://digest` | Open the Digests rail and generate the weekly digest |

External triggers respect exactly the gates the hotkey does: a denied-mic trigger routes to the Permissions tab instead of failing silently, and `record` never stacks a second recording on a live one. Everything stays local (Launch Services delivers the URL to the running daemon; no new egress). Registering the scheme is part of the bundle Info.plist, so a URL scheme added by an update needs one `scripts/install.sh` run (the fast `rebuild.sh` path does not rewrite Info.plist). **Native Shortcuts actions are built but not enabled**, and the reason is worth knowing before you go looking for them. Six first-class App Intents exist in the code (toggle / start with a BYO flag / stop / open Library at a rail / ask / digest), and `scripts/install.sh` can emit the metadata Shortcuts reads. They are off by default because they are **discoverable but not invocable** on this build: the actions list correctly in Shortcuts, but running one fails with "Shortcuts couldn't communicate with the app". Six candidate causes were excluded by measurement (2026-07-19/20); what remains is that the app is ad-hoc signed with no Apple Developer ID, and the intent handoff is the one path that requires that trust. Shipping them anyway would put six actions in your Shortcuts library that every click fails on, so `install.sh` skips the metadata unless you ask for it:

```bash
MP_APP_INTENTS=1 ./scripts/install.sh    # only useful once the app is properly signed
```

Until then the `meetingpipe://` URL scheme above is the supported automation surface, and it is fully verified: a Shortcut using the built-in **Open URL** action drives every verb, as do Raycast, Stream Deck, and `open` in a shell. The trail is in [`docs/spikes/auto1-app-intents-metadata.md`](docs/spikes/auto1-app-intents-metadata.md).

For meetings longer than ~1 hour on a cloud backend, the pipeline writes the transcript to disk along with a paste-into-Claude-Code bundle and **does not call the Anthropic API**; on a local backend it summarizes them on-device at no cost instead. See "Long meetings" below.

The on-screen prompt also has a **Record (BYO)** button: same flow, but opt-in per-meeting - useful for sensitive calls or when you'd rather hand-summarise. After the recording finishes, the meeting's Summary tab shows a **Paste your summary** box: drop your text in, hit **Save & publish**, and it fans out to your configured sinks. (`mp publish-from-paste <stem>.md` does the same thing from a shell, reading `<stem>.summary.md` off disk.)

---

## Why it is shaped this way

The README covers how to use the app; this section covers the load-bearing design decisions. The long form lives in the [ADRs](./docs/decisions/).

- **The daemon owns detection, recording, and transcription; the Python pipeline only summarizes and publishes.** ASR and diarization run in-process via FluidAudio (Parakeet TDT + pyannote) on the Apple Neural Engine, fast enough that a streaming-during-the-call design was not worth its complexity. The pipeline runs out-of-process so summarize + publish never blocks the daemon, and it ships no torch / whisperx dependency. See [ADR 0007](./docs/decisions/0007-python-sidecar.md).
- **System audio is captured with ScreenCaptureKit, the mic with AVAudioEngine, and the two are written as one stereo WAV** (mic left, system right) so diarization and silent-system detection stay possible. No aggregate devices, no BlackHole, no ffmpeg subprocess. See [ADR 0009](./docs/decisions/0009-stereo-on-disk-mono-on-playback.md).
- **Detection fuses several signals, never one.** An open meeting app is not a live call, and a held mic does not survive joining muted, so the lifecycle subsystem fuses per-process audio, ScreenCaptureKit windows, and the Accessibility Leave button into one verdict through a debounced promotion rule. See [ADR 0008](./docs/decisions/0008-verdict-fusion-architecture.md).
- **The mic is captured losslessly; muted side-comments are redacted afterward, not gated at capture.** A real-time gate that silences the mic while you look muted depends on reading another app's mute state, which is fragile for Teams and Zoom and absent for every browser meeting, so a wrong reading once silently dropped real speech. By default the mic is now recorded in full and the muted spans are redacted from the transcribed, summarized, and published artifact offline, with the full recording kept locally for recovery. That kept copy is a recovery source only: owner-only, excluded from Time Machine and iCloud, reclaimed after 30 days or once the kept-originals folder passes ~10 GB, and removed when you delete the meeting. Regulated and NDA mode keep a real-time gate instead, since no audio at rest is permitted there. See [ADR 0016](./docs/decisions/0016-capture-first-mute-redaction.md).
- **Summarization defaults to the Anthropic Messages API directly, not Claude Code; publishing uses the Notion REST API, not MCP.** Both run headless and unattended, so the deterministic API surfaces beat the interactive ones. That rationale predates headless `claude -p`: a `claude_cli` backend now spawns Claude Code non-interactively (JSON output, tools and MCP off, validated through the same schema) and summarizes at no marginal API cost on an existing Claude subscription, and an `openai` backend covers a bring-your-own OpenAI-compatible key. Both are cloud backends, so a regulated or NDA workflow forces on-device regardless, and a CLI backend is fail-closed at the policy layer since it egresses outside the in-process guard (PROV1). See [ADR 0007](./docs/decisions/0007-python-sidecar.md).
- **Privacy is a setting, not a fork.** `summarization.backend = "local"` runs MLX-Qwen on Metal with no outbound call; `modes.regulated_mode = true` clamps every sink to on-disk. Together they make a fully zero-egress pipeline.

Non-goals, by design: video capture, a live in-call transcript, multi-user sharing, cross-platform, and a mobile companion.

The subsystem map and sequence diagrams are in [ARCHITECTURE.md](./ARCHITECTURE.md); the event-log and sidecar schemas are in [CONVENTIONS.md](./CONVENTIONS.md).

---

## Requirements

- **macOS 14 (Sonoma) or later** — required for ScreenCaptureKit's `excludesCurrentProcessAudio`.
- **Apple Silicon (M-series), required.** FluidAudio (ASR + diarization) runs on the Apple Neural Engine; there is no Intel fallback.
- A few GB of free disk for the FluidAudio models, downloaded on first use.
- A Notion integration token + a database to write to.
- An Anthropic API key for the default backend. Not needed for the `local` or `claude_cli` backends (the latter rides your existing Claude Code login); the `openai` backend needs an OpenAI key instead.

---

## Install

```bash
git clone https://github.com/ggegelya/meeting-pipe.git
cd meeting-pipe
./scripts/install.sh
```

The installer will:

1. Verify Homebrew, install `ffmpeg` and `uv` if missing. (`ffmpeg` is used by the Python pipeline for audio loading; the daemon itself records natively via ScreenCaptureKit — no subprocess.)
2. Build the Swift menu-bar daemon (`swift build -c release`), generate an `AppIcon.icns` from SF Symbols, wrap the binary in a `.app` bundle, and `ditto` it into `~/Applications/MeetingPipe.app` so Spotlight can launch it.
3. Install the Python pipeline into `~/.local/share/meeting-pipe/venv/`.
4. Stage `~/.config/meeting-pipe/config.toml`, and prompt for your API keys (stored in the macOS Keychain, not a plaintext file).
5. Install the LaunchAgent so the daemon starts at login.

**First launch & Gatekeeper.** The app is unsigned (no Apple Developer subscription required for personal use). On first launch from Spotlight, macOS shows an "unverified developer" dialog. Right-click the app icon in Finder → Open, confirm once, and macOS remembers the decision. The LaunchAgent path runs the binary directly so it's not subject to that dialog after the first manual approval.

**Self-contained bundle (DIST1, in progress).** The install above needs Homebrew, `uv`, and `ffmpeg` on the machine. For a genuinely clean or locked-down Mac that can't install those, `scripts/bundle-runtime.sh` embeds a relocatable Python + the pipeline + a static `ffmpeg` into `MeetingPipe.app/Contents/Resources/pipeline-runtime/`; the daemon runs `mp` and `ffmpeg` from there before falling back to a system install. This is an owner-built path today, not yet notarized into a drag-install DMG (that step needs a Developer ID and a clean-Mac test). See [`docs/spikes/dist1-bundle-runtime.md`](docs/spikes/dist1-bundle-runtime.md).

**Rebuild loop for local edits.** Once `install.sh` has run once, `scripts/rebuild.sh` is the one-command fast path: `swift build -c release` → drop the new binary into the installed `.app` → re-sign with the stable identifier → `launchctl kickstart -k` to respawn the LaunchAgent without waiting on the 10 s throttle. Skips pipeline venv, model pre-fetch, and config staging. Target end-to-end is under 30 s on incremental builds.

### One-time manual steps

The installer can't do these for you:

1. **API keys.** The installer prompts for your Anthropic and Notion tokens and stores them in the macOS Keychain, not a plaintext file (SEC8). Skipped the prompt, or need to change a key? Set them any time in **Preferences -> Integrations**, or from a terminal:

   ```sh
   security add-generic-password -U -s com.meetingpipe.daemon -a ANTHROPIC_API_KEY -w sk-ant-...
   security add-generic-password -U -s com.meetingpipe.daemon -a NOTION_TOKEN -w ntn_...
   ```

   A change takes effect on the next recording, no restart needed. A hand-run `mp` (without the daemon) reads the same Keychain items.

   To verify: `~/.local/share/meeting-pipe/venv/bin/mp doctor`, which pings each API, validates the ML runtimes, and tells you which secret is wrong.

2. **Configure** `~/.config/meeting-pipe/config.toml`:
   - Set `notion.database_id` to your Meetings database ID (the 32-char string in the database URL).
   - Adjust `output.sinks` and the summarization backend if the defaults (Notion, Anthropic) are not what you want.

3. **Grant macOS permissions** when prompted on first launch. The daemon fires every TCC dialog in one ordered sequence within the first few seconds, instead of dribbling them out across the first recording:
   - **Notifications** — record/skip prompts and completion alerts.
   - **Microphone** — `AVAudioEngine` reads from the system default input.
   - **Screen Recording** — gates `SCStream.capturesAudio` in TCC.
   - **Accessibility** — reads window titles to detect when a meeting ends (Teams / Zoom / Webex / Slack desktop AND browser tabs). Without this, native apps will record fine but the call won't auto-stop — the daemon falls back to manual hotkey / silence-based stop, which can mean up to another 15 minutes of wav file (the idle backstop's default horizon). **Granting Accessibility requires a daemon restart** for the new trust verdict to propagate (macOS caches AX trust per-process at launch); the detector re-evaluates immediately on restart so a meeting that's still in progress is picked up automatically.

   The **Preferences ▸ Permissions** tab shows the live status of all four with **Request** (when never determined) or **Open Settings** (when denied) buttons; the menu bar surfaces a "⚠ Permissions need attention" row whenever any of mic / Screen Recording / Accessibility is missing. Recording is gated on Microphone — if it's missing, the daemon refuses to start the recording and routes you to the Permissions tab rather than producing a silent wav.

   **Signing and Screen Recording across rebuilds.** `scripts/install.sh` and `scripts/rebuild.sh` sign the app with a self-signed "MeetingPipe Dev" code-signing certificate, created automatically on first run in your login keychain (`scripts/lib/dev-cert.sh`). That gives the app an identity-based code requirement, so macOS TCC honors your Screen Recording grant across every rebuild: grant it once and it stays granted. If the cert cannot be created (no openssl), signing falls back to ad-hoc, where the cdhash changes on every build and Screen Recording needs a one-time re-toggle per rebuild; the Permissions tab's **Request** button detects that and routes you to System Settings. Run `scripts/install.sh --reset-tcc` (or `scripts/uninstall.sh --reset-tcc`) if you ever want the slate fully cleared. Going paid later is a swap, not a teardown: set `MEETINGPIPE_SIGN_ID` to an Apple Developer ID and it takes over; remove the dev cert with `security delete-identity -c "MeetingPipe Dev"`.

   No audio devices to set up. The daemon captures whatever your system audio is currently playing (regardless of output device — speakers, wired headphones, AirPods, anything) and the mic that macOS treats as the default input. Change the input in System Settings ▸ Sound and the next recording adapts.

---

## Notion database schema

Create a database with at least these properties:

| Name     | Type     | Notes                                  |
| -------- | -------- | -------------------------------------- |
| `Name`   | Title    | Meeting title; written by the pipeline |
| `Date`   | Date     | Auto-set to publish time (UTC)         |
| `Status` | Select   | Default value `Captured` — add this option |

Share the database with your Notion integration (••• → "Add connections").

### Optional properties (auto-filled when present)

Beyond the three required columns, the pipeline probes your database on every publish and fills any of these optional properties it recognises by name and matching type. Add whichever you want to filter or group by; the sink never creates or changes columns, so a property you leave out is simply skipped.

| Name           | Type         | Filled with                                       |
| -------------- | ------------ | ------------------------------------------------- |
| `Workflow`     | Select       | The workflow that recorded the meeting            |
| `Source`       | Select       | The app the meeting came from (Zoom, Teams, ...)  |
| `Attendees`    | Multi-select | Speaker names inferred for the meeting            |
| `Open actions` | Number       | Count of unresolved action items                  |

A property that exists under one of these names but with a different type is skipped with one log line, and a database that carries none of them behaves exactly as a bare `Name`/`Date`/`Status` database.

---

## Running by hand

You can run any pipeline stage on its own audio file — useful for debugging or re-publishing a fixed transcript:

```bash
# Full pipeline
~/.local/share/meeting-pipe/venv/bin/mp run-all ~/Documents/Meetings/raw/20260428-1430.wav

# Or step-by-step (transcription is done by the daemon, not the CLI)
mp summarize <transcript.md>
mp publish   <summary.json>     # fans out to every configured sink

# publish-notion is the legacy single-sink escape hatch; the daemon uses
# `mp publish` so an obsidian-only workflow reaches its actual sinks.
mp publish-notion <summary.json>

# Preflight check (validates secrets + live API access + which sinks
# are reachable + which summarization backend is selected)
mp doctor

# Filter the JSONL event streams (see Logs section)
mp logs --since 1h --category detector

# Audit detection from both ends: meeting-end reliability (recordings you had to
# stop manually), and start-detection false negatives (the mic was held but nothing
# recorded, e.g. an unlisted-domain call), with a reason per miss. --min-miss-sec
# (default 30) filters out brief dictation / voice-memo blips.
mp analyze-detection --since 7d

# Compare Anthropic vs the local backend on one transcript; writes a
# scorecard you fill in by hand. Refuses regulated/NDA meetings, since the
# cloud baseline would egress the transcript.
mp dogfood <transcript.md>
mp dogfood --report   # aggregate filled scorecards into a ship/no-ship
```

---

## Long meetings

The Anthropic API charges per token. A 1-hour meeting can cost real money to auto-summarize on a cloud backend, and you might prefer to handle it yourself in Claude Code, where you have the full conversation context anyway. Summarizing the same meeting on-device is free, so the guard is **cloud-only** (PIPE4).

Default behavior when the transcript exceeds **80 000 characters** (~20 000 tokens, ~1 hour of speech) depends on the backend:

- On a **cloud backend** (`anthropic`, or `auto` with an API key), the pipeline saves the transcript markdown at `<stem>.md`, writes a sidecar `<stem>.READY_FOR_MANUAL.md` (the exact system prompt it would have used, plus a pointer to the transcript), **skips** the Anthropic call and the Notion publish, and sends a desktop notification.
- On an **on-device backend** (`local` MLX, Apple Intelligence, or keyless `auto`), there is no per-token cost, so the meeting is summarized anyway. The local backend splits the long transcript into overlapping windows, summarizes each, and merges the partial summaries in batches (a hierarchical map-reduce sized to stay within the model's context), so a long local meeting no longer dead-ends in a paste bundle.

To process a cloud-backend bundle yourself: open Claude Code, paste the system prompt from the `.READY_FOR_MANUAL.md` file, attach (or paste) the transcript markdown, and ask for the summary. No API charge.

To change the threshold, edit `summarization.skip_above_chars` in `~/.config/meeting-pipe/config.toml` (the one knob gates both the cloud bundle and the local map-reduce). Set to `0` to disable the guard.

---

## Library window

Click the menu bar icon → **Open Library…** to open the main window (900×600, restorable, hides on Cmd+W with the daemon still running).

The window is a smart-folder rail + scoped list + context-aware detail pane, with a custom toolbar across the top:

- **Toolbar** — breadcrumb (`Library` → scope name), an optional `Edit workflow` button that appears only when a workflow scope is selected, the always-visible **state pill** (Idle / Processing / live Recording with workflow tint and timer), a Record/Stop button, and a gear that opens Preferences.
- **Rail** (under a `LIBRARY` header): `All meetings`, `Today`, `Last 7 days`, `Last 30 days`, `Needs you`, `NDA only`, `Untagged`, `Facts`, `Ask`, `Digests`. `Needs you` carries an amber count badge and gathers the meetings that want an action: a failed run, a long-meeting bundle awaiting a paste, or a finished meeting whose publish failed or only partially landed. `Facts` is a cross-meeting projection rather than a list filter: it gathers every open action (with its owner, an aging label off the due date, and a circle to mark it done in place) and the decisions from meetings in the last 30 days, each row linking back to its source meeting. Marking an action done writes the resolved flag into that meeting's summary, so it survives a republish. `Ask` (AI3) is the other projection: a question box over an engine-backed, cited answer across the whole library. It runs `mp ask` on-device (honouring the backend + egress clamp), shows a spinner while it works (answers are async per the AI2 spike, not live chat), and renders the answer with each verified citation linking back to its source meeting. `Digests` (AI4) is the third projection: a read-only list of your weekly review digests. `mp digest` gathers your open actions and recent decisions across the library into a dated, on-device summary and writes it to a `digests` folder beside your recordings. Turn on a weekly schedule in Preferences ▸ Pipeline (it installs a per-user launch agent that runs `mp digest` at the day and time you pick, and removes it when you turn it off), or click **Generate now** in the Digests view; each digest renders with the standard summary layout, with reveal-in-Finder and move-to-Trash. Under a `WORKFLOWS` header: one row per workflow (colored dot + name + meeting count; the default workflow is labelled inline). A `+ New workflow` row opens an editor sheet. Workflows are filter scopes here, not a separate destination, and selecting one narrows the list AND surfaces the workflow inspector in the right column.
- **List** — the scoped meetings list with the existing filter chips (App / Status / Date) layered on top.
- **Detail pane** — single meeting selected → the meeting detail (Summary / Transcript / Audio / Corrections / Raw); multiple selected → batch actions; no meeting but a workflow scope active → workflow inspector (Trigger / Modes / Output / Backend + Recent meetings + Edit workflow); otherwise the empty-state nudge.

A failed row names the stage that failed, and **Retry** does the least work that stage needs. When the failure was `Publishing` (every configured sink rejected the summary, e.g. Notion was down), Retry republishes the summary already on disk rather than re-transcribing and re-summarizing the meeting, so a retry after an outage costs nothing and cannot produce a different summary than the one you already reviewed. Every other stage retries the whole pipeline. A publish that landed nowhere never reports success, so it will not clear the failed row or notify you with a link to the previous meeting's page.

When a summary failed because the backend rejected the transcript's language (Apple Intelligence refuses a language it does not support, which would leave a transcript but no summary), a plain retry on the same backend would just fail again, so the failed row instead leads with **Re-summarize with Local**, which re-runs the summary on the on-device MLX model over the transcript already on disk and succeeds. The plain same-backend retry stays available underneath. You can also switch backends any time from the detail `...` menu's **Re-summarize with…** (Local or Anthropic); it re-runs summarize + republish over the existing transcript for that one run only and never rewrites the workflow's configured backend (regulated / NDA meetings still stay on-device).

Preferences is no longer a rail item — it lives on the toolbar's gear icon. Workflows are no longer a top-level tab — they're rail scopes.

If you've never recorded anything the list shows `No recordings yet - Start a meeting in Zoom / Teams / Meet / Webex / Slack, or press ⌃⌥M.` Otherwise:

The list scans `~/Documents/Meetings/raw/` (or whatever is configured in `recording.output_dir`) and shows one row per recording, grouped into Today / Yesterday / This week / Last week / Earlier this month / older months. Each row carries the meeting title (LLM-derived when available, falling back to the source app + time), source-app glyph, duration, and a status pill (Recording / Processing / Paste pending / Ready). Live recordings and rows whose pipeline run is still in flight pulse subtly so you can tell what's currently being worked on at a glance. The list refreshes automatically when the pipeline writes new sidecars - new meetings appear within a second of the underlying file landing.

Select a row and the right pane fills with the per-meeting detail view: an editable title, the meeting's date, the workflow chip when present, duration, and shortcuts to open the published note in Notion or Obsidian (when those sidecars are on disk) or reveal the raw audio in Finder. When the backend that produced the summary is known, a quiet grey provenance line sits under the caption naming it - `Claude (cloud)`, `On-device (MLX)`, or `Apple Intelligence` (the model id rides in the tooltip); it is hidden for legacy, paste, or skipped meetings with no recorded backend. A `...` menu on the header collects the less-common actions (Rename, Edit summary, Reprocess, Re-summarize with… (Local / Anthropic), Change workflow…, Corrections…, Republish, Open meta.json, Copy meeting ID, Delete…). **Change workflow…** re-routes a misrouted or manually-recorded meeting to a different workflow: it rewrites the meeting's context prompt, sinks, Notion database, and NDA posture, refreshes its chip and smart-folder membership, then offers to Regenerate (re-summarize with the new prompt, then republish) or Republish (re-send the existing summary to the new sinks). Neither runs unless you pick it. Moving into or out of an NDA workflow asks for explicit confirmation: NDA re-clamps everything to on-device + filesystem from now on, but it cannot un-publish anything already sent. Three tabs underneath:

- `Summary` renders `<stem>.summary.md` as Markdown and is read-only until you pick `Edit summary` from the header `...` menu, which swaps in the editor. The editor reuses the same field set as the standalone correction window: title, summary bullets, decisions, action items, open questions, attendees, language, notes. Its primary button is `Save correction`, which persists the edit only: it writes a correction record (verdict=edited) and overwrites `<stem>.summary.json` so the list and Markdown views immediately reflect the new content. A failed save keeps you in the editor with an inline warning and your edits intact. Republishing is a separate step (the `...` menu's `Republish`, or the row's inline Republish button once the saved summary is newer than the published page), so a save never re-pushes to your sinks on its own. A quiet `Reprocess…` affordance at the foot of the summary lets you edit the context prompt the model is given and generate a candidate summary, shown side by side; keep it to replace the current one (never auto-published) or discard to keep the original. The override applies to that run only and is never persisted.
- `Transcript` renders the diarized segments from `<stem>.json` as a speaker-grouped list. Click any line to jump the audio play head to that segment and start playing; the active line is highlighted as playback advances. A compact play / pause / scrubber strip, with a pitch-corrected **speed** menu (1x / 1.25x / 1.5x / 2x), sits at the bottom of the tab; the same audio engine is reused by the Audio tab when it lands so seeking from a transcript line and switching tabs keeps the same play head (and the same speed), and the active line stays highlighted correctly at every rate. Right-click an unnamed voice cluster that carries a voiceprint (a `Speaker N` or an `Unknown A`) and pick **Name this speaker…** to enroll that voice into your roster under a name (FEAT3-ROSTER); the name shows immediately and that person is named automatically in later meetings. The naming is reversible (FEAT3-UNDO): right-click a named speaker for **Rename…** or **Undo naming**, which reverts the label and un-enrolls the voice so later meetings stop auto-naming it. The name is stored as a reversible overlay (`<stem>.speaker_labels.json`), so your on-disk transcript (`<stem>.json`) keeps its original diarization label and an undo always restores it. When diarization merges two people into one cluster, misattributes a line, or drops a voice into the catch-all **Unknown speaker** bucket, right-click a segment and pick **Assign to…**: choose anyone else already in the meeting, or **New person…** to type a name for someone diarization never separated (a mid-meeting joiner with a line or two, or an unknown line that belongs to nobody listed). Someone you introduce with **New person…** joins the meeting's cast, so later lines go to them from the same list without retyping the name. Cmd-click or Shift-click to select several segments (a contiguous run) and assign them in one go, and **Reset to original label** undoes it. Assignment is label-only (no voiceprint is changed, so the roster is untouched); a plain left-click still seeks, and right-clicking a line (or opening a naming or edit sheet) pauses playback so the line holds still while you work. You can also fix the words themselves: right-click a line and pick **Edit text** to correct an ASR mistake. Like a speaker rename it is stored as a reversible overlay (`<stem>.transcript_corrections.json`), so the on-disk transcript keeps the original and an undo restores it. After naming, reassigning, or editing a line, regenerate the summary (the detail `...` menu's **Re-summarize with…**) for the summary body and attendees to pick up the change; the corrected words also flow into **Ask** the next time its search index is built. Manage your named voices in-app from **Preferences ▸ Pipeline ▸ People**: it lists each enrolled voice with its sample count, and **Rename…** or **Remove** any of them (removing stops a voice being auto-named in future meetings; past transcripts are unchanged). The same is available from the CLI with `mp roster list` / `mp roster rename --old <X> --new <Y>` / `mp roster forget --name <X>`.
- `Audio` shows a two-channel waveform (mic on top, system audio on the bottom) backed by downsampled peaks. The cache lives under `~/Library/Caches/MeetingPipe/waveforms/<stem>.peaks` and is keyed on the wav's size + modification time, so any change to the recording (re-record, repair, replace) invalidates the cache on the next open. Click anywhere in the waveform to seek; the play head syncs with the Transcript tab. A **speed** menu (1x / 1.25x / 1.5x / 2x, pitch-corrected) and a **Skip silence** toggle sit beside the channel and zoom controls; speed is shared with the Transcript tab, and Skip silence hops the quiet gaps (derived from the same waveform peaks) while playing. A separate zoom menu (Fit / 1× / 2× / 4× / 8×) widens the rendered track when you need to land on a specific second; zoom does not change playback speed.

Corrections is no longer a tab (the DSN2 IA pass dropped it): the `...` menu's `Corrections…` opens it as a sheet. Once you've edited (or graded) the meeting it shows the on-disk correction record: verdict, timestamp, backend + model, notes, and a side-by-side Original / Corrected preview. **Re-edit in Summary tab** closes the sheet and jumps to the Summary editor; **Revert…** asks for confirmation and then restores the original LLM summary to `<stem>.summary.json` and deletes the correction record. Notion is not changed automatically; republish if you want the page in sync.

The `Raw files` tab was dropped in the same pass. Getting at the sidecars on disk now goes through the `...` menu's `Open meta.json` and the header's reveal-in-Finder shortcut.

A filter bar sits above the list with a search field plus chips for workflow, source app, status, and date range (today / last 7 days / last 30 days / this year). The search field searches the **full transcripts** as well as titles, summaries, and open questions, backed by a SQLite FTS5 index over the library (UX16); it is the same engine behind **Cmd+K** Quick Find from the menu bar, so there is one search story. The index is a rebuildable cache under `~/Library/Caches/MeetingPipe/search/` (safe to delete; it rebuilds), updated in the background as recordings land, and search falls back to the in-memory title/summary corpus while the index catches up, so it never comes up empty. Multiple words are ANDed and prefix-matched (so "bud" finds "budget"), matching is case-insensitive and Cyrillic-aware. The chips (workflow / app / status / date) narrow within the search results; **Clear** wipes every filter. The match-count line ("N of M meetings") only appears while a filter is applied.

Cmd+click (or Shift+click for a range) to select multiple rows. The detail pane swaps to a batch-actions panel that lists the selection and offers **Merge into one meeting…** (FEAT9, described below), **Republish all** (runs `mp publish` per meeting, sequentially so the daemon's processing queue doesn't fan out; each meeting reaches every sink its workflow configures, not just Notion), **Export markdown…** (writes one `<stem>.md` bundle per meeting into a chosen folder), and **Move to Trash…** (per-row soft delete with one confirmation up front). A linear progress strip shows `<done> / <total>` while a batch is in flight.

**Merge into one meeting…** rejoins a call that dropped and reconnected, leaving two (or more) separate recordings. Select the fragments and merge: `mp merge-meetings` concatenates their audio into the earliest one (the primary), stitches the transcripts together with an explicit gap marker, re-summarizes the whole, and republishes under the primary's page (an upsert, so the existing page is updated in place). The later fragments then move to the Trash, and the completion note points at the combined page. The button is offered only when the selection is safe to merge: all finished, all in the same workflow, and all sharing the same privacy posture (a local-only recording is never merged with a cloud one). Nothing is deleted until the concatenated audio is verified on disk (the REC1 verified-outcome rule), and a re-run after a publish hiccup re-publishes rather than concatenating the audio twice.

Drag the **leading glyph** of any library row out of the window to drop a single markdown bundle (summary + transcript when both exist) into Finder, Mail, or Slack. The drag handle is confined to the glyph so the rest of the row stays free for selection — putting `.draggable` on the whole row breaks tap-to-select on macOS. Drag the waveform on the Audio tab to drop the raw `<stem>.wav` file. The markdown bundle is written under `NSTemporaryDirectory()` the moment the drag starts, so the drop target gets a real file path — not a snapshot of the editor surface.

Editing the title in the header writes the new value back to `<stem>.summary.json` when that file exists, otherwise to `<stem>.meta.json`. The list rescans on the next debounce tick and the new title appears in both the row and the detail header.

Right-click any row in the list for per-meeting actions: `Republish` (idempotent; fans out to every configured sink, not just Notion, honouring the meeting's workflow), `Regenerate summary` (re-runs `mp summarize` against the existing transcript then re-publishes), `Export…` (copies summary / transcript / audio into a chosen folder), `Reveal in Finder`, and `Move to Trash…` (soft-delete every sidecar for the stem; recoverable from the system Trash). Republish and regenerate run as background subprocesses; the row's status pill flips to a progress badge while the subprocess is in-flight.

The Preferences gear in the toolbar opens the existing standalone Preferences window.

---

## Workflows

A **workflow** is a per-context bundle of routing rules: which Notion DB to publish to, which Obsidian vault, which summarization backend, what extra system-prompt seasoning to use, and a handful of behavioural flags like NDA mode. Switch on a per-meeting basis instead of editing global config for every client.

The daemon ships with one **General** workflow seeded from your existing `summarization.team_context` + `notion.database_id`, marked as default. Until you add a second one, the library rail still shows the single `● General · default` row under `WORKFLOWS` and the prompt panel renders no chip — the existing single-routing behaviour stays unchanged. Edits live in the workflow editor sheet, opened from the rail's `+ New workflow` row, the toolbar's `Edit workflow` button when a workflow scope is active, or the inspector's `Edit workflow`.

Each workflow lives as one TOML file under `~/.config/meeting-pipe/workflows/<uuid>.toml`. Edit through the UI or hand-edit on disk; the file format is small enough to read.

**Matching.** At the start of every recording the daemon resolves a workflow via `WorkflowMatcher`. Precedence, highest specificity first:

1. Explicit override - you picked one from the prompt panel's chip dropdown.
2. Matching rule - the workflow carries `[[matching_rules]]` entries that compare `bundle_id` and/or a case-insensitive `title_regex` against the detected meeting. Bundle + title wins over bundle-only wins over title-only.
3. Default - the workflow flagged `is_default`. Always exists.

Ties on score break by the workflow's `order` (ascending). Manual recordings (`Ctrl+Opt+M` with no detected source) always fall to the default.

**Extra summary sections (WF7).** A workflow can add its own summary sections on top of the standard ones (Summary / Decisions / Action items / Open questions / Attendees). In the workflow editor's *Extra summary sections*, add a row per section: a name (e.g. "Billable follow-ups", "Feedback given / received") and an instruction telling the model what to put there. Those flow to the summarizer for every meeting in the workflow, and the produced sections render everywhere the summary does: the Library detail (read-only), Notion, Obsidian, and the filesystem/LAN Markdown. They also survive the BYO paste round-trip (any non-standard `##` heading in a hand-written `<stem>.summary.md` is kept as an extra section) and a correction edit (read-only there for now, but never dropped). Stored as `[[extra_sections]]` in the workflow TOML; a workflow that adds none keeps the standard shape unchanged.

**Where it shows up.**
- The **prompt panel** sprouts a chip next to the action buttons with the resolved workflow's color/emoji + name. Click it to pick a different workflow before clicking Record.
- The **recording HUD** shows the workflow's name (with an "NDA" tag when applicable) below the elapsed timer. The recording dot itself stays coral - it signals recording, not the workflow (DSN25).
- The **menu-bar title** reads `Recording - {Workflow}` with a trailing `· NDA` when NDA mode is on.

**Sidecar contract.** When a recording finishes the daemon writes `<stem>.meta.json` with `workflow_id`, `workflow_name`, `workflow_context_prompt`, `workflow_backend`, `workflow_sinks`, `workflow_notion_database_id`, and `workflow_nda_mode`. The pipeline's `mp.workflow.apply_overrides` reads that sidecar and patches the in-memory `Config` before summarize + publish, so every workflow knob takes effect on a single run without changing global state.

**NDA mode.** A behavioural flag with one effect: forces `backend = local` and `sinks = ["filesystem"]` regardless of what else the workflow says. Belt-and-braces - the pipeline re-enforces the override at run time so even a misconfigured workflow can't leak audio to the cloud. The HUD shows a coral `NDA` tag and the menu-bar title appends `· NDA`.

**Per-workflow Notion DB.** When a workflow enables the Notion sink the editor fetches your databases via the Notion API (`https://api.notion.com/v1/search`, filtered to `object=database`) and caches the list at `~/Library/Caches/MeetingPipe/notion-databases.json`. The picker reads from that cache; **Refresh** re-fetches. If you paste a DB id that isn't in the cache yet (newly created database, for instance) the picker preserves it as a "Custom" row so the selection doesn't snap back to none on the next render.

---

## Storage

An hour of recorded meeting is about 0.7 GB of stereo WAV, and nothing used to reclaim it. **Preferences ▸ Storage** shows what is actually on disk: the library's total size, how those bytes split across retention policies, the kept pre-redaction originals, and the two caches (waveform peaks, downloaded models) that are safe to throw away. `mp doctor` prints the same numbers under `== storage ==`. Both are read-only; nothing is deleted without you asking.

**Retention is per workflow**, set in the workflow editor under *Audio retention*, because a client call and a standup deserve different answers. Three policies:

| Policy | What happens |
| --- | --- |
| **Keep the audio forever** | The default. Nothing is ever reclaimed. |
| **Compress it to FLAC** | The WAV is transcoded to FLAC in place. Lossless, so playback, the waveform, and any later reprocessing all still work. Quiet speech roughly halves; a noisy room saves less. |
| **Delete the audio** | The transcript, summary, and every sidecar stay. The recording is gone, and a deleted recording cannot be re-transcribed. |

A policy only ever acts on a **settled** meeting: one that finished and published, and that isn't sitting in the Library's **Needs you** scope. A failed run, a paste-pending bundle, a no-speech result, and a partially-published meeting are all left alone, however old they get. So is whatever is recording right now. Meetings with no workflow (manual recordings, or ones whose workflow you deleted) are never touched.

The sweep runs when the daemon launches and after each meeting finishes. Compression needs `ffmpeg` on your `PATH`; without it the sweep logs a warning and skips. A compress writes the FLAC, reopens it, and compares durations before it deletes the WAV, so an interrupted transcode leaves the original in place.

**Caches.** Waveform peaks live in `~/Library/Caches/MeetingPipe/waveforms/` and are recomputed the next time you open a meeting's Audio tab. Downloaded local models live in `~/.cache/huggingface/hub/`; **Evict unused** deletes every one except the model Preferences ▸ Pipeline is configured to use, and they re-download on demand.

### Your library may be uploading to iCloud

meeting-pipe keeps summarization on your Mac. It cannot keep macOS from syncing the file after it is written, and **the default library path is inside iCloud's sync scope**: if System Settings ▸ [your name] ▸ iCloud ▸ **Desktop & Documents Folders** is on, everything under `~/Documents/Meetings/` (recordings, transcripts, summaries) uploads to Apple. Dropbox, Google Drive, and OneDrive do the same to any library placed inside them.

This is an operating-system behaviour, not something the app can override, so meeting-pipe detects it and tells you:

- **Preferences ▸ Storage** shows a **Cloud sync** panel naming the provider, with a **Move library…** button.
- `mp doctor` prints `[WARN] library is synced to ...` under `== storage ==`, and checks the `digests/` and `published/` folders too.
- Under `regulated_mode`, or on a Mac with any NDA workflow, the same finding is a `[FAIL]`, not a warning. Those modes promise that nothing leaves your Mac, and a synced library breaks that promise no matter what the summarizer does. (`mp doctor` still exits 0 either way; it is a diagnostic, not a gate. Grep for `[FAIL]` if you want to fail a script on it.)

**To fix it**, either move the library or turn the sync off:

- **Preferences ▸ Storage ▸ Move library…** asks for a folder outside every sync folder, shows you exactly what it will move and how much, and moves the recordings folder and its `digests/` sibling only after you confirm. It refuses while a recording or a pipeline job is in flight, and it refuses a destination that is itself synced. Your `published/` folder, if you use the filesystem sink, is not moved: `mp doctor` will keep reporting it until you point `filesystem.output_dir` somewhere local.
- Or turn off System Settings ▸ [your name] ▸ iCloud ▸ Desktop & Documents Folders, which affects far more than meeting-pipe.

---

## Backup, and moving to a new Mac

What cannot be recreated is scattered across four places: the library, the config directory (config, workflows, voiceprint, roster, glossary), the corrections corpus, and the Keychain items. `mp backup` gathers the four, names the Keychain items, and exports no secret.

```bash
mp backup ~/Backups              # a dated meeting-pipe-backup-YYYYMMDD-HHMMSS.tar.gz
mp backup ~/Backups --no-audio   # sidecars only; much smaller, meetings restore without audio
```

Or from **Preferences ▸ Storage ▸ Backup**: pick a destination once (it is remembered) and click **Back up now**; the section shows how long ago the last backup ran and surfaces any failure inline. `mp doctor` reports the same age under `== storage ==`. Restore stays a terminal step (below): a new-Mac restore runs before the app is installed and configured.

**In the archive:** the library (recordings plus every sidecar), `digests/`, `~/.config/meeting-pipe/`, and `~/Library/Application Support/MeetingPipe/corrections/`.

**Deliberately not in the archive:**

- **Keychain values.** The manifest names the four managed items (`ANTHROPIC_API_KEY`, `NOTION_TOKEN`, `HF_TOKEN`, `OPENAI_API_KEY` under service `com.meetingpipe.daemon`); the secrets themselves are never exported. You re-add them by hand.
- **`originals/`**, the kept pre-redaction recordings. [ADR 0016](./docs/decisions/) makes them mode 0600 and excludes them from Time Machine because they are the most sensitive thing on disk; putting them in a tarball you copy to a NAS would undo that. The redacted recording in the library *is* backed up.
- `secrets.env` (the legacy plaintext file), `published/` (republish regenerates it), and the caches.

### Moving to a new Mac

1. **Install** meeting-pipe (see [Install](#install)) and write `~/.config/meeting-pipe/config.toml` with `recording.output_dir` set to where you want the library on *this* Mac. Pick somewhere outside iCloud's Desktop & Documents scope while you are here.
2. **Restore.** Destinations come from the config you just wrote, not from wherever the backup was taken, so the library can live at a different path than before.
   ```bash
   mp restore ~/Backups/meeting-pipe-backup-20260709-215757.tar.gz --dry-run   # look first
   mp restore ~/Backups/meeting-pipe-backup-20260709-215757.tar.gz
   ```
   Restore refuses to write into a root that already has files (pass `--force` if you mean it), and it keeps the `config.toml` you wrote in step 1 rather than the backup's, which names the old Mac's paths. Everything else under the config directory (workflows, roster, voiceprint, glossary) is restored.
3. **Re-add the Keychain items.** `mp restore` prints the exact commands:
   ```bash
   security add-generic-password -U -s com.meetingpipe.daemon -a ANTHROPIC_API_KEY -w '<value>'
   security add-generic-password -U -s com.meetingpipe.daemon -a NOTION_TOKEN      -w '<value>'
   security add-generic-password -U -s com.meetingpipe.daemon -a HF_TOKEN          -w '<value>'
   security add-generic-password -U -s com.meetingpipe.daemon -a OPENAI_API_KEY    -w '<value>'
   ```
   Only the ones your backends actually use are needed: `HF_TOKEN` is optional, `OPENAI_API_KEY` only matters for the `openai` backend, and `ANTHROPIC_API_KEY` is not needed on `local` or `claude_cli`. Skip any you do not use.
4. **`mp doctor`.** It should report the library at its new path, no cloud sync, and your local model stack.

Per [ADR 0003](./docs/decisions/) nothing here is magic: a `cp -R` of the same four roots works just as well, and `mp restore` is only unpacking a tarball into them.

---

## Improving local quality

When `summarization.backend` is `"local"`, you can grade each published summary so the local model gets better over time. There are two surfaces:

- **Done-meeting notification.** After publish, the banner shows three actions:
  - **Open in Notion** (when applicable) opens the published page.
  - **Looks good** records a verdict-good sample inline; nothing else to do.
  - **Edit summary** opens an editor sheet pre-populated with the summary, where you can fix any field (title, summary bullets, decisions, action items, questions, attendees) and save.
- **Recent meetings…** in the menu bar lists the last 10 published meetings; pick one to open the same editor sheet. Useful when you dismissed the notification.

Every grade lands as one JSON file under `~/Library/Application Support/MeetingPipe/corrections/<stem>.json`. The corpus stays on your machine. Nothing in this loop touches the network, regardless of which summarization backend you use.

Run `mp corrections-stats` to see the current state of your corpus plus a Phase 3 readiness check (pass `--json` for a script-friendly form). Once you have ~20 corrections covering ~200 minutes of speech, `mp train-adapter --adapter-path <dir>` fine-tunes a per-user LoRA on the corpus on-device via MLX (fully local, no egress). A/B the result against the base model with `mp dogfood --adapter <dir>` (a local-only comparison, no cloud baseline) and grade the runs; if the adapter wins, opt it into the local backend by setting `summarization.local_adapter_path = "<dir>"` in `~/.config/meeting-pipe/config.toml`. Nothing is ever applied silently, and an honest negative result (the adapter is not worth adopting) is a fine outcome: the corpus stays a useful record either way.

---

## Logs

Everything lives under `~/Library/Logs/MeetingPipe/`:

- `main.log`     : app startup and general daemon notices
- `daemon.log`   — state transitions, recording start/stop, pipeline kick-off
- `recorder.log` — recording lifecycle, duration parity check
- `pipeline.log`: summarization and publishing (transcription runs in the daemon, not here)
- `events.jsonl`: structured Swift-side events, one JSON object per line
- `pipeline_events.jsonl`: structured Python-side events
- `launchd.{out,err}.log` — daemon stdout/stderr

The event logs and the four text logs self-bound by size: each rotates to `foo.1.ext` (then `.2`, `.3`) at ~5 MiB and drops the oldest, so the directory never grows without bound. `mp logs` reads across the rotated generations, so a postmortem query still spans the recent window. `tail -F ~/Library/Logs/MeetingPipe/*.log` is the fastest way to debug live. For postmortem queries against a workday's worth of detection or pipeline events, use `mp logs`:

```bash
mp logs --since 1h                                  # everything in the last hour
mp logs --since 30m --category detector             # just detector events
mp logs --since 2d --action pipeline_failed         # all pipeline failures
mp logs --since 1d --json | jq 'select(.bundle_id=="us.zoom.xos")'
```

No terminal needed for a quick triage: the menu bar's **Diagnostics…** item opens a read-only viewer over the same event logs, with the same since / category / action filters. And Preferences → Integrations → **Run doctor…** now runs the daemon's own self-check (Accessibility, Screen Recording, Microphone, per-app reachability, orphan scan) before `mp doctor`'s credential and network checks, so both halves are visible in one sheet.

`--since` accepts ISO timestamps (`2026-05-06T10:00:00Z`) or short relative offsets (`Nh` / `Nm` / `Nd` / `Ns`).

To ask a question across past meetings from the shell, `mp ask` gives an engine-backed, cited answer (AI3): it retrieves the most relevant excerpts from the on-device embedding index, synthesizes an answer with your configured backend, and carries `[stem]` citations that are verified against the retrieved meetings, so every citation resolves to a real meeting. It honours `effective_backend()` and the egress clamp (regulated / NDA force the on-device path with no cloud fallback), and per the AI2 spike it runs async with a ~4K-token context budget rather than as live chat:

```bash
mp ask "what did we decide about the Q3 budget?"    # answer + Sources
mp ask "open action items on the migration" --json  # machine-readable
mp ask "hiring plan" --model mlx-community/Qwen2.5-14B-Instruct-4bit  # 14B cites best (AI2)
```

The first ask builds the embedding index (multilingual-e5 on MLX, en/uk) and caches it; later asks reuse it and rebuild only when the library changes. The same feature is reachable in the app as the Library rail's `Ask` view. The AI2 spike that gated this (long-context RAG latency + faithfulness on your Mac) is written up in [`docs/spikes/ai2-embedding-rag-latency.md`](./docs/spikes/ai2-embedding-rag-latency.md); its throwaway measurement harness has since been retired (git history preserves it), and the packing shape it validated now lives in the shipping `mp ask` path.

To roll up commitments across every meeting, `mp actions` lists the action items the summarizer already extracted, soonest deadlines first. Each action carries a resolved flag, and a dated open action shows its age off the ISO due date:

```bash
mp actions                                          # every tracked action item
mp actions --open                                   # only unresolved
mp actions --closed                                 # only resolved
mp actions --overdue                                # open and past its due date
mp actions --owner Sam --due-before 2026-07-01      # filtered
mp actions --min-confidence high --json             # machine-readable
```

The resolved flag lives in `<stem>.summary.json` and round-trips through a republish, so marking an action done (a control DV1 adds to the Library) survives re-publishing.

For a periodic review, `mp digest` (AI4) rolls the week up into one on-device digest: it aggregates the aging open actions and the decisions from meetings in the last N days (grounded, read straight from your summaries), asks the configured engine to narrate the state of your week over those facts, and writes the result as a `MeetingSummary` to disk (a `digests` sibling of your recordings folder, outside the scanned library). Narration runs through the same backend + egress clamp as everything else (regulated / NDA keep it on-device with no cloud fallback), and if no engine is reachable the digest still generates with a deterministic summary. With `--publish` it fans out through your configured sinks like a meeting does:

```bash
mp digest                                           # write this week's digest to disk
mp digest --since 14                                # a two-week window
mp digest --publish                                 # also fan out to the sinks
```

It is latency-tolerant and adds no always-on egress: run it by hand, or schedule it (e.g. a weekly `launchd` timer or `crontab` entry invoking `mp digest`).

---

## Configuration reference

See [`config.example.toml`](./config.example.toml). Highlights:

- `recording.auto_consent_apps` — bundle IDs that auto-record without a prompt (e.g. `["us.zoom.xos"]`).
- `detection.manual_hotkey` — global hotkey for manual record (default `ctrl+option+m`).
- `detection.flag_moment_hotkey`: global hotkey to flag an important moment while recording (default `ctrl+option+f`). The HUD blinks once to acknowledge; the marker surfaces in the summary as a user-flagged moment and as a clickable chip in the transcript tab that seeks to it. Stop-only, like force-stop, so pressing it when idle does nothing.
- `detection.off_the_record_hotkey`: global hotkey to toggle an off-the-record span while recording (default `ctrl+option+o`). The HUD shows a persistent "Off the record" state while it is on. What the span does depends on the mode: under a regulated/NDA workflow the mic is zero-filled live (no off-record audio at rest); under a normal workflow the span is kept out of the transcript, summary, and every published artifact (it is redacted before anything reads the recording) while the full recording stays local for recovery. An open span auto-closes at stop. A no-op when idle, like the others.
- `detection.default_prompt_action` — what the prompt panel does when the user ignores it for `prompt_timeout_sec`. `"skip"` (default) suppresses the call, `"record"` auto-starts an auto-summary recording, `"byo"` auto-starts a BYO (manual-paste) recording. Surfaced as a segmented control in Preferences → Prompt. On a `"skip"` timeout the loss is now surfaced (it used to be silent): the menu bar shows `Suppressed (<app>)` for as long as the meeting is still detected, and a "Skipped \<app\>" notification offers a **Start recording** action that begins the recording late, bypassing the cooldown. The prompt panel and recording HUD also float over full-screen meeting Spaces now, so a full-screen call still gets the prompt.
- `transcription.language`: ASR input language for the on-device FluidAudio (Parakeet TDT) runner. `"auto"` (default) detects per meeting; an ISO 639-1 code (`en`, `uk`, `ru`, `de`, `es`, `fr`, `it`, `pt`, `pl`) pins it and skips detection, which is the safer setting if your meetings are always in one language. An unrecognised code falls back to auto-detect rather than failing. Surfaced as **Preferences → Pipeline → Languages → Transcription**; read once at startup, so a change applies on the next daemon launch. Distinct from `summarization.summary_language`, which is the *output* language of the generated summary.
- `transcription.diarization_clustering_threshold`: the one on-device diarization tuning knob (FluidAudio's speaker-embedding clustering threshold, valid range 0.5-0.9, clamped on load; default 0.65). Lower yields more distinct speakers, higher merges more voices into one. The sub-0.7 default biases toward showing one person as two unnamed clusters (which you can merge in-app) over merging several people into one voice and naming the wrong owner. A change applies on the next recording, no rebuild. Everything else about transcription (ASR and the rest of diarization) runs in the daemon via FluidAudio; the old whisper-era `transcription.*` keys (`model`, `fallback_model`, `min_speakers`, ...) were removed when ASR moved into Swift, leaving `language` and this threshold as the section's only live knobs.
- Custom vocabulary (glossary): recurring proper nouns and client / product names that ASR mangles are normalized before summarize + embed ever see them, via a separate `~/.config/meeting-pipe/glossary.toml` (see [`glossary.example.toml`](./glossary.example.toml)). Matching is case-insensitive, whole-word, longest-match-first, and Unicode-aware (works for Cyrillic word boundaries). A `[terms]` table applies to every meeting; a `[workflow."<name>".terms]` table applies only to that workflow's meetings and wins on a clash. Applied at transcript finalize on new meetings only (transcripts stay write-once; re-normalizing an old one is an explicit regenerate). An optional `[fuzzy]` stage, off by default, also corrects near-miss spellings of longer names.
- `summarization.summary_language`: `"auto"` (default; matches transcript language) or an ISO 639-1 code to force a specific output language. A fixed code (`"en"`, `"uk"`) is the safer setting: under `"auto"` a model can localize a single section into a language the transcript never contained (an all-English meeting once produced Russian action items). Every generated section, including the action items and open questions, is now language-verified after the fact and repaired once if it drifts, on both the cloud (Anthropic) and on-device (MLX) backends; under `"auto"` a confidently single-script transcript is treated as the target, so a Cyrillic section in an all-Latin meeting is caught (LANG1, generalizing the local-only LOCAL7 that the 7B/14B Ukrainian drift first motivated).
- `summarization.team_context` — domain string injected into the system prompt so the summarizer does not extract domain terms ("validation", "QMS") as action items.
- `summarization.user_label`: display name stamped on your own diarized speaker so "me vs them" reads as your name instead of `Speaker 1`. Which speaker is "you" is picked by precedence: the mic channel on a stereo recording, else a voice profile learned automatically from your stereo recordings (so it holds on mono / merged calls and when you are not the one talking most). Both tiers measure your own voice, so a meeting you only listened to names nobody: the speakers stay unnamed for you to name in the app, rather than your name landing on whoever spoke most. Blank (default) keeps generic labels. Surfaced as **Your name** in Preferences → Pipeline, where **Voice profile** shows how many meetings the profile has learned from and offers a **Reset**.
- `summarization.skip_above_chars` — long-meeting guard (default 80 000).
- `summarization.backend`: `"anthropic"` (default), `"local"` (on-device MLX, no outbound calls), `"auto"` (try Anthropic first, fall back to local on network/auth failure), or `"apple_intelligence"` (on-device Apple Intelligence, macOS 26+, produced in the daemon; experimental and not recommended for daily use, its small context forces heavy chunking and it can mislabel Ukrainian, so prefer Local MLX for a zero-egress backend). Switchable in Preferences → Pipeline.
- `summarization.local_model`: MLX model id when backend is `"local"` or `"auto"`. Default `mlx-community/Qwen2.5-7B-Instruct-4bit` (~4.3 GB on first use; cached in `~/.cache/huggingface/hub`), the engine-comparison sweet spot: on par with the 14B on capture, names owners, and stays memory-safe. Use the preset picker in Preferences → Pipeline to swap to Small (Qwen 3B-4bit, ~2 GB, faster, lower quality) or Large (Qwen 14B-4bit, ~8 GB, slower, best quality; wants 24 GB+ RAM), or pick Custom and paste any HuggingFace MLX repo id. The daemon pre-fetches the configured model immediately on first launch / on backend flip, so the first meeting in local mode does not wait several minutes for the download to finish inside `mlx_lm.server`. Progress shows in the menu bar (title suffix `↓ NN%` plus a dedicated menu row with the byte breakdown). An interrupted or partial download is detected as incomplete (not reported ready) and resumed on the next launch / backend flip; if a download fails, the menu row becomes a clickable **Retry**.
- `summarization.local_endpoint`: where `LocalSummaryClient` will spawn `mlx_lm.server`. Default `http://127.0.0.1:8765`.
- `summarization.local_startup_timeout_sec` / `local_request_timeout_sec`: local-backend timeouts (defaults 120 each). The request timeout is the base read window, scaled up by `max_tokens` so a long generation on a slow model is not cut off mid-stream; raise either if a large local model needs more headroom. The daemon's 20-minute watchdog stays the hard backstop.
- `output.sinks`: ordered list of publishers to invoke. Default `["notion"]`. Add `"obsidian"`, `"filesystem"`, and/or `"lan"` to fan out. Each sink fails independently; one going down does not block the others.
- `obsidian.vault_path`: required when `"obsidian"` is in `sinks`. The publisher writes to `<vault>/<obsidian.folder>/<date> <slug>.md` with YAML front-matter; `obsidian.attach_audio = true` copies the recording into `<vault>/<obsidian.attachments_subfolder>/`. `obsidian.template_path` points at a custom template (the built-in template covers the common case).
- `filesystem.output_dir`: where the filesystem sink drops the three files.
- `lan.mount_path`: target directory on an already-mounted SMB/NFS share for the `"lan"` sink. Same three files as the filesystem sink, but written atomically and only after a reachability check (it never creates the mount root itself, so a down share fails loudly instead of writing to local disk). On-prem, no cloud egress, so it survives regulated mode. `lan.host` is an optional label used only in the unreachable error.
- `modes.regulated_mode`: when `true`, the Notion sink no-ops at upsert time. Pair with `summarization.backend = "local"` for full zero-egress. A zero-egress run (this flag, or a per-meeting NDA workflow) also strips the cloud API tokens from the pipeline process and pins Hugging Face offline, so nothing downstream, including the local model server it spawns, can reach the network.

There are no microphone or output-device settings — the daemon auto-detects both. Change the system default input in System Settings ▸ Sound to swap mics.

---

## Troubleshooting

**No recording starts when I join a Zoom call.** Detection fuses several signals (the meeting app running and frontmost, its audio-process activity, and window-title / screen-share cues) rather than requiring the mic to be held, so joining muted still triggers it. A catch-all backstop also raises a quiet generic "Record?" prompt when the mic stays held by a plausible meeting app (a browser, FaceTime, Discord, …) for ~30 s and nothing else matched, so a call on a domain the whitelist never listed still gets caught (permission-light: it needs neither Accessibility nor Screen Recording). If a call is still missed, start recording manually with the `⌃⌥M` hotkey. To teach the daemon a meeting app it does not know without rebuilding, drop a `~/.config/meeting-pipe/meeting_apps.toml` overlay next to `config.toml` (same tables as the bundled list: `[native]`, `[browser.bundles]`, `[browser].url_fragments`, `[mic_plausible]`) and relaunch; its entries are unioned over the built-in defaults.

**The recording is silent / very quiet.** Check `recorder.log` for the `duration check` line at the end of a recording. With the in-process recorder it should always read `ratio=~100%`. If it doesn't, the Screen Recording permission may not have been granted (system audio capture is gated). Check System Settings ▸ Privacy & Security ▸ Screen Recording — MeetingPipe should be enabled.

**The recording is missing system audio (only my voice).** ScreenCaptureKit needs Screen Recording permission. After granting, restart the daemon: pick **Quit MeetingPipe** from the menu-bar icon and the LaunchAgent brings it straight back (TECH-UX7).

**The recording captured only the other side (my voice is missing).** The daemon records the system default input, and it cannot read the microphone the meeting app itself chose; if the default input is a device you're not speaking into (a Bluetooth headset left idle in A2DP is the classic case), your voice records as noise floor while the far side is clean. MeetingPipe now catches this: if the mic stays silent while system audio is live, you get a **"Your mic recorded almost nothing"** notification at stop and the Library row shows a **Mic silent** flag, and the Audio tab always shows **which mic** a recording used ("Recorded with …"). It also nudges you before a call if the input it's about to record sits idle while another mic is active. The fix is to set the right default input in **System Settings ▸ Sound ▸ Input** before recording (there is deliberately no in-app device picker).

**Speaker labels look wrong (one person split across many speakers, or multiple people collapsed into one).** Diarization is done on-device by FluidAudio (pyannote) in the daemon. It exposes one tuning knob, `transcription.diarization_clustering_threshold` (see the config reference above): if several people are collapsed into one voice, lower it for more distinct speakers; if one person is split across many, raise it. The default 0.65 already leans toward splitting over merging, because a merge names the wrong owner in the summary while a split just shows unnamed clusters you can merge in-app. A hard miss on a stereo recording falls back to channel-aware labelling (your mic vs the system mix). You can also fix any single meeting after the fact in the Transcript tab: right-click a segment and **Assign to…** another speaker, or **New person…** for someone diarization never separated or an **Unknown speaker** line (Cmd/Shift-click to assign several at once); then re-summarize so the summary reflects it. If labels are consistently wrong, capture the recording as a detection-corpus trace (TECH-C6) so the regression is reproducible.

**The transcript I see right after stop has speaker labels but the next day they look different.** That can't happen — transcript files (`<stem>.json`, `<stem>.md`) are written once and not modified. If you see this, you're probably looking at two different runs (a re-run via `mp run-all <wav>` overwrote the first). Check `pipeline.log` for two "run-all" sections matching the file's timestamp.

**The menu bar icon shows "Idle" but I'm in a meeting.** Open Console.app, filter on `subsystem:com.meetingpipe.daemon`. The detector emits an `os_log` line for every state change. If you see no events, restart the daemon with **Quit MeetingPipe** from the menu-bar icon; it relaunches itself. (**Quit (do not relaunch)** is the one that actually stops it.)

**Notion publish fails with 401 / 404.**
- 401 → `NOTION_TOKEN` is wrong or revoked. `mp doctor` confirms.
- 404 → the integration isn't shared with your database, or `notion.database_id` is wrong (use the ID, not the page slug).

**The MeetingPipe actions don't show up in Shortcuts.** Expected: they are off by default (see "Native Shortcuts actions" above). Use a Shortcut built on the **Open URL** action with a `meetingpipe://` URL instead, which is the supported path.

**A MeetingPipe Shortcuts action fails with "couldn't communicate with the app".** This is the known limitation that keeps the native actions disabled, not a broken install. The app is ad-hoc signed (no Apple Developer ID), and invoking an App Intent requires the system to hand off to the app over a trusted channel, which it refuses for a `spctl`-rejected bundle. Discovery works because it only reads a static metadata file, which is why the actions can appear and still fail. Six other causes were excluded by measurement (dead-stripped symbols, Launch Services registration, `openAppWhenRun`, launchd vs Launch Services launch, `LSUIElement`, an app crash); the notes are in `MeetingPipeAppIntents.swift`. The fix is a real Developer ID (tracked as D8 / DIST1). Meanwhile the `meetingpipe://` URLs work and are verified. If you re-enable the metadata with `MP_APP_INTENTS=1` and the actions do not appear at all, quit and reopen Shortcuts (it caches the action list), and re-run `bash daemon/scripts/auto1-app-intents-probe.sh` to confirm the toolchain can still produce the metadata after an Xcode update.

**The recording never ends; the daemon thinks the meeting is still going long after I hung up.** The end-detection probe scans the meeting app's window titles via Accessibility. If you have an unrelated window whose title contains a matching meeting word (e.g. a Slack channel named "team-calls", a Zoom "Schedule Meeting" dialog left open, a Teams chat thread named "Sprint planning meeting"), the per-app recognizer should reject it. If it doesn't, capture the offending titles with `swift scripts/dump_window_titles.swift <bundle_id> <state> reject`, add the row to `daemon/Tests/MeetingPipeTests/Fixtures/window_titles.json`, and the next test run shows whether `Detector.isActiveMeetingWindow` needs a refinement.

As a safety net, the daemon also watches for silence on both mic and system audio (gated on voice activity, not raw level, so ambient room noise does not reset the timer). Partway through the streak it surfaces a "Still meeting?" notification with a Stop action; at the end of it the recording auto-stops and emits an `auto_stop_silence` event. Look for that event in `events.jsonl` if a runaway recording stopped on its own.

The auto-stop horizon is `detection.mic_only_silence_seconds`, **default 900 s (15 minutes)**, adjustable from 1 to 30 minutes on the **Mic-only silence backstop** slider in Preferences ▸ Prompt. The nudge fires at half that horizon, capped at 8 minutes (so 7.5 minutes at the default), which keeps the warning ahead of the stop at every setting. One exception: a native meeting the lifecycle subsystem still tracks as live is kept and re-nudged rather than stopped, because prolonged silence there is usually someone waiting for a participant to join.

**Local backend won't start.**
- `mlx-lm not found`: rerun `scripts/install.sh` (or `cd pipeline && uv sync`). The dep is declared in `pyproject.toml` with an Apple-Silicon marker; non-arm64 hosts fall back to `backend="anthropic"` automatically.
- `mlx_lm.server did not become healthy within 120s`: the model is being downloaded for the first time. The default `Qwen2.5-7B-Instruct-4bit` is ~4.3 GB; check `~/.cache/huggingface/hub/` size growth. A previously-interrupted download is now detected as incomplete and resumed (it no longer reports ready while partial); watch the menu-bar download row and use its **Retry** if the fetch failed.
- Output looks fine but `mp doctor` still warns "regulated_mode + backend = anthropic": expected. `regulated_mode` does not by itself force the local backend. Set `summarization.backend = "local"` explicitly for the zero-egress contract.

**Several GB of RAM stay used after a summary run, and `mp doctor` reports an "orphaned mlx_lm.server".** The local model server runs detached, so it survives its parent being force-killed, which is what the pipeline watchdog does to a run that wedges past its timeout. The daemon reaps such a server the moment its watchdog fires, and again at every launch, so this should be self-healing. If a report persists, MeetingPipe has not restarted since the orphan appeared: quit and relaunch it from the menu-bar icon, or kill the pid `mp doctor` names.

**A regulated or NDA meeting fails with "Model ... is not in the local HuggingFace cache".** A zero-egress run refuses to download a model, because doing so would send a request to huggingface.co from a meeting that promised not to. Fetch the model once from a normal run, then re-run the meeting:

```bash
mp prefetch-model mlx-community/Qwen2.5-7B-Instruct-4bit
```

This bites after changing `summarization.local_model` and then recording an NDA meeting before any ordinary one has warmed the cache.

**I uninstalled and reinstalled but macOS still says "permission denied" and won't re-prompt.** With the self-signed "MeetingPipe Dev" signing cert (the default), Screen Recording grants survive rebuilds, so this is now rare. If it still happens:
- `scripts/install.sh --reset-tcc` (or `scripts/uninstall.sh --reset-tcc`) clears the TCC cache for a clean re-grant. Note that macOS Notifications live outside TCC and must be reset manually in System Settings → Notifications → MeetingPipe.
- On the ad-hoc fallback (no cert, openssl missing), rebuilds change the cdhash and orphan the grant: macOS keeps the stale System Settings entry but no longer applies it. Open the Permissions tab, click Request, and toggle once for the new cdhash. Creating the dev cert avoids this.

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

Why `--reset-tcc` exists: macOS keys permission grants on the bundle id (`com.meetingpipe.daemon`). If you denied a permission once, removing the .app does NOT clear that denial. TCC keeps the cached state, and the next install silently runs without the permission instead of re-prompting. The flag SIGKILLs any running daemon (so its in-process verdict cache can't write itself back), then runs `tccutil reset` for every service the daemon touches plus `reset All` as a catch-all. Notifications are NOT under TCC — they live in a separate authorization store managed by `usernoted` and have to be cleared manually from System Settings → Notifications → MeetingPipe.

---

## License

MIT — see [`LICENSE`](./LICENSE).
