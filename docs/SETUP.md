# Setting up meeting-pipe

This is the complete walkthrough, from a Mac that has never seen this project to your first meeting summary. It assumes no programming background. You will use the Terminal, but only to copy and paste commands that are given to you in full.

If something here does not match what you see on screen, that is a bug in this guide. The [troubleshooting section](#when-something-goes-wrong) at the end covers the failures that actually happen.

## What you are setting up

meeting-pipe is a menu-bar app. It notices when you join a meeting, asks whether to record, and after you hang up it transcribes the audio on your Mac and writes a summary into Notion (or Obsidian, or a folder). Everything except the summary step stays on your machine, and even the summary can be kept local.

**Time:** about 30 minutes, most of it waiting on downloads.

**What gets downloaded:** roughly 1.5 GB in total. Homebrew and its tools are a few hundred MB, the speech models are about 475 MB, and the rest is build output. If you later switch summarization to the on-device model, that is a further 4.3 GB, downloaded on demand and not part of this setup.

**What it costs:** nothing to install. Summarizing through Anthropic's API costs a few cents per meeting. There are free alternatives (an on-device model, or your existing Claude Code subscription), covered in [step 7](#step-7-choose-how-summaries-are-written).

## Before you start, check your Mac is supported

Two requirements are hard. Neither has a workaround.

**Apple Silicon.** Click the Apple menu, then **About This Mac**. The **Chip** line must say Apple M1, M2, M3, M4, or similar. If it says Intel, meeting-pipe will not work: speech recognition runs on the Neural Engine, which Intel Macs do not have.

**macOS 14 (Sonoma) or later.** The same **About This Mac** window shows your macOS version. If you are on an older version, update through System Settings before continuing.

You will also want about 5 GB of free disk space and a connection you are willing to pull 1.5 GB over.

## Step 1: Install the Xcode Command Line Tools

These provide the compiler that builds the app. They come from Apple and are free.

Open **Terminal** (press `Cmd+Space`, type `Terminal`, press Return), then paste this and press Return:

```bash
xcode-select --install
```

A dialog appears asking whether you want to install the tools. Click **Install**, accept the licence, and wait. It is a large download and can take 10 to 20 minutes.

If you instead see `command line tools are already installed`, you already have them. Move on.

To confirm it worked, paste this:

```bash
swift --version
```

You should see a version number. If you see an error mentioning `invalid active developer path`, the tools are installed but macOS has lost track of them, which happens after some system upgrades. Fix it with:

```bash
sudo xcode-select -s /Library/Developer/CommandLineTools
```

## Step 2: Install Homebrew

Homebrew installs the two other pieces meeting-pipe needs. Go to [brew.sh](https://brew.sh) and copy the installation command shown at the top of that page, then paste it into Terminal and press Return. It will ask for your Mac password (typing shows nothing, which is normal) and take several minutes.

**Do not skip the last part.** When Homebrew finishes it prints a short **Next steps** section containing two or three commands. On Apple Silicon these put Homebrew on your PATH, and without them nothing you install through Homebrew will be found. Copy those commands, paste them, press Return.

Confirm it worked by closing Terminal, opening a new one, and running:

```bash
brew --version
```

A version number means you are set. `command not found` means the Next steps commands did not run; go back and do them.

## Step 3: Download meeting-pipe and run the installer

Paste these three lines one at a time:

```bash
git clone https://github.com/ggegelya/meeting-pipe.git
cd meeting-pipe
./scripts/install.sh
```

The installer takes 5 to 15 minutes. It checks your prerequisites, installs `ffmpeg` and `uv` through Homebrew, builds the app, wraps it in `MeetingPipe.app` under your `~/Applications` folder, downloads the speech models, creates a configuration file, and sets the app to start when you log in.

Partway through it stops and asks for two API keys. **You can press Return to skip both and add them later in the app**, which is the easier path if you do not have them yet. [Step 6](#step-6-connect-notion) covers where the Notion token comes from and [step 7](#step-7-choose-how-summaries-are-written) covers the Anthropic one. Nothing you type here is echoed to the screen, and the keys go into your macOS Keychain, not into a file.

When it finishes you will see `Install complete` and a list of next steps, which the rest of this guide walks through properly.

## Step 4: Find the app and grant its permissions

Look at the right end of your menu bar. There should be a small icon reading **MeetingPipe: Idle** when clicked. If it is not there, open your `~/Applications` folder in Finder, **right-click** `MeetingPipe.app`, and choose **Open**. Right-click rather than double-click matters the first time: the app is not signed by a paid Apple developer account, so macOS shows an "unverified developer" warning that only the right-click Open path lets you get past. Confirm once and macOS remembers.

On first launch a **Welcome** window opens and walks you through the four permissions one at a time. Each has its own row explaining what it is for, with a button that asks for just that one when you click it (so you are never faced with a stack of unlabelled system dialogs). All four are needed for the whole thing to work:

| Permission | Why it is needed | If you deny it |
|---|---|---|
| **Notifications** | The record/skip prompt and the "summary ready" alert | You never see the prompt or the result |
| **Microphone** | Records your own voice | Recording refuses to start at all |
| **Screen Recording** | The only way macOS allows capturing system audio, which is everyone else's voice | You record yourself against silence |
| **Accessibility** | Reads meeting window titles to notice when a call ends | Recordings do not auto-stop, so you get up to 15 extra minutes of audio |

Screen Recording sounds alarming and is worth being precise about: meeting-pipe captures the audio stream only. It never records your screen, and no video is written to disk at any point.

**Accessibility needs one extra move.** macOS decides whether an app is trusted for Accessibility when the app launches, and it does not re-check afterwards. So after you grant it, quit and reopen the app: click the menu-bar icon and choose **Quit MeetingPipe**, and it relaunches itself within a few seconds. Until you do, the permission shows as granted but does nothing.

To see where you stand at any time, click the menu-bar icon, open **Preferences**, and go to the **Permissions** tab. It lists all four with their live status and a button to request or open the relevant System Settings pane.

## Step 5: Confirm it is alive

Before wiring anything up, check the installation itself:

```bash
~/.local/share/meeting-pipe/venv/bin/mp doctor
```

This prints a report. At this stage expect complaints about missing keys and a missing Notion database, which the next two steps fix. What you want to see is that it runs at all and that the model and permission checks pass.

## Step 6: Connect Notion

Skip this step if you would rather write summaries to Obsidian or a plain folder; [step 8](#step-8-edit-your-configuration) shows how to point them somewhere else instead.

Notion needs two things from you: a database for meetings to land in, and a token that lets meeting-pipe write to it.

**Create the database.** In Notion, make a new page, type `/database`, and choose **Table view**. Give it a name like `Meetings`. It needs three properties, and a new table gives you two of them already:

| Property | Type | Notes |
|---|---|---|
| `Name` | Title | Exists by default in a new table |
| `Date` | Date | Add this |
| `Status` | Select | Add this, and add `Captured` as one of its options |

Other columns are optional. If you add any of `Workflow`, `Source`, `Attendees` (multi-select), or `Open actions` (number), meeting-pipe fills them in automatically; if you do not, it skips them.

**Create the integration.** Go to [notion.so/my-integrations](https://www.notion.so/my-integrations), click **New integration**, name it `meeting-pipe`, associate it with your workspace, and submit. On the next screen reveal and copy the **Internal Integration Secret**. It starts with `ntn_`. This is your Notion token.

**Give the integration access to the database.** This is the step people miss, and skipping it produces a 404 later. Open your Meetings database as a full page, click the **•••** menu at the top right, choose **Connections**, and pick your `meeting-pipe` integration.

**Copy the database ID.** With the database open as a full page, look at the URL:

```
https://www.notion.so/yourworkspace/1a2b3c4d5e6f7890abcdef1234567890?v=...
```

The database ID is the 32-character block after the last `/` and before the `?`. Copy it without any hyphens.

**Store the token.** Click the menu-bar icon, open **Preferences**, go to **Integrations**, and paste the token into the Notion field. It is saved to your Keychain.

## Step 7: Choose how summaries are written

Transcription always happens on your Mac. Summarization is the one step with a choice, and it is a real one. Pick a backend in **Preferences ▸ Pipeline**:

- **Anthropic (the default).** Best quality. Costs a few cents per meeting and needs an API key from [console.anthropic.com](https://console.anthropic.com), which requires adding credit. Paste the key into **Preferences ▸ Integrations**. The transcript is sent to Anthropic; nothing else leaves your Mac.
- **Claude Code.** Free if you already pay for a Claude subscription: it drives your existing login rather than an API key. Still a cloud backend, so the transcript leaves your Mac.
- **Local.** Fully on-device, no network, no cost. Quality is lower than Anthropic's. The first meeting downloads a 4.3 GB model, so pick this now if you want it and let the download happen in the background.

You can change this later at any time, and switch a single meeting's backend after the fact from the Library.

## Step 8: Edit your configuration

The installer created a settings file at `~/.config/meeting-pipe/config.toml`. Open it in TextEdit:

```bash
open -e ~/.config/meeting-pipe/config.toml
```

Most settings have working defaults and are documented with comments in the file itself. For a Notion setup, the one line you must change is the database ID. Find the `[notion]` section and paste your 32-character ID between the quotes:

```toml
[notion]
database_id = "1a2b3c4d5e6f7890abcdef1234567890"
```

To publish somewhere other than Notion, find the `[output]` section and change `sinks`. Writing to an Obsidian vault, for example:

```toml
[output]
sinks = ["obsidian"]

[obsidian]
vault_path = "~/Documents/MyVault"
```

`sinks` takes a list, so `["notion", "obsidian"]` writes to both, and each is independent: if one fails the other still lands. Save the file and close TextEdit. Most changes take effect on the next recording; a few need the app relaunched, and the comments say which.

Now run the doctor again. It should be clean:

```bash
~/.local/share/meeting-pipe/venv/bin/mp doctor
```

## Step 9: Record your first meeting

You do not need an actual meeting to test this. Press **`Ctrl+Option+M`** anywhere in macOS and the recording starts: a small floating window appears with a timer, and the menu bar reads `Recording`. Talk for a minute or two. Press `Ctrl+Option+M` again to stop.

Now wait. The Mac transcribes the audio (usually well under a minute for a short clip, and the very first run is slower because the models are loading for the first time), then writes and publishes the summary. When it is done you get a notification you can click to open the result.

To watch it happen, click the menu-bar icon and choose **Open Library…**. Your recording appears as a row with a status that moves through Processing to Ready.

**For a real meeting**, you do not press anything. Join a call in Zoom, Teams, Meet, Webex, or a Slack huddle, and a panel appears in the top-right corner asking whether to record. Click **Record**. It stops on its own when the meeting ends.

That is the whole loop. From here, meetings turn into summaries without you doing anything.

## When something goes wrong

**The installer stops with "Xcode Command Line Tools not found".** Step 1 did not finish. Run `xcode-select --install` again and wait for the dialog to complete before re-running the installer.

**The installer stops with "Homebrew not found" even though you installed it.** The Next steps commands Homebrew printed did not run, so it is not on your PATH. Re-run them, then open a new Terminal window and try again.

**There is no icon in the menu bar.** Open `~/Applications` in Finder, right-click `MeetingPipe.app`, choose **Open**, and confirm the unverified-developer dialog. A double-click will not get past it the first time.

**Nothing happens when you join a meeting.** Open **Preferences ▸ Permissions** and check all four are granted. If Accessibility was granted recently, quit and reopen the app so the grant takes effect. You can always record manually with `Ctrl+Option+M`.

**The recording only has your voice.** Screen Recording is missing or was granted after the app started. Grant it in System Settings ▸ Privacy & Security ▸ Screen Recording, then quit and reopen the app.

**The recording only has the other people.** Your Mac's default input is not the microphone you are speaking into, which usually means idle Bluetooth headphones. Set the right input in System Settings ▸ Sound ▸ Input before recording. There is deliberately no microphone picker in the app; it follows the system setting.

**The recording never stops.** Accessibility is missing, or the meeting app is one it cannot read. The silence backstop stops it after 15 minutes of quiet regardless, and `Ctrl+Option+Shift+M` force-stops immediately.

**Notion fails with 401.** The token is wrong or was revoked. Re-copy it from your integration page into Preferences ▸ Integrations.

**Notion fails with 404.** Either the integration was never connected to the database (the **•••** ▸ **Connections** step in step 6), or the database ID is wrong. The ID is the 32 characters before the `?` in the URL, not the page name.

**Anything else.** Run `~/.local/share/meeting-pipe/venv/bin/mp doctor`, which checks each piece and names what is broken. The menu bar's **Diagnostics…** item shows the same underlying logs in a readable window. The README's [troubleshooting section](../README.md#troubleshooting) goes deeper on individual failures.

## Changing your mind

To remove meeting-pipe, from the `meeting-pipe` folder:

```bash
./scripts/uninstall.sh
```

That leaves your recordings, your settings, and your macOS permissions alone. Add `--purge` to also delete the settings, and `--all` to additionally reset the permissions so a future install prompts cleanly. Your recordings in `~/Documents/Meetings/` are never touched by the uninstaller; delete them yourself if you want them gone.

## A note on this being a from-source install

Building from source is currently the only way to install meeting-pipe, which is why this guide starts with a compiler. A drag-to-Applications installer is in progress (it needs an Apple Developer ID for notarization); when it lands, this guide gains a much shorter path at the top and everything above becomes the route for people who want to build it themselves.
