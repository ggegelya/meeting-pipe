# Go-live assessment, 2026-10-21

Owner-commissioned review against three questions: is meeting-pipe ready to put in front of other people, how smooth is the path from a clean Mac to a first result for a new user, and should it become a product or stay a personal tool.

## Bottom line

1. **Production readiness: not ready to go live to other users. Fine to keep using yourself.** The recording core is production-grade: once audio is flowing it is very hard to lose silently, crash hygiene is clean, and both suites are green locally (2,988 Swift tests, 1,396 Python tests). What is not ready is everything around that core: end-of-call automation that keeps chopping live meetings, an installed app that silently depends on the git clone (one of these is a crash-at-launch for anyone whose copy is relocated), a CI that has been red for 82 days, ten P1 fixes shipped but never confirmed in the field, and a first-run flow whose steps are not wired to each other. Roughly 2 to 3 focused weeks gets it to an honest "use at your own risk" open-source release; a stranger-proof install needs a Developer ID and another 2 to 3 weeks on top.
2. **New-user UX: the hard part is not Python, it is build-from-source.** Today a non-programmer faces 16 prerequisites, about 32 manual steps (14 of them in Terminal), an admin account, and 60 to 120 minutes before a first summary, against SETUP.md's "about 30 minutes". Python itself is manageable: ship it as the embedded runtime (DIST1) inside a signed, notarized DMG and users never see it. A Swift port is a 3 to 6 month detour and should not gate anything. With a DMG plus an in-app first run, the target is about 12 steps, 15 to 20 minutes, no terminal.
3. **Market: keep it personal, optionally publish it properly as open source, do not go paid or B2B now.** Google released AI Edge Foresight on 2026-10-08, a free, on-device meeting-notes app for Apple Silicon Macs, which sets the price of "private offline Mac meeting notes" to zero under Google's brand. Talat already sells the same FluidAudio + Parakeet + local LLM stack as a signed one-click app (Setapp, about $9/month, or $49 to $99 one-time), with voice matching, calendar, Obsidian export and MCP. Several free open-source apps cover the same ground. meeting-pipe's real differentiators (the per-workflow egress policy with regulated and NDA modes, multi-sink publishing, evidence-linked summaries, Ukrainian support, the Claude CLI backend) are genuine but matter to a small audience that looks a lot like you.

## How this was done

Eight parallel review angles, 14 agents in total: daemon production readiness, pipeline production readiness plus security, privacy and legal, distribution and dependencies, new-user UX, SwiftUI architecture and maintainability, feature quality (transcription and people identification), a test-gate run, and a web market scan. Every critical and high finding from the six code angles went to an independent skeptic told to refute it in code: 41 were checked, 18 confirmed, 23 downgraded, none refuted outright. Severities below are the post-verification ones. The two most consequential market claims (Google AI Edge Foresight, Talat) were spot-checked against their sources by hand.

All local gates passed on this M4 Max (macOS 26.5.1): ruff clean, pyright 0 errors, pytest 1,396 passed / 0 skipped in 46 s, truth fences OK, release build in 88 s, swift test 2,988 passed / 1 deliberate skip (run twice, no flakes). Side effect worth knowing: the two `swift test` runs appended about 8,000 synthetic lines to the real `~/Library/Logs/MeetingPipe/pipeline.log` and pytest left a stale `mlx-server.json` there (QG-5).

The owner's main library and event log live on the work laptop, so library-scale figures come from the repo's own measured spike docs, and field data here comes from the 9 recordings and 863 events on this Mac (2026-10-12 to 2026-10-18).

## Fix before anyone else installs it

Ranked by what a new user would hit first and how badly. IDs refer to the appendix.

| # | Fix | Why it blocks | Findings | Effort | Filed? |
|---|---|---|---|---|---|
| 1 | Make the installed app independent of the git clone | The SwiftPM resource accessor resolves bundles from `<repo>/daemon/.build`, which install.sh never copies into the app; move or delete the repo and the app calls `fatalError` during Coordinator init, then launchd restarts the crash every 10 s. Separately, the "installed" Python venv is a launcher back into the clone (editable `.pth`, shebang into `pipeline/.venv`), so a `git pull`, branch switch, or uncommitted edit changes production Python while the Swift binary stays old. | DI-1 (critical, confirmed), PP-5, UX-2 | S | No |
| 2 | Invert the end-of-call policy to "record long, trim later" | END9 through END14 are six consecutive P1 patches on the same promise; each fixes the rule the previous one shipped. A single Teams title change on 2026-10-08 produced 217 false ends in a day. A lone weak signal should open a hold that keeps recording, confirmation should need cross-class evidence, an app quit, or a long dwell, and held audio should be kept with a suggested trim point. Google Meet in a browser also stops after 120 s on another tab, minimized, or on another Space, which is what a presenter sharing a tab does. | PD-1, PD-3, UX-15, FQ-6, PD-9 | L | Symptoms only (END9-END14, DET6) |
| 3 | Get CI green and make it a real gate | Last green run on main was 2026-07-31; 10 of 11 pushes since then failed; the README badge shows red. CI resolves anthropic 2.0.0 + httpx2 (pyright fails, so pytest has not run on CI since 2026-08-04). `runWithTimeout` runs blocking AVAudioEngine calls on the Swift cooperative pool, so the REC13 wedge bound fails when threads are scarce (reproduced locally with a constrained pool). Cap the SDK, run CI against the lock, move blocking calls to GCD, add a local script that runs exactly what CI runs. | QG-1, SA-1, QG-2, PD-5, QG-3, PP-1 | S to M | No |
| 4 | Stamp a build identity and confirm the open P1s in the field | Every build is version 0.1.0 build 1, with no git SHA, so a bug report cannot be tied to code. The installed app on this Mac is older than its signature suggests: its strings predate END9 (2026-08-20), so it still runs the chop that cut a Zoom call at 16.6 s here on 2026-10-13. Ten P1 rows are shipped but unconfirmed (END9-END14, REC17, DET13, UX74, HYG7) plus four complex P1s in owner verification. Run the walkthroughs on one current build for a working week with lifecycle changes frozen. | PD-4, SA-5, DI-7 | S plus a week of calendar | Partly (per-row) |
| 5 | Make "off the record" fail closed, and decide what it covers | Redaction failure is silent: the job transcribes and publishes the unredacted WAV, logging only `mute_redaction_failed`. And the filter zeroes only the mic channel while transcription averages both, so everything the other participants say during an off-the-record stretch is still transcribed, summarized, published, and possibly sent to the cloud. GUIDE and README promise more. | PD-6 (confirmed) | M | No |
| 6 | Wire the first run together | Presets (Personal, Internal team, Client) create filesystem-only default workflows, so the Notion token entered one step later is never used. "I'll set up later" leaves a Notion-only default, so with no token every meeting lands in Needs you. No step asks for the Anthropic key, yet the presets pin Anthropic, so the test recording fails and the window closes without showing it. | UX-3 (confirmed) | M | No |
| 7 | Ask for the user's name | `user_label` ships empty and nothing asks for it, so the user's own voice is labelled "1", counted as a roster match, and the digit leaks into published summaries as an attendee. Seen in 7 of 9 transcripts on this Mac. Default it from the macOS account name in onboarding. | FQ-2 (confirmed), UX-4 | S | No |
| 8 | Ship a neutral summary prompt and empty team context | The base prompt opens as a "regulated-domain meeting summarizer", its rules assume regulated SaaS (validation, QMS, Part 11), and its examples name colleagues. `config.example.toml` ships `team_context = "FDA 21 CFR Part 11 regulated SaaS, .NET 8 + Angular + AWS EKS"`, install.sh copies it verbatim, and the workflow migrator seeds it into the default workflow. Every new user's meetings would be summarized as your employer's. | FQ-4 | S | No |
| 9 | Make the privacy promise match the defaults | The welcome screen says notes never leave the Mac and nothing is uploaded unless a publish target is configured, but the default engine sends every transcript to Anthropic and the default library sits in `~/Documents`, which iCloud Desktop & Documents uploads when that common setting is on (it is on for your own Mac). Default the library outside synced folders for new installs and say exactly what leaves the Mac for the engine picked. | UX-5 (confirmed), PD-10, DI-11 | S | SEC12 warns only |
| 10 | Add a recording-consent and voiceprint posture | Nothing tells a user that many jurisdictions require all-party consent, and `auto_consent_apps` records with no prompt. Every diarized speaker gets a stored 256-d voice embedding, named people go to a roster, and "forget" removes them from `roster.json` only. Voiceprints are biometric identifiers under Illinois BIPA and special-category data under GDPR; Otter's BIPA and wiretap claims survived dismissal in August 2026. A one-time acknowledgement, opt-in speaker recognition, 0600 file modes, and a forget-everywhere cascade cover most of it. Not legal advice; get it checked before any public push. | PP-3, PP-4 | M | No |

**Before calling it a release (a stranger installs it without you):** buy the Apple Developer ID ($99/year) and finish DIST1 as a signed, notarized DMG with a lock-pinned embedded runtime, entitlements for audio input, and an app-owned login agent plus an in-app speech-model download step, because a drag-installed app today has nothing that replaces install.sh's LaunchAgent and model prefetch (DI-3, DI-4, DI-5). Add a documented update path, at minimum tagged releases plus `git pull && ./scripts/install.sh`, and Sparkle later (DI-7). That also removes the self-signed key that every install imports with "allow any application" access (DI-6). This needs an explicit owner decision, because the root `CLAUDE.md` lists signing, notarization and Sparkle as deferred selling machinery and D8 sits at P3.

**Cheap hardening to bundle with the above:** turn off or raise the long-meeting gate for new installs, since a cloud-backend meeting past roughly 95 to 165 minutes gets only a paste-into-Claude bundle (UX-6, FQ-5); lock down the `claude_cli` spawn, which today runs Claude Code from cwd `/` with built-in read tools still available (`--allowed-tools ""` only pre-approves; `--tools ""` disables), loads the user's MCP servers and hooks, and saves every summary as a session (PP-2); ask before an external `meetingpipe://record` starts a recording (PP-8); fail loudly on an unparseable `config.toml` instead of running on defaults and later overwriting it, which silently drops regulated mode (PP-7, PD-12).

## Perspective 1: production readiness

| Area | Verdict | One line |
|---|---|---|
| Recording integrity | Ready | Per-channel intermediates, verified merge promotion, orphan and stranded-job recovery, bounded engine calls, ObjC barrier around installTap. Field data here: 4 device-change recoveries and 1 mic stall, all with no audio loss. |
| Crash safety | Ready | Zero `try!`, force unwraps only on constants, `fatalError` only in unused NSCoder inits. LaunchAgent relaunches after a crash. |
| Start detection | Ready with fixes | Works for native Teams and Zoom; non-Meet browser tabs are not detected (DET6); calibrated mostly on one user's English Teams (22 Teams traces vs 1 Zoom, 1 Webex, 2 Meet, 0 Slack in the corpus). |
| End-of-call detection | Not ready | The recurring P1 class (fix 2 above). Leave and toolbar matchers are English-only and some Teams title stems are accent-sensitive; the only teardown oracle is Teams' own log, used for every app (PD-2, medium after verification). |
| Pipeline reliability | Ready with fixes | Exit-3 contract holds, sinks isolated and idempotent, missing secrets surface as "partial". A retired or mistyped model id fails as "unknown" with a generic Retry (PP-6). On this Mac, 4 of 5 pipeline runs failed: 3 because Apple Intelligence rejects Ukrainian, 1 for a missing Anthropic key (FQ-13). |
| Security and privacy | Ready with fixes | Egress guard and `effective_backend` chokepoint hold today; logs 0600, zero tokens found in logs. Gaps: off-the-record (fix 5), claude_cli spawn, unauthenticated URL scheme, consent and voiceprints (fix 10), backups unencrypted and world-readable (PP-12). |
| Release engineering | Not ready | Red CI, no versioning, no tags across 1,007 commits, stale installed builds (fixes 3 and 4). |
| Tests | Strong locally, weak as a gate | Pure decision types are table-tested; contracts pinned by golden fixtures. But the lifecycle wiring is tested by grepping source text (a headless Coordinator cannot be built), ASR and diarization inference never runs in any test, and the cloud summarize call is only tested against fakes, which is how a Sonnet 5.5 request-shape 400 broke every summary in the field on 2026-10-01 (QG-4, QG-8, QG-9). |

The interim option if you want early users before fix 2 lands: ship with auto-stop off by default (record until Stop or the idle backstop) and the prompt defaulting to Record for known apps.

One anomaly from this Mac worth a look on your work laptop: mic level in your own segments sits around -61 dBFS in the October recordings against about -20 dBFS in September, while remote speech is about -15 dBFS. Combined with an unnormalized L+R mixdown for ASR and diarization, a quiet mic makes your own speech the hardest to transcribe and to separate, and 30 to 39 percent of your "me" cluster duration in two October meetings was system-channel speech (FQ-3, FQ-8). It may just be this Mac's built-in mic, but it is cheap to check.

## Perspective 2: new-user UX, setup to final result

**Install today.** Hard gates: Apple Silicon, macOS 14+ (in practice a recent 14.x because Swift 6 Command Line Tools are required, which install.sh does not check), an administrator account (Homebrew), about 5 GB of disk. Then CLT, Homebrew and its PATH step, ffmpeg, uv, a uv-downloaded Python, about 100 locked PyPI packages, a full release build, 474 to 630 MB of speech models, two key prompts, four permission grants (two of them in System Settings, plus a relaunch for Accessibility, probably a Documents-folder prompt too), an Anthropic Console account with prepaid credit, and about ten actions in Notion to create the database, add properties, create the integration and share it via Connections. About 32 steps and 60 to 120 minutes for a non-programmer, with 6 to 8 known stall points. The clean-Mac walk has never actually been run (DOC10, DIST1).

**First run.** Five onboarding screens, but the steps do not feed each other (fix 6). The window has no Dock or Cmd+Tab presence and no close button, and after the required Accessibility relaunch it starts over at Welcome (SA-7, medium). Preferences has about 85 rows across 8 panes, about 40 of which need an internal concept to understand (workflow, sink, backend, BYO, roster, regulated, chunking threshold); the user's own name is buried under Pipeline (UX-10). UI strings leak implementation vocabulary: "backend" 12 times, "daemon" 7, "sink" 6, plus FluidAudio, Parakeet, mlx_lm, HuggingFace, TCC, meta.json and `mp doctor`. Suggested renames: workflow to meeting type, sink to destination, backend to summary engine, BYO to record without summary, roster to known voices, regulated mode to keep everything on this Mac. Workflow routing asks for bundle ids and regular expressions (UX-11). The in-app doctor is CLI output in a window (UX-9).

**People definition, your stated pain.** Naming is per-meeting manual labour: a free-text field with no list of people already named, exact-text matching so "Dana" and "dana" become two people with no merge, 2 to 5 s per pick with occasional UI freezes (PERF8), and no way to play a voice from its chip. Confirmed matches never add a sample, so the roster only learns from clicks. Measured on your library: 167 of 504 voices auto-named (33 percent), and only 83 of 249 summarized meetings even carry the embeddings matching needs. Summaries are published before naming, so action owners can be diarization labels (UX-8). For a new user with an empty roster this is 0 percent on day one (UX-7, FQ-1, both high, not blockers).

**Proposed first run, six steps.** (1) Drag a signed, notarized app to Applications; speech models download in-app with progress. (2) "What should transcripts call you?", prefilled, plus one honest sentence about what leaves the Mac. (3) Permissions, each with its reason; the app relaunches itself after Accessibility and resumes. (4) Who writes summaries: on this Mac (default), your Claude subscription if `claude` is detected, or Anthropic with a validated key and a cost line. (5) Where notes go: a folder outside iCloud (default), an Obsidian vault, or Notion, with the app creating the database; this becomes the default workflow's destinations. (6) A 30-second test that shows the transcript with "You" already named and the summary, ending on Open Library.

**SwiftUI and app architecture.** Sound overall, with debt that is normal for its age rather than structural. Strengths: a pure-decision Core island, a real seam via SessionHost, good off-main discipline on the heavy paths, a pure StatusBarModel driving menu rebuilds. Debt: the state layer is ObservableObject-only, so the detail pane and transcript re-render at 15 Hz during playback and get patched surface by surface (SA-2); per-meeting document state has no owner, with views writing sidecars and a background carry racing main-thread writes (SA-10, the root of PERF8); `MeetingRecorder.swift` regrew to 2,327 lines (+45 percent since the July extraction) and `MeetingSessionController.swift` to 1,622 (SA-4); the main-thread invariant is neither compiler- nor runtime-checked (SA-3); zero previews, no smoke rendering, no UI tests (SA-9); and the two most-seen surfaces, the detection prompt and the recording HUD, are hand-laid-out AppKit that is not keyboard operable (SA-13). The highest-leverage move is an `@Observable` per-meeting document model that owns sidecar reads and writes. No rewrite is warranted.

**The Python and dependency worry.** The Python dependency costs about 320 MB of venv and about 100 packages, plus uv and Homebrew at install time. The real problems are that the install binds to the clone (fix 1), the bundle tool installs dependencies without the lock (it would ship anthropic 2.0.0 today, which the code has never been tested against, QG-3, DI-4), and ffmpeg is still a hard runtime dependency at three call sites even though the native AVFoundation replacement was proven in DEP1 (DI-12). Options with costs:

| Option | Cost | Verdict |
|---|---|---|
| Keep Python, ship the embedded runtime (DIST1) in a notarized DMG | 2 to 4 focused weeks plus $99/year; app about 400 MB, about 150 MB if MLX becomes an on-demand pack | Do this. Python becomes invisible to users. |
| Full Swift port (I7) | About 21k LOC of Python, 3 to 6 months solo, summary-quality regression risk; LOCAL12 already found no MLX-Swift candidate | Not before go-live. |
| Hybrid: port orchestration, cloud summarizers and publishers to Swift (about 10k LOC, 6 to 10 weeks), keep Python only as an optional local-model server | L to XL | The right long-term shape if Python shrinkage is ever wanted; trigger it on maintenance pain, not the calendar. DIST2's dismissal of it is stale (DI-14). |

## Perspective 3: market placement, and whether to continue

**What Google did.** Two 2026 moves. Gemini "Take notes for me" in Meet expanded to in-person meetings (rollout from mid-August 2026, cloud, bundled into Workspace and Google AI plans, 8 languages, no Ukrainian). And, closest to meeting-pipe, Google AI Edge Foresight (covered by TechCrunch on 2026-10-08): a free, experimental Google Labs Mac app for Apple Silicon that records mic and system audio and transcribes and summarizes on-device, with chat over meetings and a local knowledge base. TechCrunch frames it as a Granola competitor and possibly a showcase for Google's offline models. Speaker labels, export and languages were not reported.

**The rest of the field.** Funded cloud notetakers (Granola at a $1.5B valuation, Otter, Fireflies, Fathom now inside Superhuman, Read AI, tl;dv) and platform bundles (Teams Facilitator with Copilot, Zoom's AI, Notion AI Meeting Notes in Business, Apple Notes transcription in the OS) own the mainstream. On the local-first side: Talat runs the same FluidAudio + Parakeet stack on the Neural Engine, summarizes locally, matches voices to people you named before, links calendar events, auto-exports to Obsidian or a folder, and has an MCP server, all as a small signed download (on Setapp about $9/month standalone, or reported $49 to $99 one-time). anarlog (formerly Hyprnote, MIT, about 9.5k stars), Meetily (MIT, about 32k stars), MacParakeet (GPL) and others are free. FluidAudio's own showcase lists about 50 apps built on it.

**Where meeting-pipe actually stands.** Table stakes, not differentiators: bot-free capture, on-device ASR and diarization, local LLM summaries, an MCP server, Obsidian export, chat over meetings. Genuinely distinctive (absence of evidence elsewhere, not proof): a policy layer that enforces what leaves the Mac per meeting type (regulated and NDA modes through one chokepoint, NDA meetings withheld from Ask, digests and MCP); workflows as routing with per-type engine, destinations and context; isolated multi-sink publishing including a Notion database; summary points with verified timestamp chips; capture-first mute redaction; Ukrainian support that the bundled tools lack; a Claude CLI backend on an existing subscription; plain files and fully MIT. Behind: install (the biggest gap), calendar, speaker naming, in-person and mobile capture, a live notepad during the call, sharing, and trust signals (0 stars, no signed release, no site).

**Options.**

| Option | Verdict |
|---|---|
| A. Keep it personal | Recommended default. It does a job you are satisfied with and nothing in the market gives you a reason to stop. |
| B. Open source it properly | Worth doing only in a light form: signed DMG, short README with a demo, model attributions, an explicit "personal project, no promised support" note. Do not chase community growth. |
| C. Paid indie Mac app | Not now. Talat and Foresight already occupy the shape, and you would own signing, updates, payments, support, consent and BIPA hygiene. Only consider it if a cheap demand test with thresholds set in advance clears, and a wedge they do not serve is proven, most plausibly consultants or lawyers juggling clients under different NDAs who need per-client routing and audit-friendly local records. |
| D. Niche B2B (regulated, on-prem) | No. SOC 2, fleet deployment, legal and a sales motion are a different business. |

**My honest opinion.** Keep it, and stop treating it as a product-in-waiting. What you have built is unusually rigorous for a personal tool and it is correctly shaped for your situation (bilingual meetings, confidential work, Notion and Claude Code in your stack). But the commodity layer of this category is now free from Google and cheap from indies, and the parts that are uniquely yours serve a small audience. The best return on your next month is not distribution, it is the pain you already feel: end detection that never chops a meeting, speaker naming that learns, and a measured view of transcription accuracy. If you still want it public after that, do option B cheaply. One thing to check regardless: whether your employer's policy allows a self-built recorder and AI pipeline on the work laptop, and that you follow the consent rules that apply to the people in your meetings.

## Improving transcription and people identification

Measured on this Mac, ASR itself is not where content goes missing: 0.7 to 8 percent of energy-active seconds fall outside any segment and the longest gap is 1 to 4 s. The big losses are capture and end detection (fix 2). Transcription accuracy has never been measured on your audio, so the "gaps" cannot be quantified or regression-tested yet (FQ-9). Highest-leverage moves, in order:

1. **Channel-aware attribution (S, then L).** Never give your label to a strongly system-dominant segment, normalize each channel's gain before mixdown, warn on a very quiet mic. Then diarize the system channel alone for remote voices and attribute mic-dominant speech to you. This removes the you-versus-remote merge class on headphone calls and gives cleaner remote embeddings for the roster (FQ-3, FQ-8).
2. **Make the roster learn (M).** Score each diarizer span against roster centroids using the per-chunk embeddings FluidAudio already returns (currently averaged away into one mean per cluster), passively enroll high-confidence matches, add a name picker with case-insensitive matching and a Merge action, a play-sample button on unnamed chips, and a batch "apply to my other meetings with this voice" that re-finalizes without ASR (FQ-1, UX-7).
3. **Use names you already have (M).** Calendar attendees and meeting-app participant lists are the cheapest name source and are unused; CAL1's NO-GO holds only for your own calendar setup (FQ-14). Talat and Granola both lean on this.
4. **Word-level speaker assignment (M).** Speakers are assigned per sentence bucket and diarizer speech under 1 s is dropped, which hurts interjections and handovers in standups (FQ-7).
5. **Measure, then boost vocabulary (M).** Build a 30 to 60 minute hand-corrected English, Ukrainian and code-switched set with a WER mode, then try FluidAudio's bundled CTC custom-vocabulary boosting fed by glossary terms and roster names; today the glossary is only after-the-fact string substitution (FQ-10).

Model notes from the repo: keep Parakeet TDT v3 (the only model in the pinned FluidAudio that covers Ukrainian; upstream FLEURS WER about 5.4 percent English, 7.2 percent Ukrainian on read speech). Qwen3-ASR and Cohere Transcribe in FluidAudio lack Ukrainian. Sortformer caps at 4 speakers. Whisper large-v3-turbo would need a second runtime and has no evidence here; revisit only if the WER set shows Parakeet missing the bar. The FluidAudio pin is about five months old and a newer release was not checked. The local summarizer is below the project's own ship gate and its refresh bench (LOCAL13) has not been run since July (FQ-12).

## Maintainability and process

The documentation and process apparatus now costs more than it returns for one developer. Markdown grew from 0.48 MB on 2026-06-01 to 4.26 MB today (the backlog alone is 2.82 MB), 622 of 1,003 commits touch `docs/backlog`, and since 2026-08-01 about 96 of 209 commits are docs-only. It needs an AI agent to read and write it, it no longer fits in a human head, and it did not catch the drift that mattered: red CI for 82 days and ten P1 rows that are shipped but unconfirmed. Throughput has also collapsed (commits per month: 318 in July, 196 in August, 9 in September, 4 in October; done entries 127, 86, 2), which reads as the verification queue, not the code, becoming the bottleneck (SA-5, SA-6).

Two suggestions. First, a WIP limit: no new filings while more than a handful of P1s are partial, and close or revert each partial P1 after a confirmation sprint. Second, cut or hide surface that does not serve the core job (record, transcribe, label, summarize, publish): the Facts rail (your own note: barely useful; 1.2 percent of actions ever resolved), the Prep card, the App Intents that cannot be invoked without a Developer ID, LoRA training and dogfood tooling, a second Apple Intelligence engine in Swift, the LAN sink, and possibly digests and stats behind an Experimental switch (SA-11). Keep Ask, search and Quick Find, People and the roster, the Notion, Obsidian and filesystem sinks, workflows, the MCP server, and the URL scheme.

## What this review could not see

- Your work-laptop library and event log; library-scale numbers are quoted from the repo's spike docs, not recomputed.
- A real clean-Mac install, a VM install, or a corporate MDM-managed Mac; install timings are estimates.
- Any live meeting app, non-English Teams, Zoom, Slack or Webex UI, or whether Zoom and Slack release process audio at leave; locale gaps are inferred from matcher code.
- Word-level accuracy (no reference transcripts exist) and any audio by ear; channel readings are RMS heuristics over 9 recordings.
- Hardened-runtime and notarization behaviour of the embedded Python and MLX (needs a Developer ID).
- Runtime UI behaviour, VoiceOver and keyboard paths, and real CPU and memory during a 2 to 3 hour recording.
- Whether the pipeline suite passes under anthropic 2.0.0; only the type errors are confirmed.

## Appendix: all findings with verified severity

104 findings across the seven code and test angles. Critical and high findings were adversarially verified; medium and low ride on the finder's evidence. "Already filed" names the closest existing backlog row where one exists.

| ID | Severity (verified) | Blocks go-live | Finding | Already filed |
|---|---|---|---|---|
| DI-1 | critical | yes | Installed app loads its resource bundles from the repo's .build directory; any relocated or distributed copy crashes at launch |  |
| DI-3 | high | yes | No terminal-free install exists, and the from-source path (about 32 steps, admin rights, Swift 6 CLT) has never been run on a clean Mac | DIST1, D8, DOC10 |
| DI-5 | high | yes | A drag-installed app has nothing to replace install.sh's other jobs: no login agent, no model prefetch |  |
| FQ-1 | high | no | Auto speaker naming reaches a third of voices for the owner and zero for a new user; the matcher's own data says the design is at its ceiling | FEAT14 (P3 partial), FEAT17 (P2 partial, GO); the matcher wo |
| FQ-2 | high | yes | With 'Your name' unset (the default, never asked), the user's own voice is labelled '1', counted as a roster match, and leaks into summaries |  |
| FQ-6 | high | yes | The largest source of 'missing transcript' is capture and detection, not ASR | END9, END10, END11, END12, END13, END14, REC17, REC14 (P1/P2 |
| PD-1 | high | yes | End-of-call policy honours every end, so each third-party UI change turns into chopped recordings | Symptoms: END9, END10, END11, END12, END13, END14 (all P1, p |
| PD-3 | high | yes | A Google Meet browser recording ends after 120 s on another tab, minimized, or on another Space | END5 (done; designed this floor). DET6 and MIC7 touch browse |
| PD-4 | high | yes | No release gate: 11 P1 fixes unverified in the field, installed build 6 weeks stale, builds carry no identity, CI red since August | Field verifications are tracked per row (END9 to END14, REC1 |
| PD-6 | high | yes | Off the record fails open, and removes only the mic channel | MIC14 (done) built the feature; the fail-open and channel sc |
| PP-5 | high | yes | The installed pipeline is an editable install bound to the git checkout, so the app depends on the clone staying put and unchanged | DIST1 (partial; the editable binding itself is not named) |
| QG-1 | high | yes | CI on main has been red for 82 days and the signal is being ignored |  |
| QG-2 | high | no | runWithTimeout puts blocking AVAudioEngine calls on the Swift cooperative pool, so the REC13 wedge bound fails when threads are scarce (confirmed repro) |  |
| QG-3 | high | yes | Floor-only dependency ranges plus a lock-ignoring distribution build: the drag-install bundle would ship anthropic 2.0.0, which the code is incompatible with at type level and has never been tested against |  |
| QG-4 | high | yes | Lifecycle tests pin the pure halves but not the wiring or real signals, and the P1 false-end cluster keeps shipping past them | END9, END10, END11, END12, END13, END14, DET13, VALOWN1 |
| SA-1 | high | yes | CI is red on main and nobody notices because pushes are rare |  |
| SA-5 | high | yes | Most active P1 work is shipped but unconfirmed, and confirmation depends on one person's calendar | END9-END14, REC17, DET13, UX74, HYG7 individually; the proce |
| UX-1 | high | yes | Install and update are a developer build-from-source workflow with no update path | DIST1, D8 |
| UX-15 | high | yes | End-of-call detection still stops live meetings, and browser meetings other than Meet are invisible | END9, END10, END11, END12, END13, END14, DET13, REC17, DET6 |
| UX-2 | high | yes | The installed app silently depends on the cloned repo folder |  |
| UX-3 | high | yes | Onboarding steps are not wired together: presets ignore the Notion step, and the default preset's key is never asked for |  |
| UX-5 | high | yes | The welcome promise contradicts the defaults: transcripts go to Anthropic and the library sits inside iCloud's reach | SEC12 |
| UX-7 | high | no | Speaker naming is per-meeting manual labour, error-prone, and the roster learns only from clicks | FEAT14, FEAT17, PERF8 |
| DI-10 | medium | no | Uninstall leaves scheduled jobs running and several GB behind |  |
| DI-11 | medium | no | Undocumented Documents-folder TCC prompt, caused by the default library location | SEC12 (iCloud half only) |
| DI-12 | medium | no | ffmpeg remains a hard runtime dependency at three call sites even though the native replacement was proven | DEP1 (spike only), DIST1 |
| DI-13 | medium | no | Default first-summary path requires two external accounts, one of them prepaid |  |
| DI-14 | medium | no | The I7 port price is rising and DIST2's dismissal of the hybrid is stale | I7, DIST2, LOCAL12 |
| DI-15 | medium | no | Single-vendor ASR pinned exact, with a known macOS 27 ANE issue and no fallback | LOCAL5 (pin rationale only) |
| DI-2 | medium | no | The 'installed' Python pipeline is the git checkout: deleting, moving or pulling the clone changes or breaks production |  |
| DI-4 | medium | yes | The DIST1 build tool cannot produce a shippable bundle as written | DIST1 (these defects not listed) |
| DI-6 | medium | no | Every install holds a TCC-trusted signing key that any app can use without a prompt |  |
| DI-7 | medium | yes | No update mechanism, no versioning, no documented update procedure |  |
| DI-8 | medium | no | install.sh's restart path repeats the silent-failure bug rebuild.sh already fixed, and never checks the daemon came up |  |
| DI-9 | medium | no | Toolchain and OS gates are checked too loosely: Swift 6 is required but not checked, and the plist claims macOS 13 |  |
| FQ-10 | medium | no | FluidAudio's bundled acoustic vocabulary boosting is unused; the glossary only does after-the-fact string substitution | ASR1 (done; the post-ASR glossary only) |
| FQ-11 | medium | no | Pinning a transcription language is a script coercion, not 'skip detection', and the Preferences copy says otherwise |  |
| FQ-12 | medium | no | The local summarizer, the 'local-first' privacy path, is below the project's own ship gate, and its refresh bench has sat unrun since July | LOCAL13, LOCAL14 (owner-verification, complex) |
| FQ-13 | medium | no | Apple Intelligence fails every Ukrainian meeting, and recovery is manual | PIPE6 (done: typed error plus manual local re-summarize) |
| FQ-14 | medium | no | Calendar attendees and meeting-app participant names, the cheapest name sources, are unused; the calendar NO-GO only holds for the owner's own setup | CAL1 (done NO-GO), CAL3 (deferred P3) |
| FQ-16 | medium | no | Secondary intelligence surfaces are mostly thin: Facts rail barely used, a digest rendering bug, MCP transcript paging, Ask's narrow default context | DV5, UX75, AUTO5 |
| FQ-3 | medium | no | The owner's label is applied to a whole cluster with no per-segment channel check, so remote voices get attributed to the user |  |
| FQ-4 | medium | yes | The summary prompt is hard-coded to the owner's regulated-SaaS employer, and the installer ships the owner's team context to every new user |  |
| FQ-5 | medium | no | On the default cloud backend, meetings over about an hour get no summary, only a paste-into-Claude-Code bundle |  |
| FQ-7 | medium | no | Speakers are assigned per sentence bucket rather than per word, and diarizer speech under 1 s is dropped |  |
| FQ-8 | medium | no | ASR and diarization run on an unnormalized (L+R)/2 mixdown, so a quiet mic channel makes the user's own speech the hardest to transcribe and to separate |  |
| FQ-9 | medium | no | Transcription accuracy has never been measured on the owner's audio, so the 'gaps' pain point cannot be quantified or regression-tested |  |
| PD-10 | medium | no | The default library lives in ~/Documents, so iCloud Desktop & Documents syncs live meeting audio | SEC12 (done, warn-only) |
| PD-2 | medium | no | Lifecycle signals are calibrated to English-UI Teams; other apps and locales run on fewer, unmeasured legs | DET6 covers browser tabs other than Meet. AUD audit 2026-06- |
| PD-5 | medium | no | runWithTimeout runs blocking engine calls on the Swift cooperative pool, so its bound fails once the pool saturates |  |
| PD-7 | medium | no | The ffmpeg merge and redaction wait before draining stderr, a known deadlock pattern, and never kill a timed-out ffmpeg |  |
| PD-8 | medium | no | AXMuteButtonProbe still polls cross-process AX on the main thread, including a full tree re-walk |  |
| PD-9 | medium | no | Recovering from a false end is left to the user noticing within about 90 s | DET13 (P1, cooldown drops the live candidate); END13 item 5  |
| PP-1 | medium | no | CI is red and pytest has not run since anthropic SDK 1.0, and the SDK's httpx2 move will silently bypass the egress guard on the next lock refresh |  |
| PP-10 | medium | no | Deleting a meeting does not delete everything derived from it |  |
| PP-2 | medium | no | The claude_cli backend runs a full Claude Code agent with tools, the user's MCP servers and hooks, cwd '/', saved sessions, and the API key |  |
| PP-3 | medium | no | No recording-consent posture, and the privacy claims a new user sees do not match the shipped defaults | SEC12 (iCloud warning only, done); consent posture not filed |
| PP-4 | medium | no | Voiceprints of every participant are created automatically and kept indefinitely, without disclosure, and are readable by other local accounts | SEC14 (0600 for transcripts/summaries, done); voiceprint pos |
| PP-6 | medium | no | Retired, mistyped or refused model ids fail as 'unknown' with a generic Retry, auto does not fall back, and doctor checks a different model |  |
| PP-7 | medium | no | An unparseable config.toml fails open: the daemon runs on defaults and the next Preferences save overwrites the file, including regulated_mode |  |
| PP-8 | medium | no | The meetingpipe:// URL scheme is unauthenticated: any app or clicked link can start a recording or trigger cloud calls |  |
| PP-9 | medium | no | The long-meeting gate stops automatic summaries for meetings over about an hour to save cents, and no API spend is recorded anywhere |  |
| QG-5 | medium | no | Both test suites still write into the real ~/Library/Logs/MeetingPipe, contradicting CONVENTIONS.md's 'historical, not ongoing' |  |
| QG-6 | medium | no | No platform matrix: CI is macOS 15 debug only, the declared macOS 14 floor is never tested, the shipped release config is never built in CI, and the docs name the wrong runner |  |
| QG-7 | medium | no | The installer, uninstaller and runtime bundler have no automated coverage, and two of the local gates never run in CI | DIST1 (clean-Mac test owner-owed) |
| QG-8 | medium | no | The default cloud summarize call is only ever verified against fakes, and a request-shape change broke every summary in the field |  |
| QG-9 | medium | no | ASR and diarization inference never runs in any automated test, and there is no golden-audio regression net |  |
| SA-10 | medium | no | Per-meeting document state has no owner: views write sidecars, and a background carry races main-thread writes | PERF8 (optimistic model and self-write suppression scoped, g |
| SA-11 | medium | no | Feature surface is roughly twice the core job, and several features are self-declared low value | DV5 (Facts), CAL3 (Prep premise), AUTO1 |
| SA-12 | medium | no | PipelineDriver is a 24-method protocol with failing defaults, and views build their own launchers outside the job lane | ARCH5 (driver-protocol leg, deliberately unshipped) |
| SA-13 | medium | no | Two UI stacks: the most-seen surfaces are hand-laid-out AppKit and are not keyboard operable | UX27 (P4) |
| SA-2 | medium | no | ObservableObject-only state layer re-renders the detail pane and transcript at 15 Hz during playback, patched surface by surface | PERF8 (symptom only; root-cause class unfiled) |
| SA-3 | medium | no | The spine's main-thread invariant is neither compiler-checked nor runtime-checked | CONC4 (done; complete-mode migration explicitly scoped out) |
| SA-4 | medium | no | God-object regrowth in the recording and session core after the July extraction | ARCH5 (P3, promote-on-touch) |
| SA-6 | medium | no | Documentation and process apparatus now outweighs the code and still drifts | DOC15, HYG8 (narrow slices only) |
| SA-7 | medium | no | First-run window traps: onboarding has no Dock or Cmd+Tab presence and restarts after the required relaunch | UX56 (partial, P2); onboarding part unfiled |
| SA-8 | medium | no | Composition root cannot be built headless, so wiring is tested by grepping source text |  |
| SA-9 | medium | no | No UI verification path: zero previews, no smoke rendering, no UI tests | T2 |
| UX-10 | medium | no | Preferences is an engineer's control panel with key personal settings buried under 'Pipeline' |  |
| UX-11 | medium | no | Workflow routing needs bundle ids and regular expressions |  |
| UX-12 | medium | no | The Notion path verifies the wrong thing and rewrites Date and Status on every republish |  |
| UX-13 | medium | no | Accessibility needs a manual relaunch that restarts onboarding, and Quit does not quit |  |
| UX-14 | medium | no | Recording > Output directory is a live free-text path that can make the library appear to vanish |  |
| UX-16 | medium | no | No calendar or participant context, so titles and candidate names must all come from the user | CAL1, CAL3 |
| UX-4 | medium | no | The user's own name is never asked, and without it your voice is never labelled and naming it yourself never sticks |  |
| UX-6 | medium | no | On the default engine, every meeting over about an hour gets no summary, only a paste-into-Claude bundle |  |
| UX-8 | medium | no | Summaries are published before naming, so action owners and attendees are diarization labels | DV5 |
| UX-9 | medium | no | Troubleshooting and permission surfaces speak developer vocabulary |  |
| DI-16 | low | no | Gatekeeper and signing guidance in SETUP and README is wrong for both the current and the future path |  |
| DI-17 | low | no | API tokens pass through argv, and the Keychain ACL trusts /usr/bin/security | SEC8 (migration only) |
| FQ-15 | low | no | Naming copy promises automatic recognition that the matcher delivers about a third of the time |  |
| PD-11 | low | no | Every recording has a hard ceiling of about 3 h 6 min, and the stop message blames the disk | REC3 (deferred cap-raising note) |
| PD-12 | low | no | A malformed config.toml silently falls back to defaults, dropping regulated mode in the daemon |  |
| PD-13 | low | no | Resource growth is unbounded by default: whole-file in-memory transcription inside the recorder process, no disk preflight, retention opt-in | LOCAL18 (free-RAM watchdog unverified) is adjacent |
| PD-14 | low | no | Concurrency invariants rest on convention, and the docs describing them have drifted | CONC4 (done) introduced the targeted flag; complete mode is  |
| PD-15 | low | no | Some recorder copy is technical or stale | REC15 (installTap toast origin) |
| PP-11 | low | no | Secrets: any same-user process can read the Keychain items without a prompt, tokens pass through argv, and every child process inherits them | SEC8/SEC5 (done; residuals acknowledged in code comments) |
| PP-12 | low | no | Backups are unencrypted, world-readable, and written non-atomically |  |
| PP-13 | low | no | Notion API version pinned to 2022-06-28 in three places across two trees |  |
| PP-14 | low | no | Dependency floors are stale and unbounded, and the install hides frozen-sync failures |  |
| PP-15 | low | no | Third-party model licences and attributions are not tracked for distribution | BRAND1..9 (compliance pages, P3 deferred) partially |
| QG-10 | low | no | Compiler warnings regress silently: two Swift-6-mode errors are back in production code after CONC4 shipped warning-clean |  |
| SA-14 | low | no | View composition widens invalidation: computed sections and a detail view split by extension |  |
| UX-17 | low | no | The Tutorial and docs miss or contradict the first-run reality |  |
