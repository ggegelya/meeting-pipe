---
name: meeting-pipe
description: Local-first macOS meeting recorder. Paper, ink, and one signal-teal accent for live capture.
colors:
  # Ink - foreground ramp, cool near-black down to cool grey (porcelain retune)
  ink-900: "#16181C"
  ink-800: "#202329"
  ink-700: "#2D323A"
  ink-600: "#566068"
  ink-500: "#646C77"
  ink-400: "#838B95"
  ink-300: "#B9BFC7"
  ink-200: "#D9DDE2"
  ink-100: "#ECEEF1"
  ink-50: "#F5F6F8"
  # Paper - cool porcelain canvas surfaces (the warm-paper canvas is retired)
  paper: "#F5F6F8"
  paper-sunk: "#ECEEF1"
  paper-raised: "#FFFFFF"
  on-signal: "#FFFFFF"
  # Signal teal - the one accent: live capture and primary action. Splits into a
  # "display" tone (text / graphics / selection) and a deeper "fill" tone so white
  # labels on teal surfaces clear 4.5:1.
  signal-700: "#0A6E64"
  signal-600: "#0E9488"
  signal-fill: "#0C7F74"
  signal-500: "#14A89B"
  signal-400: "#4FC7BC"
  signal-100: "#DFF3F0"
  # On-air - the Instrument LED accent, capture surfaces only. Light-emitting
  # elements (meter segments, level dots, record-key ring, active mic waveform).
  onair-600: "#0FBFAC"
  # Record action fill + label (capture surfaces). Light: deep teal fill, white
  # label. Dark reads backlit (a brighter fill with a near-black label).
  record-fill: "#0C7F74"
  record-label: "#FFFFFF"
  # Pulse coral - recording dot and destructive confirm only. pulse-700 is the
  # light-mode-legible deep variant for coral text (Stop label, recording pill).
  pulse-700: "#BE353A"
  pulse-600: "#E5484D"
  pulse-500: "#F5595E"
  pulse-100: "#FFE4E4"
  # Semantic state - 700 steps are the light-mode-legible deep variants
  success-700: "#16713D"
  success-600: "#1F8F4E"
  success-100: "#DCF1E2"
  warning-700: "#8A5A00"
  warning-600: "#B27300"
  warning-100: "#FFF1CC"
  danger-600: "#C92A2A"
  danger-100: "#FCE4E4"
typography:
  display:
    fontFamily: "Inter Tight, SF Pro Display, -apple-system, sans-serif"
    fontSize: "56px"
    fontWeight: 600
    lineHeight: 1.15
    letterSpacing: "-0.02em"
  headline:
    fontFamily: "Inter Tight, SF Pro Display, -apple-system, sans-serif"
    fontSize: "40px"
    fontWeight: 600
    lineHeight: 1.15
    letterSpacing: "-0.02em"
  title:
    fontFamily: "Inter Tight, SF Pro Display, -apple-system, sans-serif"
    fontSize: "28px"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  heading:
    fontFamily: "-apple-system, SF Pro Text, Inter, sans-serif"
    fontSize: "22px"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  panel-title:
    fontFamily: "-apple-system, SF Pro Text, Inter, sans-serif"
    fontSize: "17px"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  body:
    fontFamily: "-apple-system, SF Pro Text, Inter, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.45
    letterSpacing: "0em"
  body-prominent:
    fontFamily: "-apple-system, SF Pro Text, Inter, sans-serif"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.45
  caption:
    fontFamily: "-apple-system, SF Pro Text, Inter, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.3
  label:
    fontFamily: "-apple-system, SF Pro Text, Inter, sans-serif"
    fontSize: "11px"
    fontWeight: 600
    letterSpacing: "0.08em"
  mono:
    fontFamily: "JetBrains Mono, SF Mono, ui-monospace, monospace"
    fontSize: "12px"
    fontWeight: 400
rounded:
  xs: "4px"
  sm: "8px"
  md: "14px"
  lg: "18px"
  xl: "22px"
  full: "999px"
spacing:
  "1": "4px"
  "2": "8px"
  "3": "12px"
  "4": "16px"
  "5": "20px"
  "6": "24px"
  "8": "32px"
  "10": "40px"
  "12": "48px"
  "16": "64px"
components:
  # Buttons are capsules (macOS 26): rounded-full, 26px tall, 13px side padding.
  button-primary:
    backgroundColor: "{colors.signal-fill}"
    textColor: "{colors.on-signal}"
    rounded: "{rounded.full}"
    height: "26px"
    padding: "0 13px"
  button-primary-hover:
    backgroundColor: "{colors.signal-700}"
    textColor: "{colors.on-signal}"
  button-secondary:
    backgroundColor: "{colors.paper-raised}"
    textColor: "{colors.ink-900}"
    rounded: "{rounded.full}"
    height: "26px"
    padding: "0 13px"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.ink-600}"
    rounded: "{rounded.full}"
    height: "26px"
    padding: "0 13px"
  button-danger:
    backgroundColor: "transparent"
    textColor: "{colors.danger-600}"
    rounded: "{rounded.full}"
    height: "26px"
    padding: "0 13px"
  input-text:
    backgroundColor: "{colors.paper-raised}"
    textColor: "{colors.ink-900}"
    rounded: "{rounded.sm}"
    height: "24px"
    padding: "0 8px"
  status-pill:
    backgroundColor: "{colors.ink-100}"
    textColor: "{colors.ink-600}"
    rounded: "{rounded.full}"
    height: "22px"
    padding: "0 10px 0 8px"
  workflow-chip:
    backgroundColor: "{colors.paper-raised}"
    textColor: "{colors.ink-600}"
    rounded: "{rounded.full}"
    height: "22px"
    padding: "0 8px"
  scope-row-active:
    backgroundColor: "{colors.signal-600}"
    textColor: "{colors.on-signal}"
    rounded: "{rounded.sm}"
    height: "28px"
    padding: "0 8px"
  kbd:
    backgroundColor: "{colors.paper-raised}"
    textColor: "{colors.ink-600}"
    rounded: "{rounded.xs}"
    height: "18px"
    padding: "0 5px"
  card:
    backgroundColor: "{colors.paper-raised}"
    rounded: "{rounded.md}"
    padding: "16px"
---

# Design System: meeting-pipe

## 1. Overview

**Creative North Star: "The Private Record"**

The system serves one invariant that outlasts every surface: a complete, local, trustworthy record of your meetings, kept on your own Mac, that you capture, read, search, and reason over. meeting-pipe is a menu-bar utility first, seen at only four moments (the prompt when a call is detected, the recording HUD, the done-notification, the Library), but the design is built so the record it keeps can be browsed, re-published, edited, and one day analyzed for patterns without inventing a new visual language each time. Whatever gets added stays in one register: local-first, quiet, deliberate.

Three motifs carry the whole thing. Paper: the canvas reads as a calm, cool-neutral document where transcripts and summaries live, something you would want to read, not a chrome panel; the calm-document feel now comes from layout and type, not from a warm cream tint (the porcelain retune). Hairlines, not shadows: mac-native chrome separates surfaces with 1px and 0.5px borders, reserving shadow for the few surfaces that genuinely float. One signal: a single electric teal that means capture-in-progress and earns its place by rarity, never a decorative gradient or a fill on a large surface. Density is tight and mac-native throughout, a 13px body on a compact 1.125 ramp, a 4px spacing grid living mostly on the 8 / 12 / 16 / 20 ticks, fixed window sizes. This is interface, not a content site.

The system explicitly rejects three families. It rejects the SaaS marketing cliche: no gradients, no "powered by Claude" sparkle, no decorative AI iconography, no emoji in microcopy, no celebration toasts. It rejects the generic Electron-app feel: no web-rendered chrome pretending to be a desktop app, no wrong density, no wrong fonts, no missing SF Symbols. It rejects the modern dark-glass fintech and AI-tool family: no glassy floating cards, no neon accents, no gradient borders, no "futuristic" framing. The AI is used under the hood and acknowledged in plain grey text; it is never branded and never celebrated.

**Key Characteristics:**
- Local-first as a visual commitment: the on-device option always renders at the same weight as the cloud one, never tucked into "Advanced".
- Quiet by default: literal state labels, no celebration, the summary just appears.
- Cool ink on porcelain, never pure black on pure white.
- One signal-teal accent, held to roughly 10% of any surface.
- Hairlines over shadows; a shadow means "this floats".
- Fixed window sizes and mac-native density; SF Pro at 13px is canonical.

## 2. Colors: Paper, Ink, and One Signal

A calm porcelain-and-ink neutral base, exactly one electric accent, one reserved alarm color, and a small set of functional semantic states. Nothing decorative carries color.

### Primary
- **Live-Signal Teal** (display #0E9488, bright #36C6B8 in dark): The single accent, the color of capture in progress. As the *display* tone it marks the current selection and the active tab, drives the playhead and waveform, sets teal text and dots, and tints selected rows as **Signal Wash** (#DFF3F0). The one payoff action on a surface (Record, Save, Publish) fills with the deeper **Signal Fill** (#0C7F74) so its white label clears 4.5:1 in both modes. **Deep Signal** (#0A6E64) is the fill hover and pressed state; **Bright Signal** (#14A89B) is the processing spinner and audio scrubber; **Pale Signal** (#4FC7BC) is a soft highlight. The display tone flips bright in dark so teal still reads as lit. Never a decorative gradient, never a background fill on a large surface.
- **On-Air LED** (#0FBFAC, brighter #2BE3CC in dark): The Instrument accent, used like an LED (light, not paint) and only on the capture surfaces (prompt, HUD, dropdown record rows, Library record control). It lights the meter segments, the live-level dots, the record-key ring, and the active mic waveform. Buttons, selection, and links keep the signal tokens, so the One Signal budget still holds. It is deliberately bright and, like a real LED, sits below the 3:1 UI floor on white by design; the meaning is always carried by the coral core plus a text label.

### Secondary
- **Pulse Coral** (#E5484D, #EF5A5E for the dot in dark; **Deep Pulse** #BE353A for coral text on paper): Reserved for exactly two jobs, the recording dot and the destructive confirm in dialogs. Borrowed from the universal REC red but warmer and less alarmed. It never tints a button, a background, a success state, or a workflow.

### Neutral
- **Cool Graphite** (#16181C): The primary ink for foreground text, cooler than pure black so it reads gentler against porcelain. The ramp steps down through **Slate** (#566068, muted text), **Stone** (#646C77, subtle text), and **Ash** (#838B95, faint text), then lifts into **Fog** (#ECEEF1, the hover-tint surface) and **Haze** (#F5F6F8).
- **Cool Porcelain** (#F5F6F8): The canvas, a cool off-white that reads as a calm document. **Recessed Porcelain** (#ECEEF1) sinks wells, sidebars, and toolbars; **Lifted White** (#FFFFFF) is reserved for raised cards and sheets so layering stays legible.
- **Hairline Ink**: borders are ink at low alpha, not grey fills. 1px at 10% is the default separator, 16% strengthens inputs, 0.5px Retina hairlines divide internal table rows.

### Tertiary (semantic state)
- **Verified Green** (#1F8F4E), **Caution Amber** (#B27300), **Fault Red** (#C92A2A): Functional only. They appear in inline status rows and pills, each paired with an icon and a label, never as the background of an entire toast. Each carries a wash (#DCF1E2 / #FFF1CC / #FCE4E4) for callout backgrounds. Green and amber carry a deeper 700 step (#16713D / #8A5A00) for legible text on paper; the 600 step reads in dark.

### Named Rules
**The One Signal Rule.** Live-Signal Teal appears on no more than about 10% of any surface. It marks one family of things: capture, the active path, the primary action. Its rarity is the point. Decorative teal is forbidden. The On-Air LED is part of the same budget, not a second accent.

**The Coral-Is-Recording Rule.** Pulse Coral is the recording dot and the destructive confirm, nothing else. If coral is tinting a button or a background, it is wrong.

**The No-System-Blue Rule.** The accent is teal, end-state; macOS system blue is never the accent. The focus ring is teal, `--mp-signal-600` at 32% (`--mp-focus-ring`), never the system control-accent blue.

**The Same-Level Rule.** Wherever the user routes data, the local option renders at the same visual weight as the cloud option. Local-first is shown, not hidden.

## 3. Typography

**Display Font:** Inter Tight (with SF Pro Display, -apple-system fallback)
**Body Font:** SF Pro via -apple-system / BlinkMacSystemFont (with Inter, Helvetica Neue fallback)
**Label / Mono Font:** JetBrains Mono (with SF Mono, ui-monospace fallback)

**Character:** System-native and quiet. The UI inherits SF Pro on every Mac, so chrome looks like the operating system, not a web app. Inter Tight's slight condensation gives hero and marketing moments an engineered feel without shouting. JetBrains Mono carries everything literal and machine-readable: timecodes, durations, file paths, bundle IDs, counts, and key bindings.

### Hierarchy
- **Display** (Inter Tight, 600, 56px, 1.15, -0.02em): Hero and marketing only; never in product chrome.
- **Headline** (Inter Tight, 600, 40px, 1.15, -0.02em): The largest in-product title; marketing h1.
- **Title** (Inter Tight, 600, 28px, 1.30, -0.01em): Page titles.
- **Heading** (SF Pro, 600, 22px, 1.30, -0.01em): Large in-product headers; switches to the system font.
- **Panel title** (SF Pro, 600, 17px, 1.30): The NSPanel and window title weight; Preferences and detail section headers (the 17 anchor).
- **Body** (SF Pro, 400, 13px, 1.45): Default body and button label, mac-native. Prose caps at 65 to 75ch; transcripts and dense UI may run tighter.
- **Body prominent** (SF Pro, 15px, 1.45): Reading-weight content (summary, transcript), and, at semibold, the prompt question and list/pane titles (the 15 anchor).
- **Caption** (SF Pro, 400, 12px, 1.30): Secondary labels.
- **Label / eyebrow** (SF Pro, 600, 11px, +0.08em, UPPERCASE): Sidebar and source-list section headers (LIBRARY, WORKFLOWS), the app-name eyebrow over the prompt question, and compare-column titles. A functional label, not a decorative section kicker.
- **Mono** (JetBrains Mono, 400, 12px, ss01 / cv02): Timecodes, durations, paths, identifiers, counts, and key caps.

### Named Rules
**The One-Anchor-Per-Surface Rule.** Chrome and body default to 13px, mac-native, on a compact 1.125 ramp. Each surface then earns exactly one larger anchor, and nothing else inflates: the prompt question at 15, the HUD timer at 21 (24 under the Instrument layer), list and pane titles at 15, Preferences and detail section headers at 17. This replaces the old flat thirteen-pixel rule: the anchor gives a surface a focal point without turning chrome into a content reader. Marketing surfaces may climb to display sizes; product chrome never inflates past its one anchor.

**The Mono-Numerals Rule (capture surfaces).** On the capture surfaces every timecode, duration, count, and the HUD timer is set in SF Mono, tabular; numerals elsewhere stay in the system font. Part of the Instrument control language, not a general rule.

**The No-Bold Rule.** Weights stop at semibold (600); regular (400) and medium (500) carry the rest. Bold (700 and up) is not in the system, per Apple convention.

**The System-Font-Is-Canonical Rule.** The -apple-system and SF Pro stack leads every UI surface. Inter Tight appears only at 28px and above.

## 4. Elevation

The system is flat by default and mac-native. Depth comes from hairline borders and tonal surface layering (Recessed Porcelain underneath, Cool Porcelain at rest, Lifted White raised), not from shadows. A shadow is a signal that a surface genuinely floats over the desktop. Resting cards in a list carry a 1px hairline and no shadow at all. Raised surfaces such as a sheet inside a window take the smallest ambient shadow. Floating surfaces, the HUD prompt and popovers and the menu-bar dropdown, take the full layered HUD shadow plus a translucent fill and a 0.5px stroke, mirroring `NSPanel hasShadow = true` over `NSVisualEffectView .hudWindow`.

### Shadow Vocabulary
- **Hairline** (`inset 0 0 0 0.5px rgba(22,25,29,0.10)`): The Retina divider for internal table rows and surface edges.
- **Resting / xs** (`0 1px 1.5px rgba(22,25,29,0.06)`): A barely-there lift for a single raised control.
- **Raised / sm** (`0 1px 2px rgba(22,25,29,0.08), 0 2px 6px rgba(22,25,29,0.06)`): Sheets and panels inside a window.
- **Popover / md** (`0 1px 2px rgba(22,25,29,0.08), 0 6px 16px rgba(22,25,29,0.10)`): Menus and popovers.
- **HUD float** (`0 1px 2px ..., 0 12px 32px ..., 0 24px 60px ...`): Only the meeting prompt and floating panels, always paired with the `--mp-hud-bg` fill (cool near-white at 0.78 alpha) and `backdrop-filter: blur(24px) saturate(180%)`.

### Named Rules
**The Hairlines-Not-Shadows Rule.** Surfaces at rest separate with 1px or 0.5px borders, never a drop shadow. If a resting card has a shadow, remove it.

**The Float-Earns-Blur Rule.** Translucency and backdrop blur belong only to surfaces that float over the desktop (the HUD, the menu-bar dropdown). Cards inside windows are fully opaque. Never double-blur.

**The No-Inner-Shadow Rule.** Inner shadows are forbidden everywhere.

## 5. Components

Every interactive component ships its full state set (default, hover, focus, active, disabled, and where relevant loading and error). The vocabulary is consistent surface to surface: the same button shape, the same form-control family, the same pill everywhere.

### Buttons
Confident but quiet, capsule-shaped at mac proportions (26px tall, 13px side padding), never playful.
- **Shape:** capsule (`--mp-radius-full`), the macOS 26 button language. Inputs stay rectangular at 8px; the record action is the one deliberate exception (a circular key, see below).
- **Primary:** Signal Fill (#0C7F74) fill, white label, no border. Hover darkens to Deep Signal (#0A6E64). The one payoff action per surface (Record, Save, Publish, Use candidate).
- **Secondary:** Lifted White, Cool Graphite label, 1px strong border. Hover tints to Fog (#ECEEF1). (Skip, Always for Zoom, Cancel, Keep current.)
- **Ghost:** Transparent, muted label, no border; hover fills Fog. Toolbar and icon actions.
- **Danger:** Transparent with a Fault Red label; hover fills the danger wash. Destructive only (Discard recording).
- **States:** Disabled drops to about 45% opacity. Focus is a 3px teal outer ring, always visible (the accessibility floor). Press scales the control to 0.97 over 130ms, springless; no translate, no ripple, no shadow growth.

### Inputs and form controls
- **Text input and select:** 24px tall, Lifted White, 1px strong border, 8px radius (`--mp-radius-sm`); monospace inside path fields. Focus shifts the border to Live-Signal Teal and adds the teal ring.
- **Toggle:** a 34x20 mechanical track, a fixed grey (#B9BFC7) off, Live-Signal Teal on, with a knob that snaps on a short mechanical motion (about 90 to 140ms), not a soft slide. Binary settings (Regulated mode, Auto-record).
- **Checkbox:** 14px, 4px radius (`--mp-radius-xs`), 1px border when off; teal fill with a white check when on.
- **Required states:** every control carries default, hover, focus, active, and disabled. No color-only state; a paired text or icon always accompanies the tint.

### Status pills
The workhorse state component: a rounded-full pill (19 to 22px) carrying a dot or icon plus a text label, with a tinted background, a matching border, and matching text color. Variants are Idle (Fog), live Detected (Signal Wash with a teal dot), Recording (coral wash with a pulsing coral dot), Processing (teal spinner with a stage label), Published (green wash with a check), plus Paste pending, Failed, Partial, Unpublished, and Local only. The recording dot pulses on a 1.6s opacity loop, never a scale pulse.

### Chips
- **Workflow chip:** rounded-full, a curated tonal dot (teal, deep-teal, amber, or ink, never coral) plus the workflow name, on Lifted White or Recessed Porcelain with a 0.5px border. The dot is the workflow's identity across the whole surface.
- **Filter chip:** rounded 6px, 22px, a muted label plus a chevron; opens a filter menu.
- **Mini chip:** 18px, an attribute marker on action items (owner in teal, due in amber, confidence in green), tinted with a `color-mix` of its own currentColor at about 12%.

### Cards and containers
- **Corner style:** 14px for cards (`--mp-radius-md`), 18px for panels and sheets (`--mp-radius-lg`, matching `NSPanel cornerRadius`), 22px for hero and marketing only.
- **Resting card:** Lifted White, 1px hairline, no shadow. **Floating panel:** the `--mp-hud-bg` fill, 18px radius, the HUD shadow, and a 0.5px stroke.
- **Padding:** 16 / 20 / 24, never below 12. Dense by default; do not pad to "modern web".
- **Callout** (publish-state, save-error, reprocess prompt): Recessed Porcelain or a semantic wash, a 0.5px border, and a leading state icon plus text. Never a side-stripe.

### Navigation
- **Smart-folder rail (220px):** Recessed Porcelain, uppercase functional headers (LIBRARY, WORKFLOWS), 28px scope rows. The active row is a Signal Fill teal (#0C7F74) with white text and an inverted count; an attention scope ("Needs you") carries an amber count badge. Workflow rows show the tonal dot plus a mono count.
- **Detail tab strip:** sentence-case tabs (Summary / Transcript / Audio) with a 2px Live-Signal Teal underline on the active tab; inactive tabs are muted, with no box and no pill.
- **Toolbar and breadcrumb:** a Recessed Porcelain bar with a 0.5px bottom hairline, a sidebar toggle, a `Library > Scope` breadcrumb, the idle or recording state pill, and the primary Record control.

### Signature: the Meeting Prompt (HUD)
A 600x64 horizontal pill that floats near the top of the screen (80pt inset), with `hudWindow` translucency (`blur(24px) saturate(180%)`), an 18px radius, the HUD shadow, and a 0.5px stroke. Left to right: a top-left close-x that means Skip (Notion's idiom), the app glyph (28px), a stacked uppercase app-name eyebrow over the 15px question "Record this meeting?" (the surface anchor), a live 4-bar mic waveform in the On-Air LED (level only, nothing captured yet), the workflow chip, and then the action cluster [Record (BYO) capsule] [the circular record key beside a "Record" label] [chevron capsule]. A 2px hairline along the bottom drains over the timeout (default 30s) in teal at 60% opacity, and pauses at 30% on hover so a reader never loses the prompt.

### Signature: the two-channel waveform
The audio tab stacks two channels, Mic in Live-Signal Teal above System in Stone (#646C77), each a 160-bar field tinted at about 5% of its own hue, with a single 1.5px Live-Signal Teal playhead and dot. It mirrors the stereo WAV (mic left, system right). A Mono / Stereo segmented control and a zoom chip sit in the transport row. Speaker dots in the transcript reuse a curated three-hue set (teal, amber, ink), never arbitrary hex.

### Signature: the Instrument capture controls
The capture surfaces (prompt, HUD, menu-bar record rows, Library record control) wear the Instrument control language, a deliberate set of exceptions to the quiet-chrome defaults, and only there:
- **Record key.** A 40px circular key replaces the text Record button. A concentric On-Air LED ring (inset 5px, 1.5px) rings a coral disc core; pressing gives 1.5px of downward travel and compresses the ring over 100ms. While recording the disc becomes a rounded square (the stop affordance), always beside a text label so the state is never color-only.
- **LED meters.** Voice-activity meters are discrete On-Air LED segments (3px bars, 2px gaps) that step rather than slide, not smooth bars.
- **Mono numerals.** Every timecode, duration, count, and the HUD timer is SF Mono, tabular; the HUD timer is the surface anchor (21, growing to 24 in the HUD).
- **Mechanical motion.** Keys and toggles move on short mechanical timings (90 to 140ms), no springs; the 1.6s opacity recording pulse and `prefers-reduced-motion` still hold.

## 6. Do's and Don'ts

### Do:
- **Do** hold Live-Signal Teal (#0E9488) to about 10% of any surface: primary action, current selection, active tab, playhead, capture indicator. Use Signal Wash (#DFF3F0) for selected-row tints and Signal Fill (#0C7F74) for the one filled action.
- **Do** separate resting surfaces with hairlines (1px at 10%, 0.5px Retina dividers); reserve shadow for surfaces that float.
- **Do** keep Pulse Coral (#E5484D) for the recording dot and the destructive confirm only, and the On-Air LED (#0FBFAC) for capture-surface light (meters, level dots, the record-key ring) only.
- **Do** default to SF Pro at 13px on a compact ramp, and stop weights at semibold (600).
- **Do** label every state with text or an icon, not color alone; both light and dark must be color-blind safe.
- **Do** acknowledge the AI in plain grey provenance text ("Summarized by Claude Opus 4.8, cloud"), at the same weight as the on-device line.
- **Do** keep fixed window sizes and mac-native density (prompt 600x64, preferences 480x560).
- **Do** use the uppercase label only as a functional header (sidebar sections, field labels), never as decoration.
- **Do** honor `prefers-reduced-motion`: the recording-dot loop, the panel fades, and the tint transitions degrade to crossfades or instant changes.

### Don't:
- **Don't** ship the SaaS marketing cliche: no gradients, no "powered by Claude" sparkle, no decorative AI iconography, no emoji in microcopy, no celebration toasts ("Successfully published your summary! 🎉" is the exact failure mode). Not the Notion AI, ChatGPT, or Perplexity surface aesthetic.
- **Don't** produce a generic Electron-app feel: web-rendered chrome pretending to be a desktop app, the wrong density, the wrong fonts, no SF Symbols. Not Slack, not Discord, not Linear's desktop wrapper.
- **Don't** reach for the modern dark-glass fintech and AI-tool family: glassy floating cards, neon accents, gradient borders, "futuristic" framing. Wrong even when well-crafted, for a calm menu-bar utility.
- **Don't** use macOS system blue as the accent; the accent is teal, end-state.
- **Don't** use a side-stripe (a `border-left` or `border-right` over 1px as a colored accent) on rows, cards, callouts, or alerts. Use a full hairline, a wash tint, or a leading icon instead.
- **Don't** use gradient text (`background-clip: text` on a gradient). Emphasis is weight or size, in a single solid color.
- **Don't** use glassmorphism by default; blur belongs only to surfaces that float over the desktop, and cards inside windows stay fully opaque (never double-blur).
- **Don't** use pure black (#000) or stack pure white on pure white; ink is Cool Graphite (#16181C) on Cool Porcelain (#F5F6F8).
- **Don't** add inner shadows, a scale or bounce on the recording pulse, skeleton shimmer, or decorative motion; motion conveys state only, at 120 to 280ms with no overshoot. The one control scale is the 0.97 press, springless.
- **Don't** use em-dashes as punctuation in chrome or copy; use commas, hyphens, or rewrite. Reserve the ellipsis for an in-flight state ("Processing...") or an action that opens another surface ("Preferences...").
- **Don't** let a heading stretch past its container; product windows are fixed-size, so test the real copy at the real width.
