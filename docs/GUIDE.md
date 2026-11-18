# Using meeting-pipe

This is the how-do-I guide: short recipes for the things you actually do with the app, each one a screen or less. It assumes the app is installed and has recorded at least once.

Nothing here sends you somewhere else to look something up: each recipe names the controls you click, in the order you click them, and none of it needs a terminal.

This guide lives in the app. The menu-bar icon's **Guide…** opens it in a window whenever you want it, with the recipes listed down the left.

If you would rather be shown than told, **Tutorial…** in the same menu is a short guided tour: it opens the app's own windows, rings one real control at a time, and says what it is for. Seven stops, and you can leave at any of them. It only ever runs when you pick it.

<!-- repo-only -->
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

Plus [the words this app uses](#the-words-this-app-uses) at the end. In the app that list is the section rail down the left of the window, which is why it is marked repo-only here: two copies of the same contents, one of them dead text, is worse than one.

**Not set up yet?** `docs/SETUP.md`, beside this file, takes a clean Mac to a first summary, and this guide picks up where it stops. The root `README.md` is the reference for every surface and every setting, and the engineering glossary is in `ARCHITECTURE.md`.

**Editing this file?** Everything between `<!-- repo-only -->` and `<!-- /repo-only -->` is dropped before the app renders it. Everything outside those markers is read in a window by somebody with no checkout, so it carries no repo-relative link, no filename used as a filename, and no instruction whose subject is a file rather than a control. Three treatments, in order of preference: **fold the fact in** when the reader needs the fact and not the pointer, **drop the pointer** when the fact already sits somewhere in this guide, and **mark it repo-only** when it genuinely only serves a contributor. The renderer backs that up rather than trusting it, flattening any link it cannot follow down to its label, and `GuideDocumentTests` fails on a link target that contains `../` or ends in `.md` (DOC13).
<!-- /repo-only -->

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

If you ignore the panel it does what **Preferences ▸ Prompt** says after the timeout. By default that is not a skip: the panel folds away and the offer stays. The menu bar reads `Detected <app>`, the menu's top action becomes **Record this `<app>` meeting**, and a notification offers **Start recording**, so you can start late and still get the app chip and the automatic stop. The offer lasts as long as the call does, even with the call in the background: for Teams and Zoom, as long as the app is using your microphone; for other apps and browser meetings, as long as the meeting window is there and about a minute after. While the pointer is over the panel, or its chevron menu is open, the countdown stops, so the panel never closes from under you. If the call seems to end while the panel is up, the panel stays and reads **Call may have ended. Record anyway?**; it only goes away early when the app quits or stops using the microphone.

**Skip** (or the **×**) is the deliberate version: the menu bar reads `Suppressed (<app>)`, nothing asks again about that call, and **Record this `<app>` meeting** is still there if you change your mind. It lasts for that call only, so the next call in the same app is asked about as usual.

**Google Meet in a browser** works a little differently. The Meet tab has to be the selected tab of a window that is on screen, and the app needs Screen Recording to see it; a Meet tab in the background, or behind another tab, does not prompt. A browser prompt never records by itself: if you ignore it, it folds into the offer whatever **Preferences ▸ Prompt** says, and **Always for `<app>`** is not offered for a browser. Skipping a Meet tab only skips that tab, so a different Meet call in the same browser is still asked about.

The same top action covers back-to-back meetings. When a recording ends, the app stops asking about that meeting app for about a minute, which is what keeps a prompt from popping up seconds after you hang up. There is one exception. If the app stopped a recording on its own and then sees a call in the same app within two minutes, it takes that as the stop having been a mistake and starts recording again straight away, without asking, under the workflow its own rules pick, falling back to the one the stopped recording used, and never into a less private one than the default, or than the stopped recording's own if that one was an NDA workflow (a call in a browser tab is the exception: it gets the prompt instead, and never records without a click); the new recording's header reads **Picks up where … stopped** with a **Merge** button that joins the two into one meeting. Switching straight from one Teams call to another while recording is the other case: once the new call's window has held for a few seconds, the app ends the first recording there and asks about the new call, so each call gets its own recording and its own notes; ignore the prompt and it collapses into the usual one-click offer. Otherwise, join another call inside that minute and you will not be prompted for it either, so start it from **Record this `<app>` meeting**, or with the `⌃⌥M` hotkey, which does the same thing here. Either way the recording is attached to the call, so it gets the app chip and stops on its own when you leave, instead of running on until you notice. This is the shorter of the two windows: start the second call promptly and the row is there for it, but once a call has clearly finished (you quit the meeting app, or Teams itself reports the call over) the row goes back to **Start Recording** at once, and after a less certain end within about half a minute rather than lingering. It is also there the moment a recording stops, so if one ends while you are still in the call you can press Record again immediately and stay attached to it, rather than getting a recording with no meeting behind it that will not stop itself.

### Recording by hand

Press `⌃⌥M` anywhere in macOS, or pick **Start Recording** from the menu bar. No meeting required, so it doubles as a voice memo. Press it again to stop. A recording started this way with no meeting running has nothing to watch for an ending, so stopping it is yours to do. A browser tab that later starts or leaves a call does not stop it either, since the app was never watching that tab for this recording. The one safety net is the mic-only silence backstop, which nudges and then stops after a long stretch of quiet (15 minutes by default, on the **Preferences ▸ Prompt** slider). Started while a call is running, it attaches to that call instead and stops on its own when the call ends.

### BYO, when you would rather write the summary yourself

**Record (BYO)** records exactly like a normal meeting but does not ask any engine for a summary. Afterwards, open the meeting in the Library and the **Summary** tab shows a **Paste your summary** box: drop your text in, click **Save & publish**, and it goes to the same destinations a normal meeting would.

Useful for a call you do not want summarized by anything, or one you would rather hand-write. Not available for a regulated or NDA meeting: those never produce a paste-into-a-chat bundle, and the meeting is summarized on your Mac instead.

### If the panel says "Mic lost"

It means the microphone stopped reaching the recording and the app could not get it back, usually after a device was pulled or swapped mid-call. The recording keeps running and still captures the other side of the call, so what you have is a one-sided recording rather than nothing. The panel says so for the rest of the recording rather than only in a notification you might miss, because the file keeps growing either way and there is otherwise no way to tell the two apart. There is nothing to click: stop the recording and start a new one once the microphone is back.

### If the panel says "Disk: 1h 25m left"

The disk your recordings are saved to is running short, and that is how much more of this meeting fits. The app checks when a recording starts and once a minute while it runs, and shows the countdown whenever less than two hours of recording fits. A recording that starts short is never refused: it records, and a notification says how much space is free. If the countdown drops under 15 minutes you get one more notification, and if it reaches the point where there would no longer be room to save what was already recorded, the app stops the recording itself, the same way your Stop button does, so the meeting up to then is kept and processed as normal. Freeing up space while it runs is enough; the countdown follows. A recording uses about 2 GB an hour on disk while it runs and keeps about 230 MB an hour once it stops, which is why the countdown is shorter than the free space suggests.

### If the panel says "Disk falling behind"

The disk your recordings are saved to has stopped keeping up: the app is holding more than 30 seconds of audio it could not write yet. Nothing is lost while the app holds it, and the label stays until the recording ends even if the disk catches up. If the disk never catches up, the app stops the recording itself after roughly another quarter of an hour and keeps everything written up to then, so a slow external or network drive is the thing to check.

### Off the record

For a stretch where what *you* say should not reach your notes, press `⌃⌥O`, or click the **mic-with-a-slash** button on the recording panel (it is also **Go off the record** on that panel's right-click menu). The panel shows a steady **Off the record** state and the voice meter drops to zero until you turn it off again. Press it a second time to resume; an open stretch closes by itself when you stop.

Off the record covers your microphone only. The other people on the call are still recorded, so anything they say during the stretch still reaches the transcript and the summary. If the whole conversation should stay out, stop the recording instead and start a new one afterwards.

What it does to your microphone depends on the workflow. Under an ordinary workflow the microphone keeps recording and your side of the marked stretch is cut out before anything reads the audio, so your voice from it never reaches the transcript, the summary, or anything you publish. The uncut recording is kept on your Mac as a recovery copy, readable only by you and never backed up or synced anywhere, and it is reclaimed after a month or so. Under a workflow in NDA mode, or with regulated mode on, the microphone is silenced for real while the stretch is open, because those modes promise no such audio is kept at all.

If the cut cannot be made (the audio tool it needs is missing, say), the meeting is held back rather than processed: its row in the Library shows it failed and says why, nothing is transcribed or published, and the full recording is moved into the private recovery folder instead of being used. That recording is never deleted automatically, unlike the recovery copies kept when a cut succeeds: the meeting's row offers **Show recording** to reveal it, and **Preferences ▸ Storage** lists its size. The same applies to a workflow set to cut out the stretches where you were muted.

### Flagging a moment

When something is said that you know you will want to find later, press `⌃⌥F`, or click the **flag** button on the recording panel (also **Flag this moment** on its right-click menu). The button itself confirms the press, and then keeps a small count beside the flag of how many moments you have marked in this recording, so you can tell it registered even if you were looking at the call rather than at the panel. The count starts again from nothing on your next recording. The moment shows up in the summary as a flagged moment and as a clickable chip in the **Transcript** tab that jumps you to it.

Both the flag and the off-the-record keys do nothing when no recording is running, so a mistimed press is harmless.

### Stopping

Normally you do not: the app notices the call ended and stops on its own.

It stops at once when it is certain: you quit the meeting app or the browser, or Teams itself logs that the call ended. When it is only fairly sure, because a window went away or you switched to another browser tab, it keeps recording and the recording panel reads **Confirming end** instead of **Recording**. It stops once two separate signs of the end have agreed for a minute, or after 12 minutes when only one ever appeared, and it never stops while Teams is still holding your microphone. If the call was still going, nothing was lost: the panel goes back to **Recording** and carries on. The other way round holds too: once Teams has let go of your microphone for two minutes, a Teams recording stops, even if the app still thinks the call is on; a quick headphone swap is over in seconds and does not count. That stop is final, so if the call really was still on, press Record again. Closing the lid during a call does not end the recording by itself: the time asleep does not count toward any of these waits, and on waking the app checks the call again before deciding anything.

The minutes it kept recording after the call are left out of the transcript and the summary, but stay in the recording. For Teams and Zoom the cut is the moment the app let go of your microphone, so a long stretch of **Confirming end** while the call was really still on is kept, and nothing is cut at all if the microphone was still held. For other apps the cut is where **Confirming end** began, except after the 12-minute wait, which says nothing about when the call ended, so nothing is cut then. If you press Stop while the panel reads **Confirming end**, the same cut applies only when the microphone was released and the call's window or Leave button also went, either after it or in the half minute before it; a microphone that only blinked, say while you swapped headphones, cuts nothing. The one exception: if you minimised the call window, or Teams switched to its compact view, in the half minute before swapping headphones, a Stop pressed during the swap hides the few seconds since it, and **Restore** brings them back. The meeting's **Audio** tab says **Trimmed N min after the call ended** with a **Restore** button, for the rare time the app was wrong: Restore transcribes the whole recording again and rewrites the summary from it. Under an NDA workflow or with regulated mode on, those minutes are deleted when the recording stops instead, because those modes keep no audio from after the call.

Otherwise, press `⌃⌥M` again, click **Stop recording** on the recording panel, or pick **Stop Recording** from the menu bar. `⌃⌥⇧M` is the panic key: it only ever stops, so it can never start a recording by accident. Stopping while a recording is still starting, in the second or so before the panel appears, cancels it: the moment already captured is kept and processed like any short recording, and no second recording starts. After you stop, the menu bar reads **Stopping…** while it finishes writing the recording, and the menu offers no start or stop row until that is done, since neither would do anything. How long that takes depends on how long the meeting was.

After Stop, the Mac transcribes the audio, writes the summary, and publishes it. You get a notification when it is done, and the Library row moves through Processing to Ready on its own. While it works, the row says which part it is on (**Transcribing** while the Mac is turning the audio into words, then **Summarizing** and **Publishing**) and carries a **Cancel** beside it the whole time, from the moment it starts rather than a minute in. Stopping it is safe at any point: nothing is reported as an error, and the meeting stays one click from running again.

Finishing a recording takes a second or two. If it ever takes much longer, you get a notification saying so rather than a row that quietly sits there; the recording itself is safe on disk either way, and quitting the app is always allowed, including mid-recording. Whatever was captured is picked up and finished the next time the app starts. That usually includes the off-the-record stretches, which are still cut out. When MeetingPipe cannot be sure they will be, for example after a crash or a force quit, or a quit that could not finish cleanly or came while the recording was still being finished, a recording with an off-the-record moment is kept aside in MeetingPipe's originals folder instead of being processed, and a notification says so.

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

The editor's **Sinks** are where the workflow's summaries go. Uncheck every one and the workflow publishes nowhere: its summaries stay in the Library and are never published, and the editor says so under the checkboxes. Those meetings still read **Ready** (hover the pill and it says the workflow publishes nowhere) and never land in **Needs you**, because nothing went wrong. To keep a plain Markdown copy on your Mac as well, check **Filesystem** instead.

### How a meeting picks one

Highest priority first:

1. **You picked one** from the chip on the prompt panel. A pick applies only to the meeting it was made for. If the prompt times out into the **Record this `<app>` meeting** offer, the pick stays with that offer, so starting from it records under what you picked (unless you picked a less private workflow than the one the app's own rule would choose: then the offer uses the rule's); skip the meeting, let it end before you answer, or let the offer lapse with the call, and the pick is forgotten rather than carried to the next one.
2. **A learned suggestion.** If you have moved three meetings from the same app to the same workflow, the next prompt arrives with that workflow already chosen and a quiet `Suggested · Undo` under it. Nothing is written to any rule; it is a count with a threshold, and Undo puts the original back.
3. **The workflow's own rules**, matching the app and, optionally, the meeting title. A rule with both fields empty matches nothing, and the editor drops it when you save; a title pattern that is not a valid regular expression cannot be saved. The meeting's title is usually not known yet when recording starts, so a title rule often matches nothing; in an NDA workflow the editor says so under the rule, and a meeting it misses records under the default workflow.
4. **The default workflow**, which always exists. A recording you start by hand always lands here.

If a workflow file in the workflows folder cannot be read (edited by hand into something invalid, say), it is not dropped in silence: it stays in the rail under **Workflows** with a warning sign and the reason, its rules are not applied until you fix or remove the file, and **Run doctor…** reports it as a failure.

To fix a meeting that went to the wrong place, open it in the Library and pick **Change workflow…** from the `...` menu in the detail header. That rewrites its destinations and background for you, then offers to regenerate the summary or just republish it. Neither happens unless you choose it.

### The context prompt, and why it is worth five minutes

The editor's **Context prompt** is the background the engine is given for every meeting in that workflow, and it is the cheapest quality lever in the app: it costs nothing to tell the model what it would otherwise have to guess. Three things help most:

- **Who is usually in the room and what they do.** This is what turns "someone said they would do it" into an action item with the right owner's name on it.
- **The words this team says out loud** that a transcript will mangle: product names, client names, internal acronyms.
- **What kind of meeting this is.** A standup, a client review, and a one-to-one want different summaries.

A workflow with none carries a small question-mark glyph beside its name in the rail; hover it and it says `no context`. That is an observation, not a warning; a workflow that genuinely wants none can keep the marker.

### NDA mode

A single switch in the editor with one meaning: meetings in this workflow are summarized on your Mac and written only to your local folder, whatever else the workflow says. It is enforced twice, in the app and again when the summary is produced, so a misconfigured workflow still cannot send a confidential call anywhere.

Two things to know. It applies from the moment you turn it on; it cannot un-publish a meeting that already went out. And moving a meeting into or out of an NDA workflow asks you to confirm, because it changes where that meeting can go.

One more: an NDA meeting, or any meeting with regulated mode on, never downloads anything, not even the speech models the app uses to write the transcript. On a Mac that has not yet transcribed a meeting the ordinary way, such a meeting fails with "Speech models are not downloaded". Record or retry any ordinary meeting once, so the app fetches them, and then retry the confidential one.

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

- A voice you named in **this** meeting offers **Rename…** and **Un-name**. **Un-name** takes back only the voice sample this meeting added; that person is still recognised from your other meetings, and disappears from your saved voices only if this was their one sample.
- A voice matched from your saved voices offers **Rename everywhere…**, which renames that person here, in your saved voices, and in every past meeting they appear in.
- A voice you introduced line by line has no whole-voice name to change, so its chip offers nothing; fix it on the line instead.

Sometimes an unnamed voice offers a second item that reads **Name as** and then somebody's actual name. That is a voice the app found close to one of your saved voices without being sure enough to use the name on its own. It is a suggestion and nothing else: nothing has been written, and the line under it says the app is not certain. If you know it is right, click it. The voice takes the name here, and that person gains another sample of their voice, which is what makes them recognised on their own next time. If you do not recognise the suggestion, ignore it and name the voice yourself; nothing is left behind either way. A voice the app has no guess about simply does not show the item, which is deliberate: it does not invent one to fill the space.

### Naming someone so it sticks

Right-click any line from a voice that has not been named and choose **Name this speaker…**. From then on that voice is recognised automatically in later meetings. It is reversible: right-click a named speaker for **Rename…** or **Undo naming**, which removes the voice sample this meeting added and nothing else. The person stays recognised from their other meetings (they leave your saved voices only if this meeting was their one sample), and renaming here moves this meeting's sample off the old name the same way. To erase a person from every meeting, use **Remove** on their row in Preferences ▸ Pipeline ▸ People, which asks first.

Your own on-disk transcript is never altered by any of this. Names are kept alongside it, so undo always restores the original.

### The colours

Every voice in a meeting gets a colour, used for the dot and the name on each of its lines, so you can follow one person down the page without reading the names. It is the same colour on their chip in the strip above, so somebody you spot in the strip is findable in the page, and a line you are reading is findable in the strip. Up to eight voices each get their own; past that the colours start repeating. The colour is fixed for that meeting: quit and reopen the app and everyone is the colour they were. It belongs to the meeting rather than to the person, so the same person can be a different colour in a different meeting.

### Fixing a wrongly attributed line

When two people were merged into one voice, or a line landed on the wrong person, right-click that line and pick **Assign to…**. You can pick anyone already in the meeting, or **New person…** to type a name for someone who was never separated out (a latecomer with two lines, say). Someone you introduce this way joins the meeting's cast, so later lines can go to them without retyping. Cmd-click or Shift-click to select a run of lines and assign them together, and **Reset to original label** undoes it. A line you have moved belongs to whoever it now shows, so right-clicking it again offers to name that person, never the one it came from.

This changes labels only. It does not teach the app a new voice, so your saved voices are untouched.

### Managing the people you have named

**Preferences ▸ Pipeline ▸ People** lists everyone you have named, with **Rename…** and **Remove**. Removing stops a voice being named automatically in future meetings and leaves past transcripts alone. Renaming carries: the past meetings naming that person follow the new name too.

If the file that holds the people you have named gets damaged (a hand edit or a sync conflict), naming a speaker sets the damaged copy aside next to it, named `roster.json.corrupt-` and a date, and starts a fresh list instead of writing over it. If the file only cannot be read right now, naming refuses and changes nothing. `mp doctor` reports either case.

The Library's **People** rail shows the same list with what each person is actually in, their meetings and the commitments they own, and offers the same rename.

### The three re-verbs

These sound alike and do genuinely different things. Pick by what you want changed:

| You want | Use | What it does |
| --- | --- | --- |
| Different **words** in the transcript, or names applied, or a vocabulary term to reach an old meeting | **Re-transcribe…** | Transcribes the audio again with today's vocabulary, your named voices, and the current models. Entirely on your Mac, nothing published, and it keeps the summary you already have. |
| A different **summary** of the same transcript, or a different engine | **Re-summarize with…** | Re-runs the summary over the transcript already on disk and republishes. You pick the engine. |
| To try a **different angle** on the summary before committing | **Reprocess…** | At the foot of the Summary tab. Edit the background the engine is given for this one run and see the candidate side by side with the current one. Keep it or discard it. Never published on its own. |

If one of a meeting's edit files (its speaker names, transcript corrections or flagged moments) is damaged, Re-summarize stops and names the file rather than producing a summary without your edits.

All three are in the detail header's `...` menu (Reprocess also sits under the summary itself). **Re-transcribe with the current stack…** is the same action for several meetings at once, from the batch panel when you select more than one row.

One thing worth knowing about Re-transcribe: your hand edits are carried over by **time**, not copied across, because the new transcript renumbers everything. Anything with no clear home in the new version is dropped rather than guessed at, and the count is reported when it finishes, so a lost edit is something you are told about.

The report also tells you when an edit and a vocabulary term have started disagreeing. If you once fixed a word by hand on this meeting, and later added a Vocabulary term that spells the same word the other way, the re-transcribe applies the term to the transcript and then puts your edit back on top of it, because a fix you made on one meeting outranks a rule that applies to all of them. That is the behaviour you want, but it looks exactly like the term not working, so the run names it: *1 of your edits now disagrees with a vocabulary rule*. If the rule is the one you meant, open that line and edit it again to match, and the two stop fighting.

### After you rename anyone

The transcript and the People rail resolve names every time you open them. The summary does not: it is prose an engine wrote with whatever names existed at the time. So a meeting can read a person's name in the transcript and a cluster label in the summary bullets. The detail header says so, with a **Re-summarize** button beside the sentence. Nothing re-runs on its own, because that is an engine call you should choose.

---

## 5. Finding things

**Goal:** get back to a meeting, or to a sentence inside one.

### The filter bar

Above the meetings list: a search field plus chips for workflow, app, status, and date range. The search field covers **full transcripts**, not just titles and summaries, so a phrase somebody said finds the meeting. Several words are combined, partial words match (`bud` finds `budget`), and case and Cyrillic are handled. Titles and summaries narrow the list on every key; meetings that match only in the transcript join a moment after you stop typing. A single letter searches titles and summaries only; transcripts join from the second letter. Right after an update the search box may say **Indexing transcripts…** the first time you open the Library, while it re-reads them once. The chips narrow within the results; **Clear** wipes everything.

### Quick Find

`⌘K` opens a search box over everything, without opening the Library first. It works from the menu-bar dropdown and, since 2026-08-04, from any MeetingPipe window too. Every query also carries an **Ask about your meetings** row that hands what you typed to [Ask](#6-ask-questions-across-every-meeting), already running. End your query with a question mark and that row leads the list, so type-and-Return is the whole path.

A query that matches nothing is an Ask row rather than a dead end.

### Smart folders

A search worth repeating becomes a rail item. With any filter active, a **folder-plus** button appears beside **Clear**. Click it, name the view, and it pins to the rail under **SMART FOLDERS** where it behaves like any other scope, with its own count and list.

What gets saved is the whole view, not just the text you typed: the rail scope you were in plus every chip. Right-click a folder for **Rename…**, **Update to current view** (re-point it at whatever you are looking at now, keeping its name and place), and **Delete**. Hovering one shows what it is filtering on. Selecting a folder leaves the filter bar live, so you can narrow further inside it and save that as a child.

### Copying a meeting into a chat

Sometimes the place it needs to go is a message somebody is waiting on, not a note or a page. Open the meeting, click the `...` menu on its header, and pick **Copy summary (formatted)** or **Copy transcript (formatted)**. Paste into a Teams chat, an email, a note, anywhere: the headings, bullets and bold arrive as formatting rather than as a wall of `#` and `-` characters.

Your paste-without-formatting still works. Press `⌘⇧V` instead of `⌘V` and the same text arrives plain. That is not a separate mode you have to pick, it is the same copy: the app puts a formatted version and a plain version on the clipboard together, and whichever you ask for is the one you get. Some fields take no formatting from anybody, Google Meet's in-call chat being the common one, and those simply get the plain version and read fine.

The transcript copies the names you see. Someone you have named comes across under their name, a voice nobody has named yet comes across as **Speaker 1** or **Unknown A** exactly as the Transcript tab shows it, and any line you fixed by hand comes across fixed. What is stored in the file underneath is not what gets copied.

Nothing leaves your Mac when you do this and nothing is re-generated, so it works on a confidential meeting like any other. If the meeting has no summary yet, the app says so and leaves your clipboard alone rather than letting you paste whatever was on it before.

---

## 6. Ask: questions across every meeting

**Goal:** answer "what did we decide about X" without remembering which meeting it was in.

Open the Library and pick **Ask** in the left rail. Type a question and press **Ask**. The first question builds a searchable index of your library, which takes a while and says how far along it is; later questions reuse it and only re-read the meetings that changed.

**What comes back.** An answer with citations, each one linking to the meeting it came from. Citations are checked before you see them, so one that is shown always resolves to a real meeting.

A link inside an answer or a summary is written by the model, so the app treats it with suspicion: a web link shows you its full address and waits for your yes before it opens, and a link to anything other than a web page or an email address is shown as plain text and does nothing.

**What to expect while it runs.** Only one question at a time, which the running card says out loud rather than quietly killing the first. It is safe to walk away: switch to another rail and the run keeps going, so you come back to the answer rather than a blank pane. **Cancel** stops it for real. Answers stack newest-first, so a session reads as a list; they last until you quit the app.

**What it cannot do.** It is not a chat: it answers one question at a time and does not remember the previous one. It only knows what is in your meetings, so it cannot answer from anything else. And it only answers, it never acts: it will not send anything, change anything, or schedule anything.

**Confidential meetings are not in Ask at all.** A meeting recorded under an NDA workflow is left out of the searchable index, so Ask cannot quote it and cannot cite it, whichever engine is answering. So are meetings recorded before workflows existed, which have no record of whether they were confidential: the app treats "we never wrote it down" as "do not use it" rather than guessing. If a meeting you expect is missing from an answer, that is usually why. The same rule governs the suggested questions on the empty Ask screen: they are built only from meetings Ask can see, so a left-out meeting's title or workflow name never appears in one. When every meeting you have is left out, the screen says how many are and why, instead of claiming nothing has been recorded.

### Asking from another app

**Goal:** ask the same questions from Claude Code, Claude Desktop, or another AI tool, without leaving what you are doing.

Turn on **Let AI tools read your meetings** in **Preferences ▸ Integrations ▸ Model Context Protocol**, then point your tool at the `mp mcp-serve` command. Your tool can then search your meetings, read one, pull part of a transcript, list meetings, and list what you still owe people.

**It is off until you turn it on, and that is deliberate.** Everywhere else, this app decides what leaves your Mac. Here the other tool decides what to ask for, and anything it reads has gone to whoever runs that tool. So it starts off, and turning it off again stops it.

**The same meetings stay out.** Confidential meetings, and meetings with no record of whether they were confidential, are never handed over, and there is no setting that changes that. To the other tool they look exactly like meetings that do not exist, so it cannot even tell that it is being kept from something. While regulated mode is on, every meeting is held back, the older ones too, and a tool that was already connected finds nothing from its next question on. The panel shows you both numbers, how many meetings are reachable and how many are held back, with the reason.

**Two things it cannot do.** It cannot change anything: there is no way for a connected tool to re-summarize, publish, edit, or delete. And it is not on your network. It talks to one program you started, on this Mac, so nothing else can connect to it.

---

## 7. The weekly rhythm

**Goal:** a Friday review that takes ten minutes.

### Digests

**Digests** in the Library rail is a list of dated review summaries. Click **Generate now** for one covering the last week, or turn on a schedule in **Preferences ▸ Pipeline ▸ Weekly digest** and pick the day and time; a Mac asleep at that hour catches up when it wakes.

A digest is a review, not a dump. It shows the commitments this period is actually about, which means the ones raised in the window plus anything already overdue or falling due inside it, grouped by workflow and most-pressing-first. It then says exactly what it left out, and links to Facts for the full list. Age alone never drops an item: a promise from February that is months past due is exactly what a weekly review is for, so it leads the list.

One thing to know before you turn the schedule on. The digest reads every meeting on your Mac, and then asks an engine to write the few sentences at the top. Collecting the facts happens here; writing those sentences happens wherever your summaries happen. So if your summaries go to a cloud engine, a slice of your open actions and decisions across every workflow goes there too, once a week, with nobody watching. If you would rather keep that on your Mac, turn on **Keep the digest on this Mac** in the same Preferences group. It is a little worse at writing and it changes nothing else. The text under those controls always names the engine that will actually do the writing, so you can check rather than remember.

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

A backup also refuses when your recordings folder is missing (its drive is unplugged, or the folder setting points somewhere else), when a folder inside it cannot be read, or when it suddenly holds no files at all although the last backup had some. The Backup section then says the backup failed and why, and your older backups stay as they were. If the library shrank sharply but is not empty, the backup still runs, but none of the older backups are deleted that time.

**Keep backups on an encrypted disk.** A backup holds every recording, transcript and voice sample you have. On your Mac's own disk the archive is readable only by your account, and so is a backup folder the app creates. An external drive usually ignores whose files are whose, though, so on a drive that is not encrypted (most USB sticks, and any drive formatted for Windows) anyone who picks the drive up can read it. A backup to such a drive still runs, and the last-backup line then ends with **to a drive that is not encrypted**, or **may not be encrypted** for a network share or a drive the app could not check. Use your Mac's own disk with FileVault on, or a drive you erased as encrypted APFS in Disk Utility.

**How many backups the folder keeps.** Every archive is a full copy of your library, so after each successful backup the oldest ones in that folder are deleted. What stays is the newest 7, plus one from each of the 4 weeks before those, so a daily schedule holds at most 11. Every archive in that folder named like `meeting-pipe-backup-<date>-<time>.tar.gz` counts toward this, including ones you made by hand. To keep one for good, rename it (anything that no longer fits that name) or move it to another folder.

**When there is no room.** Before writing anything, a backup checks that the destination has room for the whole archive. If it does not, it refuses without writing anything, and the Backup section says the backup failed and why: how much is free, how much it needs, and how many backups the folder already holds. The same goes for a drive that is unplugged, and a restore that cannot read an archive says what was wrong with it. When the destination is on the same disk as your library it also leaves about 4.6 GB free, enough for a two-hour recording, so a backup never takes the space your next meeting needs.

### Restoring

**Preferences ▸ Storage ▸ Restore from backup…**. Pick an archive and the app reads it first without writing anything, then shows you exactly what a restore would do: how many files land, how many replace files that are already there, and what comes back. Nothing happens until you confirm.

This is the way to undo a retention sweep, recover from a bad batch action, or pull your library back after moving it. It writes into your live library, so same-named files are replaced and there is no undo. If the disk does not have room, the restore says so before writing anything; and if it stops part way (a drive unplugged, say), each file is either the old one or the restored one, never half written, and running the restore again finishes it. Files the backup does not carry are left alone, and the setting naming where your library lives is kept rather than overwritten with the old Mac's.

Setting up a **brand new** Mac is the one case this window cannot walk you through, because it all happens before the app exists on that Mac: you install it there first, and the restore runs from the Terminal rather than from Preferences. Your keys do not come across either way, so you re-enter those by hand once. What you can do from here is make sure there is a recent archive to restore, which is the section above.

### Retention: what happens to the audio

An hour of meeting keeps about 230 MB. **Preferences ▸ Storage** shows what is actually on disk, split by policy, plus the two caches that are safe to throw away, and how much the library grew over the last 30 days with how long the free space lasts at that rate. Nothing is deleted without you asking.

The policy itself is per workflow, in the workflow editor under **Audio retention**, because a client call and a standup deserve different answers:

| Policy | What happens |
| --- | --- |
| **Keep the audio forever** | The default. Nothing is ever reclaimed. |
| **Compress it to FLAC** | Same audio, smaller file. Playback, the waveform, and re-transcribing all still work. |
| **Delete the audio** | The transcript, the summary, and everything else stay. The recording is gone, and a deleted recording cannot be re-transcribed. |

A policy only ever touches a meeting that finished and published cleanly. Anything that failed, is waiting for you, or is recording right now is left alone however old it gets, and so is any meeting whose workflow you deleted. A meeting recorded with no workflow, such as one you started by hand, follows the default workflow's policy, so setting a policy on the default covers those too; with the default on **Keep the audio forever**, as it ships, they are kept.

### Moving the library, or pointing at another folder

Where your recordings live is shown, not typed, in **Preferences ▸ Recording** (and again as **Recordings folder** in **Preferences ▸ Storage**). Beside it are two buttons. **Move library…** moves the whole folder, with the `digests` folder beside it, somewhere else: it shows what it will move and how much, and moves it only after you confirm. **Use another folder…** moves nothing: new recordings go to the folder you pick and the Library shows that folder, while your current library stays where it is and stops showing until you point back at it. It asks before it changes anything too. Both refuse while a recording or a summary is in progress, and the Library follows the change straight away, with no restart.

If the Library ever says **Your recordings folder is not at** a path, the folder it was set to is not there: renamed, moved in Finder, or on a drive that is not plugged in. Nothing was deleted. Plug the drive back in, or press **Choose folder…** and pick the folder that holds your recordings.

### One thing worth checking once

meeting-pipe keeps your meetings on your Mac. It cannot stop macOS syncing a file after it is written, and the default library location is inside iCloud's reach: if **Desktop & Documents Folders** is on in your iCloud settings, your recordings and transcripts are uploading to Apple. The same is true of a library placed inside Dropbox, Google Drive, or OneDrive.

The app checks and tells you: **Preferences ▸ Storage** shows a **Cloud sync** panel naming the provider, with **Move library…** beside it (the same button is always in **Preferences ▸ Recording**), which asks for a folder outside every sync folder, shows what it will move, and moves it only after you confirm. Under a confidential setup this is reported as a failure rather than a warning, because a synced library breaks the promise no matter what the summarizer does. The check is not only about the library: `mp doctor` also looks at the folder your summaries are published to, your backup folder, and your Obsidian vault. And when you choose a backup folder in **Preferences ▸ Storage**, the app tells you if that folder is inside a sync folder, because every backup archive carries your recordings and transcripts; it does not stop you, it just names the provider.

Under a confidential setup the app goes further than naming. The first regulated or NDA recording of a session over a synced library posts one notification naming the provider, with a **Move library…** button that opens the Storage pane; it never stops the recording. A meeting that is regulated or in an NDA workflow is not published to a local folder that a sync client owns: the Library row says **The publish folder is synced**, the summary stays in your library, and it publishes once you choose a folder outside the synced tree. A backup to a synced folder is refused the same way when your library holds any such meeting. And **Record (BYO)** is declined for them, since its whole point is to paste the transcript into a cloud chat: the meeting is summarized on your Mac instead.

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
| `⌘A` | Select everything in the field you are typing in, or every meeting in the list when the list has the focus |
| `⌘X` / `⌘V` | Cut and paste, in any field you can type in |
| `⌘Z` / `⇧⌘Z` | Undo and redo, in any field you can type in |
| `⌘,` | Open Preferences |
| `⌘K` | Quick Find, the search box over every meeting. Works here as well as from the menu-bar dropdown |
| `⌘M` | Minimise the window to the Dock. Click it there to bring it back |
| `⌘W` | Hides the Library. The app keeps running and the window comes back the way you left it |
| `Space` | Play or pause, on the Transcript and Audio tabs. Once audio is playing, a play/pause control and the position also appear in the meeting's header, so you can stop it from the Summary tab without going back. Closing the Library window, or leaving the meeting for another view, pauses it |
| `Return` | Commit a title you are editing in the detail header |
| `Esc` | Close a sheet without saving |
| `⌘` or `⇧` click | Select several meetings in the list, or several lines in a transcript |
| `↑` `↓` | Move the selection through the meeting list (add `⇧` to extend it); click a meeting first so the list has the focus |

Close the last window and the menu bar goes back to whatever app is in front. The recording panel and the Quick Find box are not windows in this sense: they float over other apps deliberately, and the keys above do not reach them.

### Without the keyboard

Every hotkey above has a control: the recording panel carries Stop, the off-the-record toggle, and the flag button on its control row, with the same three on its right-click menu. The menu-bar dropdown carries Start and Stop. Nothing here is keyboard-only.

Recording can also be driven from Shortcuts, Raycast, or a Stream Deck through the `meetingpipe://` links listed in **Preferences ▸ Advanced ▸ Automation**, each with a Copy button. A link that starts or stops a recording or builds a digest shows a small panel first, because any app or web page can open one; press Return or click the action to go ahead. An Ask link fills in the question and waits for you to press Ask.

---

## 10. When something looks wrong

**Goal:** find out what broke without reading a log.

### Start here

**Preferences ▸ Integrations ▸ Run doctor…** is the one check that covers everything: permissions, whether each meeting app is reachable, your keys, your publishing destinations, the on-device model, and how much space the library is using. It names what is broken rather than making you infer it. Run it first for anything you cannot immediately explain.

The menu bar's **Finish setup** row is the shorter version, present only while something is genuinely missing, with each item linking straight to its fix. When it is gone, you are set up.

### The Diagnostics window

The menu bar's **Diagnostics…** opens a read-only view of what the app has been doing, with filters for how far back, what kind of event, and which action. It is the readable version of the logs, and it is where to look when the question is "did it even notice the meeting". If it also says some unreadable lines were skipped, a log line got damaged as it was written and is left out of the list; one now and then is harmless, but it means that moment may be missing an entry. **Open Logs Folder** in the same menu gets you the raw files if you want them.

### A row that says Stalled

While a meeting is processing, its row in the Library shows the step it is on and how long the whole run has taken. **Stalled** means the app has stopped seeing signs of life, and it is only ever a warning: nothing is cancelled, and **Cancel** is always there if you would rather stop. It appears in two shapes. If the row stops updating at all, the processing step has gone quiet for half a minute, and the flag clears by itself the moment it starts reporting again. If the row keeps counting but reads something like **Summarizing, no reply for 1:40**, the step is running but has not finished a piece of work for a minute and a half, which is the picture of a request waiting on a slow or unreachable service; it clears when a reply comes in. A slow start is not a stall: starting the step can take a minute on a busy Mac, and the app waits two minutes for the first sign of life before it says anything.

### A meeting that failed

Failed meetings collect in the Library's **Needs you** rail, which carries an amber count. Open one to see a short explanation and its next action below the tabs. **Retry summary** reuses a complete saved transcript; **Retry publishing** uses the saved summary without another model call. If a usable transcript is missing, **Retry** starts from the recording. The configured engine and the meeting's privacy rules still apply.

An **Insufficient Anthropic credits** notice means the provider reported a credit problem. Choose **Open billing**, resolve it in your provider account, then retry. It does not mean your key expired. Missing or rejected keys lead to **Open Integrations**; expiry is named only when the provider explicitly reports it. A notice that says the provider **does not recognise the model** means the model id in **Preferences > Pipeline** was retired, mistyped or is not open to your account. Choose **Model settings** and pick another; retrying cannot help. On the Auto engine the meeting is summarized on your Mac instead, so you still get a summary. An unknown failure gets a short explanation without guessing its cause.

**Details…** opens selectable, scrollable local diagnostics in a fixed-size sheet. Use **Close** or Escape to return. The **Report preview** shows exactly what **Copy report** puts on the clipboard: app version, time, operation, cause, and any known provider, status, or request identifier. The report excludes the traceback, credentials, meeting titles, personal paths, and meeting content. Previewing and copying work offline and send nothing. Ask, Digests, People, and Preferences use the same Details control; an error notification opens its meeting when one is known.

A summary that failed for a reason a retry can fix, such as a timed-out request to the summarizing service, is retried once automatically: a minute and a half after the app starts, or as soon as the next meeting finishes processing, whichever comes first. A meeting recorded with **Record (BYO)** is never retried for you, and a second failure is left for you. If a meeting is still failed a day later, the app shows one notification when it starts, naming how many; clicking it opens the Library on the oldest.

Once you press Retry the button steps aside and the pane says what is happening, so you can tell the click landed without pressing it again; pressing it repeatedly queues one run, not one per press.

Some failures lead with a more specific fix than plain Retry, because plain Retry would just fail again. A summary the engine refused because of the language leads with re-summarizing on the on-device model. A confidential meeting that needed a model you have not downloaded leads with **Download model**, then Retry.

A confidential meeting, or one whose workflow keeps the summary on your Mac, can also be held before anything runs: "This meeting's workflow settings could not be saved, so it was not processed." That happens when the meeting's settings file could not be written as the recording stopped, most often because the disk was full. Nothing was transcribed or sent. Free some space, then **Retry**; the settings are rebuilt from the copy saved when the recording started before the meeting is processed, so it keeps its confidential handling. A meeting whose settings file exists but cannot be read is treated the same careful way: it shows **Local only** and is summarized on your Mac until the file reads again.

Ask uses a separate search model. If that model is missing during a confidential run, **Details…** retains the specific download command to run before asking again; downloading the summary model does not install the search model.

A meeting whose processing got stuck lands here on its own, so the meetings behind it are not held up. "Transcription did not finish" means turning the recording into words was still running long after it should have ended, so the app stopped it and went on to the next meeting; nothing was published. **Retry** runs it again. If the same meeting stops the same way twice, quit and reopen MeetingPipe from the menu bar, then **Retry**. With Apple Intelligence as the summary engine, "Apple Intelligence did not answer" is the same kind of stop at the summary step: the transcript is saved, and **Retry** asks again.

A meeting you stopped yourself lands here too, and says **Processing cancelled**. Quitting or restarting the app stops a run in progress rather than leaving it working out of sight, and that meeting says **Processing interrupted** when the app comes back; **Retry** resumes it. Cancel sends no error notification; the row remains available to resume when you choose.

A recording that was cut short (the app was quit hard, crashed, or could not finish writing it) is normally finished and processed on its own, usually right away and at the latest the next time the app starts. If one sat unfinished for more than a day, the app stops picking it up by itself and the menu bar shows **N unfinished recordings from earlier** under the failed row instead. Its submenu offers **Recover**, which finishes and processes them like any other recording, and **Discard**, which moves their audio out of your library into MeetingPipe's private originals folder. Discard deletes nothing; **Preferences ▸ Storage** lists what is kept there.

### When a re-transcribe is the answer

Reach for **Re-transcribe…** when the problem is the **words or the voices**, not the summary:

- A name or a product comes out wrong, and you have since added it to your Vocabulary.
- One person is split across several unnamed voices, or two people were merged into one.
- You have named voices since this meeting was recorded and want them applied.

If the transcript is right and the summary is what disappoints, that is **Re-summarize with…** instead. See [the three re-verbs](#the-three-re-verbs).

If the same person keeps being split or merged across meetings, the setting to move is **Speaker separation** in **Preferences ▸ Pipeline ▸ Speaker labels**: **More distinct** when several people collapse into one, **Merge more** when one person splits into many. Quit from the menu bar so the app relaunches and picks it up, then re-transcribe.

The same group has **Clean up speaker labels after transcription**, which asks the model to merge labels that are one person after each new meeting. It works with every summarization engine. With Apple Intelligence it uses the local model on this Mac, since Apple Intelligence only writes summaries; with any other engine it uses that engine.

The app already ships on **More distinct**, because separating too eagerly is the cheaper mistake: an extra unnamed voice is one naming away from correct, while two people merged into one puts a confidently wrong name on the summary's attendees and its action owners. So if your problem is people being merged, you are already at that end of the dial and moving it will not help. Two things it genuinely cannot fix, worth knowing before you spend an evening on it: a big call with many similar-sounding voices can still merge two of them at any setting, and a sentence that changes speaker part-way through stays one turn whatever you choose, because this setting decides which voice a passage belongs to and never where one passage ends and the next begins. Both are better handled by naming the voices afterwards in the transcript.

### Nothing recorded at all

Open **Preferences ▸ Permissions** and check all four. Accessibility is the one that catches people out: macOS decides whether to trust an app when it launches and does not re-check, so after granting it you have to quit and reopen the app before it does anything. Until then it reads as granted and has no effect.

You can always record by hand with `⌃⌥M` while you sort it out.

If a notification said **Restart MeetingPipe to keep recording**, that is the cause, and permissions are fine. The Mac's audio system stopped answering several times, so the app stopped asking rather than freeze, and it will not start a recording until it is reopened. Quit and reopen the app; if the notification comes back soon after, restarting the Mac is the reliable reset for the audio system itself.

### The Library is empty and says it can't read the folder

The meetings are still there; the app has lost permission to open the folder they are in. If the message offers **Open Privacy & Security**, turn MeetingPipe back on under **Files and Folders** there, and the list comes back without a restart. Otherwise press **Reveal in Finder** and check the folder: a drive that is not responding or a folder whose permissions changed after a restore are the usual causes. **Run doctor…** shows the same thing as a failing **library.readable** row.

### The recording has only one side of the call

- **Only your voice.** Screen Recording is missing, or was granted after the app started. Grant it, then quit and reopen the app.
- **Only the other people.** Your Mac's default input is not the microphone you are talking into, which usually means idle Bluetooth headphones. Set the right input in **System Settings ▸ Sound ▸ Input** before recording. There is deliberately no microphone picker in the app; it follows the system setting. The app notices this case and flags it on the meeting, and the Audio tab always names which microphone a recording used.
- **You, but very quietly.** The microphone works but records you far too softly, often the built-in one with its input level low. After about five minutes of a call where your voice has barely reached a speaking level, the recording panel reads **Mic very quiet** instead of **Recording**; point at it to see which microphone it means, and click it to make it go away. When the recording stops you also get a notification saying the same. If you were talking, open **System Settings ▸ Sound ▸ Input**, raise that microphone's input level or choose another one, and carry on. If you hardly spoke in that meeting, you can ignore it.
- **The other people are missing for part of it.** A notification at the end, **Part of the other side is missing**, says roughly how long. The other side's audio started late or stopped early, often after a brief loss of system audio that recovered by itself, so your own voice is all there is for that stretch. Nothing needs fixing for the next meeting unless it keeps happening; if it does, **Diagnostics…** in the menu bar shows which side was short and why.

### The recording is shorter than the meeting was

You get a notification at the end when a finished recording holds noticeably less audio than the time it was running, so this is something the app tells you rather than something you find out weeks later. Play the meeting back before you rely on its summary, and if it keeps happening, **Diagnostics…** in the menu bar shows the recorder's own account of each recording.

The cause that used to be behind it was the app's own doing and is fixed. When only one side of the call was being captured, the finished file used to end where that side stopped, taking the rest of your own voice with it. Now the short side is padded with silence, and a side that started late is placed where it actually began, so the recording is as long as the meeting was. The same goes for meetings over about three hours, which could lose the end of the other side of the call before.

### A notification said "Recording stopped" in the middle of a meeting

If the notification says the disk was almost full, the app stopped on purpose while there was still room to save the recording: everything up to that point was kept and is processed as normal, and the panel's "Disk: ... left" countdown (see Recording a meeting) was the warning. Free up space before the next meeting.

Otherwise, the app could not keep saving the audio, so it stopped the recording rather than carry on capturing nothing. Everything up to that point was kept and is processed as normal. If the notification says the disk is full, it names the disk and how much space is left: free up space before the next meeting. If it says the folder recordings are saved to stopped responding, nothing was failing but the audio was piling up waiting to be saved, which happens when that folder is on a network drive or a cloud drive that hung: put the library back on this Mac before the next meeting (for a synced folder, **Move library…** in **Preferences ▸ Storage** does it). If it does not mention the disk or the folder, the app could not tell why, and **Preferences ▸ Integrations ▸ Run doctor…** is the place to look.

### The recording did not stop when the call did

If the recording panel reads **Confirming end**, the app has noticed the call probably ended and is making sure: it stops within a minute when a second sign agrees, or after 12 minutes when none does, and the extra minutes are left out of your notes (see [Stopping](#stopping) for exactly where the cut falls). It keeps going for as long as Teams holds your microphone, because that is the surest sign the call is still up, and a Teams recording stops two minutes after Teams lets go of it. See [Stopping](#stopping). Otherwise:

Accessibility is missing, or the meeting app is one whose windows cannot be read. There is a backstop: after a long stretch of silence the recording stops itself, and partway through that stretch you get a "Still meeting?" notification with a Stop button. `⌃⌥⇧M` stops it immediately. The length of that stretch is the **Mic-only silence backstop** slider in **Preferences ▸ Prompt**. The stretch only counts while the other side of the call can be heard: if the recording panel says **System audio not captured**, the far side is not reaching the recording, and the backstop waits rather than treating your muted mic as an empty call. The app retries once by itself; if the notice stays, **Retry system audio** on the panel is the fix, and the backstop picks up again once audio is flowing.

### Preferences says your last change was not saved

A row above every pane reads "Your last change was not saved", and the menu bar has a row saying a setting was not saved. The switch or field you changed still shows your new value, but it never reached the settings file (or, for an API key, the Keychain), so the next summary runs on the old one. Usually the disk is full or the settings folder lost its write permission; for a key, the Keychain refused it (open Keychain Access and check the login keychain is unlocked). Fix that, then click **Try again**; both rows clear once the change lands. If the row says the key has a character that cannot be stored, Try again will not help: paste the key again, whole. **Reveal in Finder** shows the settings file when that is the one that failed. Changing the control again also retries.

### Preferences says the settings file has a syntax error

Every pane in **Preferences** shows one row instead of its controls: "config.toml has a syntax error at line N". The settings file, `~/.config/meeting-pipe/config.toml`, was edited by hand and something in it no longer reads, often a missing bracket or quote on the line named. Nothing in it has been lost: the app will not save over a file it cannot read, so every setting you had is still there, waiting for the typo to be fixed. Until then the app plays safe. It runs as if **Regulated mode** were on, so nothing leaves your Mac, and every other setting sits at its default. Meetings still record, but their summaries fail until the file is fixed, because the summarizer reads the same file; once it reads again, **Retry** on the failed meeting picks it up. Click **Open in editor** on that row, fix the line it names and save; the panes come back with your settings in them a moment later (closing and reopening Preferences does the same).

The same row can name **Regulated mode** instead of a line: the file reads, but its regulated switch is written as something other than `true` or `false`, or it sits outside its `[modes]` section, usually because `modes.regulated_mode = true` was added at the bottom of the file. The app treats that as on until you fix it, and summaries stop until then too. Put `regulated_mode = true` (or `false`) on its own line under a `[modes]` heading.

### Anything else

Two families of failure are worth naming, because both read as the app being broken and neither is.

**A destination refused it.** Every place a summary publishes succeeds or fails on its own, so a Notion page that will not write does not stop the copy going to Obsidian or your folder. The **Needs you** row names the destination that failed, **Run doctor…** says why (a key that expired, a database the integration was never shared with, a share that is not mounted), and **Retry** sends the summary already on disk rather than writing a new one.

**An engine refused it.** A summary written on your Mac needs its model downloaded and enough free memory to run it, and when either is missing it stops with the reason rather than taking the Mac down: it names the model to fetch, or the memory it wanted against what was free. The row leads with whichever fix applies, so the fix is a click rather than a diagnosis. A cloud engine's refusals arrive the same way, with the key or the limit named.

---

## The words this app uses

Plain-language versions of the terms in this guide and in the app.

**Workflow.** One saved answer to "how should meetings like this be handled": where the summary goes, which engine writes it, what background that engine gets, whether it is confidential, and what happens to the audio afterwards. See [recipe 2](#2-workflows-one-setup-per-kind-of-meeting).

**Context prompt.** The background you give the engine for every meeting in a workflow: who is usually there, what they do, what the team's words mean.

**Backend, or engine.** The thing that writes the summary. Some run on your Mac and some are a service on the internet, and the app always says which: `Anthropic (cloud)`, `Local MLX (on-device)`, and so on. Transcription is never one of these; it always runs on your Mac. Which Anthropic model does the writing is **Anthropic model** in **Preferences ▸ Pipeline ▸ Summarization**.

**BYO.** "Bring your own summary." Record the meeting normally but ask no engine for a summary; paste your own afterwards and publish that.

**NDA mode.** A workflow switch meaning summaries stay on your Mac and are written only to a local folder. Regulated mode is the same idea applied to the whole app rather than one workflow.

**Off the record.** A stretch of a live recording where your microphone is cut out of your notes. The other side of the call is still transcribed.

**Flagged moment.** A point in a recording you marked while it was happening, so you can find it again.

**Diarization, or speaker labels.** Splitting the audio into who-said-what. It produces voices, not names; naming them is [recipe 4](#4-voices-who-said-what).

**Cast strip.** The row of voices above a transcript, saying who is in this meeting and how many are named.

**Roster, or your saved voices.** The people you have named. A voice you name once is recognised in later meetings, until you remove it.

**Vocabulary.** Your list of wrong-to-right word pairs, applied to new transcripts. See [recipe 3](#3-vocabulary-teaching-it-your-words).

**Smart folder.** A saved search pinned to the Library rail.

**Digest.** A dated review summary across many meetings, rather than a summary of one. Confidential meetings, and meetings with no record of whether they were confidential, are left out of it.

**MCP.** A common way for AI tools to reach the things on your computer. Here it is one read-only connection that lets a tool you already use search and read your meetings. Off unless you turn it on; see [asking from another app](#asking-from-another-app).

**Sink, or destination.** Somewhere a summary is published: Notion, an Obsidian vault, a folder on this Mac, or a network share. Each one succeeds or fails on its own; one being down does not block the others.

**Publish, and republish.** Sending the summary to those destinations. Republishing sends the current version again, which is what you do after editing a summary or marking an action done.

**Settled meeting.** One that finished and published cleanly and is not waiting on you. Only settled meetings are touched by an audio retention policy.
