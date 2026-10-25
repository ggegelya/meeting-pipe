# Performance and long-term stability review, 2026-10-25

Scope (owner-commissioned): performance in long-term use of the daemon and the pipeline, meaning memory leaks, resource drains, main-thread starvation and freezes, unbounded growth on disk, and the robustness of every save and write path. Base: `main` at `01e904a`. The owner asked that comments, docs and the backlog not be trusted as statements of what the code does, so every claim below was checked in code. The owner approved filing the findings on 2026-10-25; the backlog rows are the record of what is owed, and this file is the record of how they were found.

## Method

Eight read-only finders ran in parallel, one per subsystem: recording and the audio write path; meeting detection with its AX and CoreAudio polling; the coordinator, session control and main-thread blocking; the Library, its stores, search index and SwiftUI rendering; the pipeline subprocess, transcription engine and model lifecycle; logs, sidecars, config writes and disk growth; the Python pipeline; and the status bar, HUD, prompt, notifications and windows. Each was told to treat comments as hypotheses and to cite file and line. Each finder's output then went to an independent verifier told to refute every finding: check the code exists, is reachable in production, runs on the thread claimed, is not already mitigated, and matters at realistic scale (24/7 for weeks, thousands of meetings, three-hour recordings). 111 findings came back: 1 critical, 16 high, 42 medium and 51 low after verification, 1 refuted (SUBPROCESS-11, a retain cycle in `runMP` that does not exist). A second pass of nine agents deduped them against the active backlog, `owner-verification.md` and the archives, re-checked the code, and drafted the specs; two other audit bands (code quality, observability) landed on `main` during that pass and the drafts were reconciled against them.

## Live measurement and its limits

Measured on the owner's personal Mac on 2026-10-25: the installed daemon (pid 77137) had been up 7 days 8 hours with an 18 MB physical footprint, 0.0% CPU, zero wakeups across a 10 s sample, 5 threads, 478 Mach ports and 41 open files. That is a clean idle baseline and nothing more: Teams was not running, no meeting had been recorded in that process's lifetime, and the installed bundle (mtime 2026-09-11) predates END9, DET13 and every 2026-10-24 landing, so it is not the code this review read. `~/Library/Logs/MeetingPipe/pipeline.log` was 1.4 MB and 84,285 lines since 2026-07-07. `$TMPDIR` held 3,516 leftover `mp-*` test directories totalling 5.4 GB, all created by `daemon/Tests` (covered by [T11](../backlog/tasks/T11.md)).

Not covered: behaviour during a live recording (needs a meeting), the AX load on a running Teams (needs Teams open; PERF17 to PERF19 and PERF6 carry owner-run measurements), the work laptop's library and logs, write-failure branches (not exercisable read-only), and the rendered UI.

## Themes

1. Accessibility and CoreAudio calls still run on the main thread during calls: the mute-button probe's 1 Hz poll and its rearm walk ([PERF10](../backlog/tasks/PERF10.md), proposed for P1), the engage, start, arm and stop paths (PERF15), and the HAL signals' unsynchronised state (CONC9).
2. The Teams accessibility tree is walked heavily both idle and in meetings: discovery's three passes per scan, kept running through prompts and recordings (PERF17), the window watcher's 1 Hz all-window walk (PERF18), and polls that never back off (PERF19).
3. Several post-recording phases have no ceiling, so one hang blocks every later meeting (PIPE36), and quitting the daemon leaves its jobs running unsupervised (PIPE37).
4. Library work on the main thread and rebuilt-from-scratch state: the search index wiped at every launch (PERF20), playback that never releases the output device (PERF21), the watcher Quick Find never detaches (PERF22), rails that re-read the library on every change (PERF23).
5. Recording integrity at the edges: the orphan sweep can delete a starting recording (REC23, P1), a wedged audio engine is reused on main (REC27, P1), a zombie capture stream can write into the next recording (REC28), writer queues have no bound (REC25), and the 4 GiB WAV ceiling at about 3 h 06 min ([REC19](../backlog/tasks/REC19.md), proposed for P1).
6. Growth without a bound: daily full backups never pruned (STOR12), the local model server's prompt cache (LOCAL22), and local requests sized in characters rather than tokens (LOCAL23).

## Result

27 new tasks, two of them P1 (each names its broken promise and notes the owner may re-band):

- **PERF15** (P2): Engaging, arming and disengaging a meeting runs full AX walks, a ScreenCaptureKit wait and queue syncs on the main thread, so the prompt, Record and Stop stall while the meeting app is slow
- **PERF16** (P2): Smaller costs in the mute plumbing: LogMuteAdapter re-copies its buffer once per line on the main thread, and RealAXBackend keeps an AXObserver on the main run loop after a failed first registration
- **PERF17** (P2): Discovery keeps scanning and AX-walking through every prompt and recording although nothing reads the result, and scans queue behind a slow one with no in-flight guard
- **PERF18** (P2): The mute backstop re-walks every Teams window once a second for the whole recording, including the Calendar or chat window that never has a mute button
- **PERF19** (P2): In-call signal polls never slow down: ScreenCaptureKit is enumerated up to twice a second with no in-flight guard, and the adaptive backoff lasts one poll
- **PERF20** (P2): The Library search index is wiped at every launch and rebuilt with one full-table scan per meeting, and every search keystroke queries it synchronously on main
- **PERF21** (P2): Library playback leaves the audio output running after pause, end of file and window close, and calls its engine unbounded on the main thread
- **PERF22** (P2): Quick Find leaves the library watcher attached for the life of the process, every launch's first scan parses every transcript for its length, and every rescan republishes even when nothing changed
- **PERF23** (P2): Facts, People and Meeting time re-read the whole library on every store revision in uncancelled passes that can land out of order, and Meeting time's transcript cache dies on every rail switch
- **PERF24** (P2): The status menu spawns launchctl and lists the whole recordings folder on the main thread at every open, rebuilds and discards the whole menu on every queue, state and download tick, and the in-app doctor runs its self-check on main
- **PERF25** (P2): Smaller pipeline costs: every summarize reads every earlier meeting's sidecar to find one, and a local run reloads the model between speaker cleanup and summarize or after any request longer than five minutes
- **PERF26** (P2): The Library's status spinners and pulses and the recording HUD's pulse redraw at the display's full refresh rate while visible, and a Paste pending row spins until someone pastes
- **PERF27** (P2): A failure's Details window leaks on every click, and tutorial anchors republish on every scroll and resize while no tour runs
- **REC23** (P1): The after-job orphan sweep can merge a recording that is still starting, delete its live intermediates, and publish a few-second stub in place of the meeting
- **REC24** (P2): A failed orphan re-merge is retried after every job forever, and two job completions can merge the same orphan at once over one temp file
- **REC25** (P2): The capture writers queue without bound and count only thrown errors, so a stalled disk grows memory about 2 GB an hour unseen, and an abandoned writer's failures can force-stop the next recording
- **REC26** (P2): Flagged moments are written only at stop, so a crash, a quit or a rebuild mid-meeting recovers the audio and loses every flag
- **REC27** (P1): A wedged AVAudioEngine survives a timed-out teardown or restart and is then called synchronously on the main thread by the next start, wake or watchdog tick, so one audio wedge can freeze the app
- **REC28** (P2): A system capture the channel has given up on can still write into it, so a stream whose stopCapture() hung delivers into the next recording's system WAV, and the start Task applies its outcome off the main thread
- **CONC9** (P2): ProcessAudioSignal, HALSystemMuteProbe and HALVoiceActivityProbe change their state from the main thread and the CoreAudio bus queue with no lock, so a process-list change races the 1 Hz poll
- **CONC10** (P2): An open alert or menu stalls every default-mode Timer on the detection, end-of-call, prompt and HUD paths, and the prompt and HUD cannot be clicked while an alert is up
- **PIPE36** (P2): The pipeline lane's in-daemon phases have no ceiling and Cancel cannot reach two of them, so one hung redaction, transcription or Apple Intelligence pass holds every later meeting until a restart
- **PIPE37** (P2): Quitting or restarting the daemon leaves its in-flight mp jobs running with no watchdog, and the relaunch marks their meetings interrupted while they still write, so a Retry runs a second pipeline on the same stem
- **STOR12** (P2): Automatic backups are never pruned, so a daily full-library archive fills its destination, and backup and restore decompress the whole archive several extra times against a fixed 30-minute cap
- **LOCAL22** (P2): mlx_lm.server runs with its default prompt cache of ten full KV caches and no byte cap, so a warm server keeps gigabytes of finished requests resident for the daemon's lifetime
- **LOCAL23** (P2): Local summarize sizes its requests in characters against the cloud gate's knob, so one call can run past Qwen2.5's 32K context or a tight tier's ceiling, and map-reduce makes about 115 calls for two hours of speech
- **AI13** (P2): The embedding index is rewritten whole and in place every eight meetings, so a kill inside a save forces a full rebuild and two writers can tear it

Amended in place, with only what each lacked: PERF10, PERF13, CONC5, CONC7, CONC8, PIPE22, PIPE24, PIPE30, REC19, REC20, STOR7, STOR9, ARCH10, AUTO6, DET10, END16, LOCAL21, OBS5, UX93, HYG10 (the review's 71 comment-drift items, grouped by who corrects each). Already covered with nothing to add: PERF12 (LIBRARY-10), CONC7 (SUBPROCESS-12), T11 (the test temp directories).

Reopened on the owner's decision (2026-10-26, P2): DETECTION-3 and DETECTION-5 show that PERF6's shipped promise (an idle app skips the control-button AX walks) no longer holds, because DET5 added `isLoneNative` and `isFrontmost` to `shouldWalkControlAX` and the Teams recognizer admits chat windows, so [PERF6](../backlog/tasks/PERF6.md) is open again; its fix reverses part of DET5. Re-band proposals, not applied: PERF10 to P1 (a hung meeting client freezes Stop and the hotkeys for as long as it hangs) and REC19 to P1 (every meeting past about 3 h 06 min loses its tail).

## Findings index

Verified severity, verdict, and where each finding was filed.

| Finding | Severity | Verdict | Title | Filed as |
|---|---|---|---|---|
| DETECTION-1 | critical | confirmed | AXMuteButtonProbe polls the meeting app's AX tree on the main thread at 1 Hz and re-walks the whole tree on main every 5 s while its element reads unknown | PERF10 |
| DETECTION-2 | high | confirmed | Lifecycle engage, recording start, arm and disengage run full AX walks, an SCK probe and a HAL process enumeration on, or blocking, the main thread | PERF15 |
| DETECTION-3 | high | confirmed | Idle discovery runs three exhaustive AX tree walks of Teams every 3-12 s all day because isLoneNative bypasses the PERF6 walk gate | PERF6 (reopened 2026-10-26) |
| DETECTION-6 | high | confirmed | MeetingAXWindowWatcher performs an exhaustive multi-window AX walk about once a second for the whole recording | PERF18 |
| DETECTION-7 | high | confirmed | ProcessAudioSignal mutates its arrays and state from the main thread and the HAL bus queue with no synchronisation | CONC9 |
| LIBRARY-1 | high | confirmed | FTS5 search index is wiped on every launch by the indexer's first (empty) reconcile, then rebuilt with O(N^2) SQLite work; search reports ready while transcript hits are missing | PERF20 |
| LIBRARY-2 | high | confirmed | Playback AVAudioEngine is never stopped after pause or end-of-file, and its owner survives closing the Library window, so output IO runs indefinitely | PERF21 |
| MAINTHREAD-1 | high | confirmed | The AX mute-button health poll and its full-tree re-walk run on the main run loop for every native recording | PERF10 |
| MAINTHREAD-2 | high | confirmed | Engaging, arming and disengaging the lifecycle does full cross-process AX walks, a ScreenCaptureKit probe and HAL polling on the main thread | PERF15 |
| MAINTHREAD-4 | high | plausible | The after-job orphan sweep can treat a recording that is still starting as an orphan, merge it, and delete its live intermediates | REC23 |
| PERSISTENCE-1 | high | confirmed | Every recording longer than about 3 h 06 min hits the 4 GiB RIFF limit on the Float32 system-audio WAV intermediate and is force-stopped (or its system leg is mis-sized at merge) | REC19 |
| PERSISTENCE-2 | high | confirmed | Scheduled backups are full-library archives (audio included), written daily, never pruned, and read back in full a second time | STOR12 |
| PYTHON-1 | high | confirmed | mlx_lm.server runs with its default prompt cache: 10 entries and no byte limit, so a warm server keeps GBs of old KV caches resident for weeks | LOCAL22 |
| PYTHON-2 | high | confirmed | Local single-pass summarize sends up to 80k chars (~20-40k tokens) in one request, ignoring the RAM-tier context ceiling the codebase measured as the OOM boundary | LOCAL23 |
| PYTHON-3 | high | confirmed | Scheduled backups are full archives (audio included) that are never pruned, so the destination disk fills | STOR12 |
| RECORDING-1 | high | plausible | A wedged AVAudioEngine survives a timed-out teardown and is then called synchronously on the main thread (start, device-change recovery, wake, watchdog), so a single wedge can freeze the whole app | REC27 |
| UI-1 | high | confirmed | Library audio playback engine keeps the output device running after pause, end of file, selection change and window close | PERF21 |
| DETECTION-10 | medium | confirmed | ShareableContentSignal polls SCShareableContent at 2 Hz for the whole engaged session and abandons timed-out requests | PERF19 |
| DETECTION-4 | medium | confirmed | Discovery keeps doing full scans and AX walks during prompting and recording although every result is discarded | PERF17 |
| DETECTION-5 | medium | confirmed | Admitted browser candidates get a Leave-button DFS of every browser window that can never match | PERF6 (reopened 2026-10-26) |
| DETECTION-9 | medium | confirmed | events.jsonl appends are unsynchronised across threads and pay mkdir + stat + open/close per event on the calling thread, including main | PERF13 |
| LIBRARY-3 | medium | confirmed | Quick Find re-attaches the library directory watcher and nothing detaches it, so the store keeps rescanning and re-ranking while every window is hidden | PERF22 |
| LIBRARY-4 | medium | confirmed | Facts, People and Meeting time re-read the whole library on every revision in uncancelled, overlapping detached tasks that can land out of order; the Stats transcript cache dies on every rail switch | PERF23 |
| LIBRARY-5 | medium | confirmed | Cold scan after every launch fully parses every transcript JSON just to read audio_seconds; non-cacheable rows reparse it on every scan | PERF22 |
| LIBRARY-6 | medium | confirmed | Every search keystroke does synchronous whole-library work on main: an FTS5 prefix query ranked by bm25 (ranking then discarded), plus in-memory scans; the Quick Find ranker scans each haystack up to 7 times | PERF20 |
| LIBRARY-7 | medium | confirmed | Delete and export run synchronously on main: each delete lists the whole recordings directory and trashes files one by one; batch loops never yield | STOR7 |
| LIBRARY-8 | medium | plausible | Daemon-side read-modify-write of summary.json/meta.json can destroy the file on a failed read, swallows write failures, and is not serialized with pipeline rewrites | ARCH10 |
| MAINTHREAD-5 | medium | confirmed | Storage sweeps run after every job without serialization; failed orphan merges retry forever and overlapping runs fight over fixed temp files | REC24 |
| MAINTHREAD-7 | medium | confirmed | The Diagnostics window parses every rotated event-log generation synchronously on main, on open and on every filter change | PERF13 |
| MAINTHREAD-8 | medium | plausible | The model-prefetch stderr readabilityHandler is never cleared, so it can busy-loop at EOF after every prefetch; termination also does a blocking read on main | CONC7 |
| MAINTHREAD-9 | medium | plausible | The pipeline queue has no watchdog over the in-daemon redaction and transcription phase, so one hung pass wedges every later meeting | PIPE36 |
| PERSISTENCE-10 | medium | plausible | Capture writer queues are unbounded, so a stalled (not failing) disk grows memory by about 2 GB per hour until jetsam | REC25 |
| PERSISTENCE-4 | medium | confirmed | Diagnostics window parses up to ~40 MiB of JSONL on the main thread on every appear and every filter change | PERF13 |
| PERSISTENCE-5 | medium | confirmed | Batch 'Move to Trash' (and the merge's fragment cleanup) runs synchronously on main and re-enumerates the whole library directory once per meeting | STOR7 |
| PERSISTENCE-6 | medium | confirmed | Storage sweeps after every job are not single-flight: concurrent retention sweeps transcode the same WAVs with blocking ffmpeg on cooperative-pool threads, and the orphan directory scan runs on main | CONC5 |
| PYTHON-4 | medium | confirmed | Backup is written in place under its final name, and backup/restore decompress the whole multi-GB gzip stream 2-4 extra times | STOR12 |
| PYTHON-5 | medium | confirmed | Embedding-index checkpoint rewrites the whole index every 8 meetings, non-atomically; a kill mid-save forces a full rebuild | AI13 |
| PYTHON-6 | medium | confirmed | Long-lived MCP server builds the search index once with the first call's allowlist and never refreshes or locks it | AUTO6 |
| PYTHON-7 | medium | confirmed | Diarize-cleanup Anthropic client keeps the SDK defaults (600 s timeout, 2 internal retries), so a stalled socket can eat 30 min per window | PIPE24 |
| PYTHON-8 | medium | plausible | Local map-reduce makes ~1 full-schema LLM call per 1,300 chars and can re-run the whole thing; long meetings blow the daemon's 20/90-min watchdogs | LOCAL23 |
| RECORDING-2 | medium | plausible | An SCStream whose stopCapture() timed out keeps delivering into the channel and writes into the next recording's (or the retry's) system WAV | REC28 |
| RECORDING-4 | medium | confirmed | Capture intermediates are 32-bit float WAV (about 2.07 GB per recorded hour), and the system channel reaches the 4 GiB RIFF limit at about 3h06m | REC19 |
| RECORDING-5 | medium | confirmed | ffmpeg Process handling: a timed-out merge is never terminated, stderr is drained only after exit, and the mute-redaction ffmpeg has no timeout at all (it can wedge the whole pipeline lane) | CONC5 |
| RECORDING-6 | medium | confirmed | The orphan sweep runs after every job: a synchronous raw/ directory scan on main, no in-flight guard (concurrent same-stem merges), and no retry cap | REC24 |
| RECORDING-8 | medium | confirmed | Recorded audio grows without bound on disk by default (about 230 MB per recorded hour kept forever), with no free-space preflight and transient intermediates in the same library tree | REC20 |
| SUBPROCESS-1 | medium | plausible | Mute-redaction ffmpeg has no timeout, no kill, and an undrained stderr pipe, and it runs at the head of the serial pipeline lane | CONC5 |
| SUBPROCESS-13 | medium | confirmed | Transcription loads the whole WAV as one stereo Float32 buffer plus a mono copy: about 2.1 GB transient peak for a 3 h meeting | REC20 |
| SUBPROCESS-3 | medium | confirmed | A failed orphan re-merge is retried after every successful job and at every launch, forever, with no attempt cap or backoff | REC24 |
| SUBPROCESS-4 | medium | plausible | The in-daemon FluidAudio transcription pass has no ceiling and no stall signal, so a wedged CoreML/ANE call or model download blocks the whole lane | PIPE36 |
| SUBPROCESS-5 | medium | confirmed | Apple Intelligence summarization holds the lane with no timeout and cannot be cancelled; a long meeting becomes hundreds of sequential on-device calls | PIPE36 |
| SUBPROCESS-6 | medium | confirmed | Cancel (and any non-timeout kill) of a local-backend mp leaves the setsid'd multi-GB mlx_lm.server resident until the next successful job or relaunch | PIPE22 |
| SUBPROCESS-7 | medium | confirmed | Quitting or restarting the daemon leaves in-flight mp children (and their grandchildren) running unsupervised; the relaunch then marks the job interrupted and invites a racing retry | PIPE37 |
| SUBPROCESS-8 | medium | confirmed | Digest/backup schedule controls run unbounded launchctl bootout+bootstrap synchronously on the main thread, once per DatePicker change | CONC5 |
| SUBPROCESS-9 | medium | confirmed | Diagnostics window parses every rotated generation of both event logs on the main thread on each filter change | PERF13 |
| UI-2 | medium | confirmed | Status-bar menu does a launchctl subprocess and full recordings-dir listing on the main thread on every open, and re-does the dir listing on every state/queue/download-progress rebuild that is then discarded | PERF24 |
| UI-3 | medium | confirmed | Diagnostics window reads and JSON-parses every generation of both event logs on the main thread, on open and on every filter change | PERF13 |
| UI-6 | medium | confirmed | TimelineView(.animation) spinners and pulses re-render every display frame; 'Paste pending' rows spin forever | PERF26 |
| UI-7 | medium | confirmed | App-modal dialogs and status-menu tracking suspend every default-mode Timer that drives detection, end confirmation, prompt timeout and the HUD | CONC10 |
| UI-8 | medium | confirmed | Library playback calls AVAudioEngine start/stop synchronously and unbounded on the main thread | PERF21 |
| DETECTION-11 | low | confirmed | AdaptivePollCadence backs off for only one poll after an edge-only notification, so the 1 Hz signal polls never slow down | PERF19 |
| DETECTION-12 | low | confirmed | CallTeardownWatcher polls the Teams log directory at 1 Hz for the whole process lifetime, with a new DispatchQueue and timer per tick and regex/DateFormatter work in the sort comparator | END16 |
| DETECTION-13 | low | plausible | LogMuteAdapter splits the log chunk quadratically on the main thread | PERF16 |
| DETECTION-14 | low | confirmed | RealAXBackend keeps an AXObserver and its main run-loop source forever when the first registration for a PID fails | PERF16 |
| DETECTION-15 | low | confirmed | Mic-busy detection binds to the default input device once at launch and never follows device changes | DET10 |
| DETECTION-8 | low | plausible | Discovery scans have no in-flight guard, so a slow scan builds an unbounded backlog on scanQueue | PERF17 |
| LIBRARY-10 | low | confirmed | 5 s pipeline heartbeat and 15 Hz playback clock invalidate whole Library subtrees; the transcript list recomputes O(n) arrays per tick | PERF12 |
| LIBRARY-11 | low | confirmed | Menu bar failed-count does a full recordings-directory listing on main on every menu rebuild | PERF13 |
| LIBRARY-9 | low | confirmed | Every rescan republishes the full meetings array and bumps revision even when nothing changed, and each revision runs O(n) Calendar/DateFormatter work on main | PERF22 |
| MAINTHREAD-10 | low | confirmed | Log.event and Log.writeLine append to shared files from many threads without serialization (seek-then-write, no O_APPEND), so concurrent lines overwrite each other and rotation races | PERF13 |
| MAINTHREAD-11 | low | confirmed | Notifier.doneEntries grows for the life of the process: entries are removed only when the user clicks the notification | UX93 |
| MAINTHREAD-12 | low | plausible | Keychain access shells out to /usr/bin/security synchronously on main with no timeout, at launch and on every secrets save | CONC5 |
| MAINTHREAD-13 | low | plausible | ConfigStore renders rawDocument (a TOMLKit C++ tree) on writeQueue while main can mutate it in writeBack or saveNow | CONC8 |
| MAINTHREAD-3 | low | confirmed | Opening the menu-bar menu spawns launchctl synchronously on main, and every menu rebuild re-lists the whole recordings directory | PERF24 |
| MAINTHREAD-6 | low | confirmed | CallTeardownWatcher lists Teams' log directory once a second, around the clock, whether or not Teams or a call exists | END16 |
| PERSISTENCE-11 | low | confirmed | 'Move library' planning walks the entire library on the main thread | PERF13 |
| PERSISTENCE-12 | low | confirmed | Backup and digest schedule changes run launchctl bootout and bootstrap on main with an unbounded waitUntilExit | CONC5 |
| PERSISTENCE-13 | low | confirmed | A failed mp spawn leaks the pipeline.log FileHandle, both Pipes and the Process (retain cycle through terminationHandler) | CONC7 |
| PERSISTENCE-14 | low | confirmed | Library audio grows without bound by default (keep forever, uncompressed 16 kHz stereo s16 WAV) | REC20 |
| PERSISTENCE-15 | low | confirmed | Flagged moments are held only in memory until stop, so a crash or abort mid-meeting loses them | REC26 |
| PERSISTENCE-3 | low | confirmed | File logger has no lock or queue, opens the file without O_APPEND, does synchronous I/O on the caller's thread, and pipeline.log has two independent writers | PERF13 |
| PERSISTENCE-7 | low | plausible | MeetingStore watcher cancel handler closes self.watcherFD rather than its own fd, so a quick stop/start leaks the old fd and kills the new watcher | PERF22 |
| PERSISTENCE-8 | low | confirmed | Selecting a meeting while the Transcript or Audio tab is active decodes its whole recording and writes a permanent peaks-cache file, even with Skip silence off, in detached tasks that are never cancelled | PERF21 |
| PERSISTENCE-9 | low | confirmed | The on-device Apple Intelligence summarizer overwrites <stem>.summary.json and .summary.md in place, without an atomic write and at umask mode | PIPE30 |
| PYTHON-10 | low | confirmed | Per-call O(library) metadata scans with no index: every summarize reads every earlier meeting's meta sidecar; MCP, ask and digest re-scan visibility per call | PERF25 |
| PYTHON-11 | low | plausible | atomic_write_text never fsyncs, and SIGKILL leaks hidden temp files into the library | PIPE30 |
| PYTHON-12 | low | confirmed | Publish idempotency sidecars and several content files are written non-atomically; a torn <stem>.notion.json causes a duplicate Notion page | PIPE30 |
| PYTHON-13 | low | confirmed | The warm server's mlx-server.log is only rotated when opened, so it grows for the daemon's lifetime | LOCAL21 |
| PYTHON-14 | low | confirmed | Avoidable multi-GB model reloads: cleanup and summarize each own an mlx server, and a stale idle timer kills the server after long requests | PERF25 |
| PYTHON-15 | low | plausible | pipeline.log has two writers: Python's O_APPEND FileHandler plus the daemon's non-append handle receiving the same stderr | PERF13 |
| PYTHON-9 | low | plausible | roster.json / voiceprint.json are read-modify-written without a lock through a shared fixed .tmp name, and a corrupt roster reads as empty and gets overwritten | STOR9 |
| RECORDING-10 | low | confirmed | A failed start() leaks voice processing (HAL left degraded for other apps) and leaves a `.capturemode` marker file behind | REC27 |
| RECORDING-3 | low | plausible | Capture writers queue without bound and have no backpressure or visibility; an abandoned drain keeps writing after stop and can force-stop the next recording | REC25 |
| RECORDING-7 | low | plausible | `.stopping` blocks every prompt and manual Record for the whole ffmpeg merge, which grows with meeting length; the 90 s stop-stall alarm is below the 300 s merge ceiling | CONC5 |
| RECORDING-9 | low | confirmed | The system-capture start Task mutates main-confined channel state from the cooperative pool | REC28 |
| SUBPROCESS-10 | low | confirmed | Preferences 'Run doctor' runs AX round-trips, a full recordings-dir scan, and an SQLite open synchronously on main | PERF24 |
| SUBPROCESS-12 | low | confirmed | runMP can lose the final stderr chunk and races on the shared stderrTail buffer and log handle | CONC7 |
| SUBPROCESS-14 | low | confirmed | ASR and diarizer CoreML models stay resident for the whole daemon lifetime after the first meeting | REC20 |
| SUBPROCESS-15 | low | confirmed | reapStorage on every successful job scans the whole recordings dir on main and starts an unguarded background sweep that can overlap itself | CONC5 |
| SUBPROCESS-16 | low | confirmed | Keychain reads and writes spawn /usr/bin/security synchronously with an unbounded waitUntilExit on main (7 at launch, 3 per secrets save) | CONC5 |
| SUBPROCESS-17 | low | confirmed | Minor subprocess hygiene: unread stderr pipes, a prompt preview with no timeout, a prefetch stderr handler never cleared, and a loose reaper identity check | CONC5 |
| SUBPROCESS-2 | low | plausible | Merge/convert ffmpeg is abandoned on its 300 s ceiling but never killed, and its stderr pipe is never drained | CONC5 |
| UI-10 | low | confirmed | Recording HUD: infinite full-frame-rate Core Animation pulse and zero-tolerance 10 Hz / 2 Hz timers for the whole recording | PERF26 |
| UI-11 | low | confirmed | FailureDialog.showDetails leaks a window and its hosting controller per 'Details…' click (retain cycle) | PERF27 |
| UI-12 | low | confirmed | Notifier.doneEntries grows by one entry per done banner and is removed only when the user acts on that banner | UX93 |
| UI-13 | low | confirmed | PermissionsCenter publishes every probe result even when unchanged (4 objectWillChange per 2 s poll) | OBS5 |
| UI-14 | low | confirmed | Tutorial anchor frames are published on every layout or scroll change even when no tour is running | PERF27 |
| UI-15 | low | confirmed | Guide window re-parses all inline markdown on every rail hover and section change | PERF13 |
| UI-4 | low | confirmed | Preferences Doctor runs the daemon self-check synchronously on the main actor (AX IPC to meeting apps, second SQLite connection with busy timeout, recordings-dir scan) | PERF24 |
| UI-5 | low | confirmed | Quick Find re-arms the MeetingStore directory watcher and never suspends it; its hidden model re-ranks and runs FTS on main on every store change with the stale last query | PERF22 |
| UI-9 | low | confirmed | Preferences subprocesses block cooperative-pool threads; prompt preview has no watchdog and drains stderr only after exit, MCP status never drains stderr | CONC5 |
| SUBPROCESS-11 | none | refuted | runMP's terminationHandler captures the RunHandle that strongly holds the Process (a retain cycle), and the pipe read ends are never closed explicitly | not filed (refuted) |
