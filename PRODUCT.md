# Product

## Register

product

## Users

Built for one user (Georgy), and people built like him: engineers, PMs, and consultants who care about local-first software, run meetings on a single Mac, and won't tolerate a cloud database. They live in macOS day to day and expect native chrome. The job-to-be-done is: capture a meeting, get a labelled transcript plus a usable summary published into the notes system they already keep, with no surprises and no egress that wasn't opted into.

**Reading CLI flags is a tolerance, not a preference, and getting set up is not the job.** An earlier version of this section said the persona "reads CLI flags faster than landing pages", which was true as a description and wrong as a licence: it was read as permission to leave setup as an exercise for the reader, and it steered work away from the one path a new user actually walks. Setup ease is in scope and always was. [`docs/SETUP.md`](./docs/SETUP.md) is the single exhaustive clean-Mac walkthrough, written for someone with no programming background, and it is expected to stay true as surfaces change. What stays out of scope is everything tied to *selling* (see the project `CLAUDE.md`): licence keys, telemetry, a landing site, marketing copy. A guide that gets one person from a fresh Mac to a first published summary is not marketing.

meeting-pipe runs in the menu bar so it stays out of the way during the meeting itself. The user only really sees the UI at four moments: the prompt panel when a call is detected, the recording HUD while audio is flowing, the done-notification when a summary is ready, and the Library window when reviewing or republishing yesterday's meetings. Every other moment is "nothing visible, nothing needed."

## Product Purpose

meeting-pipe records video meetings on-device (Zoom, Teams, Google Meet, Webex, Slack huddles; native apps and browser tabs), transcribes them with speaker diarization on the Apple Neural Engine, and publishes a Markdown summary to Notion, Obsidian, the filesystem, or a LAN share. Two values are load-bearing:

- **Local-first by default.** Audio, transcript, and diarization stay on the Mac. Summarization is the only step that can leave the machine, and it can be flipped to a local MLX model for a zero-egress pipeline. Regulated mode plus the local backend together guarantee that nothing crosses the wire.
- **Hands-off when it works, predictable when it doesn't.** Detection fuses multiple signals into one verdict before a prompt fires; the lifecycle subsystem is built around not being wrong. When something does fail, the failure is named in plain English, not buried in a state machine.

Success looks like: meetings happen, summaries appear in Notion within a few minutes of Stop, and the user does not have to think about meeting-pipe between those two events. Long meetings (over one hour by default) write a ready-for-Claude-Code bundle to disk instead of burning API budget without permission.

## Brand Personality

Three words: **local-first, quiet, deliberate.**

- **Local-first.** Privacy is not a feature, it is the personality. "On-device by default" sits in the first sentence of the README and the UI never asks the user to compromise on it. The local backend, regulated mode, BYO mode, and LAN sink are all surfaced as first-class options, not "Advanced" trapdoors.
- **Quiet.** The product does not announce itself. No "Listening..." copy, no "AI-powered" badges, no celebration toasts. The summary just appears. The menu-bar title reads literal state ("Idle" / "Recording" / "Processing..."), never aspirational.
- **Deliberate.** Fixed window sizes, hairline borders, SF Pro at native 13px, one signal-teal accent that earns its use. The verdict-fusion lifecycle is the same personality applied to detection: do not be wrong, do not guess, wait for evidence.

Voice: address the user as "you" in second person. Refer to the system in third person ("the daemon", "meeting-pipe"), never "we" or "I". Sentence case everywhere except menu items (Title Case, per macOS HIG). Ellipsis only for in-flight async states or for an action that opens another surface. No exclamation marks ever. No emoji in product chrome. Notification bodies are two to four words.

## Anti-references

- **SaaS marketing cliché.** No gradients, no "powered by Claude" sparkle, no decorative AI iconography, no emoji in microcopy. The product uses Claude under the hood; it does not brand itself with it. "Successfully published your summary! 🎉" is the exact failure mode to stay away from. Concretely: not the Notion AI / ChatGPT / Perplexity surface aesthetic.
- **Generic Electron-app feel.** No web-rendered chrome pretending to be a desktop app: wrong density, wrong fonts, wrong window sizes, no SF Symbols, no native-looking translucency. The HUD is a real `NSPanel` with `NSVisualEffectView .hudWindow`. The menu-bar item is a real `NSStatusItem`. If a surface can be built with native materials, it is. Concretely: not Slack, not Discord, not Linear's desktop wrapper.
- **Modern dark-glass fintech / AI-tool family.** Glassy floating cards, neon accents, gradient borders, "futuristic" framing. Even the well-crafted version of that look is wrong for a calm utility that sits in the menu bar.

## Design Principles

Seven strategic principles. These shape decisions about what to build and why; visual rules live in DESIGN.md.

1. **Local-first is a UI commitment, not just a backend setting.** Every surface that lets the user route data shows the local option at the same visual level as the cloud one. Regulated mode and BYO mode get first-class affordances on the prompt panel and the Workflow editor, not "Advanced" tucks.
2. **Truthful states, not aspirational ones.** Status copy describes literal current state. "Idle", "Detected Zoom", "Recording", "Stopping...", "Processing...". Never "Listening" or "Standing by". When the daemon is unsure, the UI says so; it does not paper over with a confident label.
3. **Quiet about the AI.** No sparkle, no "AI summary" badge, no Claude branding in product chrome. The summary just appears in Notion. The local-vs-cloud backend choice is exposed because it has privacy consequences, not because it is a feature to celebrate.
4. **Match the mac, then earn deviations.** Default to AppKit conventions: SF Pro at 13px, SF Symbols, sentence case for chrome (Title Case for menu commands), hairline borders not heavy shadows, fixed window sizes, system Dark Mode auto-follow, cool-porcelain canvas. When a custom pattern is right (the Library's smart-folder rail, the workflow tint on the HUD, the two-channel waveform), keep it grounded in native materials.
5. **Show the work; never hide a failure.** When detection misses, the manual hotkey is one keypress away and the Permissions tab tells the user exactly which grant is missing. When a sink fails, the row's status pill says why and the other sinks still fire. When a long meeting skips Anthropic, the `.READY_FOR_MANUAL.md` sidecar tells the user what to paste into Claude Code. No silent fallbacks, no quiet degradations.
6. **The CLI is an escape hatch, not a surface.** Every product operation gets a UI affordance; the `mp` CLI and the daemon's argv commands exist for debugging, dogfood, and owner-dev diagnostics. A capability that ships CLI-only is unfinished (standing rule since 2026-07; the backlog delegation contract enforces it). The persona above reads CLI flags fine, but that is tolerance, not preference.
7. **Setup is a surface, and its failures are the loudest ones.** A first-run user has no mental model to fall back on, so an unexplained prerequisite or a silently-ineffective permission reads as "this is broken", not "I missed a step". Prerequisites fail early with a message naming the fix (`install.sh` dies on a missing Swift toolchain rather than letting `swift build` emit `invalid active developer path`), permissions explain what they buy and what breaks without them, and the walkthrough in [`docs/SETUP.md`](./docs/SETUP.md) is maintained as a first-class surface, not a nice-to-have. This is principle 5 (show the work, never hide a failure) applied to the half hour before anything works.

## Accessibility & Inclusion

Apple HIG-floor accommodations, formally:

- **VoiceOver on every interactive surface.** The rail items, the meetings list rows, detail-pane tabs, prompt panel buttons, Preferences controls, the recording HUD, the menu-bar dropdown, and the done-meeting notification all carry accessible labels and roles. Custom views (the smart-folder rail, the two-channel waveform, the workflow chip) declare their roles explicitly.
- **Focus ring always visible.** Custom controls match the system's accent-ring style; nothing is focus-only-via-mouse. Tab order matches reading order on every window.
- **System Dark Mode auto-follows.** No per-app override. Same palette inverted; dark mode is muted near-blacks (`#1A1B1E` base), not pitch black.
- **`prefers-reduced-motion` honored.** The recording-dot opacity loop, the panel fade in/out, the Library row pulse, and the workflow tint transitions degrade to crossfades or instant transitions when reduced motion is on. This applies whether the user is on macOS Reduce Motion or has it set per-app.
- **Dynamic Type for content surfaces.** Transcript, summary, and Markdown rendering respect the system text-size setting. Chrome (menu bar, HUD, status bar text) stays at fixed mac-native sizes by design, because rescaling 22pt status bars breaks the mac mental model.
- **No color-only state.** Status pills carry text plus tint; the recording dot is coral and labelled "Recording"; workflow tints are always paired with the workflow name; sink success and failure both carry icons plus copy. Color-blind safe in both themes.
- **Keyboard-first for every recording flow.** The manual record hotkey (default `⌃⌥M`) toggles globally; `⌃⌥⇧M` is the panic force-stop. Library actions have keyboard shortcuts; the prompt panel's Record / Skip / BYO buttons are reachable by Tab; Cmd+W hides the Library window without quitting the daemon.
