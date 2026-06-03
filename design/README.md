# Meeting Pipe — Design System

A modern, mac-first design system for **Meeting Pipe**: a local-first meeting
recorder that detects calls, captures audio on-device, transcribes with speaker
diarization, and ships AI-summarized notes to Notion.

The product runs almost entirely in the macOS menu bar today. This system is
built so the next generation of UI — local summary management, manual note
editing, settings — can grow from the same vocabulary without inventing new
patterns each time.

---

## Sources

| Source | Where | Read on demand via |
|---|---|---|
| Codebase (Swift menu-bar app + Python pipeline) | `github.com/ggegelya/meeting-pipe` | `github_get_tree`, `github_read_file` |
| Spec | `meeting-pipe/SPEC.md` | (read in setup) |
| README | `meeting-pipe/README.md` | (read in setup) |

No design files, Figma, or pre-existing brand were attached. Identity,
typography, color, and iconography are **proposed** by this system, derived from
the codebase's voice, the macOS-native interaction patterns it uses
(`NSPanel`, `NSVisualEffectView .hudWindow`, `SCStream`, `UNUserNotification`),
and the user's stated direction: *modern, mac-first, minimalistic, slightly
futuristic, simple*. **All of it is open to your edits.**

---

## Product context

**One product, one platform.** Meeting Pipe is a single macOS 14+ application
distributed as `MeetingPipe.app`. There is no website, no mobile companion, no
web UI.

**Architecture in one breath.** A Swift menu-bar daemon detects meetings via
two-signal AND (a known meeting app + microphone in use), shows a floating
HUD-style prompt asking whether to record, captures system audio via
ScreenCaptureKit and the user's mic via AVAudioEngine, mixes them to a 16 kHz
mono WAV, and hands off to a Python pipeline that runs WhisperX + pyannote
(both gated locally), summarizes via the Anthropic API, and publishes to
Notion.

**Surfaces today.**
1. Status-bar icon + drop-down menu (`waveform.circle`, "Idle" / "Recording" / …).
2. Floating "Meeting detected" prompt panel (top-right, 380×180, `hudWindow`).
3. SwiftUI Preferences window (480×560, three tabs: Recording / Detection / Modes).
4. Banner notifications via `UNUserNotificationCenter`.

**Surfaces this system anticipates.**
- A summary library (browse local meetings, re-publish, search transcripts).
- Manual note editor.
- Onboarding (permissions walk-through: Mic / Screen Recording / Accessibility).
- A small marketing site (someday).

---

## Index

| File | What it is |
|---|---|
| `colors_and_type.css` | All design tokens — colors, type scale, fonts, radii, shadows, motion. Single source of truth. |
| `assets/` | Logos, wordmark, app icon, menu-bar template icons. |
| `fonts/` | Webfonts (loaded from Google Fonts in CSS — see Caveats). |
| `preview/` | Cards rendered in the Design System tab — palette, type, components, foundations. |
| `ui_kits/macos_app/` | Pixel-faithful recreations of the Swift/SwiftUI surfaces. |
| `SKILL.md` | Cross-compatible Agent Skill descriptor. |

---

## CONTENT FUNDAMENTALS

The codebase has a strong, opinionated voice — read the SPEC and the inline
comments and you can hear the author. The product copy should match.

### Voice
**Direct, technical, calm. No marketing-speak.** The tool is a utility used by
engineers, PMs, and consultants on regulated calls. It does its job and gets
out of the way.

- **Person.** Address the user as **"you"**. Refer to the system in third
  person ("the daemon", "Meeting Pipe", *not* "we" or "I"). The daemon doesn't
  have a personality — it has a job.
- **Brevity.** A single sentence beats a paragraph. Notification copy is two
  to four words: "Recording started." "Meeting published." "Open in Notion."
- **Truthful states.** Status copy describes literal state, not aspiration.
  *"Idle"*, *"Detected Zoom"*, *"Recording"*, *"Stopping…"*, *"Processing…"*.
  Never "Listening" or "Standing by".
- **Quiet about the AI.** The product uses Claude under the hood but does not
  brand itself with it. The summary just appears in Notion; the user doesn't
  need a sparkle icon to know.

### Casing
- **Sentence case** for everything: titles, buttons, menu items, panel labels.
  Apple-native: *"Open Logs Folder"*, not *"Open logs folder"* in menu items
  (mac convention is title case for menu commands), but **sentence case
  everywhere else**.
- **Menu items use Title Case** (mac HIG): *"Start Recording"*, *"Open Recordings Folder"*, *"Quit MeetingPipe"*.
- **Buttons sentence case**: *"Record"*, *"Skip"*, *"Always for Zoom"*, *"Record (BYO)"*.

### Punctuation
- **Ellipsis (…) is meaningful**: indicates an in-flight async state
  (*"Processing…"*) or that an action will open another surface
  (*"Preferences…"*). Never decorative.
- **Em dash with spaces** for asides: *"Record, but skip the API call — you'll
  summarize the transcript yourself."*
- **No exclamation marks.** Ever. Even on success: *"Meeting published."*, not
  *"Meeting published!"*.

### Numbers, units, identifiers
- Lowercase units with a space: *`16 kHz`*, *`80 000 chars`*, *`5s`*.
- File paths and bundle IDs in **monospace**: `~/Documents/Meetings/raw/`,
  `us.zoom.xos`.
- Hotkeys with proper symbols: *`⌃⌥M`*, not *`Ctrl+Opt+M`* (mac convention).
- Timecodes: `mm:ss` for short, `hh:mm:ss` for long.

### Emoji
**No emoji** in product UI. Not in menu items, not in notifications, not in
copy. Allowed only inside user-generated transcript content (where it's
verbatim from the speaker).

### Examples (lift these tones)

> **Good** — Recording started. *(notification body)*
> **Good** — Meeting detected — Zoom *(panel title + subtitle)*
> **Good** — When enabled, the pipeline writes summaries to disk only — no
>            transcript or summary is uploaded to Notion. Use for client /
>            regulated meetings. *(prefs help text)*
> **Good** — Format: 'ctrl+option+m', 'cmd+shift+r'. Restart MeetingPipe after
>            changing.
>
> **Bad** — 🎙️ We're listening! Tap Record to start recording your awesome meeting!
> **Bad** — Successfully published your summary to Notion! 🎉
> **Bad** — Initializing acoustic capture pipeline…

---

## VISUAL FOUNDATIONS

The design system is built on three motifs:

1. **Paper** — the canvas reads as a calm, slightly warm document, not a
   chrome panel. It's where transcripts and summaries live, so it should feel
   like something you'd want to read.
2. **Hairlines, not shadows** — mac-native chrome separates surfaces with
   1px / 0.5px borders, not heavy drop shadows. Shadows appear only on
   *floating* surfaces (panels, popovers, sheets).
3. **Signal blue** — one electric accent, used surgically. It is the color of
   *capture in progress*. Never a decorative gradient, never a background fill
   on large surfaces.

### Color
- **Ink** (warm near-blacks) for foreground. We avoid pure `#000` — `#14161A`
  reads gentler against paper.
- **Paper** (`#FBFAF7` base) for canvas. `#FFFFFF` reserved for raised cards
  and sheets, so layering is legible.
- **Signal** (`#0E8C82`) for the primary action and live capture indicator.
  Used at 100% (button fill, focus ring) or as a 4–10% tint
  (selected row, mention).
- **Pulse** (`#E5484D`) is reserved exclusively for the recording dot and the
  destructive confirm in dialogs.
- **Semantic** — success / warning / danger — appear only in inline status
  rows. Not as backgrounds for entire toasts.
- Dark mode auto-follows the system. Same palette, inverted surfaces; muted,
  not pitch black (`#1A1B1E` base).

### Typography
- **System font is canonical.** SF Pro on mac. We list `-apple-system,
  BlinkMacSystemFont` first in every stack.
- **Display**: *Inter Tight* (Google Fonts). Slight condensation, engineered
  feel; only used at 28px+ for marketing/hero moments. **(Substitution flag —
  see Caveats.)**
- **Mono**: *JetBrains Mono* for code, paths, kbd. SF Mono on mac when
  available.
- **Base size 13px** — mac native. Compact ramp because the app is chrome,
  not content. Marketing pages can step up to `--mp-text-3xl` / `4xl`.
- **Weights**: regular (400), medium (500), semibold (600). **No bold.**
  Apple convention.
- **Tracking**: tight negative on display sizes (-0.02em), 0 on body, +0.08em
  uppercase for eyebrow labels.

### Spacing
- **4-px grid.** Mac chrome lives mostly on 8 / 12 / 16 / 20 ticks — that's
  what `MeetingPromptWindow.swift` uses (16 leading, 14 top, 12 between rows).
- Density: tight. This is a tool, not a content site.

### Backgrounds
- **No gradients** on surfaces. (There is one on the app icon — a subtle paper
  gradient — and that's it.)
- **No textures or patterns.** The blank paper *is* the texture.
- **No full-bleed photography** anywhere in product UI. Screenshots can appear
  in marketing (someday), framed in mac chrome — never edge-to-edge.

### Animation & motion
- **Short, snappy, no bounce.** The Swift code uses 0.18s for panel fade-in,
  0.15s for fade-out. We honor that: `--mp-dur-base = 180ms`.
- **Easing**: `cubic-bezier(0.22, 0.61, 0.36, 1)` — Apple's default-ish out
  curve. No overshoot, no spring.
- **Recording pulse**: a 1.6s opacity loop on the red dot, *not* a scale
  pulse. Scale pulses read as urgent; the dot should feel steady.
- **No skeleton loaders, no shimmer.** Async states use the system spinner or
  the literal label *"Processing…"*.

### Hover & press
- **Hover**: 4–6% darken on filled buttons, light tint background on ghost
  buttons (`var(--mp-ink-100)`). No scale, no shadow change.
- **Press**: 8% darken + a 1px translate-y on raised buttons (matches AppKit
  bezel). No ripple effects.
- **Focus**: 3px outer ring at `var(--mp-signal-600)` @ 32% opacity. Always
  visible — accessibility floor.

### Borders
- 1px hairline `rgba(20, 22, 26, 0.10)` is the default surface separator.
- Stronger 1px `rgba(20, 22, 26, 0.18)` for inputs.
- 0.5px hairlines (Retina) on internal table dividers — `box-shadow: inset 0
  0 0 0.5px ...`.

### Shadows / elevation
- **Resting** surfaces (cards in a list): no shadow, hairline border only.
- **Raised** surfaces (preferences sheet inside main window): `--mp-shadow-sm`.
- **Floating** surfaces (HUD prompt, popovers): `--mp-shadow-lg` + the
  `--mp-hud-bg` translucent fill + 0.5px stroke. Mirrors `NSPanel
  hasShadow=true` + `NSVisualEffectView .hudWindow`.
- **No inner shadows** anywhere.

### Transparency & blur
- Used only on *floating* surfaces and the menu-bar dropdown — anywhere the
  underlying desktop should bleed through. The `--mp-hud-bg` token is
  `rgba(248, 247, 244, 0.78)`; combined with `backdrop-filter: blur(24px)
  saturate(180%)` it matches `.hudWindow`.
- Cards inside windows are **fully opaque**. Don't double-blur.

### Imagery
- Cool / neutral tone. If we use real screenshots, they appear in a
  rendered macOS window chrome (browser_window or macos_window starter), with
  a subtle 1px hairline; never raw rectangles.
- No grain, no sepia, no duotone.

### Corner radii (highly intentional — mac-native)
- 4px tags / chips
- 6px buttons / inputs (matches `NSButton.bezelStyle = .rounded`)
- 10px cards
- **14px panels / sheets** (matches `panel.cornerRadius = 14` in
  `MeetingPromptWindow.swift`)
- 20px hero / marketing cards
- Pill / dot: full-rounded

### Cards
- Resting: `--mp-bg-raised` (white) + 1px hairline + 10px radius. **No shadow.**
- Floating: `--mp-hud-bg` + 14px radius + `--mp-hud-shadow` + 0.5px stroke.
- Padding: 16 / 20 / 24 — never less than 12.
- Content density: dense by default. Don't pad to "modern web".

### Layout rules
- **Fixed window sizes** for product UI — preferences is exactly 480×560,
  prompt is exactly 380 × auto. Web pages are responsive; mac apps are not.
- **Top-right anchor** for floating prompts (16px inset). This is the same
  anchor Notion's web prompts use — explicit precedent in `SPEC.md`.
- Sidebar widths in marketing: 240–280; reading column: 640–720.
- Status bar: always 22pt height (mac-mandated).

---

## ICONOGRAPHY

### Approach
**SF Symbols is canonical.** The Swift daemon is built on SF Symbols
(`waveform.circle`, `mic`, `waveform`, `lock.shield` are referenced in the
codebase). For HTML / web previews where SF Symbols isn't available, we use
**Lucide** as a substitute — a closely-matching open-source set with similar
1.5–2px stroke weight and rounded joins.

| Surface | Icon source |
|---|---|
| macOS app (Swift / SwiftUI) | SF Symbols (system) |
| Web previews, design system docs, marketing | **Lucide** via CDN — `https://unpkg.com/lucide-static@latest/icons/<name>.svg` |
| Logo / mark | Custom — see `assets/` |

### Style rules
- **1.5px stroke** for sizes ≤ 20px. 2px above.
- **Rounded line caps and joins.** No square miters.
- **24px nominal viewBox**, displayed at 16 / 18 / 20 / 24.
- **Monochrome only** — `currentColor`. Never tinted decoratively. Active
  state uses `--mp-signal-600`.
- **No filled icons** as primary state. Filled is reserved for "selected" in
  toggles (e.g. recording state in menu bar).
- **No emoji as iconography.**

### Specific symbols mapped
| Concept | SF Symbol | Lucide equivalent |
|---|---|---|
| Brand mark | (custom) | (custom) |
| Menu-bar idle | `waveform.circle` | `audio-waveform` (in circle) |
| Menu-bar recording | (red dot inside circle) | (custom) |
| Mic permission | `mic` | `mic` |
| Screen recording perm | `rectangle.dashed` | `monitor` |
| Accessibility perm | `accessibility` | `circle-user` |
| Notion publish | (no SF symbol — use Notion glyph from their press kit if available, otherwise label-only) | — |
| Settings | `gearshape` | `settings` |
| Folder | `folder` | `folder` |
| Logs | `doc.text` | `file-text` |

### Logo & marks
- `assets/logo.svg` — wordmark + mark, horizontal.
- `assets/logomark.svg` — mark only, square.
- `assets/wordmark.svg` — wordmark only.
- `assets/menubar-icon.svg` — 18×18 template icon for `NSStatusItem.button.image`.
- `assets/menubar-icon-recording.svg` — recording state, full color (not template).
- `assets/app-icon.svg` — 256×256 squircle app icon.

All marks use `currentColor` so they tint correctly in both modes and inside
the menu bar.

---

## CAVEATS — please review

1. **No prior brand was attached.** The identity proposed here (Paper /
   Ink / Signal blue, the pipe-with-waveform mark, Inter Tight + JetBrains
   Mono) is my read of the codebase voice and the user's "modern, mac-first,
   minimalistic, slightly futuristic" brief. **Tell me which directions to
   push or pull** — bolder color? More mono / terminal-feel? Different
   mark shape (currents I considered: a pipe, a stack of bars, a single
   waveform line)?
2. **Font substitution.** No font files were provided. I'm using **Inter
   Tight** for display via Google Fonts as a stand-in for SF Pro Display
   metrics, and **JetBrains Mono** for monospace. If you have licensed brand
   fonts, drop them in `fonts/` and update `colors_and_type.css`. If you'd
   like me to swap to e.g. *Geist*, *General Sans*, *IBM Plex*, or
   *Söhne*, say the word.
3. **Logo.** The pipe-and-waveform mark is a first pass. It works at 18×18
   menu-bar size and reads well in both modes, but I'm guessing at how
   recognizable / distinctive you want it. Easy to iterate on.
4. **Recording-state menu-bar icon** uses a red dot. macOS's recording
   indicator is also red (and there's now a system-level orange dot for mic
   access). Consider whether you want the in-app indicator to match the
   system orange dot for consistency, or stay coral red for distinctness.
5. **Notion + AI branding.** I deliberately kept those out of the product's
   visual identity (per the "quiet about the AI" voice rule). If you want
   them more visible — e.g. an "Powered by Claude" mark in settings — say so.

---

## SKILL.md

If you download this folder and drop it into `~/.claude/skills/`, it works as
an Agent Skill. See `SKILL.md` for the descriptor.
