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

For meetings longer than ~1 hour, the pipeline writes the transcript to disk along with a paste-into-Claude-Code bundle and **does not call the Anthropic API**. See "Long meetings" below.

The on-screen prompt also has a **Record (BYO)** button: same flow, but opt-in per-meeting — useful for sensitive calls or when you'd rather hand-summarise. After the recording finishes, save your summary as `<stem>.summary.md` next to the transcript and run `mp publish-from-paste <stem>.md` to push it to Notion.

---

## Why it is shaped this way

The README covers how to use the app; this section covers the load-bearing design decisions. The long form lives in the [ADRs](./docs/decisions/).

- **The daemon owns detection, recording, and transcription; the Python pipeline only summarizes and publishes.** ASR and diarization run in-process via FluidAudio (Parakeet TDT + pyannote) on the Apple Neural Engine, fast enough that a streaming-during-the-call design was not worth its complexity. The pipeline runs out-of-process so summarize + publish never blocks the daemon, and it ships no torch / whisperx dependency. See [ADR 0007](./docs/decisions/0007-python-sidecar.md).
- **System audio is captured with ScreenCaptureKit, the mic with AVAudioEngine, and the two are written as one stereo WAV** (mic left, system right) so diarization and silent-system detection stay possible. No aggregate devices, no BlackHole, no ffmpeg subprocess. See [ADR 0009](./docs/decisions/0009-stereo-on-disk-mono-on-playback.md).
- **Detection fuses several signals, never one.** An open meeting app is not a live call, and a held mic does not survive joining muted, so the lifecycle subsystem fuses per-process audio, ScreenCaptureKit windows, and the Accessibility Leave button into one verdict through a debounced promotion rule. See [ADR 0008](./docs/decisions/0008-verdict-fusion-architecture.md).
- **The mic is captured losslessly; muted side-comments are redacted afterward, not gated at capture.** A real-time gate that silences the mic while you look muted depends on reading another app's mute state, which is fragile for Teams and Zoom and absent for every browser meeting, so a wrong reading once silently dropped real speech. By default the mic is now recorded in full and the muted spans are redacted from the transcribed, summarized, and published artifact offline, with the full recording kept locally for recovery. Regulated and NDA mode keep a real-time gate instead, since no audio at rest is permitted there. See [ADR 0016](./docs/decisions/0016-capture-first-mute-redaction.md).
- **Summarization calls the Anthropic Messages API directly, not Claude Code; publishing uses the Notion REST API, not MCP.** Both run headless and unattended, so the deterministic API surfaces beat the interactive ones.
- **Privacy is a setting, not a fork.** `summarization.backend = "local"` runs MLX-Qwen on Metal with no outbound call; `modes.regulated_mode = true` clamps every sink to on-disk. Together they make a fully zero-egress pipeline.

Non-goals, by design: video capture, a live in-call transcript, multi-user sharing, cross-platform, and a mobile companion.

The subsystem map and sequence diagrams are in [ARCHITECTURE.md](./ARCHITECTURE.md); the event-log and sidecar schemas are in [CONVENTIONS.md](./CONVENTIONS.md).

---

## Requirements

- **macOS 14 (Sonoma) or later** — required for ScreenCaptureKit's `excludesCurrentProcessAudio`.
- **Apple Silicon (M-series), required.** FluidAudio (ASR + diarization) runs on the Apple Neural Engine; there is no Intel fallback.
- A few GB of free disk for the FluidAudio models, downloaded on first use.
- A Notion integration token + a database to write to.
- An Anthropic API key (unless you run the local summary backend).

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
4. Stage `~/.config/meeting-pipe/config.toml` and `secrets.env` (mode 0600).
5. Install the LaunchAgent so the daemon starts at login.

**First launch & Gatekeeper.** The app is unsigned (no Apple Developer subscription required for personal use). On first launch from Spotlight, macOS shows an "unverified developer" dialog. Right-click the app icon in Finder → Open, confirm once, and macOS remembers the decision. The LaunchAgent path runs the binary directly so it's not subject to that dialog after the first manual approval.

**Rebuild loop for local edits.** Once `install.sh` has run once, `scripts/rebuild.sh` is the one-command fast path: `swift build -c release` → drop the new binary into the installed `.app` → re-sign with the stable identifier → `launchctl kickstart -k` to respawn the LaunchAgent without waiting on the 10 s throttle. Skips pipeline venv, model pre-fetch, and config staging. Target end-to-end is under 30 s on incremental builds.

### One-time manual steps

The installer can't do these for you:

1. **Fill in secrets** at `~/.config/meeting-pipe/secrets.env`:

   ```env
   ANTHROPIC_API_KEY=sk-ant-...
   NOTION_TOKEN=ntn_...
   ```

   You can rotate these any time — the daemon re-reads `secrets.env` every time it spawns the pipeline, so a new value takes effect on the next recording. No restart needed.

   To verify: `~/.local/share/meeting-pipe/venv/bin/mp doctor` — pings each API, validates the ML runtimes, and tells you which secret is wrong.

2. **Configure** `~/.config/meeting-pipe/config.toml`:
   - Set `notion.database_id` to your Meetings database ID (the 32-char string in the database URL).
   - Adjust `output.sinks` and the summarization backend if the defaults (Notion, Anthropic) are not what you want.

3. **Grant macOS permissions** when prompted on first launch. The daemon fires every TCC dialog in one ordered sequence within the first few seconds, instead of dribbling them out across the first recording:
   - **Notifications** — record/skip prompts and completion alerts.
   - **Microphone** — `AVAudioEngine` reads from the system default input.
   - **Screen Recording** — gates `SCStream.capturesAudio` in TCC.
   - **Accessibility** — reads window titles to detect when a meeting ends (Teams / Zoom / Webex / Slack desktop AND browser tabs). Without this, native apps will record fine but the call won't auto-stop — the daemon falls back to manual hotkey / silence-based stop, which can mean an extra 5 minutes of wav file. **Granting Accessibility requires a daemon restart** for the new trust verdict to propagate (macOS caches AX trust per-process at launch); the detector re-evaluates immediately on restart so a meeting that's still in progress is picked up automatically.

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

---

## Running by hand

You can run any pipeline stage on its own audio file — useful for debugging or re-publishing a fixed transcript:

```bash
# Full pipeline
~/.local/share/meeting-pipe/venv/bin/mp run-all ~/Documents/Meetings/raw/20260428-1430.wav

# Or step-by-step (transcription is done by the daemon, not the CLI)
mp summarize    <transcript.md>
mp publish-notion <summary.json>

# Preflight check (validates secrets + live API access + which sinks
# are reachable + which summarization backend is selected)
mp doctor

# Filter the JSONL event streams (see Logs section)
mp logs --since 1h --category detector

# Audit meeting-end detection reliability: pairs each recording with its
# preceding lifecycle.ended event and surfaces sessions you stopped manually
mp analyze-detection --since 7d

# Compare Anthropic vs the local backend on one transcript; writes a
# scorecard you fill in by hand. Refuses regulated/NDA meetings, since the
# cloud baseline would egress the transcript.
mp dogfood <transcript.md>
mp dogfood --report   # aggregate filled scorecards into a ship/no-ship
```

---

## Long meetings

The Anthropic API charges per token. A 1-hour meeting can cost real money to auto-summarize — and you might prefer to handle it yourself in Claude Code, where you have access to the full conversation context anyway.

Default behavior: if the transcript exceeds **80 000 characters** (~20 000 tokens, ~1 hour of speech), the pipeline:

1. Saves the transcript markdown as usual at `<stem>.md`.
2. Writes a sidecar `<stem>.READY_FOR_MANUAL.md` containing the exact system prompt the pipeline would have used, plus a pointer to the transcript.
3. **Skips** the Anthropic call and the Notion publish.
4. Sends a desktop notification.

To process the meeting yourself: open Claude Code, paste the system prompt from the `.READY_FOR_MANUAL.md` file, attach (or paste) the transcript markdown, and ask for the summary. No API charge.

To change the threshold or disable the guard, edit `summarization.skip_above_chars` in `~/.config/meeting-pipe/config.toml`. Set to `0` to disable.

---

## Library window

Click the menu bar icon → **Open Library…** to open the main window (900×600, restorable, hides on Cmd+W with the daemon still running).

The window is a smart-folder rail + scoped list + context-aware detail pane, with a custom toolbar across the top:

- **Toolbar** — breadcrumb (`Library` → scope name), an optional `Edit workflow` button that appears only when a workflow scope is selected, the always-visible **state pill** (Idle / Processing / live Recording with workflow tint and timer), a Record/Stop button, and a gear that opens Preferences.
- **Rail** (under a `LIBRARY` header): `All meetings`, `Today`, `Last 7 days`, `Last 30 days`, `Needs you`, `NDA only`, `Untagged`, `Facts`. `Needs you` carries an amber count badge and gathers the meetings that want an action: a failed run, a long-meeting bundle awaiting a paste, or a finished meeting whose publish failed or only partially landed. `Facts` is a cross-meeting projection rather than a list filter: it gathers every open action (with its owner, an aging label off the due date, and a circle to mark it done in place) and the decisions from meetings in the last 30 days, each row linking back to its source meeting. Marking an action done writes the resolved flag into that meeting's summary, so it survives a republish. Under a `WORKFLOWS` header: one row per workflow (colored dot + name + meeting count; the default workflow is labelled inline). A `+ New workflow` row opens an editor sheet. Workflows are filter scopes here, not a separate destination, and selecting one narrows the list AND surfaces the workflow inspector in the right column.
- **List** — the scoped meetings list with the existing filter chips (App / Status / Date) layered on top.
- **Detail pane** — single meeting selected → the meeting detail (Summary / Transcript / Audio / Corrections / Raw); multiple selected → batch actions; no meeting but a workflow scope active → workflow inspector (Trigger / Modes / Output / Backend + Recent meetings + Edit workflow); otherwise the empty-state nudge.

Preferences is no longer a rail item — it lives on the toolbar's gear icon. Workflows are no longer a top-level tab — they're rail scopes.

If you've never recorded anything the list shows `No recordings yet - Start a meeting in Zoom / Teams / Meet / Webex / Slack, or press ⌃⌥M.` Otherwise:

The list scans `~/Documents/Meetings/raw/` (or whatever is configured in `recording.output_dir`) and shows one row per recording, grouped into Today / Yesterday / This week / Last week / Earlier this month / older months. Each row carries the meeting title (LLM-derived when available, falling back to the source app + time), source-app glyph, duration, and a status pill (Recording / Processing / Paste pending / Ready). Live recordings and rows whose pipeline run is still in flight pulse subtly so you can tell what's currently being worked on at a glance. The list refreshes automatically when the pipeline writes new sidecars - new meetings appear within a second of the underlying file landing.

Select a row and the right pane fills with the per-meeting detail view: an editable title, the meeting's date, the workflow chip when present, duration, and shortcuts to open the published note in Notion or Obsidian (when those sidecars are on disk) or reveal the raw audio in Finder. When the backend that produced the summary is known, a quiet grey provenance line sits under the caption naming it - `Claude (cloud)`, `On-device (MLX)`, or `Apple Intelligence` (the model id rides in the tooltip); it is hidden for legacy, paste, or skipped meetings with no recorded backend. A `...` menu on the header collects the less-common actions (Rename, Edit summary, Corrections…, Republish, Reprocess, Open meta.json, Copy meeting ID, Delete…). Three tabs underneath:

- `Summary` renders `<stem>.summary.md` as Markdown and is read-only until you pick `Edit summary` from the header `...` menu, which swaps in the editor. The editor reuses the same field set as the standalone correction window: title, summary bullets, decisions, action items, open questions, attendees, language, notes. Its primary button is `Save correction`, which persists the edit only: it writes a correction record (verdict=edited) and overwrites `<stem>.summary.json` so the list and Markdown views immediately reflect the new content. A failed save keeps you in the editor with an inline warning and your edits intact. Republishing is a separate step (the `...` menu's `Republish`, or the row's inline Republish button once the saved summary is newer than the published page), so a save never re-pushes to your sinks on its own. A quiet `Reprocess…` affordance at the foot of the summary lets you edit the context prompt the model is given and generate a candidate summary, shown side by side; keep it to replace the current one (never auto-published) or discard to keep the original. The override applies to that run only and is never persisted.
- `Transcript` renders the diarized segments from `<stem>.json` as a speaker-grouped list. Click any line to jump the audio play head to that segment and start playing; the active line is highlighted as playback advances. A compact play / pause / scrubber strip sits at the bottom of the tab; the same audio engine is reused by the Audio tab when it lands so seeking from a transcript line and switching tabs keeps the same play head.
- `Audio` shows a two-channel waveform (mic on top, system audio on the bottom) backed by downsampled peaks. The cache lives under `~/Library/Caches/MeetingPipe/waveforms/<stem>.peaks` and is keyed on the wav's size + modification time, so any change to the recording (re-record, repair, replace) invalidates the cache on the next open. Click anywhere in the waveform to seek; the play head syncs with the Transcript tab. A zoom menu (Fit / 1× / 2× / 4× / 8×) widens the rendered track when you need to land on a specific second.

Corrections is no longer a tab (the DSN2 IA pass dropped it): the `...` menu's `Corrections…` opens it as a sheet. Once you've edited (or graded) the meeting it shows the on-disk correction record: verdict, timestamp, backend + model, notes, and a side-by-side Original / Corrected preview. **Re-edit in Summary tab** closes the sheet and jumps to the Summary editor; **Revert…** asks for confirmation and then restores the original LLM summary to `<stem>.summary.json` and deletes the correction record. Notion is not changed automatically; republish if you want the page in sync.

The `Raw files` tab was dropped in the same pass. Getting at the sidecars on disk now goes through the `...` menu's `Open meta.json` and the header's reveal-in-Finder shortcut.

A filter bar sits above the list with a search field plus chips for workflow, source app, status, and date range (today / last 7 days / last 30 days / this year). Search is in-memory across titles, summary bullets, decisions, action tasks, and open questions — built from the `<stem>.summary.json` sidecar during scan. Multiple words are ANDed together; matching is case-insensitive. The chips show the active value inline (e.g. "App: Zoom"); **Clear** wipes every filter. The match-count line ("N of M meetings") only appears while a filter is applied. Full-transcript search via SQLite FTS5 is the deferred upgrade path (see backlog TECH-A3); the in-memory implementation covers everyday volume.

Cmd+click (or Shift+click for a range) to select multiple rows. The detail pane swaps to a batch-actions panel that lists the selection and offers **Republish all** (loops `mp publish-notion` sequentially so the daemon's processing queue doesn't fan out), **Export markdown…** (writes one `<stem>.md` bundle per meeting into a chosen folder), and **Move to Trash…** (per-row soft delete with one confirmation up front). A linear progress strip shows `<done> / <total>` while a batch is in flight.

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

**Where it shows up.**
- The **prompt panel** sprouts a chip next to the action buttons with the resolved workflow's color/emoji + name. Click it to pick a different workflow before clicking Record.
- The **recording HUD** tints its pulse dot to the workflow's color and shows the name + an "NDA" tag (when applicable) below the elapsed timer.
- The **menu-bar title** reads `Recording - {Workflow}` with a trailing `· NDA` when NDA mode is on.

**Sidecar contract.** When a recording finishes the daemon writes `<stem>.meta.json` with `workflow_id`, `workflow_name`, `workflow_context_prompt`, `workflow_backend`, `workflow_sinks`, `workflow_notion_database_id`, and `workflow_nda_mode`. The pipeline's `mp.workflow.apply_overrides` reads that sidecar and patches the in-memory `Config` before summarize + publish, so every workflow knob takes effect on a single run without changing global state.

**NDA mode.** A behavioural flag with one effect: forces `backend = local` and `sinks = ["filesystem"]` regardless of what else the workflow says. Belt-and-braces - the pipeline re-enforces the override at run time so even a misconfigured workflow can't leak audio to the cloud. The HUD shows a coral `NDA` tag and the menu-bar title appends `· NDA`.

**Per-workflow Notion DB.** When a workflow enables the Notion sink the editor fetches your databases via the Notion API (`https://api.notion.com/v1/search`, filtered to `object=database`) and caches the list at `~/Library/Caches/MeetingPipe/notion-databases.json`. The picker reads from that cache; **Refresh** re-fetches. If you paste a DB id that isn't in the cache yet (newly created database, for instance) the picker preserves it as a "Custom" row so the selection doesn't snap back to none on the next render.

---

## Improving local quality

When `summarization.backend` is `"local"`, you can grade each published summary so the local model gets better over time. There are two surfaces:

- **Done-meeting notification.** After publish, the banner shows three actions:
  - **Open in Notion** (when applicable) opens the published page.
  - **Looks good** records a verdict-good sample inline; nothing else to do.
  - **Edit summary** opens an editor sheet pre-populated with the summary, where you can fix any field (title, summary bullets, decisions, action items, questions, attendees) and save.
- **Recent meetings…** in the menu bar lists the last 10 published meetings; pick one to open the same editor sheet. Useful when you dismissed the notification.

Every grade lands as one JSON file under `~/Library/Application Support/MeetingPipe/corrections/<stem>.json`. The corpus stays on your machine. Nothing in this loop touches the network, regardless of which summarization backend you use.

Run `mp corrections-stats` to see the current state of your corpus plus a Phase 3 readiness check (the upcoming local-LoRA training needs ~20 corrections covering ~200 minutes of speech before it can fine-tune a per-user adapter). Pass `--json` for a script-friendly form.

---

## Logs

Everything lives under `~/Library/Logs/MeetingPipe/`:

- `daemon.log`   — state transitions, recording start/stop, pipeline kick-off
- `detector.log` — meeting detection events (which app/tab, debounce timing)
- `recorder.log` — recording lifecycle, duration parity check
- `pipeline.log`: summarization and publishing (transcription runs in the daemon, not here)
- `events.jsonl`: structured Swift-side events, one JSON object per line
- `pipeline_events.jsonl`: structured Python-side events
- `launchd.{out,err}.log` — daemon stdout/stderr

`tail -F ~/Library/Logs/MeetingPipe/*.log` is the fastest way to debug live. For postmortem queries against a workday's worth of detection or pipeline events, use `mp logs`:

```bash
mp logs --since 1h                                  # everything in the last hour
mp logs --since 30m --category detector             # just detector events
mp logs --since 2d --action pipeline_failed         # all pipeline failures
mp logs --since 1d --json | jq 'select(.bundle_id=="us.zoom.xos")'
```

`--since` accepts ISO timestamps (`2026-05-06T10:00:00Z`) or short relative offsets (`Nh` / `Nm` / `Nd` / `Ns`).

To search across past meetings from the shell, `mp ask` runs a lexical (TF-IDF) ranking over your summaries and transcripts, fully on-device with no extra dependency:

```bash
mp ask budget Q3 forecast                           # top meetings, with a snippet
mp ask "migration to postgres" --top 3 --json       # machine-readable
```

This is the zero-dependency MVP. The on-device semantic layer over the same library now exists: `mp ai2-spike` builds a real embedding index (multilingual-e5 on MLX, en/uk) and measures long-context RAG latency + faithfulness on your Mac, the go/no-go that gates engine-backed cited answers (see [`docs/spikes/ai2-embedding-rag-latency.md`](./docs/spikes/ai2-embedding-rag-latency.md)).

```bash
mp ai2-spike --index-only                           # just build the embedding index
mp ai2-spike --reuse-index --sizes 4000,8000,16000  # measure RAG TTFT + faithfulness
```

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

---

## Configuration reference

See [`config.example.toml`](./config.example.toml). Highlights:

- `recording.auto_consent_apps` — bundle IDs that auto-record without a prompt (e.g. `["us.zoom.xos"]`).
- `detection.manual_hotkey` — global hotkey for manual record (default `ctrl+option+m`).
- `detection.default_prompt_action` — what the prompt panel does when the user ignores it for `prompt_timeout_sec`. `"skip"` (default) suppresses the call, `"record"` auto-starts an auto-summary recording, `"byo"` auto-starts a BYO (manual-paste) recording. Surfaced as a segmented control in Preferences → Prompt. On a `"skip"` timeout the loss is now surfaced (it used to be silent): the menu bar shows `Suppressed (<app>)` for as long as the meeting is still detected, and a "Skipped \<app\>" notification offers a **Start recording** action that begins the recording late, bypassing the cooldown. The prompt panel and recording HUD also float over full-screen meeting Spaces now, so a full-screen call still gets the prompt.
- Transcription (ASR + speaker diarization) runs in the daemon via FluidAudio and is not tuned through `config.toml`. The old `transcription.*` keys were removed when ASR moved into Swift.
- `summarization.summary_language` — `"auto"` (default; matches transcript language) or an ISO 639-1 code to force a specific output language.
- `summarization.team_context` — domain string injected into the system prompt so the summarizer does not extract domain terms ("validation", "QMS") as action items.
- `summarization.skip_above_chars` — long-meeting guard (default 80 000).
- `summarization.backend`: `"anthropic"` (default), `"local"` (on-device MLX, no outbound calls), `"auto"` (try Anthropic first, fall back to local on network/auth failure), or `"apple_intelligence"` (on-device Apple Intelligence, macOS 26+, produced in the daemon). Switchable in Preferences → Pipeline.
- `summarization.local_model`: MLX model id when backend is `"local"` or `"auto"`. Default `mlx-community/Qwen2.5-3B-Instruct-4bit` (~2 GB on first use; cached in `~/.cache/huggingface/hub`). Use the preset picker in Preferences → Pipeline to swap to the curated Recommended (Qwen 14B-4bit, ~8 GB, slower, better quality) or Large (Qwen 32B-4bit, ~18 GB, slowest, best quality) options, or pick Custom and paste any HuggingFace MLX repo id. The daemon pre-fetches the configured model immediately on first launch / on backend flip, so the first meeting in local mode does not wait several minutes for the download to finish inside `mlx_lm.server`. Progress shows in the menu bar (title suffix `↓ NN%` plus a dedicated menu row with the byte breakdown). An interrupted or partial download is detected as incomplete (not reported ready) and resumed on the next launch / backend flip; if a download fails, the menu row becomes a clickable **Retry**.
- `summarization.local_endpoint`: where `LocalSummaryClient` will spawn `mlx_lm.server`. Default `http://127.0.0.1:8765`.
- `summarization.local_startup_timeout_sec` / `local_request_timeout_sec`: local-backend timeouts (defaults 120 each). The request timeout is the base read window, scaled up by `max_tokens` so a long generation on a slow model is not cut off mid-stream; raise either if a large local model needs more headroom. The daemon's 20-minute watchdog stays the hard backstop.
- `output.sinks`: ordered list of publishers to invoke. Default `["notion"]`. Add `"obsidian"`, `"filesystem"`, and/or `"lan"` to fan out. Each sink fails independently; one going down does not block the others.
- `obsidian.vault_path`: required when `"obsidian"` is in `sinks`. The publisher writes to `<vault>/<obsidian.folder>/<date> <slug>.md` with YAML front-matter; `obsidian.attach_audio = true` copies the recording into `<vault>/<obsidian.attachments_subfolder>/`. `obsidian.template_path` points at a custom template (the built-in template covers the common case).
- `filesystem.output_dir`: where the filesystem sink drops the three files.
- `lan.mount_path`: target directory on an already-mounted SMB/NFS share for the `"lan"` sink. Same three files as the filesystem sink, but written atomically and only after a reachability check (it never creates the mount root itself, so a down share fails loudly instead of writing to local disk). On-prem, no cloud egress, so it survives regulated mode. `lan.host` is an optional label used only in the unreachable error.
- `modes.regulated_mode`: when `true`, the Notion sink no-ops at upsert time. Pair with `summarization.backend = "local"` for full zero-egress (every outbound HTTP request would assert in tests).

There are no microphone or output-device settings — the daemon auto-detects both. Change the system default input in System Settings ▸ Sound to swap mics.

---

## Troubleshooting

**No recording starts when I join a Zoom call.** Detection fuses several signals (the meeting app running and frontmost, its audio-process activity, and window-title / screen-share cues) rather than requiring the mic to be held, so joining muted still triggers it. If a call is missed, confirm the app is listed in `meeting_apps.toml`, then start recording manually with the `⌃⌥M` hotkey.

**The recording is silent / very quiet.** Check `recorder.log` for the `duration check` line at the end of a recording. With the in-process recorder it should always read `ratio=~100%`. If it doesn't, the Screen Recording permission may not have been granted (system audio capture is gated). Check System Settings ▸ Privacy & Security ▸ Screen Recording — MeetingPipe should be enabled.

**The recording is missing system audio (only my voice).** ScreenCaptureKit needs Screen Recording permission. After granting, restart the daemon: `launchctl kickstart -k gui/$(id -u)/com.meetingpipe.daemon`.

**Speaker labels look wrong (one person split across many speakers, or multiple people collapsed into one).** Diarization is done on-device by FluidAudio (pyannote) in the daemon, with no user-facing tuning knobs. A hard miss on a stereo recording falls back to channel-aware labelling (your mic vs the system mix). If labels are consistently wrong, capture the recording as a detection-corpus trace (TECH-C6) so the regression is reproducible.

**The transcript I see right after stop has speaker labels but the next day they look different.** That can't happen — transcript files (`<stem>.json`, `<stem>.md`) are written once and not modified. If you see this, you're probably looking at two different runs (a re-run via `mp run-all <wav>` overwrote the first). Check `pipeline.log` for two "run-all" sections matching the file's timestamp.

**The menu bar icon shows "Idle" but I'm in a meeting.** Open Console.app, filter on `subsystem:com.meetingpipe.daemon`. The detector emits an `os_log` line for every state change. If you see no events, restart the daemon: `launchctl kickstart -k gui/$(id -u)/com.meetingpipe.daemon`.

**Notion publish fails with 401 / 404.**
- 401 → `NOTION_TOKEN` is wrong or revoked. `mp doctor` confirms.
- 404 → the integration isn't shared with your database, or `notion.database_id` is wrong (use the ID, not the page slug).

**The recording never ends; the daemon thinks the meeting is still going long after I hung up.** The end-detection probe scans the meeting app's window titles via Accessibility. If you have an unrelated window whose title contains a matching meeting word (e.g. a Slack channel named "team-calls", a Zoom "Schedule Meeting" dialog left open, a Teams chat thread named "Sprint planning meeting"), the per-app recognizer should reject it. If it doesn't, capture the offending titles with `swift scripts/dump_window_titles.swift <bundle_id> <state> reject`, add the row to `daemon/Tests/MeetingPipeTests/Fixtures/window_titles.json`, and the next test run shows whether `Detector.isActiveMeetingWindow` needs a refinement.

As a safety net, the daemon also watches the audio level. After 90 s of unbroken silence on both mic and system audio it surfaces a "Still meeting?" notification with a Stop action; after 5 min it auto-stops and emits an `auto_stop_silence` event. Look for that event in `events.jsonl` if a runaway recording stopped on its own.

**Local backend won't start.**
- `mlx-lm not found`: rerun `scripts/install.sh` (or `cd pipeline && uv sync`). The dep is declared in `pyproject.toml` with an Apple-Silicon marker; non-arm64 hosts fall back to `backend="anthropic"` automatically.
- `mlx_lm.server did not become healthy within 120s`: the model is being downloaded for the first time. The default `Qwen2.5-3B-Instruct-4bit` is ~2 GB; check `~/.cache/huggingface/hub/` size growth. A previously-interrupted download is now detected as incomplete and resumed (it no longer reports ready while partial); watch the menu-bar download row and use its **Retry** if the fetch failed.
- Output looks fine but `mp doctor` still warns "regulated_mode + backend = anthropic": expected. `regulated_mode` does not by itself force the local backend. Set `summarization.backend = "local"` explicitly for the zero-egress contract.

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
