# Using meeting-pipe

This is the how-do-I guide: short recipes for the things you actually do with the app, each one a screen or less. It assumes the app is installed and has recorded at least once. If it is not, [`SETUP.md`](./SETUP.md) takes you from a clean Mac to a first summary, and this guide picks up where that one stops.

Nothing here needs a terminal. Where a recipe mentions a deeper reference, it links to it rather than repeating it: [`README.md`](../README.md) is the reference for every surface and every setting.

You can open this guide from the app at any time: click the menu-bar icon and choose **Guide…**.

**Contents**

1. [Recording a meeting](#1-recording-a-meeting)
2. [Workflows: one setup per kind of meeting](#2-workflows-one-setup-per-kind-of-meeting)
3. [Vocabulary: teaching it your words](#3-vocabulary-teaching-it-your-words)
4. [Voices: who said what](#4-voices-who-said-what)
5. [Finding things](#5-finding-things)
6. [Ask: questions across every meeting](#6-ask-questions-across-every-meeting)
7. [The weekly rhythm](#7-the-weekly-rhythm)
8. [Keeping it safe](#8-keeping-it-safe)
9. [Hotkeys and shortcuts](#9-hotkeys-and-shortcuts)
10. [When something looks wrong](#10-when-something-looks-wrong)

Plus [the words this app uses](#the-words-this-app-uses) at the end.

---

## 1. Recording a meeting

**Goal:** get a call onto disk, with or without the app asking first.

### The prompt

Join a call in Zoom, Teams, Google Meet, Webex, or a Slack huddle and a small panel appears in the top-right corner. It names the app it found and shows the workflow it is about to use.

- **Record** starts recording.
- The **chevron** beside Record holds the rest: **Record (BYO)**, **Always for `<app>`** (never ask again for that app), and **Skip this meeting**.
- The **×** in the corner is the same as Skip.
- **Last time** appears when this workflow has met before. Click it and the panel expands in place to show the previous meeting: its title, how long ago, the first few summary points, and what it left open. Click again to collapse.
- The **workflow chip** shows which routing this meeting will use. Click it to pick a different one before you record.

If you ignore the panel it does what **Preferences ▸ Prompt** says after the timeout, which by default is to skip. A skipped meeting is not lost: the menu bar reads `Suppressed (<app>)` for as long as the call is still running, and the menu's top action changes to **Record this `<app>` meeting**, so you can start late and still get the app chip and the automatic stop.

### Recording by hand

Press `⌃⌥M` anywhere in macOS, or pick **Start Recording** from the menu bar. No meeting required, so it doubles as a voice memo. Press it again to stop.

### BYO, when you would rather write the summary yourself

**Record (BYO)** records exactly like a normal meeting but does not ask any engine for a summary. Afterwards, open the meeting in the Library and the **Summary** tab shows a **Paste your summary** box: drop your text in, click **Save & publish**, and it goes to the same destinations a normal meeting would.

Useful for a call you do not want summarized by anything, or one you would rather hand-write.

### Off the record

For a stretch of a call that should not reach your notes, press `⌃⌥O`, or click the **mic-with-a-slash** button on the recording panel (it is also **Go off the record** on that panel's right-click menu). The panel shows a steady **Off the record** state and the voice meter drops to zero until you turn it off again. Press it a second time to resume; an open stretch closes by itself when you stop.

What that actually does depends on the workflow. Under an ordinary workflow the microphone keeps recording and the marked stretch is cut out before anything reads the audio, so it never reaches the transcript, the summary, or anything you publish. The uncut recording is kept on your Mac as a recovery copy, readable only by you and never backed up or synced anywhere, and it is reclaimed after a month or so. Under a workflow in NDA mode, or with regulated mode on, the microphone is silenced for real while the stretch is open, because those modes promise no such audio is kept at all.

### Flagging a moment

When something is said that you know you will want to find later, press `⌃⌥F`, or click the **flag** button on the recording panel (also **Flag this moment** on its right-click menu). The panel blinks once to confirm. The moment shows up in the summary as a flagged moment and as a clickable chip in the **Transcript** tab that jumps you to it.

Both the flag and the off-the-record keys do nothing when no recording is running, so a mistimed press is harmless.

### Stopping

Normally you do not: the app notices the call ended and stops on its own. Otherwise, press `⌃⌥M` again, click **Stop recording** on the recording panel, or pick **Stop Recording** from the menu bar. `⌃⌥⇧M` is the panic key: it only ever stops, so it can never start a recording by accident.

After Stop, the Mac transcribes the audio, writes the summary, and publishes it. You get a notification when it is done, and the Library row moves through Processing to Ready on its own.

---

## 2. Workflows: one setup per kind of meeting

**Goal:** stop editing settings between a client call and a standup.

A **workflow** is one saved answer to "how should meetings like this be handled": where the summary is published, which Notion database, which engine writes it, what background the engine is given, whether it is confidential, and what happens to the audio afterwards. You get one called **General** to start with, and you only need more once two kinds of meeting want different answers.

### Making and editing one

Open the Library (menu bar ▸ **Open Library…**). Under the **WORKFLOWS** heading in the left rail:

- **+ New workflow** opens the editor.
- Right-click any workflow row (or swipe it left) for **Edit workflow…** and **Delete workflow…**.
- Selecting a workflow shows a summary of it in the right pane, with **Edit workflow** at its top right.

The menu bar's **Manage Workflows…** is the same editor without opening the Library first.

### How a meeting picks one

Highest priority first:

1. **You picked one** from the chip on the prompt panel.
2. **A learned suggestion.** If you have moved three meetings from the same app to the same workflow, the next prompt arrives with that workflow already chosen and a quiet `Suggested · Undo` under it. Nothing is written to any rule; it is a count with a threshold, and Undo puts the original back.
3. **The workflow's own rules**, matching the app and, optionally, the meeting title.
4. **The default workflow**, which always exists. A recording you start by hand always lands here.

To fix a meeting that went to the wrong place, open it in the Library and pick **Change workflow…** from the `...` menu in the detail header. That rewrites its destinations and background for you, then offers to regenerate the summary or just republish it. Neither happens unless you choose it.

### The context prompt, and why it is worth five minutes

The editor's **Context prompt** is the background the engine is given for every meeting in that workflow, and it is the cheapest quality lever in the app: it costs nothing to tell the model what it would otherwise have to guess. Three things help most:

- **Who is usually in the room and what they do.** This is what turns "someone said they would do it" into an action item with the right owner's name on it.
- **The words this team says out loud** that a transcript will mangle: product names, client names, internal acronyms.
- **What kind of meeting this is.** A standup, a client review, and a one-to-one want different summaries.

A workflow with none carries a quiet `· no context` beside its name in the rail. That is an observation, not a warning; a workflow that genuinely wants none can keep the marker.

### NDA mode

A single switch in the editor with one meaning: meetings in this workflow are summarized on your Mac and written only to your local folder, whatever else the workflow says. It is enforced twice, in the app and again when the summary is produced, so a misconfigured workflow still cannot send a confidential call anywhere.

Two things to know. It applies from the moment you turn it on; it cannot un-publish a meeting that already went out. And moving a meeting into or out of an NDA workflow asks you to confirm, because it changes where that meeting can go.

---

## 3. Vocabulary: teaching it your words

**Goal:** stop your product's name coming out wrong in every transcript.

Transcription is good at ordinary speech and bad at names it has never heard: your company, your clients, your internal jargon. The **Vocabulary** is a list of what-it-hears to what-it-should-say pairs, applied to every new transcript before anything else reads it.

### Clarifying a word where you found it

You will usually notice the problem while reading a transcript, so fix it there:

1. Open the meeting in the Library and go to the **Transcript** tab.
2. Right-click the line with the wrong word and pick **Clarify a word…**.
3. The line is shown at the top of the box. Type the words as they came out wrong, and what they should say.
4. Choose which of the two you want, then press the button. It names what it will do.

The choice is the important part, because the two do very different amounts:

- **Fix this line only** changes that one line, in this one meeting, and nothing else. You can change it back from the same menu.
- **Always fix this** adds the pair to your Vocabulary, so every transcript finished from then on is written the corrected way, including meetings you have not recorded yet. Because a term only reaches an existing meeting through a rebuild, this option also offers to **re-transcribe this meeting afterwards**; tick it and the meeting you are looking at comes back corrected. Leave it off and this meeting keeps the words it has until you rebuild it yourself.

Nothing at all is written until you press one of those buttons. That is deliberate: a garble you cannot decode is safe to open, read, and walk away from, and walking away is often the right answer.

### Adding a term as you correct a line

The other way round works too. Right-click a line, pick **Edit text**, correct the word, and save. If the fix was one word (or two words next to each other), a small box offers to remember the pair, already filled in with what was heard and what you typed. Check the two sides, and press **Add**.

Nothing is written until you press Add, and both sides stay editable until you do. A bigger rewrite deliberately produces no offer at all, rather than guessing at a pair that would be wrong.

### Adding a term the direct way

**Preferences ▸ Pipeline ▸ Vocabulary**. Each row is one pair: what the transcriber hears on the left, how it should be spelled on the right. The **Applies to** picker switches between your global list and a single workflow's own list, so a client's product names can stay with that client's meetings. An empty list shows a greyed example row so you can see the shape; it is display-only and writes nothing.

A workflow's own terms are one click from its editor too, which carries a **Vocabulary…** link that opens this pane with that workflow already selected.

### When terms take effect

Terms are applied when a transcript is finished, so **a new meeting picks them up automatically and an old one does not**. To fix an old meeting, open it and pick **Re-transcribe…** from the `...` menu. That is the one action that rewrites an existing transcript; see [the three re-verbs](#the-three-re-verbs) below for why the other two do not.

### Near-misses

The same group has **Also catch near-misses (one letter off)**, which additionally corrects spellings that are close to a term you listed. It is off by default on purpose: a wrong substitution is worse than a missed one. Turn it on if your terms are long names that come back slightly different every time.

---

## 4. Voices: who said what

**Goal:** get names on the transcript instead of `Speaker 2`, and fix it when it lands on the wrong person.

### The cast strip

Above the transcript lines is a strip naming every voice in the meeting and saying how many of them are actually named. It is the fastest place to start, and it tells apart the two situations that look identical in the lines themselves: **nobody is enrolled yet**, so nothing could have been matched, versus **your list of voices is populated and this one was missed**, which is worth a re-transcribe once you have named them.

Each chip carries two marks, and they mean different things. The coloured dot on the left is that person's colour in the lines below (see [the colours](#the-colours)). The small icon next to it says how the app got their name: your own voice, one matched from your saved voices, one you named here, or one still unnamed.

Click **Name** on an unnamed voice to name it. Right-click a chip for the rest:

- A voice you named in **this** meeting offers **Rename…** and **Un-name**.
- A voice matched from your saved voices offers **Rename everywhere…**, which renames that person here, in your saved voices, and in every past meeting they appear in.
- A voice you introduced line by line has no whole-voice name to change, so its chip offers nothing; fix it on the line instead.

### Naming someone so it sticks

Right-click any line from a voice that has not been named and choose **Name this speaker…**. From then on that voice is recognised automatically in later meetings. It is fully reversible: right-click a named speaker for **Rename…** or **Undo naming**, which also stops later meetings using the name.

Your own on-disk transcript is never altered by any of this. Names are kept alongside it, so undo always restores the original.

### The colours

Every voice in a meeting gets a colour, used for the dot and the name on each of its lines, so you can follow one person down the page without reading the names. It is the same colour on their chip in the strip above, so somebody you spot in the strip is findable in the page, and a line you are reading is findable in the strip. Up to eight voices each get their own; past that the colours start repeating. The colour is fixed for that meeting: quit and reopen the app and everyone is the colour they were. It belongs to the meeting rather than to the person, so the same person can be a different colour in a different meeting.

### Fixing a wrongly attributed line

When two people were merged into one voice, or a line landed on the wrong person, right-click that line and pick **Assign to…**. You can pick anyone already in the meeting, or **New person…** to type a name for someone who was never separated out (a latecomer with two lines, say). Someone you introduce this way joins the meeting's cast, so later lines can go to them without retyping. Cmd-click or Shift-click to select a run of lines and assign them together, and **Reset to original label** undoes it. A line you have moved belongs to whoever it now shows, so right-clicking it again offers to name that person, never the one it came from.

This changes labels only. It does not teach the app a new voice, so your saved voices are untouched.

### Managing the people you have named

**Preferences ▸ Pipeline ▸ People** lists everyone you have named, with **Rename…** and **Remove**. Removing stops a voice being named automatically in future meetings and leaves past transcripts alone. Renaming carries: the past meetings naming that person follow the new name too.

The Library's **People** rail shows the same list with what each person is actually in, their meetings and the commitments they own, and offers the same rename.

### The three re-verbs

These sound alike and do genuinely different things. Pick by what you want changed:

| You want | Use | What it does |
| --- | --- | --- |
| Different **words** in the transcript, or names applied, or a vocabulary term to reach an old meeting | **Re-transcribe…** | Transcribes the audio again with today's vocabulary, your named voices, and the current models. Entirely on your Mac, nothing published, and it keeps the summary you already have. |
| A different **summary** of the same transcript, or a different engine | **Re-summarize with…** | Re-runs the summary over the transcript already on disk and republishes. You pick the engine. |
| To try a **different angle** on the summary before committing | **Reprocess…** | At the foot of the Summary tab. Edit the background the engine is given for this one run and see the candidate side by side with the current one. Keep it or discard it. Never published on its own. |

All three are in the detail header's `...` menu (Reprocess also sits under the summary itself). **Re-transcribe with the current stack…** is the same action for several meetings at once, from the batch panel when you select more than one row.

One thing worth knowing about Re-transcribe: your hand edits are carried over by **time**, not copied across, because the new transcript renumbers everything. Anything with no clear home in the new version is dropped rather than guessed at, and the count is reported when it finishes, so a lost edit is something you are told about.

### After you rename anyone

The transcript and the People rail resolve names every time you open them. The summary does not: it is prose an engine wrote with whatever names existed at the time. So a meeting can read a person's name in the transcript and a cluster label in the summary bullets. The detail header says so, with a **Re-summarize** button beside the sentence. Nothing re-runs on its own, because that is an engine call you should choose.

---

## 5. Finding things

**Goal:** get back to a meeting, or to a sentence inside one.

### The filter bar

Above the meetings list: a search field plus chips for workflow, app, status, and date range. The search field covers **full transcripts**, not just titles and summaries, so a phrase somebody said finds the meeting. Several words are combined, partial words match (`bud` finds `budget`), and case and Cyrillic are handled. The chips narrow within the results; **Clear** wipes everything.

### Quick Find

`⌘K` opens a search box over everything, without opening the Library first. It works from the menu-bar dropdown and, since 2026-08-04, from any MeetingPipe window too. Every query also carries an **Ask about your meetings** row that hands what you typed to [Ask](#6-ask-questions-across-every-meeting), already running. End your query with a question mark and that row leads the list, so type-and-Return is the whole path.

A query that matches nothing is an Ask row rather than a dead end.

### Smart folders

A search worth repeating becomes a rail item. With any filter active, a **folder-plus** button appears beside **Clear**. Click it, name the view, and it pins to the rail under **SMART FOLDERS** where it behaves like any other scope, with its own count and list.

What gets saved is the whole view, not just the text you typed: the rail scope you were in plus every chip. Right-click a folder for **Rename…**, **Update to current view** (re-point it at whatever you are looking at now, keeping its name and place), and **Delete**. Hovering one shows what it is filtering on. Selecting a folder leaves the filter bar live, so you can narrow further inside it and save that as a child.

---

## 6. Ask: questions across every meeting

**Goal:** answer "what did we decide about X" without remembering which meeting it was in.

Open the Library and pick **Ask** in the left rail. Type a question and press **Ask**. The first question builds a searchable index of your library, which takes a while and says how far along it is; later questions reuse it and only re-read the meetings that changed.

**What comes back.** An answer with citations, each one linking to the meeting it came from. Citations are checked before you see them, so one that is shown always resolves to a real meeting.

**What to expect while it runs.** Only one question at a time, which the running card says out loud rather than quietly killing the first. It is safe to walk away: switch to another rail and the run keeps going, so you come back to the answer rather than a blank pane. **Cancel** stops it for real. Answers stack newest-first, so a session reads as a list; they last until you quit the app.

**What it cannot do.** It is not a chat: it answers one question at a time and does not remember the previous one. It only knows what is in your meetings, so it cannot answer from anything else. And it only answers, it never acts: it will not send anything, change anything, or schedule anything.

A confidential workflow keeps Ask on your Mac exactly as it keeps summaries there.

---

## 7. The weekly rhythm

**Goal:** a Friday review that takes ten minutes.

### Digests

**Digests** in the Library rail is a list of dated review summaries. Click **Generate now** for one covering the last week, or turn on a schedule in **Preferences ▸ Pipeline ▸ Weekly digest** and pick the day and time; a Mac asleep at that hour catches up when it wakes.

A digest is a review, not a dump. It shows the commitments this period is actually about, which means the ones raised in the window plus anything already overdue or falling due inside it, grouped by workflow and most-pressing-first. It then says exactly what it left out, and links to Facts for the full list. Age alone never drops an item: a promise from February that is months past due is exactly what a weekly review is for, so it leads the list.

### Facts

**Facts** in the rail gathers every open action and the decisions from the last 30 days, each row linking back to its source meeting. The amber badge on the rail counts what is overdue or due today, so an ageing promise resurfaces without your opening anything.

Actions here are commitments, not occurrences. When a recurring meeting restates the same promise, the restatements group into one row tagged `restated 3x`, and marking that row done closes every instance at once.

### Resolving an action item

Two places, one result. Click the circle beside an action in **Facts**, or beside an action in a meeting's **Summary** tab. The row stays where it is, struck through and dimmed rather than vanishing, and clicking again reopens it.

The done mark is stored with the meeting, so it survives. It does not go out to Notion or Obsidian on its own, though: republish that meeting (the `...` menu's **Republish**) when you want the published page to catch up.

### People

**People** in the rail is one row per person you have named: the meetings they were in, the actions they own, and when you last saw them. It is the same commitments Facts shows, grouped the same way, so marking one done clears it in both places at once. Nobody appears until you name a voice, so it starts empty and says where to go.

---

## 8. Keeping it safe

**Goal:** be able to lose the Mac without losing the meetings.

### Backing up

**Preferences ▸ Storage ▸ Backup**. Choose a destination once (it is remembered) and click **Back up now**. The section shows how long ago the last backup ran, and says so inline if one failed.

Turn on **Automatic backup** for the same thing on a schedule: daily, or a weekday you pick, at a time you pick. Because those runs are unattended, the last-backup line here is where you read their outcome.

The archive carries your recordings and everything written beside them, your settings and workflows, your saved voices and vocabulary, and your corrections. It deliberately does **not** carry your API keys: the archive names which ones you had, but the values themselves are never exported, and you re-enter them by hand. It also leaves out the pre-redaction original recordings, which are the most sensitive thing on your disk and are kept locked down for exactly that reason.

If the destination is on an external drive, a backup refuses to run while the drive is unplugged rather than quietly filling your startup disk.

### Restoring

**Preferences ▸ Storage ▸ Restore from backup…**. Pick an archive and the app reads it first without writing anything, then shows you exactly what a restore would do: how many files land, how many replace files that are already there, and what comes back. Nothing happens until you confirm.

This is the way to undo a retention sweep, recover from a bad batch action, or pull your library back after moving it. It writes into your live library, so same-named files are replaced and there is no undo. Files the backup does not carry are left alone, and the setting naming where your library lives is kept rather than overwritten with the old Mac's.

Setting up a **brand new** Mac is different, because it happens before the app exists there. That path is in the README, under [Moving to a new Mac](../README.md#moving-to-a-new-mac).

### Retention: what happens to the audio

An hour of meeting is about 0.7 GB. **Preferences ▸ Storage** shows what is actually on disk, split by policy, plus the two caches that are safe to throw away. Nothing is deleted without you asking.

The policy itself is per workflow, in the workflow editor under **Audio retention**, because a client call and a standup deserve different answers:

| Policy | What happens |
| --- | --- |
| **Keep the audio forever** | The default. Nothing is ever reclaimed. |
| **Compress it to FLAC** | Same audio, smaller file. Playback, the waveform, and re-transcribing all still work. |
| **Delete the audio** | The transcript, the summary, and everything else stay. The recording is gone, and a deleted recording cannot be re-transcribed. |

A policy only ever touches a meeting that finished and published cleanly. Anything that failed, is waiting for you, or is recording right now is left alone however old it gets, and so is any meeting with no workflow.

### One thing worth checking once

meeting-pipe keeps your meetings on your Mac. It cannot stop macOS syncing a file after it is written, and the default library location is inside iCloud's reach: if **Desktop & Documents Folders** is on in your iCloud settings, your recordings and transcripts are uploading to Apple. The same is true of a library placed inside Dropbox, Google Drive, or OneDrive.

The app checks and tells you: **Preferences ▸ Storage** shows a **Cloud sync** panel naming the provider, with **Move library…** beside it, which asks for a folder outside every sync folder, shows what it will move, and moves it only after you confirm. Under a confidential setup this is reported as a failure rather than a warning, because a synced library breaks the promise no matter what the summarizer does.

---

## 9. Hotkeys and shortcuts

**Goal:** the whole list in one place.

### Global, anywhere in macOS

These four work whatever app you are in. Change any of them in **Preferences ▸ General ▸ Hotkeys**: click the field, press the chord you want, and restart MeetingPipe afterwards.

| Key | Does |
| --- | --- |
| `⌃⌥M` | Start or stop a recording |
| `⌃⌥⇧M` | Stop only, never starts. The panic key |
| `⌃⌥F` | Flag the current moment (while recording) |
| `⌃⌥O` | Start or end an off-the-record stretch (while recording) |

The last three do nothing when nothing is recording.

### In the menu-bar dropdown

Click the menu-bar icon and these keys are shown beside their rows. Most of them act on the open menu, so they are a faster click rather than a global chord. `⌘,` and `⌘K` are the exceptions: both also work from any MeetingPipe window, because a window being open gives the app a menu bar of its own.

| Key | Row |
| --- | --- |
| `⌘L` | Open Library… |
| `⌘K` | Quick Find… |
| `⌘,` | Preferences… |
| `⌘Q` | Quit MeetingPipe |
| `⌥⌘Q` | Quit (do not relaunch) |

**Quit MeetingPipe** is not the one that closes it for good: with launch-at-login on, the app comes back a few seconds later. **Quit (do not relaunch)** is the one that really stops it, and it is only in the menu while something could actually bring the app back. Turn off either **Relaunch after quitting** or **Launch at login** (both under Preferences ▸ General ▸ Startup) and the row goes away, because from then on plain **Quit MeetingPipe** already closes it for good.

### In a window

Open a window and MeetingPipe puts a menu bar across the top of the screen, the way any Mac app does. The usual keys work from there.

| Key | Does |
| --- | --- |
| `⌘C` | Copy what you have selected. Select transcript or summary text and this is how you get it out |
| `⌘A` | Select everything in the field you are typing in |
| `⌘X` / `⌘V` | Cut and paste, in any field you can type in |
| `⌘Z` / `⇧⌘Z` | Undo and redo, in any field you can type in |
| `⌘,` | Open Preferences |
| `⌘K` | Quick Find, the search box over every meeting. Works here as well as from the menu-bar dropdown |
| `⌘M` | Minimise the window to the Dock. Click it there to bring it back |
| `⌘W` | Hides the Library. The app keeps running and the window comes back the way you left it |
| `Space` | Play or pause, on the Transcript and Audio tabs |
| `Return` | Commit a title you are editing in the detail header |
| `Esc` | Close a sheet without saving |
| `⌘` or `⇧` click | Select several meetings in the list, or several lines in a transcript |

Close the last window and the menu bar goes back to whatever app is in front. The recording panel and the Quick Find box are not windows in this sense: they float over other apps deliberately, and the keys above do not reach them.

### Without the keyboard

Every hotkey above has a control: the recording panel carries Stop, the off-the-record toggle, and the flag button on its control row, with the same three on its right-click menu. The menu-bar dropdown carries Start and Stop. Nothing here is keyboard-only.

Recording can also be driven from Shortcuts, Raycast, or a Stream Deck through the `meetingpipe://` links listed in **Preferences ▸ Advanced ▸ Automation**, each with a Copy button.

---

## 10. When something looks wrong

**Goal:** find out what broke without reading a log.

### Start here

**Preferences ▸ Integrations ▸ Run doctor…** is the one check that covers everything: permissions, whether each meeting app is reachable, your keys, your publishing destinations, the on-device model, and how much space the library is using. It names what is broken rather than making you infer it. Run it first for anything you cannot immediately explain.

The menu bar's **Finish setup** row is the shorter version, present only while something is genuinely missing, with each item linking straight to its fix. When it is gone, you are set up.

### The Diagnostics window

The menu bar's **Diagnostics…** opens a read-only view of what the app has been doing, with filters for how far back, what kind of event, and which action. It is the readable version of the logs, and it is where to look when the question is "did it even notice the meeting". **Open Logs Folder** in the same menu gets you the raw files if you want them.

### A meeting that failed

Failed meetings collect in the Library's **Needs you** rail, which carries an amber count. The row names the stage that failed and offers **Retry**, which does the least work that stage needs: a meeting that failed only at publishing republishes the summary already on disk rather than re-doing the whole thing, so a retry after an outage costs nothing and cannot produce a different summary than the one you read.

Some failures lead with a more specific fix than plain Retry, because plain Retry would just fail again. A summary the engine refused because of the language leads with re-summarizing on the on-device model. A confidential meeting that needed a model you have not downloaded leads with **Download model**, then Retry.

A meeting you stopped yourself lands here too, and says so: **Interrupted**, with "You cancelled this run. Reprocess to run it again." Nothing is reported when you press Cancel, since you asked for it; the row is here only so the meeting stays one click from running again rather than looking finished when it is not.

### When a re-transcribe is the answer

Reach for **Re-transcribe…** when the problem is the **words or the voices**, not the summary:

- A name or a product comes out wrong, and you have since added it to your Vocabulary.
- One person is split across several unnamed voices, or two people were merged into one.
- You have named voices since this meeting was recorded and want them applied.

If the transcript is right and the summary is what disappoints, that is **Re-summarize with…** instead. See [the three re-verbs](#the-three-re-verbs).

If the same person keeps being split or merged across meetings, the setting to move is **Speaker separation** in **Preferences ▸ Pipeline ▸ Speaker labels**: **More distinct** when several people collapse into one, **Merge more** when one person splits into many. Quit from the menu bar so the app relaunches and picks it up, then re-transcribe.

The app already ships on **More distinct**, because separating too eagerly is the cheaper mistake: an extra unnamed voice is one naming away from correct, while two people merged into one puts a confidently wrong name on the summary's attendees and its action owners. So if your problem is people being merged, you are already at that end of the dial and moving it will not help. Two things it genuinely cannot fix, worth knowing before you spend an evening on it: a big call with many similar-sounding voices can still merge two of them at any setting, and a sentence that changes speaker part-way through stays one turn whatever you choose, because this setting decides which voice a passage belongs to and never where one passage ends and the next begins. Both are better handled by naming the voices afterwards in the transcript.

### Nothing recorded at all

Open **Preferences ▸ Permissions** and check all four. Accessibility is the one that catches people out: macOS decides whether to trust an app when it launches and does not re-check, so after granting it you have to quit and reopen the app before it does anything. Until then it reads as granted and has no effect.

You can always record by hand with `⌃⌥M` while you sort it out.

### The recording has only one side of the call

- **Only your voice.** Screen Recording is missing, or was granted after the app started. Grant it, then quit and reopen the app.
- **Only the other people.** Your Mac's default input is not the microphone you are talking into, which usually means idle Bluetooth headphones. Set the right input in **System Settings ▸ Sound ▸ Input** before recording. There is deliberately no microphone picker in the app; it follows the system setting. The app notices this case and flags it on the meeting, and the Audio tab always names which microphone a recording used.

### The recording did not stop when the call did

Accessibility is missing, or the meeting app is one whose windows cannot be read. There is a backstop: after a long stretch of silence the recording stops itself, and partway through that stretch you get a "Still meeting?" notification with a Stop button. `⌃⌥⇧M` stops it immediately. The length of that stretch is the **Mic-only silence backstop** slider in **Preferences ▸ Prompt**.

### Anything else

[`README.md`](../README.md#troubleshooting) has the long form, including the failures that only happen with a particular publishing destination or a particular engine.

---

## The words this app uses

Plain-language versions of the terms in this guide and in the app. The engineering glossary, if you ever need it, is in [`ARCHITECTURE.md`](../ARCHITECTURE.md#glossary).

**Workflow.** One saved answer to "how should meetings like this be handled": where the summary goes, which engine writes it, what background that engine gets, whether it is confidential, and what happens to the audio afterwards. See [recipe 2](#2-workflows-one-setup-per-kind-of-meeting).

**Context prompt.** The background you give the engine for every meeting in a workflow: who is usually there, what they do, what the team's words mean.

**Backend, or engine.** The thing that writes the summary. Some run on your Mac and some are a service on the internet, and the app always says which: `Anthropic (cloud)`, `Local MLX (on-device)`, and so on. Transcription is never one of these; it always runs on your Mac.

**BYO.** "Bring your own summary." Record the meeting normally but ask no engine for a summary; paste your own afterwards and publish that.

**NDA mode.** A workflow switch meaning summaries stay on your Mac and are written only to a local folder. Regulated mode is the same idea applied to the whole app rather than one workflow.

**Off the record.** A stretch of a live recording marked to stay out of your notes.

**Flagged moment.** A point in a recording you marked while it was happening, so you can find it again.

**Diarization, or speaker labels.** Splitting the audio into who-said-what. It produces voices, not names; naming them is [recipe 4](#4-voices-who-said-what).

**Cast strip.** The row of voices above a transcript, saying who is in this meeting and how many are named.

**Roster, or your saved voices.** The people you have named. A voice you name once is recognised in later meetings, until you remove it.

**Vocabulary.** Your list of wrong-to-right word pairs, applied to new transcripts. See [recipe 3](#3-vocabulary-teaching-it-your-words).

**Smart folder.** A saved search pinned to the Library rail.

**Digest.** A dated review summary across many meetings, rather than a summary of one.

**Sink, or destination.** Somewhere a summary is published: Notion, an Obsidian vault, a folder on this Mac, or a network share. Each one succeeds or fails on its own; one being down does not block the others.

**Publish, and republish.** Sending the summary to those destinations. Republishing sends the current version again, which is what you do after editing a summary or marking an action done.

**Settled meeting.** One that finished and published cleanly and is not waiting on you. Only settled meetings are touched by an audio retention policy.
